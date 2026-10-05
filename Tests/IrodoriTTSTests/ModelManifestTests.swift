import XCTest
@testable import IrodoriTTS

final class ModelManifestTests: XCTestCase {
    private func data(_ transform: (inout [[String: Any]]) -> Void = { _ in }) throws -> Data {
        var rows: [[String: Any]] = ModelBundle.requiredPaths.map { ["path": $0, "bytes": 1, "sha256": String(repeating: "a", count: 64)] }
        transform(&rows)
        return try JSONSerialization.data(withJSONObject: ["format": "irodori-coreml-distribution-v1", "bundleVersion": "test", "files": rows])
    }
    func testCompleteManifest() throws { XCTAssertEqual(try ModelBundle.manifest(from: data()).files.count, ModelBundle.requiredPaths.count) }
    func testPublishedURLsKeepStandardAndNestedINT8Separate() {
        let standard = ModelVariant.standard.manifestURL
        let light = ModelVariant.lightINT8.manifestURL
        XCTAssertEqual(standard.absoluteString,
            "https://huggingface.co/AILogDev/Irodori-TTS-v4.1-Small-MF-CoreML/resolve/b02a670f0cb41c382844672fa8f0f03b3b9b8082/manifest.json")
        XCTAssertEqual(light.absoluteString,
            "https://huggingface.co/AILogDev/Irodori-TTS-v4.1-Small-MF-CoreML/resolve/v0.2.0-int8/int8/manifest.json")
        let relative = "tokenizer/tokenizer.json"
        XCTAssertEqual(light.deletingLastPathComponent().appendingPathComponent(relative).path,
            "/AILogDev/Irodori-TTS-v4.1-Small-MF-CoreML/resolve/v0.2.0-int8/int8/tokenizer/tokenizer.json")
        XCTAssertFalse(standard.deletingLastPathComponent().appendingPathComponent(relative).path.contains("/int8/"))
    }
    func testVariantInformationUsesManifestBytesAndTextStorage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try data().write(to: root.appendingPathComponent("manifest.json"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("text_encoder.json"))
        var info = try ModelBundle.information(at: root)
        XCTAssertEqual(info.variant, .standard)
        XCTAssertEqual(info.fileBytes, Int64(ModelBundle.requiredPaths.count))
        try Data("{\"weight_storage\":\"int8-symmetric-block128-float32-compute\"}".utf8).write(to: root.appendingPathComponent("text_encoder.json"))
        info = try ModelBundle.information(at: root)
        XCTAssertEqual(info.variant, .lightINT8)
        XCTAssertEqual(info.bundleVersion, "test")
    }
    func testSharedDecoderManifestRequiresItsOwnLayout() throws {
        let rows = ModelBundle.sharedDecoderRequiredPaths.map {
            ["path": $0, "bytes": 1, "sha256": String(repeating: "a", count: 64)] as [String: Any]
        }
        var object: [String: Any] = ["format": "irodori-coreml-distribution-v2", "bundleVersion": "test", "files": rows]
        XCTAssertEqual(try ModelBundle.manifest(from: JSONSerialization.data(withJSONObject: object)).files.count, rows.count)
        object["files"] = ModelBundle.requiredPaths.map {
            ["path": $0, "bytes": 1, "sha256": String(repeating: "a", count: 64)] as [String: Any]
        }
        XCTAssertThrowsError(try ModelBundle.manifest(from: JSONSerialization.data(withJSONObject: object)))
        object["format"] = "irodori-coreml-distribution-v3"
        XCTAssertThrowsError(try ModelBundle.manifest(from: JSONSerialization.data(withJSONObject: object)))
    }
    func testIncompleteDuplicateOrMalformedManifest() throws {
        let variants: [(inout [[String: Any]]) -> Void] = [
            { $0.removeFirst() }, { $0.append($0[0]) },
            { $0[0]["sha256"] = "not-a-checksum" }, { $0[0]["bytes"] = -1 },
            { $0.append(["path": "../outside", "bytes": 1, "sha256": String(repeating: "a", count: 64)]) }
        ]
        for edit in variants { XCTAssertThrowsError(try ModelBundle.manifest(from: data(edit))) }
    }
    func testSymlinkEscape() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: root.deletingLastPathComponent())
        XCTAssertThrowsError(try ModelBundle.safeURL("escape/outside", under: root))
    }
    func testStandaloneFlexibleDecoderMustBePresentAndAllowed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ModelBundle.sharedDecoderRequiredPaths {
            let target = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1]).write(to: target)
        }
        for name in ModelBundle.auxiliary {
            try JSONSerialization.data(withJSONObject: ["compute_precision": "float32", "inputs": ["input"], "outputs": ["out": "output"]])
                .write(to: root.appendingPathComponent("\(name).json"))
        }
        var core: [String: Any] = ["format": "irodori-coreml-only-v2",
            "decoder_stage_1_functions": ["fixed64":"w64", "fixed57":"w57", "flexible128":"w128"],
            "flexible_decoder_stage_1_package": "decoder_stage_1_2d_w128.mlpackage"]
        func writeCore() throws { try JSONSerialization.data(withJSONObject: core).write(to: root.appendingPathComponent("coreml-only.json")) }
        try writeCore()
        XCTAssertThrowsError(try ModelBundle.validate(at: root))
        for path in ["Manifest.json", "Data/com.apple.CoreML/model.mlmodel", "Data/com.apple.CoreML/weights/weight.bin"] {
            let target = root.appendingPathComponent("decoder_stage_1_2d_w128.mlpackage/\(path)")
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1]).write(to: target)
        }
        try ModelBundle.validate(at: root)
        core["flexible_decoder_stage_1_package"] = "../other.mlpackage"
        try writeCore()
        XCTAssertThrowsError(try ModelBundle.validate(at: root))
    }
}
