import Foundation
import AVFoundation

public enum ReferenceAudio {
    /// Same AVAudioConverter path as the validated Local AI app.
    public static func read(_ url: URL) throws -> Data {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let seconds = Double(file.length) / format.sampleRate
        guard seconds >= 0.16, seconds <= 120 else {
            throw IrodoriError.invalid("Reference audio must be between 0.16 and 120 seconds. A clear 3–10 second clip is a useful starting point.")
        }
        guard let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)),
              let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false) else {
            throw IrodoriError.invalid("Cannot allocate reference audio")
        }
        try file.read(into: source, frameCount: AVAudioFrameCount(file.length))
        guard let converter = AVAudioConverter(from: format, to: targetFormat),
              let target = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity:
                AVAudioFrameCount(ceil(Double(source.frameLength) * 48_000 / format.sampleRate) + 4096)) else {
            throw IrodoriError.invalid("Cannot convert reference audio")
        }
        var consumed = false
        var error: NSError?
        converter.convert(to: target, error: &error) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true
            status.pointee = .haveData
            return source
        }
        if let error { throw error }
        guard let samples = target.floatChannelData?[0], target.frameLength > 0 else {
            throw IrodoriError.invalid("Reference audio is empty")
        }
        return Data(bytes: samples, count: Int(target.frameLength) * MemoryLayout<Float>.size)
    }

    public static func writeWAV(pcm16: Data, to url: URL) throws {
        guard !pcm16.isEmpty, pcm16.count.isMultiple(of: 2), pcm16.count < Int(UInt32.max) - 36 else {
            throw IrodoriError.invalid("Invalid 48 kHz mono PCM16")
        }
        var data = Data()
        func ascii(_ text: String) { data.append(contentsOf: text.utf8) }
        func u16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        ascii("RIFF"); u32(UInt32(pcm16.count) + 36); ascii("WAVEfmt "); u32(16)
        u16(1); u16(1); u32(48_000); u32(96_000); u16(2); u16(16)
        ascii("data"); u32(UInt32(pcm16.count)); data.append(pcm16)
        try data.write(to: url, options: .atomic)
    }
}
