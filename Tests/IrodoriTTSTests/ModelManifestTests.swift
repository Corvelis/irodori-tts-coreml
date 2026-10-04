import XCTest
@testable import IrodoriTTS

final class ModelManifestTests: XCTestCase {
    private func data(_ transform: (inout [[String: Any]]) -> Void = { _ in }) throws -> Data {
        var rows: [[String: Any]] = ModelBundle.requiredPaths.map { ["path": $0, "bytes": 1, "sha256": String(repeating: "a", count: 64)] }
        transform(&rows)
        return try JSONSerialization.data(withJSONObject: ["format": "irodori-coreml-distribution-v1", "bundleVersion": "test", "files": rows])
    }
    func testCompleteManifest() throws { XCTAssertEqual(try ModelBundle.manifest(from: data()).files.count, ModelBundle.requiredPaths.count) }
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
}
