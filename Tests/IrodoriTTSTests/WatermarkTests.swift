import XCTest
@testable import IrodoriTTS

private final class SynthesisCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<SynthesisResult, Error>?
    func set(_ task: Task<SynthesisResult, Error>) { lock.lock(); defer { lock.unlock() }; self.task = task }
    func cancel() { lock.lock(); defer { lock.unlock() }; task?.cancel() }
}

final class WatermarkTests: XCTestCase {
    func testCancellationFromFinalWatermarkedChunkDiscardsResult() async throws {
        guard let path = ProcessInfo.processInfo.environment["IRODORI_TEST_MODELS"] else {
            throw XCTSkip("Set IRODORI_TEST_MODELS for synthesis cancellation tests")
        }
        let engine = IrodoriEngine()
        try await engine.prepare(modelDirectory: URL(fileURLWithPath: path))
        let cancellation = SynthesisCancellation()
        let task = Task {
            try await engine.synthesize("こんにちは。", splitSentences: false) { _ in cancellation.cancel() }
        }
        cancellation.set(task)
        do { _ = try await task.value; XCTFail("Cancelled output must not be returned") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected error: \(error)") }
        await engine.release()
    }

    func testRequiresPreparationAndValidPCM() async throws {
        let marker = AudioWatermarker()
        do { _ = try await marker.apply(to: Data([0, 0])); XCTFail("Expected prepare requirement") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Prepare")) }
        XCTAssertThrowsError(try WatermarkStream.samples(Data([0])))
        XCTAssertEqual(try WatermarkStream.samples(Data([0, 128, 255, 127])), [-1, Float(32767) / 32768])
        XCTAssertEqual(WatermarkOptions().identifier, 0x4952)
    }

    func testStreamingAndCompletedAudioAgreeAcrossChunkSizesAndRepeatedCalls() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["IRODORI_TEST_MODELS"], let fixture = env["IRODORI_TEST_WATERMARK_PCM"] else {
            throw XCTSkip("Set IRODORI_TEST_MODELS and IRODORI_TEST_WATERMARK_PCM for AudioSeal model tests")
        }
        let bytes = try Data(contentsOf: URL(fileURLWithPath: fixture))
        let runtime = try WatermarkRuntime(root: URL(fileURLWithPath: path))
        var expected: Data?
        for size in [bytes.count, 14_002, 73_998] {
            let stream = WatermarkStream(runtime: runtime, options: WatermarkOptions())
            var emitted = Data()
            for offset in stride(from: 0, to: bytes.count, by: size) {
                try stream.append(bytes.subdata(in: offset..<min(bytes.count, offset + size))) { emitted.append($0) }
            }
            try stream.append(Data(), finish: true) { emitted.append($0) }
            XCTAssertEqual(stream.pcm, emitted)
            XCTAssertEqual(stream.pcm.count, bytes.count)
            XCTAssertNotEqual(stream.pcm, bytes)
            if let expected { XCTAssertEqual(stream.pcm, expected) }
            expected = stream.pcm
        }
        let marked = try XCTUnwrap(expected)
        let detection = try runtime.detect(marked)
        XCTAssertGreaterThan(detection.score, 0.9)
        XCTAssertEqual(detection.identifier, 0x4952)
        XCTAssertLessThan(try runtime.detect(bytes).score, 0.05)
        // A tail shorter than one window must be flushed without truncation or padding in output.
        let short = bytes.prefix(2_002)
        let stream = WatermarkStream(runtime: runtime, options: WatermarkOptions(identifier: 123))
        try stream.append(Data(short), finish: true, emit: { _ in })
        XCTAssertEqual(stream.pcm.count, short.count)
        let silence = WatermarkStream(runtime: runtime, options: WatermarkOptions())
        let zeros = Data(count: 96_000)
        try silence.append(zeros, finish: true, emit: { _ in })
        XCTAssertEqual(silence.pcm, zeros)
    }
}
