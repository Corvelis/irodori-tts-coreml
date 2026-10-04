import Foundation
import AVFoundation

@MainActor final class PCMPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
    init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }
    func append(_ data: Data) throws {
        if !engine.isRunning {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
            #endif
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(data.count / 2)),
              let samples = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = buffer.frameCapacity
        data.withUnsafeBytes { raw in
            for i in 0..<Int(buffer.frameLength) {
                let value = raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)
                samples[i] = Float(Int16(littleEndian: value)) / 32768
            }
        }
        if !engine.isRunning { try engine.start() }
        node.scheduleBuffer(buffer)
        if !node.isPlaying { node.play() }
    }
    func stop() { node.stop(); engine.stop() }
}
