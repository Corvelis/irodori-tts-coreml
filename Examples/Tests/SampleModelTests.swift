import XCTest
import Foundation
import CryptoKit
import IrodoriTTS

final class SampleModelTests: XCTestCase {
    private func fixture(at root: URL) throws {
        let files = FileManager.default
        var data = Dictionary(uniqueKeysWithValues: ModelBundle.requiredPaths.map { ($0, Data([1, 2, 3, 4])) })
        data["coreml-only.json"] = Data("{\"format\":\"irodori-coreml-only-v1\"}".utf8)
        for name in ModelBundle.auxiliary {
            data["\(name).json"] = try JSONSerialization.data(withJSONObject:
                ["compute_precision":"float32", "inputs":["input"], "outputs":["out":"output"]])
        }
        for (path, bytes) in data {
            let target = root.appendingPathComponent(path)
            try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: target)
        }
        let entries: [[String: Any]] = ModelBundle.requiredPaths.map { path in
            let bytes = data[path]!
            return ["path":path, "bytes":bytes.count,
                    "sha256":SHA256.hash(data:bytes).map { String(format:"%02x",$0) }.joined()]
        }
        try JSONSerialization.data(withJSONObject:
            ["format":"irodori-coreml-distribution-v1", "bundleVersion":"test", "files":entries])
            .write(to: root.appendingPathComponent("manifest.json"))
    }
    @MainActor private func wait(_ model: SampleModel) async throws {
        for _ in 0..<1000 {
            if !model.busy { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Sample operation did not finish")
    }
    @MainActor func testFreshImportDeletionAndDataBoundaries() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = root.appendingPathComponent("AppSupport"), documents = root.appendingPathComponent("Documents")
        let suite = "IrodoriSampleTests.\(UUID().uuidString)", settings = UserDefaults(suiteName: suite)!
        defer { try? files.removeItem(at: root); settings.removePersistentDomain(forName: suite) }
        try files.createDirectory(at: documents, withIntermediateDirectories: true)
        let model = SampleModel(storeDirectory: store, settings: settings, documentsDirectory: documents)
        XCTAssertTrue(model.needsSetup); XCTAssertEqual(model.downloadVariant, .standard)
        let external = root.appendingPathComponent("External/original"); try fixture(at: external)
        model.importModel(external); try await wait(model)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.installedModels.count, 1)
        XCTAssertEqual(model.modelPath, model.installedModels.first?.id)
        let imported = try XCTUnwrap(model.installedModels.first)
        XCTAssertTrue(model.canDeleteModel(imported))
        XCTAssertNotEqual(imported.url.path, external.path)
        let second = store.appendingPathComponent("Models/second"); try fixture(at: second)
        model.refreshInstalledModels()
        XCTAssertEqual(model.installedModels.count, 2, "App-container path aliases must not duplicate the selected model")
        let voice = store.appendingPathComponent("References/voice.wav")
        try files.createDirectory(at: voice.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("test recording".utf8).write(to: voice)
        let wav = store.appendingPathComponent("generated.wav"); try Data("test WAV".utf8).write(to: wav)
        let foreign = SampleModel.InstalledModel(url: external, information: try ModelBundle.information(at: external))
        XCTAssertFalse(model.canDeleteModel(foreign))
        model.deleteModel(foreign)
        XCTAssertTrue(files.fileExists(atPath: external.path))
        let symlink = store.appendingPathComponent("Models/link")
        try files.createSymbolicLink(at: symlink, withDestinationURL: external)
        XCTAssertFalse(SampleModelStorage.owns(symlink, parents: [store.appendingPathComponent("Models")]))
        try files.removeItem(at: symlink)
        model.deleteModel(imported); try await wait(model)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(files.fileExists(atPath: imported.url.path))
        XCTAssertEqual(model.modelPath, second.resolvingSymlinksInPath().standardizedFileURL.path)
        XCTAssertTrue(files.fileExists(atPath: voice.path) && files.fileExists(atPath: wav.path) && files.fileExists(atPath: external.path))
        model.deleteModel(try XCTUnwrap(model.installedModels.first)); try await wait(model)
        XCTAssertTrue(model.needsSetup); XCTAssertTrue(model.installedModels.isEmpty)
        XCTAssertNil(settings.string(forKey: "modelPath"))
    }
    @MainActor func testPendingDownloadSurvivesRelaunchAndDiscardIsScoped() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = root.appendingPathComponent("AppSupport"), documents = root.appendingPathComponent("Documents")
        let suite = "IrodoriSampleTests.\(UUID().uuidString)", settings = UserDefaults(suiteName: suite)!
        defer { try? files.removeItem(at: root); settings.removePersistentDomain(forName: suite) }
        try files.createDirectory(at: documents, withIntermediateDirectories: true)
        let url = ModelVariant.standard.manifestURL
        settings.set(url.absoluteString, forKey: "pendingDownloadURL")
        let saved = store.appendingPathComponent("Models/keep"); try fixture(at: saved)
        let suffix = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format:"%02x",$0) }.joined().prefix(24)
        let key = SHA256.hash(data: Data(url.absoluteString.utf8)).prefix(8).map { String(format:"%02x",$0) }.joined()
        let staging = store.appendingPathComponent("Models/.download-\(suffix)-\(key).partial")
        try files.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: staging.appendingPathComponent("test"))
        let model = SampleModel(storeDirectory: store, settings: settings, documentsDirectory: documents)
        XCTAssertTrue(model.shouldShowDownload)
        XCTAssertEqual(model.pendingDownloadURL, url.absoluteString)
        model.discardPendingDownload(); try await wait(model)
        XCTAssertFalse(files.fileExists(atPath: staging.path))
        XCTAssertEqual(model.pendingDownloadURL, "")
        XCTAssertNil(settings.string(forKey: "pendingDownloadURL"))
        XCTAssertTrue(files.fileExists(atPath: saved.path))
    }
}
