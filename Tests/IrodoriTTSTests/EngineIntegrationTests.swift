import XCTest
@testable import IrodoriTTS

private final class ChunkCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ data: Data) { lock.lock(); defer { lock.unlock() }; bytes.append(data) }
    func value() -> Data { lock.lock(); defer { lock.unlock() }; return bytes }
}

final class EngineIntegrationTests: XCTestCase {
    func testFixedSeedsReproducePCMAndReportActualSeeds() async throws {
        guard let models = ProcessInfo.processInfo.environment["IRODORI_TEST_MODELS"] else {
            throw XCTSkip("Set IRODORI_TEST_MODELS for fixed-seed audio tests")
        }
        let engine = IrodoriEngine()
        try await engine.prepare(modelDirectory: URL(fileURLWithPath: models))
        let input = "こんにちは。今日はいい天気ですね。"
        let first = try await engine.synthesize(input, seed: 98_765, splitSentences: false, watermark: nil)
        let repeatAudio = try await engine.synthesize(input, seed: 98_765, splitSentences: false, watermark: nil)
        XCTAssertEqual(first.generationSeeds, [98_765])
        XCTAssertEqual(first.pcm16, repeatAudio.pcm16, "Fixed input and seed must preserve PCM in this runtime")
        let other = try await engine.synthesize(input, seed: 98_766, splitSentences: false, watermark: nil)
        XCTAssertEqual(other.generationSeeds, [98_766]); XCTAssertNotEqual(first.pcm16, other.pcm16)
        let maximum = try await engine.synthesize("はい。", seed: UInt32.max, watermark: nil)
        XCTAssertEqual(maximum.generationSeeds, [UInt32.max])
        let random = try await engine.synthesize("はい。", seed: nil, watermark: nil)
        XCTAssertEqual(random.generationSeeds.count, 1)
        let zero = try await engine.synthesize("はい。", seed: 0, watermark: nil)
        XCTAssertEqual(zero.generationSeeds, [0])
        await engine.release()
    }
    func testWholeInputKeepsSanitizationAndRejectsLimitsWithoutSplitting() async throws {
        guard let models = ProcessInfo.processInfo.environment["IRODORI_TEST_MODELS"] else {
            throw XCTSkip("Set IRODORI_TEST_MODELS for whole-input tests")
        }
        let engine = IrodoriEngine()
        try await engine.prepare(modelDirectory: URL(fileURLWithPath: models))
        let input = "**こんにちは。** 詳細は https://example.com。"
        let chunks = ChunkCollector()
        let whole = try await engine.synthesize(input, splitSentences: false) { chunks.append($0.pcm16) }
        XCTAssertEqual(whole.preparedText, SpeechText.prepare(input))
        XCTAssertEqual(whole.sentenceCount, 1)
        XCTAssertEqual(whole.metrics.count, 1)
        XCTAssertEqual(whole.pcm16, chunks.value())
        XCTAssertGreaterThan(whole.audioSeconds, 0)
        let normal = try await engine.synthesize(input)
        XCTAssertEqual(normal.sentenceCount, SpeechText.sentences(whole.preparedText).count)
        let rejected = ChunkCollector()
        do {
            _ = try await engine.synthesize(String(repeating: "これは長い文章です。", count: 200),
                                            splitSentences: false) { rejected.append($0.pcm16) }
            XCTFail("Whole-input mode must not silently split an oversized input")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("sentence exceeds model limit"))
        }
        XCTAssertTrue(rejected.value().isEmpty)
        let recovered = try await engine.synthesize("はい。", splitSentences: false)
        XCTAssertEqual(recovered.sentenceCount, 1)
        XCTAssertFalse(recovered.pcm16.isEmpty)
        await engine.release()
    }

    func testCaptionConditioningAndCache() async throws {
        guard let models = ProcessInfo.processInfo.environment["IRODORI_TEST_MODELS"] else {
            throw XCTSkip("Set IRODORI_TEST_MODELS for real-model caption tests")
        }
        let engine = IrodoriEngine()
        try await engine.prepare(modelDirectory: URL(fileURLWithPath: models))
        let caption = "落ち着いた、やさしい話し方。自然な抑揚で話す。"
        let chunks = ChunkCollector()
        let first = try await engine.synthesize("こんにちは。", caption: caption, rawText: true) { chunks.append($0.pcm16) }
        XCTAssertEqual(first.pcm16, chunks.value())
        XCTAssertEqual(first.metrics.first?["captionEnabled"], 1)
        XCTAssertEqual(first.metrics.first?["captionCacheHit"], 0)
        let cached = try await engine.synthesize("明日は公園へ行きます。", caption: caption, rawText: true)
        XCTAssertEqual(cached.metrics.first?["captionCacheHit"], 1)
        let cleared = try await engine.synthesize("こんにちは。", caption: "  ", rawText: true)
        XCTAssertEqual(cleared.metrics.first?["captionEnabled"], 0)
        let again = try await engine.synthesize("こんにちは。", caption: caption, rawText: true)
        XCTAssertEqual(again.metrics.first?["captionCacheHit"], 0)
        do {
            _ = try await engine.synthesize("こんにちは。", caption: String(repeating: "静かな声。", count: 256))
            XCTFail("Expected caption length error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("voice instruction exceeds model limit"))
        }
        let recovered = try await engine.synthesize("こんにちは。", caption: caption, rawText: true)
        XCTAssertEqual(recovered.metrics.first?["captionCacheHit"], 1)
        await engine.release()
    }

    func testReferenceLifecycleStreamingAndCancellation() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let models = env["IRODORI_TEST_MODELS"], let reference = env["IRODORI_TEST_REFERENCE"] else {
            throw XCTSkip("Set IRODORI_TEST_MODELS and IRODORI_TEST_REFERENCE for opt-in real-model tests")
        }
        let engine = IrodoriEngine()
        try await engine.prepare(modelDirectory: URL(fileURLWithPath: models))
        try await engine.registerReference(URL(fileURLWithPath: reference))
        let again = try await engine.registerReference(URL(fileURLWithPath: reference))
        XCTAssertTrue(again.cacheHit)
        let chunks = ChunkCollector()
        let audio = try await engine.synthesize("こんにちは。", rawText: true) { chunks.append($0.pcm16) }
        XCTAssertEqual(audio.pcm16, chunks.value())
        XCTAssertGreaterThan(audio.audioSeconds, 0)
        // A task cancelled before execution must produce neither success nor audio.
        let cancelled = Task { try await engine.synthesize("停止する文章です。", rawText: true) }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        try await engine.registerReference(nil)
        let recovered = try await engine.synthesize("はい。", rawText: true)
        XCTAssertFalse(recovered.pcm16.isEmpty)
        await engine.release()
        do { _ = try await engine.synthesize("はい。"); XCTFail("Expected prepare requirement") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Prepare")) }
    }
}
