# Irodori TTS Core ML — getting started

[日本語](../README.md) · [API reference (Japanese)](API.md) · [Performance](VALIDATION.md)

This community runtime runs Irodori TTS v4.1 Small MF on iPhone and Apple Silicon Mac. It includes a Swift package, shared SwiftUI samples, a macOS CLI and conversion tools. Runtime dependencies are Apple frameworks only; Python and ONNX Runtime are not required for inference.

**Version 0.1.0, GitHub tag v0.1.0.** [Download the SDK and samples](https://github.com/Corvelis/irodori-tts-coreml/releases/tag/v0.1.0) and the separate [Core ML model bundle](https://huggingface.co/AILogDev/Irodori-TTS-v4.1-Small-MF-CoreML). Preserve the MIT / Apache-2.0 component terms and model-card use conditions; see [license details](LICENSE_REVIEW.md) and [component notices](../THIRD_PARTY_NOTICES.md). This is a community implementation, not an official Aratako or Apple release.

## Contents and requirements

| Artifact | Contents |
|---|---|
| Code repository | IrodoriTTS Swift package, iOS/macOS samples, CLI, conversion tools and docs |
| Separate model bundle | 15 Core ML ML Programs, tokenizer/config, sidecars and SHA-256 manifest; approximately 2.99 GB |

Deployment targets are iOS 17+ and macOS 14+, with Swift tools 5.9+. Use an Apple Silicon Mac with Xcode and Command Line Tools. Performance and memory use vary with the device and input. Allow extra disk space for app-owned model copies and Core ML compilation caches.

## Run on Mac

Clone the [code repository](https://github.com/Corvelis/irodori-tts-coreml), then download the matching model bundle into a new folder beside it:

```sh
git clone --branch v0.1.0 --depth 1 https://github.com/Corvelis/irodori-tts-coreml.git
cd irodori-tts-coreml
```

Run from the source root:

```sh
swift build -c release
.build/release/irodori download --manifest 'https://huggingface.co/AILogDev/Irodori-TTS-v4.1-Small-MF-CoreML/resolve/b02a670f0cb41c382844672fa8f0f03b3b9b8082/manifest.json' --destination ../Irodori-TTS-v4.1-Small-MF-CoreML
.build/release/irodori verify --models ../Irodori-TTS-v4.1-Small-MF-CoreML
.build/release/irodori synthesize \
  --models ../Irodori-TTS-v4.1-Small-MF-CoreML \
  --text 'こんにちは。今日はいい天気ですね。' \
  --output ./irodori-output.wav --report ./irodori-report.json
afplay ./irodori-output.wav
```

Add `--reference ./reference.wav` to use a reference voice. Output is 48 kHz mono PCM16 WAV. First use may take much longer because Core ML compiles and specializes models. See [CLI usage](CLI.md) for repeated measurements and reports.

## Open the samples

Open `Examples/IrodoriSamples.xcodeproj`. Choose IrodoriMac for Mac or IrodoriiOS for a connected iPhone. Configure your own signing team and bundle identifier. UI labels are currently Japanese; see [the walkthrough](SAMPLES.md).

1. **フォルダを選ぶ** / **モデルを変更**: select the folder containing manifest.json and all 15 packages, not an individual package. It is verified and copied into the app.
2. Enable the voice-permission toggle for a reference. **音声を選ぶ** imports a file; **録音する** starts recording and **録音を停止** stops it. Begin with a clear 3–10 second clip you are authorized to use.
3. **準備** prepares the model/reference. **生成して再生** synthesizes the entire prepared input once and plays the completed WAV, also preparing if needed. The GUI sample does not split at punctuation or play partial PCM. Long inputs wait for complete synthesis and are rejected if they exceed model limits, rather than silently split or truncated. The output player supports pause/resume/replay. **停止** stops playback and cancels further synthesis output.
4. **WAVを保存** exports the completed WAV. The app's generated.wav is replaced by the next successful synthesis.
5. **登録音声とキャッシュを削除** deletes all reference copies/recordings owned by this sample and the feature cache. External originals, models and generated WAV are retained.

For a first playback, leave the reference unset and the caption empty, import the model folder and press **生成して再生** using the default text. Separate preparation is optional. The URL downloader uses the matching manifest URL in the [model download guide](HUGGINGFACE.md).

The UI uses two columns on wide Mac windows and a vertical layout on iPhone, with separate model/voice settings and RTF, synthesis time and audio duration.

One voice is selected at a time; there is no named voice library UI. Selection persists, but the consent toggle resets on launch. The previous generated WAV remains on disk, but its playback card is not restored on relaunch. Imported models and compilation caches need extra disk space. Old model copies are not automatically deleted.

## Use the SDK in your app

In Xcode, choose **File → Add Package Dependencies…**, enter `https://github.com/Corvelis/irodori-tts-coreml.git`, select **Exact Version 0.1.0**, and link the **IrodoriTTS** library product. You can also add the repository root as a local Swift package. Keep one IrodoriEngine per conversation. Call prepare(modelDirectory:), then registerReference(URL?), then synthesize. Pass nil for no reference. The SDK does not bundle/download models automatically or play audio by itself.

The [integration guide](GETTING_STARTED.md) contains a complete WAV function; [streaming and cancellation](STREAMING.md) provides a controller with a sample player. onChunk runs on the inference queue and provides headerless little-endian PCM16. Dispatch UI/playback work to the main actor. Cancellation discards future chunks but does not interrupt an in-flight Core ML prediction or clear an application's playback queue.

Reference registration derives cached speaker features; it does not train or modify weights. clearReferenceCache removes features, not original audio files. release frees held sessions, not disk caches. See [voice storage and deletion](VOICE_REGISTRATION.md).

## Audio watermarking

AudioSeal is enabled by default for streamed playback and WAV output. Synthesis RTF and first PCM timing include watermark processing. Use `watermark: nil` in Swift or `--no-watermark` in the CLI for comparisons. See [the English watermark guide](WATERMARK.en.md) for identifier customization, detection and standalone APIs.

## Performance and limitations

RTF is synthesis time divided by output duration. Preparation, ASR, LLM, queue waiting and physical speaker latency are excluded. First PCM means callback readiness, not audible onset. The SDK retains complete PCM even when streaming; it is not an unbounded constant-memory stream.

Default text preparation handles Markdown, URLs and punctuation, then splits sentences and retries supported length-limit failures. `splitSentences: false` preserves sanitization while synthesizing one whole utterance and rejecting length-limit errors without a split retry. The GUI sample uses this mode and omits onChunk. The SDK/CLI defaults and optional decoder PCM callbacks remain available. rawText bypasses sanitization as well as sentence splitting. There is no pronunciation dictionary. Optional Japanese Voice Design captions are supported by `synthesize(text, caption: instruction)` and CLI `--caption`; see [API](API.md). Voice Design adherence and exact reference-voice similarity are not guaranteed. See [performance and input limitations](VALIDATION.md) and [troubleshooting](TROUBLESHOOTING.md).

The [conversion guide](CONVERSION.md) explains pinned sources and numerical checks. Conversion scripts are reference implementations. Use the distributed models for normal operation, and validate numerical outputs and generated speech when reconverting. Models, recordings, compiled caches and generated audio are excluded from the source archive.

The [shared decoder model guide](COMPACT_MODELS.en.md) describes the smaller v2 layout, conversion tool and iOS 18 / macOS 15 requirements. Version 0.1.0 supports the v1 layout only.
