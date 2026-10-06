# Using the iPhone and Mac samples

[日本語](SAMPLES.md) · [TestFlight distribution](TESTFLIGHT.en.md) · [Privacy](PRIVACY.en.md)

Open `Examples/IrodoriSamples.xcodeproj`. Choose `IrodoriiOS` for an iPhone or `IrodoriMac` for an Apple Silicon Mac. Set your own signing team and bundle identifier before running on a device. UI labels are Japanese. The app uses a vertical layout on iPhone and two columns in wide Mac windows, with light and dark appearance support.

## First use

1. At the top, **はじめにモデルを準備** guides you to model download. Choose standard FP32 (approximately 2.99 GB, the default) or light INT8 (approximately 1.96 GB, iOS 18/macOS 15 or later).
2. Press **モデルをダウンロード**. No Hugging Face account or URL entry is needed. Allow additional free space for compiled/device-specific Core ML caches and prefer Wi-Fi. Keep the app open while downloading.
3. Progress shows received bytes, percentage and download/verification status. A 100% transfer can still be under verification. The completed model is selected automatically.
4. Leave the reference unset and style instructions empty, then press **生成して再生** using the initial text. Separate **準備** is optional. First-time model compilation and specialization may take longer than repeated generation.

The sample synthesizes the full input once, waits for the WAV to finish, and plays it. It does not split at punctuation or use pseudo-streaming playback. Inputs exceeding model limits are rejected; shorten the text instead of expecting automatic segmentation.

## Pause and retry downloads

**ダウンロードを中断** pauses the download. On iPhone, switching to another app also pauses it. Automatic screen locking is temporarily suppressed only during a download and restored afterward. This is not a background-download implementation.

After interruption, network failure or app relaunch, press **再開する**. Completed files are reused after size and SHA-256 verification; the interrupted individual file starts again. **取得データを削除** discards only this pending transfer. Resolve a pending transfer before downloading another variant.

For an existing bundle, use **フォルダを選ぶ** / **モデルを変更** and choose the parent folder containing `manifest.json` and all model packages. The app verifies it and stores its own copy; the external source remains. **URLからダウンロード** accepts an HTTPS manifest URL for a custom distribution.

## Model switching and deletion

Use **保存済みモデル** to switch bundles. The old sessions are released; reference selection and style instructions are preserved, while displayed synthesis results are cleared. The selected model is prepared on the next generation.

Open **モデルを管理** to see installed bundles and delete an app-owned copy with the trash button and confirmation. External originals, registered voices and exported WAVs are retained. Deleting the active model releases it and selects another saved model if one exists. Deleting all models returns to the first-use download guide. Core ML caches may remain under system management, so not all cache space is necessarily reclaimed at the same time.

## Reference voices and style

Enable **利用できる声を登録** only for your own voice or one you have explicit permission to use. **音声を選ぶ** imports audio. **録音する** starts a recording and **録音を停止** ends it; use a clear 3–10 second clip and allow microphone access when prompted. Then press **準備** or **生成して再生**. A short Japanese description in the style field can guide speaking style, with or without a reference.

**登録音声とキャッシュを削除** removes all reference copies/recordings owned by the sample and its feature cache, while preserving external source files. One reference is selected at a time; there is no named voice library. Selection persists across launches, but the voice-permission toggle resets.

## Playback, export and numbers

The output player supports pause/resume/replay. **停止** stops playback or cancels synthesis; a running Core ML call may need to finish before the next operation. **WAVを保存** opens iPhone sharing or the Mac save dialog. Save a separate copy if you want to retain it after the next generation.

RTF is synthesis time divided by audio duration. It includes the default AudioSeal watermark processing and excludes model preparation, reference setup, WAV export and speaker playback delay. ASR and LLM are not part of this sample. Preparation may show 0 ms when the same model is already held; the reference-cache indicator means feature reuse. Generated audio and exported WAV use the same 48 kHz mono PCM16 samples.
