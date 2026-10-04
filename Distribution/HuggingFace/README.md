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

# Irodori TTS v4.1 Small MF — Core ML

日本語のIrodori TTS v4.1 Small MFをiPhone / Apple Silicon Macで使うCore MLモデル一式です。参照音声による声の指定と、日本語テキストによる話し方の指示に対応します。

**bundleVersion: 0.1.0** · **[Swift SDKとサンプル](https://github.com/Corvelis/irodori-tts-coreml)** · **[v0.1.0 Release](https://github.com/Corvelis/irodori-tts-coreml/releases/tag/v0.1.0)** · **[English quick start](https://github.com/Corvelis/irodori-tts-coreml/blob/v0.1.0/docs/README.en.md)**

## 含まれるもの

15個のCore ML ML Programパッケージ、ModernBERT Japaneseのtokenizer、config、7個の補助モデルmetadata、全配布ファイルのサイズとSHA-256を記載した `manifest.json` を含みます。元revisionと変換構成は `provenance.json` に記載しています。

モデル一式は約2.99 GBです。`.mlpackage`を1つだけ取得せず、フォルダ一式を保持してください。構成・ファイル名を変更したり異なる版を混ぜたりしないでください。

## Macで使う

開発にはApple Silicon Mac、Xcode、Command Line Toolsを使用します。アプリの対象はiOS 17以降 / macOS 14以降です。実行にPythonやONNX Runtimeは不要です。

```sh
git clone --branch v0.1.0 --depth 1 https://github.com/Corvelis/irodori-tts-coreml.git
cd irodori-tts-coreml
swift build -c release
.build/release/irodori download --manifest 'https://huggingface.co/AILogDev/Irodori-TTS-v4.1-Small-MF-CoreML/resolve/v0.1.0/manifest.json' --destination ../Irodori-TTS-v4.1-Small-MF-CoreML
.build/release/irodori verify --models ../Irodori-TTS-v4.1-Small-MF-CoreML
.build/release/irodori synthesize --models ../Irodori-TTS-v4.1-Small-MF-CoreML --text 'こんにちは。今日はいい天気ですね。' --output ./irodori-output.wav
afplay ./irodori-output.wav
```

参照音声は任意です。CLIでは `--reference ./reference.wav`、話し方の指示は `--caption '落ち着いた、やさしい話し方。'` を追加します。自分の声など、使用許可のある3〜10秒程度の明瞭な録音を用意してください。

## iPhone / Macサンプルで使う

1. `Examples/IrodoriSamples.xcodeproj` を開きます。Macは `IrodoriMac`、iPhoneは `IrodoriiOS` schemeを選び、自分のSigning TeamとBundle Identifierを設定して実行します。
2. 「URLからダウンロード」に上のmanifest URLを入力し、「ダウンロードして検証」を押します。取得済みの場合は「フォルダを選ぶ」で一式の親フォルダを取り込みます。
3. まず「参照なし」で「生成して再生」を押します。参照音声を使う場合は録音または音声ファイルの取り込みを行います。

詳細は[モデル取得と配置](https://github.com/Corvelis/irodori-tts-coreml/blob/v0.1.0/docs/HUGGINGFACE.md)、[SDK導入](https://github.com/Corvelis/irodori-tts-coreml/blob/v0.1.0/docs/GETTING_STARTED.md)、[サンプル操作](https://github.com/Corvelis/irodori-tts-coreml/blob/v0.1.0/docs/SAMPLES.md)を参照してください。

## 構成と制約

DiTはcached attention、mixed-linear precision、4 integration stepsを使用します。補助モデルとdecoder stage 0はFP32、decoder stages 1–3はFP16と重なりのあるタイルを使用します。出力は48 kHz、モノラル、PCM16です。

本文はBOSを含め256トークン、潜在系列は768フレームまでです。GUIサンプルは全文を一度に合成し、完成WAVを再生します。長すぎる場合は文章を短くしてください。SDKの文分割・PCMチャンク通知も利用できます。

初回はCore MLのコンパイル・ロード・特殊化に時間がかかります。速度・使用メモリ・発音・声質は端末や入力によって変わります。参照音声との完全な一致やVoice Design指示への追従は保証されません。原本に加え、アプリ内コピーとコンパイルキャッシュの空き容量を確保してください。モデル取得後の生成はオフラインで動作します。

## 音声の透かし

AudioSealのFP32付与・検出モデルを同梱します。対応SDKは再生PCMと保存WAVへの透かし付与を標準で有効にし、RTFにも処理時間を含めます。原音は48 kHzのまま保持し、透かし信号だけを加算します。詳細は[透かしの付与と検出](https://github.com/Corvelis/irodori-tts-coreml/blob/v0.1.0/docs/WATERMARK.md)を参照してください。AudioSealのコードと重みはMITです。

## ライセンスと使用条件

コミュニティによるCore ML変換で、AratakoやAppleの公式提供ではありません。IrodoriとModernBERT等のMIT、Meta由来部分のApache-2.0を保持します。DACVAE元重みについては[Metaの公式回答](https://huggingface.co/facebook/dacvae-watermarked/discussions/1)を参照してください。[部品別ライセンス](THIRD_PARTY_NOTICES.md)、[利用条件](LICENSE_REVIEW.md)、同梱の `LICENSES/` と `NOTICE` を保持してください。

[上流モデルの使用条件](https://huggingface.co/Aratako/Irodori-TTS-v4.1-Small-MF)に従い、使用許可のある声を使ってください。合成音声を本人の実際の発話として偽らないでください。

## English

A community Core ML bundle for Japanese Irodori TTS v4.1 Small MF on iPhone and Apple Silicon Mac, with optional reference voices and Japanese Voice Design captions. The matching Swift SDK version is **0.1.0**.

Download the complete ~2.99 GB bundle with the versioned manifest URL above. Keep all 15 packages and accompanying files together. The immutable model commit is also listed in the [download guide](https://github.com/Corvelis/irodori-tts-coreml/blob/v0.1.0/docs/HUGGINGFACE.md). Inference uses Apple frameworks only and runs offline after download. Output is 48 kHz mono PCM16 WAV. Allow extra time and disk space for first-use Core ML compilation.

AudioSeal watermark generation/detection models are included. The SDK applies the watermark to playback PCM and exported WAV by default, and includes its processing time in RTF. See [the English watermark guide](https://github.com/Corvelis/irodori-tts-coreml/blob/v0.1.0/docs/WATERMARK.en.md).

See the [English quick start](https://github.com/Corvelis/irodori-tts-coreml/blob/v0.1.0/docs/README.en.md) for SDK integration and sample operation. Preserve MIT / Apache-2.0 component terms and follow upstream voice-use conditions.
