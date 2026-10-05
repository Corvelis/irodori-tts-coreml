import Foundation
import CryptoKit

public struct ModelManifest: Codable, Sendable {
    public struct FileEntry: Codable, Sendable {
        public let path: String
        public let bytes: Int64
        public let sha256: String
    }
    public let format: String
    public let bundleVersion: String
    public let files: [FileEntry]
}

public enum IrodoriError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

public enum ModelBundle {
    public static let auxiliary = ["text_encoder", "speaker_encoder", "duration", "context_kv_text",
                                   "context_kv_speaker", "dacvae_encode_stats", "decoder_stage_0"]
    public static let decoderAndDiT = ["dit_step_cached_mixed_linear_768", "decoder_stage_1_2d_fixed_w64",
                                      "decoder_stage_1_2d_fixed_w57", "decoder_stage_1_2d_w128",
                                      "decoder_stage_2_2d_fixed_w256", "decoder_stage_3_2d_w511"]
    public static var requiredPaths: [String] { paths(sharedDecoder: false) }
    public static var sharedDecoderRequiredPaths: [String] { paths(sharedDecoder: true) }

    private static func paths(sharedDecoder: Bool) -> [String] {
        var paths = ["coreml-only.json", "config.json", "tokenizer/tokenizer.json", "audioseal.json"]
        for name in auxiliary { paths.append("\(name).json") }
        let decoder = sharedDecoder ? ["dit_step_cached_mixed_linear_768", "decoder_stage_1_multifunction",
            "decoder_stage_2_2d_fixed_w256", "decoder_stage_3_2d_w511"] : decoderAndDiT
        for name in auxiliary + decoder + ["audioseal_generator", "audioseal_detector"] {
            paths += ["Manifest.json", "Data/com.apple.CoreML/model.mlmodel", "Data/com.apple.CoreML/weights/weight.bin"]
                .map { "\(name).mlpackage/\($0)" }
        }
        return paths
    }

    private static func components(of path: String) throws -> [Substring] {
        let pieces = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.contains("\\"), !path.contains(":"),
              pieces.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw IrodoriError.invalid("Unsafe model path: \(path)")
        }
        return pieces
    }

    public static func safeURL(_ path: String, under root: URL) throws -> URL {
        let pieces = try components(of: path)
        // Resolve the existing root once. Foundation can resolve /private/tmp
        // to /tmp for an existing directory but leave a missing child unresolved.
        // Appending validated components to the same root avoids that mismatch.
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let target = resolvedRoot.appendingPathComponent(path)
        var current = resolvedRoot
        for piece in pieces {
            current.appendPathComponent(String(piece))
            let attributes = try? FileManager.default.attributesOfItem(atPath: current.path)
            if attributes?[.type] as? FileAttributeType == .typeSymbolicLink {
                throw IrodoriError.invalid("Model files must not be symbolic links: \(path)")
            }
        }
        let prefix = resolvedRoot.path.hasSuffix("/") ? resolvedRoot.path : resolvedRoot.path + "/"
        guard target.path.hasPrefix(prefix) else {
            throw IrodoriError.invalid("Model path leaves its directory: \(path)")
        }
        return target
    }

    public static func checksum(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        // FileHandle can create autoreleased Foundation buffers. Drain each
        // chunk so verifying multi-gigabyte bundles does not retain them all.
        while try autoreleasepool(invoking: {
            guard let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty else { return false }
            hash.update(data: data)
            return true
        }) {}
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func manifest(from data: Data) throws -> ModelManifest {
        let value = try JSONDecoder().decode(ModelManifest.self, from: data)
        let required: [String]
        switch value.format {
        case "irodori-coreml-distribution-v1": required = requiredPaths
        case "irodori-coreml-distribution-v2": required = sharedDecoderRequiredPaths
        default: throw IrodoriError.invalid("Unsupported model manifest format")
        }
        guard !value.files.isEmpty,
              Set(value.files.map(\.path)).count == value.files.count,
              Set(required).isSubset(of: Set(value.files.map(\.path))),
              value.files.allSatisfy({ $0.bytes > 0 && $0.sha256.count == 64 &&
                  $0.sha256.allSatisfy { "0123456789abcdef".contains($0) } }) else {
            throw IrodoriError.invalid("Invalid or incomplete model manifest")
        }
        // Manifest paths are data; filesystem checks belong to the actual bundle root.
        for file in value.files { _ = try components(of: file.path) }
        return value
    }

    /// Structure checks are cheap. Set verifyHashes for newly downloaded/imported bundles.
    public static func validate(at root: URL, verifyHashes: Bool = false) throws {
        let coreURL = try safeURL("coreml-only.json", under: root)
        let core = try JSONSerialization.jsonObject(with: Data(contentsOf: coreURL)) as? [String: Any]
        let sharedDecoder: Bool
        switch core?["format"] as? String {
        case "irodori-coreml-only-v1": sharedDecoder = false
        case "irodori-coreml-only-v2":
            sharedDecoder = true
            guard core?["decoder_stage_1_functions"] as? [String:String] ==
                    ["fixed64":"w64", "fixed57":"w57", "flexible128":"w128"] else {
                throw IrodoriError.invalid("Invalid shared decoder functions")
            }
            if #available(iOS 18, macOS 15, *) {} else {
                throw IrodoriError.invalid("Shared decoder models require iOS 18 or macOS 15")
            }
        default: throw IrodoriError.invalid("This is not an Irodori Core ML bundle")
        }
        var required = paths(sharedDecoder: sharedDecoder)
        if let standalone = core?["flexible_decoder_stage_1_package"] {
            guard sharedDecoder, standalone as? String == "decoder_stage_1_2d_w128.mlpackage" else {
                throw IrodoriError.invalid("Invalid standalone flexible decoder package")
            }
            required += ["Manifest.json", "Data/com.apple.CoreML/model.mlmodel", "Data/com.apple.CoreML/weights/weight.bin"]
                .map { "decoder_stage_1_2d_w128.mlpackage/\($0)" }
        }
        for path in required {
            let file = try safeURL(path, under: root)
            let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            guard attrs[.type] as? FileAttributeType == .typeRegular,
                  (attrs[.size] as? NSNumber)?.int64Value ?? 0 > 0 else {
                throw IrodoriError.invalid("Missing model file: \(path)")
            }
        }
        for name in auxiliary {
            let meta = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("\(name).json"))) as? [String: Any]
            guard meta?["compute_precision"] as? String == "float32",
                  let inputs = meta?["inputs"] as? [String], !inputs.isEmpty,
                  let outputs = meta?["outputs"] as? [String: String], !outputs.isEmpty else {
                throw IrodoriError.invalid("Invalid FP32 component metadata: \(name)")
            }
        }
        if verifyHashes {
            let manifest = try manifest(from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
            guard manifest.format == (sharedDecoder ? "irodori-coreml-distribution-v2" : "irodori-coreml-distribution-v1") else {
                throw IrodoriError.invalid("Model layout and manifest format differ")
            }
            guard Set(required).isSubset(of: Set(manifest.files.map(\.path))) else {
                throw IrodoriError.invalid("Manifest does not cover every required model file")
            }
            for entry in manifest.files {
                let url = try safeURL(entry.path, under: root)
                let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
                guard size?.int64Value == entry.bytes, try checksum(url) == entry.sha256 else {
                    throw IrodoriError.invalid("Model checksum mismatch: \(entry.path)")
                }
            }
        }
    }
}
