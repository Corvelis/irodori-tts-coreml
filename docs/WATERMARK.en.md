# Audio watermarking

[日本語](WATERMARK.md) · [Getting started](README.en.md)

The SDK, CLI and samples apply **AudioSeal watermarking by default**. Streamed PCM, completed PCM and exported WAV contain the same watermark. Analyze the signal with the detector to identify it.

## SDK

The model bundle must include `audioseal_generator.mlpackage`, `audioseal_detector.mlpackage` and `audioseal.json`.

```swift
let audio = try await engine.synthesize("こんにちは。今日はいい天気ですね。")
try audio.writeWAV(to: outputURL)
let detection = try await engine.detectWatermark(in: audio.pcm16)
print(detection.detected, detection.score, detection.identifier)
```

The default 16-bit identifier is **18770 (0x4952)**, stored least significant bit first. Customize it with `watermark: WatermarkOptions(identifier: 1234)`. Disable watermarking for comparisons with `watermark: nil`. Avoid applying a second watermark to already marked audio.

To apply or detect a watermark without loading the TTS models:

```swift
let marker = AudioWatermarker()
try await marker.prepare(modelDirectory: models)
let marked = try await marker.apply(to: originalPCM16)
let detection = try await marker.detect(in: marked.pcm16)
try marked.writeWAV(to: outputURL)
await marker.release()
```

Input is headerless little-endian PCM16, 48 kHz, mono. `ReferenceAudio.read` returns Float32, which must not be passed directly to these APIs. `score` is the fraction of analyzed samples with positive detection probability above 0.5. `detected` is true at score >= 0.5. `bitProbabilities` contains the 16 message-bit probabilities; `identifier` thresholds them at 0.5. Ignore the identifier when no watermark is detected.

## CLI

```sh
.build/release/irodori synthesize --models ./Models --text 'こんにちは。今日はいい天気ですね。' --output ./speech.wav
.build/release/irodori detect-watermark --models ./Models --input ./speech.wav
```

Use `--watermark-id 1234` to change the identifier or `--no-watermark` to disable watermarking. Reports include the algorithm, identifier and watermark processing time for each run.

## Timing, quality and limits

Original 48 kHz audio is retained. A resampled 16 kHz analysis signal is used to generate the watermark; only the watermark is resampled back and added. TTS weights and generation steps are unchanged. The watermark fades near silence, and exact silence stays silent.

A two-second window emits its central one-second region. Streaming uses 0.5 seconds of audio lookahead; this is an audio duration, not a fixed wall-clock wait. First PCM may arrive later than with watermarking disabled. The GUI still synthesizes the whole input and plays the completed WAV.

Synthesis time, RTF and first PCM timing include watermark processing. `audio.watermark?.processingMilliseconds` measures watermark work separately and excludes work inside the caller's playback callback. Model preparation, including initial watermark compilation/loading/warmup, is outside synthesis RTF. The detector loads when analysis is requested.

Watermarking slightly changes the waveform. Audible effects and overhead depend on the input and device. Very short audio, silence and heavy editing/compression can prevent reliable detection or message recovery. The identifier and detection score are not a signature, proof of speaker identity or tamper-proof provenance.

AudioSeal code and weights are MIT licensed. Preserve [its license](../LICENSES/AudioSeal-MIT.txt) and [component notices](../THIRD_PARTY_NOTICES.md). See the [official implementation](https://github.com/facebookresearch/audioseal) and [model repository](https://huggingface.co/facebook/audioseal).
