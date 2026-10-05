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

日本語の音声合成、端末内Voice Cloning、テキストによる話し方の指示に対応する、iPhone / Apple Silicon Mac向けのCore MLモデルです。現行版と軽量INT8版を同じSwift SDKで利用できます。

[Swift SDK / iPhone・Macサンプル](https://github.com/Corvelis/irodori-tts-coreml) · [English quick start](https://github.com/Corvelis/irodori-tts-coreml/blob/v0.2.0/docs/README.en.md) · [取得と配置](https://github.com/Corvelis/irodori-tts-coreml/blob/v0.2.0/docs/HUGGINGFACE.md)

## モデルを選ぶ

| 版 | 配置 | 容量 | 必要なOS | SDK | 固定版manifest |
|---|---|---:|---|---|---|
| 現行版 | ルート | 約2.99 GB | iOS 17 / macOS 14以降 | 0.1.0以降 | [現行版](https://huggingface.co/AILogDev/Irodori-TTS-v4.1-Small-MF-CoreML/resolve/b02a670f0cb41c382844672fa8f0f03b3b9b8082/manifest.json) |
| 軽量INT8版 | [int8/](https://huggingface.co/AILogDev/Irodori-TTS-v4.1-Small-MF-CoreML/tree/v0.2.0-int8/int8) | 約1.96 GB | iOS 18 / macOS 15以降 | 0.2.0以降 | [軽量版](https://huggingface.co/AILogDev/Irodori-TTS-v4.1-Small-MF-CoreML/resolve/v0.2.0-int8/int8/manifest.json) |

現行版はbundleVersion `0.1.0`・15パッケージ、軽量版は `0.2.0-int8`・14パッケージです。各モデルはCore MLパッケージ、tokenizer/config、補助metadata、manifestと部品別ライセンスを含みます。

各manifestはそのモデルだけを対象とし、CLI・SDK・サンプルは選択した版だけを取得します。Hugging Faceからリポジトリ全体を取得した場合は、現行版はルート、軽量版は `int8` を使用します。モデル一式のファイル名・階層を維持し、異なる版の部品を混ぜないでください。

## Macで使う

```sh
git clone --branch v0.2.0 --depth 1 https://github.com/Corvelis/irodori-tts-coreml.git
cd irodori-tts-coreml
swift build -c release
.build/release/irodori download --variant standard --destination ../Irodori-CoreML-Standard
.build/release/irodori verify --models ../Irodori-CoreML-Standard
.build/release/irodori synthesize --models ../Irodori-CoreML-Standard --text 'こんにちは。今日はいい天気ですね。' --output ./irodori.wav
afplay ./irodori.wav
```

軽量版は別の保存先へ取得します。

```sh
.build/release/irodori download --variant light-int8 --destination ../Irodori-CoreML-INT8
.build/release/irodori verify --models ../Irodori-CoreML-INT8
.build/release/irodori synthesize --models ../Irodori-CoreML-INT8 --text 'こんにちは。今日はいい天気ですね。' --output ./irodori-int8.wav
```

参照音声は `--reference ./reference.wav`、話し方は `--caption '落ち着いた、やさしい話し方。'` で指定します。出力は48 kHz mono PCM16 WAVです。実行にPythonやONNX Runtimeは不要で、取得後はオフラインで生成できます。初回のCore MLコンパイルには追加時間と空き容量が必要です。

## iPhone / MacサンプルとSDK

`Examples/IrodoriSamples.xcodeproj` を開き、自分の署名設定で実行します。「取得するモデル」で版を選び、「モデルをダウンロード」を押します。取得済みの一式は「フォルダを選ぶ」で取り込み、「保存済みモデル」で切り替えます。参照音声は使用許可のある録音・音声ファイルを取り込んで登録します。[サンプル操作](https://github.com/Corvelis/irodori-tts-coreml/blob/v0.2.0/docs/SAMPLES.md)を参照してください。

GUIサンプルは入力全体を一度に合成し、完成WAVを再生します。SDKはSwift Package Managerから追加でき、両モデルで同じ合成・参照登録APIを使います。[SDK導入](https://github.com/Corvelis/irodori-tts-coreml/blob/v0.2.0/docs/GETTING_STARTED.md)を参照してください。

## 軽量版の精度と測定

INT8化するのはテキストエンコーダーの大きな重みの保存精度です。テキストの計算・入出力はFP32、他の補助モデル・DiT・デコーダーの既存精度と4 integration stepsは維持します。固定幅stage 1は重みを共有し、可変幅stage 1は独立して保持します。

24種類の日本語入力×3 seed、72組の比較で、DNSMOS OVRL平均は現行版3.0365・軽量版3.0311でした。これは推定指標であり、人による音質評価ではありません。条件別の差、発話内容、数値誤差、速度と測定の制約は[音質比較](https://github.com/Corvelis/irodori-tts-coreml/blob/v0.2.0/docs/QUALITY.md)に記載しています。容量削減率は音質劣化率やRAM削減率ではありません。

本文はBOSを含め256トークン、潜在系列は768フレームまでです。Voice Designや参照音声への完全な一致は保証されません。

## 音声の透かし

両モデルはAudioSealのFP32付与・検出モデルを含みます。SDKは再生PCMと保存WAVへの付与を標準で有効にし、RTFに処理時間を含めます。[透かしの利用](https://github.com/Corvelis/irodori-tts-coreml/blob/v0.2.0/docs/WATERMARK.md)を参照してください。

## ライセンスと使用条件

コミュニティによる変換・実装で、AratakoやAppleの公式提供ではありません。モデルと上流部分のMIT / Apache-2.0条件、同梱の `LICENSES/`、`NOTICE`、[部品別表記](THIRD_PARTY_NOTICES.md)を保持してください。[DACVAE重みの公式回答](https://huggingface.co/facebook/dacvae-watermarked/discussions/1)と[ライセンス詳細](LICENSE_REVIEW.md)を参照してください。

使用許可のある声を使い、[上流モデルの使用条件](https://huggingface.co/Aratako/Irodori-TTS-v4.1-Small-MF)に従ってください。合成音声を本人の実際の発話として偽らないでください。

## English

A community Core ML conversion of Japanese Irodori TTS v4.1 Small MF for iPhone and Apple Silicon Mac, supporting on-device Voice Cloning, Japanese Voice Design captions and AudioSeal watermarking.

- **Standard:** repository root, ~2.99 GB, 15 packages, iOS 17+ / macOS 14+, SDK 0.1.0+.
- **Light INT8:** `int8/`, ~1.96 GB, 14 packages, iOS 18+ / macOS 15+, SDK 0.2.0+.

With SDK 0.2.0, use `irodori download --variant standard` or `--variant light-int8` and specify a new destination with `--destination`. Only the selected bundle is downloaded. Its contents are placed directly in that local destination; pass it to `--models` or `prepare(modelDirectory:)`. If you download the entire Hub repository, use its root for standard or the `int8` directory for light. Do not mix package files.

INT8 applies to text-encoder weight storage; FP32 text computations and other component precisions remain unchanged. In 72 paired comparisons, mean DNSMOS OVRL was 3.0365 for standard and 3.0311 for light. DNSMOS is an estimated metric, not a human listening score; see [quality measurements and limitations](https://github.com/Corvelis/irodori-tts-coreml/blob/v0.2.0/docs/QUALITY.en.md).

Use authorized reference audio and preserve all MIT / Apache-2.0 component notices and upstream use conditions. See [English setup](https://github.com/Corvelis/irodori-tts-coreml/blob/v0.2.0/docs/README.en.md), [download guidance](https://github.com/Corvelis/irodori-tts-coreml/blob/v0.2.0/docs/HUGGINGFACE.en.md) and [watermark guidance](https://github.com/Corvelis/irodori-tts-coreml/blob/v0.2.0/docs/WATERMARK.en.md).
