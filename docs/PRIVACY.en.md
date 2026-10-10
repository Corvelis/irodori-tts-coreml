# Privacy in the Irodori Core ML sample

[日本語](PRIVACY.md)

This policy applies to the default iPhone and Mac sample apps provided in this repository.

Input text, speaking-style instructions, recordings and imported reference audio are processed on-device. They are not sent to external servers for speech synthesis or Voice Cloning. The microphone is used only when you start recording and grant the operating system's permission.

The app stores model selection, style instructions, reference selection and seed mode/value locally. Named voice presets contain model identity, captions, a fixed seed and a private reference snapshot when applicable; these are not transmitted. **保存した声を管理** deletes individual presets and their snapshots. **登録音声とキャッシュを削除** removes all app-owned reference copies/recordings and voice-feature caches, including reference-backed presets; reference-free presets and external sources remain. A generated result registered as a reference is also copied locally. Generated audio is saved as an app-owned WAV and replaced after the next successful synthesis. AudioSeal embeds an audio signal to help identify generated speech; watermarking does not communicate with a server or transmit personal information.

Model downloads connect to Hugging Face. Ordinary connection details, such as your IP address and requested files, reach the hosting server. Requests do not include your text or reference audio. See [Hugging Face's privacy policy](https://huggingface.co/privacy). A custom manifest URL connects to the host you specify. Speech generation needs no network connection after models have been downloaded. Opening external links is user initiated.

You choose WAV export/share destinations using the operating system's interface. Their own settings and policies apply to shared data. Use **モデルを管理** to delete saved models and **取得データを削除** to discard an interrupted download. Uninstalling removes app-owned data but preserves files exported elsewhere. Recordings/settings may be included in operating-system backups according to your settings; the app-owned model directory is excluded because its contents can be downloaded again.

The sample contains no advertising, tracking or analytics SDK. If distributed through TestFlight, Apple handles crash information and feedback you submit using [its TestFlight system](https://developer.apple.com/testflight/). Contact the project through [GitHub Issues](https://github.com/Corvelis/irodori-tts-coreml/issues); private recordings or confidential text are not required for public reports.
