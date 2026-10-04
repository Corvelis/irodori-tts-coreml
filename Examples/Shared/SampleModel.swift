import SwiftUI
import AVFoundation
import CryptoKit
import IrodoriTTS

@MainActor final class SampleModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var text = "こんにちは。今日はいい天気なので、近くの公園まで散歩に行きましょう。"
    @Published var caption = UserDefaults.standard.string(forKey: "caption") ?? "" {
        didSet { UserDefaults.standard.set(caption, forKey: "caption") }
    }
    @Published var modelPath = UserDefaults.standard.string(forKey: "modelPath") ?? ""
    @Published var referencePath = UserDefaults.standard.string(forKey: "referencePath") ?? ""
    @Published var manifestURL = ""
    @Published var status = "モデルフォルダを選んでください。"
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

    override init() {
        store = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("IrodoriSample", isDirectory: true)
        super.init()
        try? FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        // Recorded files stay inside this app's container; only persist their basename.
        if !referencePath.isEmpty {
            referencePath = store.appendingPathComponent("References/\(URL(fileURLWithPath: referencePath).lastPathComponent)").path
        }
        if !modelPath.isEmpty && !FileManager.default.fileExists(atPath: modelPath) {
            let replacement = store.appendingPathComponent("Models/\(URL(fileURLWithPath: modelPath).lastPathComponent)")
            if FileManager.default.fileExists(atPath: replacement.path) { modelPath = replacement.path }
        }
        if !modelPath.isEmpty {
            status = referencePath.isEmpty
                ? "文章を入力して、音声を生成できます。"
                : "登録音声の利用許可を確認して、音声を生成してください。"
        }
    }

    private func work(_ body: @escaping @MainActor () async throws -> Void) {
        guard !busy, !recording else { return }
        stopPlayback()
        errorMessage = nil
        busy = true
        task = Task {
            defer { busy = false; task = nil }
            do { try await body() }
            catch is CancellationError { status = "停止しました。" }
            catch { report(error) }
        }
    }

    func importModel(_ source: URL) {
        work {
            self.status = "モデルをコピーして検証しています…"
            let allowed = source.startAccessingSecurityScopedResource()
            defer { if allowed { source.stopAccessingSecurityScopedResource() } }
            let destination = self.store.appendingPathComponent("Models/\(UUID().uuidString)")
            try await Task.detached {
                try ModelBundle.validate(at: source, verifyHashes: true)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                do { try FileManager.default.copyItem(at: source, to: destination) }
                catch { try? FileManager.default.removeItem(at: destination); throw error }
            }.value
            self.stopPlayback()
            await self.engine.release()
            self.ready = false
            self.modelPreparationMilliseconds = nil
            self.referencePreparationMilliseconds = nil
            self.modelPath = destination.path
            UserDefaults.standard.set(destination.path, forKey: "modelPath")
            self.status = "モデルを取り込みました。音声の準備を実行してください。"
        }
    }

    func download() {
        guard let url = URL(string: manifestURL), url.scheme == "https" else { status = "HTTPSのmanifest.json URLを入力してください。"; return }
        work {
            self.status = "モデルを取得しています…"
            let suffix = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24)
            let destination = self.store.appendingPathComponent("Models/download-\(suffix)")
            try await ModelDownloader().download(manifestURL: url, to: destination) { done, total, file in
                Task { @MainActor in self.status = "取得 \(done)/\(total): \(file)" }
            }
            self.stopPlayback()
            await self.engine.release()
            self.ready = false
            self.modelPreparationMilliseconds = nil
            self.referencePreparationMilliseconds = nil
            self.modelPath = destination.path
            UserDefaults.standard.set(destination.path, forKey: "modelPath")
            self.status = "取得と検証が完了しました。"
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
            UserDefaults.standard.set(destination.path, forKey: "referencePath")
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
        let message = error.localizedDescription
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
            self.referencePath = ""; UserDefaults.standard.removeObject(forKey: "referencePath")
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
                referencePath = url.path; UserDefaults.standard.set(url.path, forKey: "referencePath")
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
