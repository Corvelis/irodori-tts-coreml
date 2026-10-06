import SwiftUI
import AVFoundation
import CryptoKit
import IrodoriTTS

@MainActor final class SampleModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var text = "こんにちは。今日はいい天気なので、近くの公園まで散歩に行きましょう。"
    @Published var caption = "" {
        didSet { self.settings.set(caption, forKey: "caption") }
    }
    @Published var modelPath = ""
    @Published var referencePath = ""
    @Published var manifestURL = ""
    @Published var downloadVariant: ModelVariant = .standard
    struct InstalledModel: Identifiable, Sendable {
        let url: URL
        let information: ModelBundleInformation
        var id: String { url.path }
    }
    @Published var installedModels: [InstalledModel] = []
    @Published private(set) var downloading = false
    @Published private(set) var downloadProgress: ModelDownloadProgress?
    @Published private(set) var pendingDownloadURL = ""
    private var activeDownloadID: UUID?
    private var pausedDownload = false
    #if os(iOS)
    private var previousIdleTimerDisabled: Bool?
    #endif
    @Published var modelDetail = "現行版 約2.99 GB / 軽量INT8版 約1.96 GB"
    @Published var status = "モデルをダウンロードすると、音声を生成できます。"
    @Published var statistics = ""
    @Published var busy = false
    @Published var recording = false
    @Published var consent = false
    @Published var outputURL: URL?
    private let engine = IrodoriEngine()
    @Published var result: SynthesisResult?
    @Published var errorMessage: String?
    @Published var ready = false
    @Published var modelPreparationMilliseconds: Double?
    @Published var referencePreparationMilliseconds: Double?
    @Published var referenceCacheHit = false
    @Published var isPlaying = false
    @Published var playbackPosition = 0.0
    @Published var waveform: [Double] = []
    private var player: AVAudioPlayer?
    private var playbackTimer: Timer?
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var task: Task<Void, Never>?
    private let store: URL
    private let settings: UserDefaults
    private let documents: URL

    override convenience init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("IrodoriSample", isDirectory: true)
        self.init(storeDirectory: directory, settings: .standard)
    }
    init(storeDirectory: URL, settings: UserDefaults, documentsDirectory: URL? = nil) {
        store = storeDirectory; self.settings = settings
        documents = documentsDirectory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        super.init()
        caption = self.settings.string(forKey: "caption") ?? ""
        modelPath = self.settings.string(forKey: "modelPath") ?? ""
        referencePath = self.settings.string(forKey: "referencePath") ?? ""
        pendingDownloadURL = self.settings.string(forKey: "pendingDownloadURL") ?? ""
        try? FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        // Recorded files stay inside this app's container; only persist their basename.
        if !referencePath.isEmpty {
            referencePath = store.appendingPathComponent("References/\(URL(fileURLWithPath: referencePath).lastPathComponent)").path
        }
        if !modelPath.isEmpty && !FileManager.default.fileExists(atPath: modelPath) {
            let replacement = store.appendingPathComponent("Models/\(URL(fileURLWithPath: modelPath).lastPathComponent)")
            if FileManager.default.fileExists(atPath: replacement.path) { modelPath = replacement.path }
            else {
                let moved = documents.appendingPathComponent(URL(fileURLWithPath: modelPath).lastPathComponent)
                if FileManager.default.fileExists(atPath: moved.path) { modelPath = moved.path }
            }
        }
        if !modelPath.isEmpty {
            modelPath = URL(fileURLWithPath: modelPath).resolvingSymlinksInPath().standardizedFileURL.path
            self.settings.set(modelPath, forKey: "modelPath")
        }
        refreshInstalledModels()
        if !modelPath.isEmpty && !installedModels.contains(where: { $0.id == modelPath }) {
            modelPath = ""; self.settings.removeObject(forKey: "modelPath")
        }
        if modelPath.isEmpty, let first = installedModels.first {
            modelPath = first.id; self.settings.set(modelPath, forKey: "modelPath")
            modelDetail = first.information.description
        }
        if !pendingDownloadURL.isEmpty {
            status = "中断したダウンロードがあります。「再開」で取得済みファイルを再利用できます。"
        } else if !modelPath.isEmpty {
            status = referencePath.isEmpty
                ? "文章を入力して、音声を生成できます。"
                : "登録音声の利用許可を確認して、音声を生成してください。"
        }
    }

    func refreshInstalledModels() {
        let files = FileManager.default
        var roots = [URL]()
        for parent in [store.appendingPathComponent("Models"), documents] {
            roots += (try? files.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        }
        if !modelPath.isEmpty { roots.append(URL(fileURLWithPath: modelPath)) }
        var seen = Set<String>()
        installedModels = roots.compactMap { candidate in
            let root = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard seen.insert(root.path).inserted, let info = try? ModelBundle.information(at: root) else { return nil }
            return InstalledModel(url: root, information: info)
        }.sorted { $0.information.variant.rawValue < $1.information.variant.rawValue }
        if let current = installedModels.first(where: { $0.id == modelPath }) { modelDetail = current.information.description }
    }

    func selectModel(_ path: String) {
        guard path != modelPath else { return }
        work {
            self.status = "モデルを検証しています…"
            let url = URL(fileURLWithPath: path)
            try await Task.detached { try ModelBundle.validate(at: url, verifyHashes: true) }.value
            try Task.checkCancellation()
            await self.activateModel(url)
            self.status = "モデルを切り替えました。"
        }
    }

    private func activateModel(_ url: URL) async {
        stopPlayback()
        await engine.release()
        ready = false
        modelPreparationMilliseconds = nil
        referencePreparationMilliseconds = nil
        referenceCacheHit = false
        result = nil; waveform = []; statistics = ""; outputURL = nil
        modelPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        self.settings.set(modelPath, forKey: "modelPath")
        refreshInstalledModels()
    }

    func downloadSelectedVariant() {
        guard downloadVariant.isSupported else { status = "軽量INT8版には \(downloadVariant.minimumOS) 以降が必要です。"; return }
        manifestURL = downloadVariant.manifestURL.absoluteString
        download()
    }

    private func work(_ body: @escaping @MainActor () async throws -> Void) {
        guard !busy, !recording else { return }
        stopPlayback()
        errorMessage = nil
        busy = true
        task = Task {
            defer { busy = false; task = nil }
            do { try await body() }
            catch is CancellationError {
                status = pausedDownload ? "取得を中断しました。「再開」で取得済みファイルを再利用できます。" : "停止しました。"
            }
            catch { report(error) }
        }
    }

    func importModel(_ source: URL) {
        work {
            self.status = "モデルをコピーして検証しています…"
            let allowed = source.startAccessingSecurityScopedResource()
            defer { if allowed { source.stopAccessingSecurityScopedResource() } }
            let parent = try self.modelDirectory()
            let destination = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try await Task.detached {
                try ModelBundle.validate(at: source, verifyHashes: true)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                do { try FileManager.default.copyItem(at: source, to: destination) }
                catch { try? FileManager.default.removeItem(at: destination); throw error }
            }.value
            await self.activateModel(destination)
            self.status = "モデルを取り込みました。「生成して再生」で試せます。初回準備には時間がかかります。"
        }
    }

    var needsSetup: Bool { modelPath.isEmpty }
    var shouldShowDownload: Bool { downloading || !pendingDownloadURL.isEmpty }
    var downloadAmount: String {
        guard let value = downloadProgress, value.totalBytes > 0 else { return "モデル情報を確認中…" }
        return "\(Self.bytes(value.receivedBytes)) / \(Self.bytes(value.totalBytes))"
    }
    var downloadPhase: String {
        guard let phase = downloadProgress?.phase else { return "モデル情報を確認しています" }
        switch phase {
        case .manifest: return "モデル情報を確認しています"
        case .downloading: return "モデルをダウンロードしています"
        case .verifying: return "ファイルの整合性を検証しています"
        case .complete: return "ダウンロードと検証が完了しました"
        }
    }
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .decimal)
    }
    var downloadSpaceGuidance: String {
        "空き容量は約\(Self.bytes(downloadVariant.approximateBytes * 2 + 512 * 1024 * 1024))以上が目安です。端末向けの初回最適化には追加容量が必要な場合があります。"
    }

    private func modelDirectory() throws -> URL {
        var parent = store.appendingPathComponent("Models", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try parent.setResourceValues(values)
        return parent
    }

    private func downloadDestination(_ url: URL) throws -> URL {
        let suffix = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24)
        return try modelDirectory().appendingPathComponent("download-\(suffix)", isDirectory: true)
    }

    func download() {
        guard let url = URL(string: manifestURL), url.scheme == "https", url.host != nil else {
            report(IrodoriError.invalid("HTTPSのmanifest.json URLを入力してください。")); return
        }
        guard pendingDownloadURL.isEmpty || pendingDownloadURL == url.absoluteString else {
            report(IrodoriError.invalid("中断した取得データを再開するか、削除してから別のモデルを取得してください。")); return
        }
        work {
            let id = UUID()
            self.activeDownloadID = id; self.pausedDownload = false
            self.downloading = true; self.downloadProgress = nil
            self.pendingDownloadURL = url.absoluteString
            self.settings.set(url.absoluteString, forKey: "pendingDownloadURL")
            #if os(iOS)
            self.previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
            #endif
            defer {
                self.activeDownloadID = nil; self.downloading = false
                #if os(iOS)
                if let previous = self.previousIdleTimerDisabled { UIApplication.shared.isIdleTimerDisabled = previous }
                self.previousIdleTimerDisabled = nil
                #endif
            }
            self.status = "モデルを取得しています。完了までアプリを開いたままお待ちください。"
            let destination = try self.downloadDestination(url)
            if FileManager.default.fileExists(atPath: destination.path) {
                self.status = "保存済みのモデルを検証しています…"
                try await Task.detached { try ModelBundle.validate(at: destination, verifyHashes: true) }.value
            } else {
                do {
                    try await ModelDownloader().download(manifestURL: url, to: destination, byteProgress: { value in
                        Task { @MainActor in
                            guard self.activeDownloadID == id else { return }
                            self.downloadProgress = value
                            self.status = self.downloadPhase
                        }
                    })
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    throw error
                }
            }
            try Task.checkCancellation()
            await self.activateModel(destination)
            self.pendingDownloadURL = ""; self.settings.removeObject(forKey: "pendingDownloadURL")
            self.status = "モデルの取得が完了しました。「生成して再生」で試せます。初回準備には時間がかかります。"
        }
    }

    func retryDownload() {
        guard !pendingDownloadURL.isEmpty else { return }
        manifestURL = pendingDownloadURL; download()
    }
    func pauseDownload() {
        guard downloading else { return }
        pausedDownload = true; task?.cancel()
        status = "取得を中断しています…"
    }

    func canDeleteModel(_ installed: InstalledModel) -> Bool {
        return SampleModelStorage.owns(installed.url, parents: [store.appendingPathComponent("Models"), documents])
    }
    func deleteModel(_ installed: InstalledModel) {
        guard installedModels.contains(where: { $0.id == installed.id }), canDeleteModel(installed) else {
            report(IrodoriError.invalid("このアプリの保存済みモデルだけを削除できます。")); return
        }
        work {
            let current = self.modelPath == installed.id
            if current { await self.engine.release(); self.ready = false }
            let modelParent = self.store.appendingPathComponent("Models")
            let documents = self.documents
            try await Task.detached {
                // Recheck ownership after the async boundary before deletion.
                guard SampleModelStorage.owns(installed.url, parents: [modelParent, documents]) else {
                    throw IrodoriError.invalid("削除対象を確認できませんでした。")
                }
                try FileManager.default.removeItem(at: installed.url)
            }.value
            if current {
                self.modelPath = ""; self.settings.removeObject(forKey: "modelPath")
                self.modelPreparationMilliseconds = nil; self.referencePreparationMilliseconds = nil
                self.result = nil; self.waveform = []; self.outputURL = nil; self.statistics = ""
            }
            self.refreshInstalledModels()
            if current, let first = self.installedModels.first { await self.activateModel(first.url) }
            self.status = "保存済みモデルを削除しました。登録音声と書き出したWAVは保持されます。"
        }
    }
    func discardPendingDownload() {
        guard let url = URL(string: pendingDownloadURL), !busy else { return }
        work {
            let destination = try self.downloadDestination(url)
            let key = SHA256.hash(data: Data(url.absoluteString.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
            let staging = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent)-\(key).partial")
            if FileManager.default.fileExists(atPath: staging.path) { try FileManager.default.removeItem(at: staging) }
            self.pendingDownloadURL = ""; self.downloadProgress = nil
            self.settings.removeObject(forKey: "pendingDownloadURL")
            self.status = "中断した取得データを削除しました。"
        }
    }

    func importReference(_ source: URL) {
        guard consent else { status = "利用する声の許可を確認してください。"; return }
        work {
            let allowed = source.startAccessingSecurityScopedResource()
            defer { if allowed { source.stopAccessingSecurityScopedResource() } }
            let destination = self.store.appendingPathComponent("References/\(UUID().uuidString).\(source.pathExtension)")
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await Task.detached { _ = try ReferenceAudio.read(source); try FileManager.default.copyItem(at: source, to: destination) }.value
            self.ready = false
            self.referencePath = destination.path
            self.settings.set(destination.path, forKey: "referencePath")
            self.status = "参照音声を登録しました。"
        }
    }

    func prepare() {
        work { try await self.prepareEngine() }
    }
    private func prepareEngine() async throws {
        guard !modelPath.isEmpty else { throw IrodoriError.invalid("モデルを選択してください。") }
        if !referencePath.isEmpty && !consent { throw IrodoriError.invalid("利用する声の許可を確認してください。") }
        status = "モデルと参照音声を準備しています…"
        let load = try await engine.prepare(modelDirectory: URL(fileURLWithPath: modelPath))
        try Task.checkCancellation()
        let reference = try await engine.registerReference(referencePath.isEmpty ? nil : URL(fileURLWithPath: referencePath))
        try Task.checkCancellation()
        modelPreparationMilliseconds = load
        referencePreparationMilliseconds = reference.milliseconds
        referenceCacheHit = reference.cacheHit
        ready = true
        statistics = String(format: "モデル準備 %.0f ms / 参照 %.0f ms%@", load, reference.milliseconds, reference.cacheHit ? "（キャッシュ）" : "")
        status = "準備できました。"
    }

    func speak() {
        work {
            self.stopPlayback()
            try await self.prepareEngine()
            try Task.checkCancellation()
            self.status = "音声を生成しています…"
            // One sanitized input, one utterance. Playback begins only after the WAV is complete.
            let result = try await self.engine.synthesize(self.text, caption: self.caption, splitSentences: false)
            try Task.checkCancellation()
            let url = self.store.appendingPathComponent("generated.wav")
            try result.writeWAV(to: url); self.outputURL = url
            self.statistics += String(format: "\nRTF %.3f / 最初のPCM %.0f ms / 音声 %.2f 秒", result.rtf, result.firstPCMMilliseconds, result.audioSeconds)
            self.result = result
            self.waveform = Self.envelope(result.pcm16)
            self.playbackPosition = 0
            try self.startPlayback()
        }
    }

    func stop() {
        if downloading { pauseDownload(); return }
        task?.cancel()
        stopPlayback()
        status = busy ? "停止しています…" : "停止しました。"
    }

    var playbackFraction: Double {
        guard let duration = result?.audioSeconds, duration > 0 else { return 0 }
        return min(1, playbackPosition / duration)
    }
    var playbackTime: String {
        let elapsed = Int(playbackPosition)
        let duration = Int(result?.audioSeconds ?? 0)
        return String(format: "%d:%02d / %d:%02d", elapsed / 60, elapsed % 60, duration / 60, duration % 60)
    }

    func togglePlayback() {
        guard !busy, !recording else { return }
        if isPlaying {
            player?.pause()
            isPlaying = false
            playbackTimer?.invalidate(); playbackTimer = nil
            status = "一時停止中です。"
        } else {
            do { try startPlayback() }
            catch { report(error) }
        }
    }

    private func startPlayback() throws {
        guard let url = outputURL else { return }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)
        #endif
        if player == nil {
            player = try AVAudioPlayer(contentsOf: url)
            player?.delegate = self
        }
        guard let player else { return }
        if playbackFraction >= 1 { player.currentTime = 0; playbackPosition = 0 }
        guard player.play() else { throw IrodoriError.invalid("音声を再生できませんでした。") }
        errorMessage = nil; isPlaying = true; status = "再生中です。"
        playbackTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPlaying else { return }
                self.playbackPosition = self.player?.currentTime ?? 0
            }
        }
        playbackTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopPlayback() {
        playbackTimer?.invalidate(); playbackTimer = nil
        player?.stop(); player = nil
        isPlaying = false; playbackPosition = 0
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard self.player === player else { return }
            self.playbackTimer?.invalidate(); self.playbackTimer = nil
            self.isPlaying = false
            self.playbackPosition = self.result?.audioSeconds ?? 0
            self.status = flag ? "再生が完了しました。" : "音声の再生を完了できませんでした。"
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            guard self.player === player else { return }
            self.stopPlayback()
            self.report(error ?? IrodoriError.invalid("音声を再生できませんでした。"))
        }
    }

    func report(_ error: Error) {
        let cocoa = error as NSError
        if cocoa.domain == NSCocoaErrorDomain && cocoa.code == NSUserCancelledError { return }
        let message: String
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost:
                message = "通信を完了できませんでした。接続を確認して「再開」を押してください。取得済みファイルは再利用します。"
            default: message = urlError.localizedDescription
            }
        } else { message = error.localizedDescription }
        status = message.contains("sentence exceeds model limit")
            ? "文章がモデルの上限を超えています。短くして、もう一度生成してください。"
            : message
        errorMessage = status
    }

    // Display actual peak amplitudes from the generated PCM, without changing the audio.
    private static func envelope(_ pcm: Data) -> [Double] {
        let count = pcm.count / 2
        guard count > 0 else { return [] }
        return pcm.withUnsafeBytes { raw in
            (0..<32).map { bin in
                let start = bin * count / 32, end = (bin + 1) * count / 32
                var peak = 0.0
                for index in start..<end {
                    let sample = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))
                    peak = max(peak, abs(Double(sample)) / 32768)
                }
                return sqrt(peak)
            }
        }
    }

    func deleteReference() {
        work {
            self.stopPlayback()
            try await self.engine.clearReferenceCache()
            // Delete only this sample's imported/recorded files, never the selected original.
            let directory = self.store.appendingPathComponent("References")
            if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
            self.ready = false
            self.referencePath = ""; self.settings.removeObject(forKey: "referencePath")
            self.status = "登録音声と参照特徴キャッシュを削除しました。"
        }
    }

    func toggleRecording() {
        if recording {
            recorder?.stop(); recorder = nil; recording = false
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false)
            #endif
            guard let url = recordingURL else { return }
            do { _ = try ReferenceAudio.read(url)
                ready = false
                referencePath = url.path; self.settings.set(url.path, forKey: "referencePath")
                status = "録音を登録しました。"
            } catch { try? FileManager.default.removeItem(at: url); report(error) }
            return
        }
        guard consent, !busy else { status = "自分の声、または許可のある声を録音してください。"; return }
        work {
            let allowed = await AVCaptureDevice.requestAccess(for: .audio)
            guard allowed else { throw IrodoriError.invalid("マイクのアクセスが許可されていません。") }
            self.stopPlayback()
            #if os(iOS)
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            let url = self.store.appendingPathComponent("References/\(UUID().uuidString).wav")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            self.recorder = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
            guard self.recorder?.record() == true else { throw IrodoriError.invalid("録音を開始できません。") }
            self.recordingURL = url; self.recording = true; self.status = "録音中。3〜10秒を目安に停止してください。"
        }
    }
}

// Only direct, non-symlink children of app-owned model directories can be
// deleted. Never delete a document-picker source or a directory outside them.
enum SampleModelStorage {
    static func owns(_ url: URL, parents: [URL]) -> Bool {
        let candidate = url.standardizedFileURL
        guard (try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]))?.isSymbolicLink == false,
              (try? candidate.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return false }
        return parents.contains { parent in
            candidate.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path == parent.resolvingSymlinksInPath().standardizedFileURL.path &&
            candidate.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL.path == parent.resolvingSymlinksInPath().standardizedFileURL.path
        }
    }
}
