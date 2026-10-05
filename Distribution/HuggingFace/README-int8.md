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

# Irodori TTS v4.1 Small MF — Core ML 軽量INT8版

日本語の音声合成、端末内Voice Cloning、日本語テキストによる話し方の指示に対応するコミュニティ版です。**モデル約1.96 GB・SDK 0.2.0以降・iOS 18 / macOS 15以降**。

[Swift SDK / iPhone・Macサンプル](https://github.com/Corvelis/irodori-tts-coreml) · [English](https://github.com/Corvelis/irodori-tts-coreml/blob/v0.2.0/docs/README.en.md) · [音質測定](https://github.com/Corvelis/irodori-tts-coreml/blob/v0.2.0/docs/QUALITY.md)

この軽量版はリポジトリの `int8/` にあります。手動で取り込む場合はこのフォルダを選びます。CLI・SDKでは選択した軽量版の中身だけを保存先へ直接配置します。

## モデルを選ぶ

| 版 | 容量 | 必要なOS | manifest |
|---|---:|---|---|
| 現行版 | 約2.99 GB | iOS 17 / macOS 14以降 | [現行版](https://huggingface.co/AILogDev/Irodori-TTS-v4.1-Small-MF-CoreML/resolve/b02a670f0cb41c382844672fa8f0f03b3b9b8082/manifest.json) |
| 軽量INT8版 | 約1.96 GB | iOS 18 / macOS 15以降 | [軽量版](https://huggingface.co/AILogDev/Irodori-TTS-v4.1-Small-MF-CoreML/resolve/v0.2.0-int8/int8/manifest.json) |

この一式はbundleVersion `0.2.0-int8`、14個のCore MLパッケージ、tokenizer/config、補助metadata、数値検証レポートとSHA-256 manifestを含みます。フォルダ一式を保持し、異なる版のファイルを混ぜないでください。

## Macで使う

```sh
git clone --branch v0.2.0 --depth 1 https://github.com/Corvelis/irodori-tts-coreml.git
cd irodori-tts-coreml
swift build -c release
.build/release/irodori download --variant light-int8 --destination ../Irodori-CoreML-INT8
.build/release/irodori verify --models ../Irodori-CoreML-INT8
.build/release/irodori synthesize --models ../Irodori-CoreML-INT8 --text 'こんにちは。今日はいい天気ですね。' --output ./irodori.wav
afplay ./irodori.wav
```

参照音声は `--reference ./reference.wav`、話し方は `--caption '落ち着いた、やさしい話し方。'` で指定します。実行にPythonやONNX Runtimeは不要で、取得後はオフラインで生成します。出力は48 kHz mono PCM16 WAVです。初回のCore MLコンパイルには追加時間と空き容量が必要です。

## iPhone / Macサンプル

`Examples/IrodoriSamples.xcodeproj` を開き、自分の署名設定で実行します。「取得するモデル」で軽量INT8版を選び、「モデルをダウンロード」を押します。取得済みの一式は「フォルダを選ぶ」で取り込めます。「保存済みモデル」から現行版と切り替えられます。参照音声を使う場合は利用許可を確認し、録音または音声ファイルを取り込みます。[サンプル操作](https://github.com/Corvelis/irodori-tts-coreml/blob/v0.2.0/docs/SAMPLES.md)を参照してください。

## 精度と制約

INT8はテキストエンコーダーの大きな重みの保存精度です。計算と入出力はFP32、他の補助モデル・DiT・デコーダーの精度と4 integration stepsは現行版を維持します。固定幅stage 1は重みを共有し、可変幅stage 1は独立して保持します。

本文はBOSを含め256トークン、潜在系列は768フレームまでです。GUIサンプルは全文を合成してから完成WAVを再生します。Voice Designや参照音声への完全な一致は保証されません。測定条件・数値誤差・読みの比較は[音質測定](https://github.com/Corvelis/irodori-tts-coreml/blob/v0.2.0/docs/QUALITY.md)に記載します。容量削減率は音質劣化率やRAM削減率ではありません。

## 音声の透かし

AudioSealのFP32付与・検出モデルを含みます。SDKは再生PCMと保存WAVへの付与を標準で有効にし、RTFに処理時間を含めます。[透かし](https://github.com/Corvelis/irodori-tts-coreml/blob/v0.2.0/docs/WATERMARK.md)を参照してください。

## ライセンスと使用条件

AratakoやAppleの公式提供ではありません。モデルと上流部分のMIT / Apache-2.0条件、同梱の `LICENSES/`、`NOTICE`、[部品別表記](THIRD_PARTY_NOTICES.md)を保持してください。[DACVAE重みの公式回答](https://huggingface.co/facebook/dacvae-watermarked/discussions/1)と[ライセンス詳細](LICENSE_REVIEW.md)を参照してください。

使用許可のある声を使い、[上流モデルの使用条件](https://huggingface.co/Aratako/Irodori-TTS-v4.1-Small-MF)に従ってください。合成音声を本人の実際の発話として偽らないでください。

## English

A community light INT8 Core ML bundle (~1.96 GB) for Japanese Irodori TTS v4.1 Small MF. Requires SDK 0.2.0+, iOS 18+ / macOS 15+. Supports on-device Voice Cloning, Japanese Voice Design captions and AudioSeal watermarking. INT8 applies to text-encoder weight storage; FP32 text computations and other model precision remain unchanged. Download the complete bundle using `irodori download --variant light-int8 --destination NEW_DIRECTORY`. The standard model stays at the repository root; this light bundle lives under `int8/`. Downloads place its contents directly in the chosen local destination. Standard ~2.99 GB models remain available via `--variant standard`. Preserve MIT / Apache-2.0 terms and authorized voice-use conditions. See [English quality measurements](https://github.com/Corvelis/irodori-tts-coreml/blob/v0.2.0/docs/QUALITY.en.md).
