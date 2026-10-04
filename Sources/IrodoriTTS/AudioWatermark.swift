import Foundation
import CoreML
import Accelerate

/// AudioSeal's 16-bit payload identifies an output family; it is not a signature.
public struct WatermarkOptions: Sendable {
    public let identifier: UInt16
    public init(identifier: UInt16 = 0x4952) { self.identifier = identifier }
}

public struct WatermarkInfo: Sendable {
    public let algorithm = "AudioSeal"
    public let identifier: UInt16
    public let processingMilliseconds: Double
}

public struct WatermarkDetection: Sendable {
    /// Fraction of analyzed samples whose positive probability exceeds 0.5.
    public let score: Double
    public let identifier: UInt16
    public let bitProbabilities: [Double]
    public var detected: Bool { score >= 0.5 }
}

// Confined to the engine's inference queue. Detection loads its model lazily.
final class WatermarkRuntime {
    static let window = 96_000, hop = 48_000, context = 24_000
    let root: URL
    let generator: MLModel
    private var detector: MLModel?
    private var compiledURLs: [URL] = []
    let fir: [Float]

    init(root: URL) throws {
        self.root = root
        let metadata = try JSONDecoder().decode(Metadata.self, from:
            Data(contentsOf: ModelBundle.safeURL("audioseal.json", under: root)))
        guard metadata.format == "irodori-audioseal-v1", metadata.sampleRate == 16_000,
              metadata.windowSamples == 32_000, metadata.fir.count == 129,
              metadata.fir.allSatisfy({ $0.isFinite }), abs(metadata.fir.reduce(0, +) - 1) < 0.001 else {
            throw IrodoriError.invalid("Invalid AudioSeal model metadata")
        }
        fir = metadata.fir
        let loaded = try Self.load("audioseal_generator", root: root)
        generator = loaded.0
        compiledURLs.append(loaded.1)
        // Compile and warm the generator during model preparation, outside synthesis RTF.
        _ = try predict([Float](repeating: 0, count: 32_000), identifier: 0x4952)
    }

    private struct Metadata: Decodable {
        let format: String
        let sampleRate: Int
        let windowSamples: Int
        let fir: [Float]
    }

    deinit { for url in compiledURLs { try? FileManager.default.removeItem(at: url) } }

    private static func load(_ name: String, root: URL) throws -> (MLModel, URL) {
        let package = try ModelBundle.safeURL(name + ".mlpackage/Manifest.json", under: root).deletingLastPathComponent()
        let compiled = try MLModel.compileModel(at: package)
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndGPU
        do { return (try MLModel(contentsOf: compiled, configuration: config), compiled) }
        catch { try? FileManager.default.removeItem(at: compiled); throw error }
    }

    private func input(_ samples: [Float]) throws -> MLMultiArray {
        guard samples.count == 32_000, samples.allSatisfy({ $0.isFinite }) else {
            throw IrodoriError.invalid("Invalid AudioSeal input")
        }
        let array = try MLMultiArray(shape: [1, 1, 32_000], dataType: .float32)
        samples.withUnsafeBufferPointer { source in
            array.dataPointer.copyMemory(from: source.baseAddress!, byteCount: samples.count * 4)
        }
        return array
    }

    private func output(_ result: MLFeatureProvider, name: String, count: Int) throws -> [Float] {
        guard let a = result.featureValue(for: name)?.multiArrayValue,
              a.dataType == .float32, a.count == count else {
            throw IrodoriError.invalid("Invalid AudioSeal output: \(name)")
        }
        var expected = 1, contiguous = true
        for i in a.shape.indices.reversed() {
            if a.shape[i].intValue > 1 { contiguous = contiguous && a.strides[i].intValue == expected }
            expected *= a.shape[i].intValue
        }
        let values = contiguous
            ? Array(UnsafeBufferPointer(start: a.dataPointer.assumingMemoryBound(to: Float.self), count: count))
            : (0..<count).map { a[$0].floatValue }
        guard values.allSatisfy({ $0.isFinite }) else { throw IrodoriError.invalid("AudioSeal returned non-finite audio") }
        return values
    }

    func predict(_ samples: [Float], identifier: UInt16) throws -> [Float] {
        let bits = try MLMultiArray(shape: [1, 16], dataType: .int32)
        let pointer = bits.dataPointer.assumingMemoryBound(to: Int32.self)
        for i in 0..<16 { pointer[i] = Int32((identifier >> i) & 1) }
        let features = try MLDictionaryFeatureProvider(dictionary: ["audio": input(samples), "message": bits])
        return try output(generator.prediction(from: features), name: "watermark", count: 32_000)
    }

    // Resample only the analysis signal and the watermark. Original 48 kHz PCM is retained.
    func downsample(_ samples: [Float]) -> [Float] {
        let half = fir.count / 2
        let padded = [Float](repeating: 0, count: half) + samples + [Float](repeating: 0, count: half + 2)
        var result = [Float](repeating: 0, count: (samples.count + 2) / 3)
        let count = result.count
        padded.withUnsafeBufferPointer { src in fir.withUnsafeBufferPointer { kernel in
            result.withUnsafeMutableBufferPointer { dst in
                vDSP_desamp(src.baseAddress!, 3, kernel.baseAddress!, dst.baseAddress!,
                            vDSP_Length(count), vDSP_Length(fir.count))
            }
        }}
        return result
    }

    func upsample(_ samples: [Float]) -> [Float] {
        let half = fir.count / 2
        var padded = [Float](repeating: 0, count: samples.count * 3 + half * 2)
        for i in samples.indices { padded[half + i * 3] = samples[i] }
        let kernel = fir.map { $0 * 3 }
        var result = [Float](repeating: 0, count: samples.count * 3)
        let count = result.count
        padded.withUnsafeBufferPointer { src in kernel.withUnsafeBufferPointer { filter in
            result.withUnsafeMutableBufferPointer { dst in
                vDSP_conv(src.baseAddress!, 1, filter.baseAddress!, 1, dst.baseAddress!, 1,
                          vDSP_Length(count), vDSP_Length(kernel.count))
            }
        }}
        return result
    }

    func detect(_ pcm16: Data) throws -> WatermarkDetection {
        let samples = try WatermarkStream.samples(pcm16)
        guard !samples.isEmpty else { throw IrodoriError.invalid("No audio to analyze") }
        if detector == nil {
            let loaded = try Self.load("audioseal_detector", root: root)
            detector = loaded.0; compiledURLs.append(loaded.1)
        }
        var positives = 0, total = 0, bitSum = [Double](repeating: 0, count: 16)
        for cursor in stride(from: 0, to: samples.count, by: Self.window) {
            let count = min(Self.window, samples.count - cursor)
            let wave = Array(samples[cursor..<(cursor + count)]) + [Float](repeating: 0, count: Self.window - count)
            let result = try detector!.prediction(from: MLDictionaryFeatureProvider(dictionary: ["audio": input(downsample(wave))]))
            let probability = try output(result, name: "probability", count: 32_000)
            let bits = try output(result, name: "message_probability", count: 16)
            let valid = (count + 2) / 3
            positives += probability.prefix(valid).filter { $0 > 0.5 }.count
            total += valid
            for i in bits.indices { bitSum[i] += Double(bits[i]) * Double(valid) }
        }
        let bits = bitSum.map { $0 / Double(total) }
        let identifier = bits.enumerated().reduce(UInt16(0)) { $0 | ($1.element > 0.5 ? UInt16(1) << $1.offset : 0) }
        return WatermarkDetection(score: Double(positives) / Double(total), identifier: identifier, bitProbabilities: bits)
    }
}

// A centered two-second window produces one second of output with 0.5 s lookahead.
// Buffered state is local to one sentence, so repeated generation cannot reuse audio.
final class WatermarkStream {
    private let runtime: WatermarkRuntime
    private let options: WatermarkOptions
    private var original: [Float] = []
    private var cursor = 0
    private(set) var pcm = Data()
    private(set) var milliseconds = 0.0
    init(runtime: WatermarkRuntime, options: WatermarkOptions) { self.runtime = runtime; self.options = options }

    static func samples(_ pcm: Data) throws -> [Float] {
        guard pcm.count.isMultiple(of: 2) else { throw IrodoriError.invalid("Invalid PCM16 audio") }
        return pcm.withUnsafeBytes { raw in
            (0..<(pcm.count / 2)).map { Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))) / 32768 }
        }
    }

    func append(_ bytes: Data, finish: Bool = false, emit: (Data) -> Void) throws {
        var mark = ProcessInfo.processInfo.systemUptime
        original += try Self.samples(bytes)
        while cursor < original.count && (finish || original.count >= cursor + WatermarkRuntime.hop + WatermarkRuntime.context) {
            let count = min(WatermarkRuntime.hop, original.count - cursor)
            let left = cursor - WatermarkRuntime.context
            var window = [Float](repeating: 0, count: WatermarkRuntime.window)
            let from = max(0, left), to = min(original.count, left + WatermarkRuntime.window)
            if from < to { window.replaceSubrange((from - left)..<(to - left), with: original[from..<to]) }
            let watermark = try runtime.upsample(runtime.predict(runtime.downsample(window), identifier: options.identifier))
            // Keep silent pauses silent. Only the watermark fades below a -60 dB RMS envelope.
            var energy = [Double](repeating: 0, count: window.count + 1)
            for i in window.indices { energy[i + 1] = energy[i] + Double(window[i]) * Double(window[i]) }
            var bytes = Data(count: count * 2)
            bytes.withUnsafeMutableBytes { raw in
                for i in 0..<count {
                    let center = WatermarkRuntime.context + i
                    let rms = sqrt(max(0, energy[center + 480] - energy[center - 480]) / 960)
                    let gain = Float(min(1, rms / 0.001))
                    let value = original[cursor + i] + watermark[center] * gain
                    let quantized = Int16(max(-32768, min(32767, (value * 32768).rounded())))
                    raw.storeBytes(of: quantized.littleEndian, toByteOffset: i * 2, as: Int16.self)
                }
            }
            pcm.append(bytes); cursor += count
            // Exclude caller work from watermark-specific timing; total synthesis includes it.
            milliseconds += (ProcessInfo.processInfo.systemUptime - mark) * 1000
            emit(bytes)
            mark = ProcessInfo.processInfo.systemUptime
        }
        let discard = max(0, cursor - WatermarkRuntime.context)
        if discard > 0 { original.removeFirst(discard); cursor -= discard }
        milliseconds += (ProcessInfo.processInfo.systemUptime - mark) * 1000
    }
}

public struct WatermarkedAudio: Sendable {
    public let pcm16: Data
    public let watermark: WatermarkInfo
    public func writeWAV(to url: URL) throws { try ReferenceAudio.writeWAV(pcm16: pcm16, to: url) }
}

/// Apply or detect AudioSeal without loading the TTS models. Inputs are 48 kHz mono PCM16.
public actor AudioWatermarker {
    private var runtime: WatermarkRuntime?
    public init() {}

    @discardableResult public func prepare(modelDirectory: URL) throws -> Double {
        let start = ProcessInfo.processInfo.systemUptime
        runtime = try WatermarkRuntime(root: modelDirectory)
        return (ProcessInfo.processInfo.systemUptime - start) * 1000
    }
    public func apply(to pcm16: Data, options: WatermarkOptions = WatermarkOptions()) throws -> WatermarkedAudio {
        guard let runtime else { throw IrodoriError.invalid("Prepare a watermark model first") }
        guard !pcm16.isEmpty else { throw IrodoriError.invalid("No audio to watermark") }
        let stream = WatermarkStream(runtime: runtime, options: options)
        try stream.append(pcm16, finish: true, emit: { _ in })
        return WatermarkedAudio(pcm16: stream.pcm, watermark: WatermarkInfo(identifier: options.identifier,
                                                                         processingMilliseconds: stream.milliseconds))
    }
    public func detect(in pcm16: Data) throws -> WatermarkDetection {
        guard let runtime else { throw IrodoriError.invalid("Prepare a watermark model first") }
        return try runtime.detect(pcm16)
    }
    public func release() { runtime = nil }
}
