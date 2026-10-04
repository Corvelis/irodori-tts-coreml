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
    public static var requiredPaths: [String] {
        var paths = ["coreml-only.json", "config.json", "tokenizer/tokenizer.json"]
        for name in auxiliary { paths.append("\(name).json") }
        for name in auxiliary + decoderAndDiT {
            paths += ["Manifest.json", "Data/com.apple.CoreML/model.mlmodel", "Data/com.apple.CoreML/weights/weight.bin"]
                .map { "\(name).mlpackage/\($0)" }
        }
        return paths
    }

    public static func safeURL(_ path: String, under root: URL) throws -> URL {
        let pieces = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.contains("\\"), !path.contains(":"),
              pieces.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw IrodoriError.invalid("Unsafe model path: \(path)")
        }
        let target = root.appendingPathComponent(path)
        // URL.resolvingSymlinksInPath may leave a path unresolved when its final
        // file does not exist yet (the downloader case). Check each ancestor.
        var current = root
        for piece in pieces {
            current.appendPathComponent(String(piece))
            let attributes = try? FileManager.default.attributesOfItem(atPath: current.path)
            if attributes?[.type] as? FileAttributeType == .typeSymbolicLink {
                throw IrodoriError.invalid("Model files must not be symbolic links: \(path)")
            }
        }
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard target.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(resolvedRoot) else {
            throw IrodoriError.invalid("Model path leaves its directory: \(path)")
        }
        return target
    }

    public static func checksum(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func manifest(from data: Data) throws -> ModelManifest {
        let value = try JSONDecoder().decode(ModelManifest.self, from: data)
        guard value.format == "irodori-coreml-distribution-v1", !value.files.isEmpty,
              Set(value.files.map(\.path)).count == value.files.count,
              Set(requiredPaths).isSubset(of: Set(value.files.map(\.path))),
              value.files.allSatisfy({ $0.bytes > 0 && $0.sha256.count == 64 &&
                  $0.sha256.allSatisfy { "0123456789abcdef".contains($0) } }) else {
            throw IrodoriError.invalid("Invalid or incomplete model manifest")
        }
        for file in value.files { _ = try safeURL(file.path, under: URL(fileURLWithPath: "/model")) }
        return value
    }

    /// Structure checks are cheap. Set verifyHashes for newly downloaded/imported bundles.
    public static func validate(at root: URL, verifyHashes: Bool = false) throws {
        for path in requiredPaths {
            let file = try safeURL(path, under: root)
            let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            guard attrs[.type] as? FileAttributeType == .typeRegular,
                  (attrs[.size] as? NSNumber)?.int64Value ?? 0 > 0 else {
                throw IrodoriError.invalid("Missing model file: \(path)")
            }
        }
        let core = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("coreml-only.json"))) as? [String: Any]
        guard core?["format"] as? String == "irodori-coreml-only-v1" else {
            throw IrodoriError.invalid("This is not an Irodori Core ML bundle")
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
