import Foundation

/// Model storage variants. Both use the same synthesis and reference APIs.
public enum ModelVariant: String, CaseIterable, Identifiable, Codable, Sendable {
    case standard
    case lightINT8 = "light-int8"

    public var id: String { rawValue }
    public var title: String { self == .standard ? "現行版" : "軽量INT8版" }
    public var approximateBytes: Int64 { self == .standard ? 2_991_687_169 : 1_962_744_724 }
    public var minimumOS: String { self == .standard ? "iOS 17 / macOS 14" : "iOS 18 / macOS 15" }
    public var isSupported: Bool {
        if self == .standard { return true }
        if #available(iOS 18, macOS 15, *) { return true }
        return false
    }

    /// Versioned release URL; applications may supply their own immutable manifest URL.
    public var manifestURL: URL {
        let revision = self == .standard ? "b02a670f0cb41c382844672fa8f0f03b3b9b8082" : "v0.2.0-int8"
        return URL(string: "https://huggingface.co/AILogDev/Irodori-TTS-v4.1-Small-MF-CoreML/resolve/\(revision)/manifest.json")!
    }
}

public struct ModelBundleInformation: Sendable {
    public let variant: ModelVariant
    public let bundleVersion: String
    public let fileBytes: Int64
    public var description: String {
        String(format: "%@ · 約%.2f GB", variant.title, Double(fileBytes) / 1_000_000_000)
    }
}

extension ModelBundle {
    /// Reads metadata without loading Core ML sessions or hashing large weight files.
    /// Use validate(at:verifyHashes:) when accepting newly imported files.
    public static func information(at root: URL) throws -> ModelBundleInformation {
        let value = try manifest(from: Data(contentsOf: safeURL("manifest.json", under: root)))
        let text = try JSONSerialization.jsonObject(with: Data(contentsOf: safeURL("text_encoder.json", under: root))) as? [String: Any]
        let storage = text?["weight_storage"] as? String ?? "float32"
        let variant: ModelVariant = storage.hasPrefix("int8-") ? .lightINT8 : .standard
        let bytes = try value.files.reduce(Int64(0)) { partial, file in
            let (sum, overflow) = partial.addingReportingOverflow(file.bytes)
            guard !overflow else { throw IrodoriError.invalid("Model size overflow") }
            return sum
        }
        return ModelBundleInformation(variant: variant, bundleVersion: value.bundleVersion, fileBytes: bytes)
    }
}
