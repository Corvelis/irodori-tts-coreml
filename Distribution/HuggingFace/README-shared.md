---
language:
- ja
pipeline_tag: text-to-speech
license: other
license_name: mit-and-apache-2.0
license_link: https://huggingface.co/AILogDev/Irodori-TTS-v4.1-Small-MF-CoreML/blob/main/THIRD_PARTY_NOTICES.md
library_name: coreml
base_model:
- Aratako/Irodori-TTS-v4.1-Small-MF
- Aratako/Semantic-DACVAE-Japanese-32dim
- sbintuitions/modernbert-ja-310m
tags:
- coreml
- ios
- macos
- voice-cloning
---

# Irodori TTS v4.1 Small MF — Core ML（重み共有形式）

iPhone / Apple Silicon Mac向けの日本語音声合成モデルです。端末内でのVoice Cloningと、日本語テキストによる話し方の指示に対応します。[Swift SDKとサンプル](https://github.com/Corvelis/irodori-tts-coreml)で利用できます。

## 要件と構成

- iOS 18以降 / macOS 15以降。開発にはApple Silicon MacとXcodeが必要です。
- `irodori-coreml-distribution-v2` に対応したSDKを使用してください。SDK v0.1.0はこの形式に非対応です。
- 13個のCore MLパッケージ、tokenizer、config、metadata、SHA-256 manifest、部品別ライセンスを含みます。
- 元の15パッケージ版から同じデコーダー重みを共有し、約170 MBを削減します。量子化や重みの丸めは追加していません。
- 実行時にPythonやONNX Runtimeは不要です。取得後はオフラインで生成できます。

個別の `.mlpackage` ではなくモデル一式を取得し、`manifest.json` とともに保持してください。版を混ぜたりファイル名を変更したりしないでください。版番号と各ファイルのサイズはmanifest、変換元はprovenanceに記載しています。原本に加え、アプリ内コピーとCore MLコンパイルキャッシュ分の空き容量が必要です。

## 使い方

SDKの `prepare(modelDirectory:)` へモデル一式の親フォルダを渡します。サンプルでは「フォルダを選ぶ」から一式を取り込み、「生成して再生」を押します。録音や音声取り込みによる参照登録、WAV保存にも対応します。

Mac CLIでは、対応SDKをReleaseビルドして次を実行します。

```sh
.build/release/irodori verify --models ../CoreMLModels
.build/release/irodori synthesize --models ../CoreMLModels \
  --text 'こんにちは。今日はいい天気ですね。' --output ./irodori-output.wav
afplay ./irodori-output.wav
```

`--reference ./reference.wav` で声を指定し、`--caption '落ち着いた、やさしい話し方。'` で話し方を指示できます。[重み共有形式](https://github.com/Corvelis/irodori-tts-coreml/blob/main/docs/COMPACT_MODELS.md)、[導入ガイド](https://github.com/Corvelis/irodori-tts-coreml/blob/main/docs/GETTING_STARTED.md)、[サンプル操作](https://github.com/Corvelis/irodori-tts-coreml/blob/main/docs/SAMPLES.md)を参照してください。

## 精度・速度・制約

補助モデルとdecoder stage 0はFP32、DiTはcached mixed-linear、decoder stages 1–3は既存のFP16です。4 integration steps、出力は48 kHz mono PCM16です。AudioSealの透かしを再生PCMと保存WAVへ標準で付与し、その処理はRTFに含まれます。

初回のコンパイル・ロードと、新しい入力形状の特殊化には追加時間がかかります。速度とRAM使用量は端末・文章・同時処理で変わります。同一の保存重みでもCore MLの実行経路による小さな数値差は起こり得ます。参照音声との完全な一致や音声指示への追従は保証されません。

本文はBOSを含め256トークン、潜在系列は768フレームまでです。サンプルは全文生成後に再生します。上限を超える文章は短くしてください。SDKでは文分割とPCM通知も利用できます。

## ライセンス

コミュニティによる変換・実装で、AratakoやAppleの公式提供ではありません。MIT / Apache-2.0の部品別条件が適用されます。[部品別ライセンス](THIRD_PARTY_NOTICES.md)、[ライセンス確認](LICENSE_REVIEW.md)、`NOTICE`、`LICENSES/` を保持してください。使用許可のある声を使い、[上流モデルの使用条件](https://huggingface.co/Aratako/Irodori-TTS-v4.1-Small-MF)に従ってください。

## English

A community Core ML bundle for Japanese Irodori TTS v4.1 Small MF, with on-device Voice Cloning and Japanese voice instructions. The v2 layout shares identical stage-1 decoder weights across three functions, saving approximately 170 MB without additional quantization or rounding.

Requires iOS 18 / macOS 15 or later and a v2-compatible SDK. SDK v0.1.0 does not support this layout. Download all 13 packages and accompanying files, retaining the manifest and component notices. Inference runs offline using Apple frameworks only. Output is 48 kHz mono PCM16; AudioSeal watermarking is enabled by default for playback and WAV export.

See the [English shared-model guide](https://github.com/Corvelis/irodori-tts-coreml/blob/main/docs/COMPACT_MODELS.en.md). Compilation time, memory use, speed and numerical outputs depend on the device and execution path. Preserve MIT / Apache-2.0 component terms and follow upstream voice-use conditions.
