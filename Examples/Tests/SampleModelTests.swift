import XCTest
import Foundation
import CryptoKit
@testable import IrodoriTTS

final class SampleModelTests: XCTestCase {
    @MainActor func testGeneratedReferenceRequiresConsentAndPreservesOutput() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "IrodoriSampleTests.\(UUID().uuidString)", settings = UserDefaults(suiteName: suite)!
        defer { try? files.removeItem(at: root); settings.removePersistentDomain(forName: suite) }
        let store = root.appendingPathComponent("AppSupport")
        let model = SampleModel(storeDirectory: store, settings: settings, documentsDirectory: root.appendingPathComponent("Documents"))
        let pcm = Data(repeating: 1, count: 48_000)
        model.result = SynthesisResult(pcm16: pcm, preparedText: "こんにちは。", synthesisMilliseconds: 1,
            firstPCMMilliseconds: 1, sentenceCount: 1, metrics: [["generationSeed": 42]], diagnostics: [], watermark: nil)
        model.seedMode = .fixed; model.seedText = "42"; model.caption = "やさしい声。"
        model.useGeneratedAudioAsReference()
        XCTAssertFalse(model.busy); XCTAssertEqual(model.referencePath, "")
        XCTAssertFalse(files.fileExists(atPath: store.appendingPathComponent("References").path))
        model.consent = true; model.useGeneratedAudioAsReference(); try await wait(model)
        XCTAssertNil(model.errorMessage)
        let reference = URL(fileURLWithPath: model.referencePath)
        XCTAssertEqual(reference.deletingLastPathComponent(), store.appendingPathComponent("References"))
        XCTAssertEqual(try Data(contentsOf: reference).dropFirst(44), pcm)
        XCTAssertEqual(model.result?.pcm16, pcm); XCTAssertEqual(model.fixedSeed, 42)
        XCTAssertEqual(model.caption, "やさしい声。")
        let reopened = SampleModel(storeDirectory: store, settings: settings, documentsDirectory: root.appendingPathComponent("Documents"))
        XCTAssertEqual(reopened.referencePath, reference.path); XCTAssertFalse(reopened.consent)
    }

    @MainActor func testSeedValidationAndKeepingActualGeneratedSettings() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = root.appendingPathComponent("AppSupport"), documents = root.appendingPathComponent("Documents")
        let suite = "IrodoriSampleTests.\(UUID().uuidString)", settings = UserDefaults(suiteName: suite)!
        defer { try? files.removeItem(at: root); settings.removePersistentDomain(forName: suite) }
        let modelRoot = store.appendingPathComponent("Models/model"); try fixture(at: modelRoot)
        let model = SampleModel(storeDirectory: store, settings: settings, documentsDirectory: documents)
        XCTAssertEqual(model.seedMode, .random); XCTAssertNil(try model.requestedSeed())
        model.seedMode = .fixed
        for value in ["", "-1", "1.2", "+3", "4294967296"] {
            model.seedText = value; XCTAssertFalse(model.seedIsValid); XCTAssertThrowsError(try model.requestedSeed())
        }
        model.seedText = "0"; XCTAssertEqual(try model.requestedSeed(), 0)
        model.seedText = "4294967295"; XCTAssertEqual(try model.requestedSeed(), UInt32.max)
        model.rememberGeneratedVoice(modelPath: model.modelPath, referencePath: "", caption: "落ち着いた声。", seed: 123)
        model.caption = "あとで変更した指示"; model.seedText = "456"; model.seedMode = .random
        model.keepGeneratedVoice(); try await wait(model)
        XCTAssertNil(model.errorMessage); XCTAssertEqual(model.caption, "落ち着いた声。")
        XCTAssertEqual(model.seedMode, .fixed); XCTAssertEqual(try model.requestedSeed(), 123)
        model.saveVoicePreset(named: "元のモデル"); try await wait(model)
        let saved = try XCTUnwrap(model.voicePresets.first)
        let otherRoot = store.appendingPathComponent("Models/other-version")
        try fixture(at: otherRoot, bundleVersion: "another-version")
        model.refreshInstalledModels(); model.selectModel(otherRoot.path); try await wait(model)
        XCTAssertEqual(model.modelPath, otherRoot.resolvingSymlinksInPath().path)
        model.applyVoicePreset(saved); try await wait(model)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.modelPath, modelRoot.resolvingSymlinksInPath().path)
        XCTAssertEqual(model.selectedVoicePresetID, saved.id)
        let reopened = SampleModel(storeDirectory: store, settings: settings, documentsDirectory: documents)
        XCTAssertEqual(reopened.seedMode, .fixed); XCTAssertEqual(reopened.fixedSeed, 123)
        model.rerollSeed(); XCTAssertEqual(model.seedMode, .fixed); XCTAssertNotEqual(model.fixedSeed, 123)
    }

    @MainActor func testSavedVoiceSnapshotsRestoreAndDeleteWithoutTouchingOriginal() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = root.appendingPathComponent("AppSupport"), documents = root.appendingPathComponent("Documents")
        let suite = "IrodoriSampleTests.\(UUID().uuidString)", settings = UserDefaults(suiteName: suite)!
        defer { try? files.removeItem(at: root); settings.removePersistentDomain(forName: suite) }
        let modelRoot = store.appendingPathComponent("Models/model"); try fixture(at: modelRoot)
        let source = store.appendingPathComponent("References/source.wav")
        try files.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ReferenceAudio.writeWAV(pcm16: Data(repeating: 1, count: 48_000), to: source)
        let original = try Data(contentsOf: source)
        let model = SampleModel(storeDirectory: store, settings: settings, documentsDirectory: documents)
        model.consent = true; model.referencePath = source.path; model.caption = "やさしい声。"
        model.seedMode = .fixed; model.seedText = "4294967295"
        model.saveVoicePreset(named: "お気に入り"); try await wait(model)
        XCTAssertNil(model.errorMessage); XCTAssertEqual(model.voicePresets.count, 1)
        let preset = try XCTUnwrap(model.voicePresets.first)
        let snapshot = source.deletingLastPathComponent().appendingPathComponent(try XCTUnwrap(preset.referenceFileName))
        XCTAssertNotEqual(snapshot, source); XCTAssertEqual(try Data(contentsOf: snapshot), original)
        let reopened = SampleModel(storeDirectory: store, settings: settings, documentsDirectory: documents)
        XCTAssertEqual(reopened.voicePresets.first?.id, preset.id); XCTAssertFalse(reopened.consent)
        reopened.caption = "変更"; reopened.seedText = "9"
        reopened.applyVoicePreset(preset); try await wait(reopened)
        XCTAssertNil(reopened.errorMessage); XCTAssertEqual(reopened.caption, "やさしい声。")
        XCTAssertEqual(reopened.fixedSeed, UInt32.max); XCTAssertEqual(URL(fileURLWithPath: reopened.referencePath).lastPathComponent, snapshot.lastPathComponent)
        XCTAssertFalse(reopened.consent, "Restoring a voice must not grant consent automatically")
        reopened.deleteVoicePreset(preset); try await wait(reopened)
        XCTAssertNil(reopened.errorMessage); XCTAssertTrue(reopened.voicePresets.isEmpty)
        XCTAssertFalse(files.fileExists(atPath: snapshot.path)); XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertTrue(files.fileExists(atPath: modelRoot.path))
        reopened.consent = true; reopened.referencePath = source.path
        reopened.saveVoicePreset(named: "別の参照付き"); try await wait(reopened)
        reopened.referencePath = ""; reopened.saveVoicePreset(named: "参照なし"); try await wait(reopened)
        XCTAssertEqual(reopened.voicePresets.count, 2)
        reopened.deleteReference(); try await wait(reopened)
        XCTAssertNil(reopened.errorMessage); XCTAssertEqual(reopened.voicePresets.map(\.name), ["参照なし"])
        XCTAssertFalse(files.fileExists(atPath: source.path)); XCTAssertTrue(files.fileExists(atPath: modelRoot.path))
    }

    @MainActor func testPresetNeverSilentlyUsesAnotherModelAndMissingReferenceCanBeDeleted() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = root.appendingPathComponent("AppSupport")
        let suite = "IrodoriSampleTests.\(UUID().uuidString)", settings = UserDefaults(suiteName: suite)!
        defer { try? files.removeItem(at: root); settings.removePersistentDomain(forName: suite) }
        let modelRoot = store.appendingPathComponent("Models/model"); try fixture(at: modelRoot)
        let model = SampleModel(storeDirectory: store, settings: settings, documentsDirectory: root.appendingPathComponent("Documents"))
        model.seedMode = .fixed; model.seedText = "0"; model.saveVoicePreset(named: "固定"); try await wait(model)
        let saved = try XCTUnwrap(model.voicePresets.first)
        let missing = SampleModel.VoicePreset(id: UUID(), name: "別モデル", caption: "", seed: 1,
            modelDigest: "unknown", modelTitle: "別の版", referenceFileName: nil)
        model.applyVoicePreset(missing); try await wait(model)
        XCTAssertNotNil(model.errorMessage); XCTAssertEqual(model.fixedSeed, 0)
        let escape = SampleModel.VoicePreset(id: UUID(), name: "不正な参照", caption: "", seed: 1,
            modelDigest: saved.modelDigest, modelTitle: saved.modelTitle, referenceFileName: "../outside.wav")
        model.applyVoicePreset(escape); try await wait(model)
        XCTAssertNotNil(model.errorMessage); XCTAssertEqual(model.referencePath, "")
        let source = store.appendingPathComponent("References/source.wav")
        try files.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ReferenceAudio.writeWAV(pcm16: Data(repeating: 1, count: 48_000), to: source)
        model.consent = true; model.referencePath = source.path
        model.saveVoicePreset(named: "参照付き"); try await wait(model)
        let withReference = try XCTUnwrap(model.voicePresets.last)
        let reference = source.deletingLastPathComponent().appendingPathComponent(try XCTUnwrap(withReference.referenceFileName))
        try files.removeItem(at: reference)
        model.deleteVoicePreset(withReference); try await wait(model)
        XCTAssertNil(model.errorMessage); XCTAssertEqual(model.voicePresets.count, 1)
        XCTAssertTrue(files.fileExists(atPath: source.path))
    }

    private func fixture(at root: URL, bundleVersion: String = "test") throws {
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
            ["format":"irodori-coreml-distribution-v1", "bundleVersion":bundleVersion, "files":entries])
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
