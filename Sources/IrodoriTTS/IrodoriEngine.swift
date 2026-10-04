import Foundation
import CryptoKit
import IrodoriNative

public struct PCMChunk: Sendable {
    public let pcm16: Data
    public let sampleRate = 48_000
    public let sequence: Int
}

public struct SynthesisResult: Sendable {
    public let pcm16: Data
    public let preparedText: String
    public let synthesisMilliseconds: Double
    public let firstPCMMilliseconds: Double
    public let sentenceCount: Int
    public let metrics: [[String: Double]]
    public let diagnostics: [[String: String]]
    public let watermark: WatermarkInfo?
    public var audioSeconds: Double { Double(pcm16.count) / 96_000 }
    public var rtf: Double { synthesisMilliseconds / 1000 / max(audioSeconds, 0.000001) }
    public func writeWAV(to url: URL) throws { try ReferenceAudio.writeWAV(pcm16: pcm16, to: url) }
}

public struct ReferenceRegistration: Sendable {
    public let milliseconds: Double
    public let cacheHit: Bool
}

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func check() throws { if cancelled { throw CancellationError() } }
}

/// Own one engine per conversation. All native state is confined to its serial queue.
public final class IrodoriEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "IrodoriTTS.inference", qos: .userInitiated)
    private let native = IrodoriLocalBridge()
    private var modelURL: URL?
    private var referenceDigest: SHA256.Digest?
    private var watermarker: WatermarkRuntime?

    public init() {}

    private func perform<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                autoreleasepool {
                    do { continuation.resume(returning: try body()) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        }
    }

    /// Returns initial model preparation time, separately from synthesis RTF.
    @discardableResult public func prepare(modelDirectory: URL) async throws -> Double {
        try await perform {
            let url = modelDirectory.standardizedFileURL
            if self.modelURL == url { return 0 }
            try ModelBundle.validate(at: url)
            let start = ProcessInfo.processInfo.systemUptime
            self.modelURL = nil
            self.referenceDigest = nil
            self.watermarker = nil
            try self.native.loadModel(atPath: url.path, useCoreML: true, fastDiT: true)
            self.watermarker = try WatermarkRuntime(root: url)
            self.modelURL = url
            return (ProcessInfo.processInfo.systemUptime - start) * 1000
        }
    }

    @discardableResult public func registerReference(_ url: URL?) async throws -> ReferenceRegistration {
        try await perform {
            guard self.modelURL != nil else { throw IrodoriError.invalid("Prepare a model first") }
            let start = ProcessInfo.processInfo.systemUptime
            let data = try url.map(ReferenceAudio.read) ?? Data()
            let digest = SHA256.hash(data: data)
            if self.referenceDigest == digest {
                return ReferenceRegistration(milliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1000, cacheHit: true)
            }
            self.referenceDigest = nil
            try self.native.setReferencePcmData(data)
            self.referenceDigest = digest
            return ReferenceRegistration(milliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1000,
                                         cacheHit: self.native.referenceCacheHit)
        }
    }

    /// Callback runs on the inference queue. Dispatch UI work to the main actor.
    /// Set splitSentences to false to synthesize the sanitized input as one utterance.
    /// In that mode length-limit errors are returned without splitting or truncating.
    /// Cancellation discards subsequent chunks; an in-flight Core ML prediction finishes first.
    public func synthesize(_ text: String, caption: String = "", rawText: Bool = false, splitSentences: Bool = true,
                           watermark: WatermarkOptions? = WatermarkOptions(),
                           onChunk: (@Sendable (PCMChunk) -> Void)? = nil) async throws -> SynthesisResult {
        let cancellation = CancellationFlag()
        return try await withTaskCancellationHandler(operation: {
            try await self.perform {
                try cancellation.check()
                guard self.modelURL != nil else { throw IrodoriError.invalid("Prepare a model first") }
                let prepared = rawText ? text : SpeechText.prepare(text)
                let shouldSplit = splitSentences && !rawText
                var pending = shouldSplit ? SpeechText.sentences(prepared) : [prepared]
                guard !prepared.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !pending.isEmpty else {
                    throw IrodoriError.invalid("No speakable text")
                }
                let start = ProcessInfo.processInfo.systemUptime
                var pcm = Data(), sequence = 0, count = 0
                var synthesisMs = 0.0, firstMs = -1.0
                var watermarkMs = 0.0
                var metrics: [[String: Double]] = [], diagnostics: [[String: String]] = []
                while !pending.isEmpty {
                    try cancellation.check()
                    let sentence = pending.removeFirst()
                    var emitted = false
                    var received = false
                    var callbackError: Error?
                    let stream = watermark.map { WatermarkStream(runtime: self.watermarker!, options: $0) }
                    let emit: (Data) -> Void = { bytes in
                        if cancellation.cancelled { return }
                        emitted = true
                        if firstMs < 0 { firstMs = (ProcessInfo.processInfo.systemUptime - start) * 1000 }
                        onChunk?(PCMChunk(pcm16: bytes, sequence: sequence))
                        sequence += 1
                    }
                    let sentenceStart = ProcessInfo.processInfo.systemUptime
                    do {
                        let output = try self.native.synthesizeText(sentence, caption: caption, onPcm: { bytes in
                            if cancellation.cancelled || callbackError != nil { return }
                            received = true
                            do {
                                if let stream { try stream.append(bytes, emit: emit) }
                                else { emit(bytes) }
                            } catch { callbackError = error }
                        })
                        try cancellation.check()
                        if let error = callbackError { throw error }
                        guard let bytes = output["pcm16"] as? Data, !bytes.isEmpty else {
                            throw IrodoriError.invalid("No audio returned")
                        }
                        if let stream {
                            try stream.append(received ? Data() : bytes, finish: true, emit: emit)
                            guard stream.pcm.count == bytes.count else { throw IrodoriError.invalid("Watermark output length differs from generated audio") }
                            pcm.append(stream.pcm)
                            watermarkMs += stream.milliseconds
                        } else {
                            if !received { emit(bytes) }
                            pcm.append(bytes)
                        }
                        try cancellation.check()
                        count += 1
                        synthesisMs += (ProcessInfo.processInfo.systemUptime - sentenceStart) * 1000
                        let m = output["metrics"] as? [String: Any] ?? [:]
                        metrics.append(m.compactMapValues { ($0 as? NSNumber)?.doubleValue })
                        diagnostics.append(m.compactMapValues { $0 as? String })
                    } catch {
                        synthesisMs += (ProcessInfo.processInfo.systemUptime - sentenceStart) * 1000
                        // The engine rejects length limits before producing PCM. Never replay emitted audio.
                        if shouldSplit && !emitted && error.localizedDescription.contains("sentence exceeds model limit"),
                           let parts = SpeechText.bisect(sentence) {
                            pending.insert(contentsOf: parts, at: 0)
                        } else { throw error }
                    }
                }
                return SynthesisResult(pcm16: pcm, preparedText: prepared, synthesisMilliseconds: synthesisMs,
                    firstPCMMilliseconds: firstMs, sentenceCount: count, metrics: metrics, diagnostics: diagnostics,
                    watermark: watermark.map { WatermarkInfo(identifier: $0.identifier, processingMilliseconds: watermarkMs) })
            }
        }, onCancel: { cancellation.cancel() })
    }

    /// Analyze 48 kHz mono PCM16; score is evidence of a watermark, not proof of identity.
    public func detectWatermark(in pcm16: Data) async throws -> WatermarkDetection {
        try await perform {
            guard let runtime = self.watermarker else { throw IrodoriError.invalid("Prepare a model first") }
            return try runtime.detect(pcm16)
        }
    }

    public func clearReferenceCache() async throws {
        try await perform {
            self.native.clearReference()
            self.referenceDigest = nil
            let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: false)
            let directory = caches.appendingPathComponent("irodori-reference-coreml-v1")
            if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        }
    }

    public func release() async {
        _ = try? await perform { self.native.releaseResources(); self.modelURL = nil; self.referenceDigest = nil; self.watermarker = nil }
    }
}
