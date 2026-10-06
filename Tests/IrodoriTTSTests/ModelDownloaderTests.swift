import XCTest
import CryptoKit
@testable import IrodoriTTS

private actor FixtureTransport: ModelDownloadTransport {
    let manifestData: Data
    var files: [String: Data]
    var requests: [String: Int] = [:]
    var failure: String?
    var corrupt: String?
    var delay: UInt64 = 0
    var requested: (@Sendable () -> Void)?
    init(manifest: Data, files: [String: Data]) { manifestData = manifest; self.files = files }
    func manifest(from url: URL) async throws -> Data { manifestData }
    func file(from url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        let path = String(url.path.dropFirst("/models/".count))
        requests[path, default: 0] += 1
        requested?()
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        if failure == path { throw URLError(.networkConnectionLost) }
        var data = try XCTUnwrap(files[path])
        if corrupt == path { data[0] ^= 1 }
        progress(Int64(data.count / 2)); progress(Int64(data.count))
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: temporary)
        return temporary
    }
    func setFailure(_ path: String?) { failure = path }
    func setCorruption(_ path: String?) { corrupt = path }
    func setDelay(_ value: UInt64, requested: @escaping @Sendable () -> Void) {
        delay = value; self.requested = requested
    }
    func count(_ path: String) -> Int { requests[path, default: 0] }
    func requestCount() -> Int { requests.values.reduce(0, +) }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ModelDownloadProgress] = []
    func append(_ value: ModelDownloadProgress) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    func snapshot() -> [ModelDownloadProgress] { lock.lock(); defer { lock.unlock() }; return values }
}

final class ModelDownloaderTests: XCTestCase {
    private let url = URL(string: "https://example.invalid/models/manifest.json")!
    private func fixture() throws -> FixtureTransport {
        var files = Dictionary(uniqueKeysWithValues: ModelBundle.requiredPaths.map { ($0, Data([1, 2, 3, 4])) })
        files["coreml-only.json"] = Data("{\"format\":\"irodori-coreml-only-v1\"}".utf8)
        for name in ModelBundle.auxiliary {
            files["\(name).json"] = try JSONSerialization.data(withJSONObject:
                ["compute_precision": "float32", "inputs": ["input"], "outputs": ["out": "output"]])
        }
        let entries: [[String: Any]] = ModelBundle.requiredPaths.map { path in
            let data = files[path]!
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return ["path": path, "bytes": data.count, "sha256": hash]
        }
        let manifest = try JSONSerialization.data(withJSONObject:
            ["format": "irodori-coreml-distribution-v1", "bundleVersion": "fixture", "files": entries])
        return FixtureTransport(manifest: manifest, files: files)
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    func testByteProgressAndVerifiedInstall() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("model")
        let record = ProgressRecorder()
        let downloader = ModelDownloader(transport: try fixture(), capacity: { _ in Int64.max })
        try await downloader.download(manifestURL: url, to: destination, byteProgress: { record.append($0) })
        try ModelBundle.validate(at: destination, verifyHashes: true)
        let values = record.snapshot()
        XCTAssertTrue(values.contains { $0.phase == .downloading && $0.receivedBytes > 0 && $0.fractionCompleted < 1 })
        XCTAssertTrue(values.contains { $0.phase == .verifying })
        XCTAssertEqual(values.last?.phase, .complete)
        XCTAssertEqual(values.last?.fractionCompleted, 1)
        XCTAssertEqual(values.last?.completedFiles, ModelBundle.requiredPaths.count)
        XCTAssertEqual(values.map(\.receivedBytes), values.map(\.receivedBytes).sorted())
    }
    func testRetryReusesOnlyVerifiedFiles() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("model")
        let transport = try fixture()
        let downloader = ModelDownloader(transport: transport, capacity: { _ in Int64.max })
        await transport.setFailure("tokenizer/tokenizer.json")
        do { try await downloader.download(manifestURL: url, to: destination); XCTFail("Expected failure") }
        catch is URLError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let staging = try ModelDownloader.stagingDirectory(manifestURL: url, destination: destination)
        // Same-size corruption must not be accepted on retry.
        let core = staging.appendingPathComponent("coreml-only.json")
        var bytes = try Data(contentsOf: core); bytes[0] ^= 1; try bytes.write(to: core)
        await transport.setFailure(nil)
        try await downloader.download(manifestURL: url, to: destination)
        let coreRequests = await transport.count("coreml-only.json")
        let configRequests = await transport.count("config.json")
        XCTAssertEqual(coreRequests, 2)
        XCTAssertEqual(configRequests, 1)
        try ModelBundle.validate(at: destination, verifyHashes: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }
    func testCorruptTransferNeverPublishesBundle() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("model")
        let transport = try fixture(); await transport.setCorruption("config.json")
        let downloader = ModelDownloader(transport: transport, capacity: { _ in Int64.max })
        do { try await downloader.download(manifestURL: url, to: destination); XCTFail("Expected checksum error") }
        catch is IrodoriError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        await transport.setCorruption(nil)
        try await downloader.download(manifestURL: url, to: destination)
        let reused = await transport.count("coreml-only.json")
        XCTAssertEqual(reused, 1)
    }
    func testInsufficientCapacityStopsBeforeFileTransfer() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = try fixture()
        let downloader = ModelDownloader(transport: transport, capacity: { _ in 0 })
        do { try await downloader.download(manifestURL: url, to: root.appendingPathComponent("model")); XCTFail("Expected capacity error") }
        catch { XCTAssertTrue(error.localizedDescription.contains("空き容量")) }
        let requests = await transport.requestCount()
        XCTAssertEqual(requests, 0)
    }
    func testCancellationDoesNotPublishAndAllowsRetry() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("model")
        let transport = try fixture()
        let requested = expectation(description: "request started")
        await transport.setDelay(10_000_000_000) { requested.fulfill() }
        let downloader = ModelDownloader(transport: transport, capacity: { _ in Int64.max })
        let task = Task { try await downloader.download(manifestURL: url, to: destination) }
        await fulfillment(of: [requested], timeout: 2)
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        await transport.setDelay(0, requested: {})
        try await downloader.download(manifestURL: url, to: destination)
        try ModelBundle.validate(at: destination, verifyHashes: true)
    }
    func testPinnedHostTransportProgressAndChecksum() async throws {
        guard ProcessInfo.processInfo.environment["IRODORI_TEST_NETWORK"] == "1" else {
            throw XCTSkip("Set IRODORI_TEST_NETWORK=1 for the public-host transport smoke test")
        }
        let transport = URLModelDownloadTransport()
        let manifestURL = ModelVariant.standard.manifestURL
        let data = try await transport.manifest(from: manifestURL)
        let manifest = try ModelBundle.manifest(from: data)
        let entry = try XCTUnwrap(manifest.files.first { $0.bytes >= 32_768 && $0.bytes < 2_000_000 })
        let amounts = ByteRecorder()
        let file = try await transport.file(from: manifestURL.deletingLastPathComponent().appendingPathComponent(entry.path)) {
            amounts.append($0)
        }
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value, entry.bytes)
        XCTAssertEqual(try ModelBundle.checksum(file), entry.sha256)
        XCTAssertTrue(amounts.hasPositiveProgress())
    }
    func testOverflowAndManifestSpecificStaging() throws {
        XCTAssertThrowsError(try ModelDownloader.requiredCapacity(remaining: Int64.max, total: 1))
        let first = try ModelDownloader.stagingDirectory(manifestURL: url, destination: URL(fileURLWithPath: "/tmp/model"))
        let second = try ModelDownloader.stagingDirectory(manifestURL: URL(string: "https://example.invalid/other/manifest.json")!, destination: URL(fileURLWithPath: "/tmp/model"))
        XCTAssertNotEqual(first, second)
        XCTAssertThrowsError(try ModelDownloader.stagingDirectory(manifestURL: URL(string: "http://example.invalid/manifest.json")!, destination: URL(fileURLWithPath: "/tmp/model")))
    }
}

private final class ByteRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var positive = false
    func append(_ value: Int64) { lock.lock(); defer { lock.unlock() }; positive = positive || value > 0 }
    func hasPositiveProgress() -> Bool { lock.lock(); defer { lock.unlock() }; return positive }
}
