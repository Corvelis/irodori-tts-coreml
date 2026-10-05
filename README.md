# Irodori TTS Core ML

Irodori TTS v4.1 Small MFをiPhoneとApple Silicon Macで動かすSwift SDKです。日本語の音声合成、参照音声による声の指定、テキストによる話し方の指示に対応します。生成音声にはAudioSealの透かしを標準で付与します。

[English](docs/README.en.md) · [v0.2.0 Release](https://github.com/Corvelis/irodori-tts-coreml/releases/tag/v0.2.0) · [Core MLモデル](https://huggingface.co/AILogDev/Irodori-TTS-v4.1-Small-MF-CoreML)

## 配布内容

| 配布物 | 内容 |
|---|---|
| Swift SDK | Xcode / Swift Package Managerから追加する `IrodoriTTS` ライブラリ |
| iPhone / Macサンプル | モデル取得、録音・音声取り込み、音声合成、再生、WAV保存 |
| Mac CLI | モデル取得・検証、WAV生成、RTF測定 |
| Core MLモデル | [Hugging Face](https://huggingface.co/AILogDev/Irodori-TTS-v4.1-Small-MF-CoreML)で別配布。現行版 約2.99 GB / 軽量INT8版 約1.96 GB |
| 変換コード | 再変換・数値比較の参考実装 |

音声合成にはAppleのフレームワークを使用します。実行にPythonやONNX Runtimeは不要で、モデル取得後はオフラインで生成できます。モデルはSDKに内蔵していません。

## 要件

- 開発環境: Apple Silicon Mac、Xcode、Command Line Tools。
- アプリのDeployment Target: iOS 17以降 / macOS 14以降。Swift tools 5.9以降。
- 保存容量: 選択したモデル原本に加え、アプリ内コピーとCore MLコンパイルキャッシュを保存する空き容量。
- 出力音声: 48 kHz、モノラル、PCM16 WAV。

初回はCore MLのコンパイルとロードに時間がかかります。速度・使用メモリは端末、文章、参照音声、同時に動く処理によって変わります。

## モデルを選ぶ

| モデル | 容量 | 必要なOS | SDK |
|---|---:|---|---|
| 現行版 | 約2.99 GB | iOS 17 / macOS 14以降 | 0.1.0以降 |
| 軽量INT8版 | 約1.96 GB | iOS 18 / macOS 15以降 | 0.2.0以降 |

軽量INT8版はテキストエンコーダーの重みをINT8で保存し、計算と出力はFP32を維持します。固定幅デコーダーは同じ重みを共有し、可変幅デコーダーは独立して保持します。音声登録・話し方の指示・透かしは両モデルで利用できます。[比較結果と再測定](docs/QUALITY.md)を参照してください。

## Macで音声を生成する

モデルの取得先は新しいフォルダを指定してください。

```sh
git clone --branch v0.2.0 --depth 1 https://github.com/Corvelis/irodori-tts-coreml.git
cd irodori-tts-coreml
swift build -c release
.build/release/irodori download --manifest 'https://huggingface.co/AILogDev/Irodori-TTS-v4.1-Small-MF-CoreML/resolve/b02a670f0cb41c382844672fa8f0f03b3b9b8082/manifest.json' --destination ../Irodori-TTS-v4.1-Small-MF-CoreML
.build/release/irodori verify --models ../Irodori-TTS-v4.1-Small-MF-CoreML
.build/release/irodori synthesize --models ../Irodori-TTS-v4.1-Small-MF-CoreML --text 'こんにちは。今日はいい天気ですね。' --output ./irodori-output.wav
afplay ./irodori-output.wav
```

軽量版はダウンロード時に `--variant light-int8` を指定し、保存先を別フォルダにします。合成APIは共通です。

参照音声を使う場合は `--reference ./reference.wav` を追加します。自分の声など使用許可のある音声を用意してください。`--caption '落ち着いた、やさしい話し方。'` で話し方を指定できます。

## iPhone / Macサンプルを使う

1. `Examples/IrodoriSamples.xcodeproj` をXcodeで開きます。
2. Macは `IrodoriMac`、iPhoneは `IrodoriiOS` schemeを選びます。自分のSigning Teamと一意のBundle Identifierを設定して実行します。
3. 「モデル」で取得する版を選び、「モデルをダウンロード」を押します。取得済みなら「フォルダを選ぶ」でモデル一式を取り込みます。「保存済みモデル」から切り替えられます。
4. まず「参照なし」で「生成して再生」を押します。声を指定する場合は、録音または音声ファイルの取り込みを行います。

サンプルは入力全体を一度に合成し、完成したWAVを再生します。再生・一時停止・再開・停止・WAV保存に対応します。上限を超えた場合は文章を短くしてください。[サンプルの使い方](docs/SAMPLES.md)に詳しい操作があります。

## 自分のアプリへSDKを追加する

Xcodeの **File → Add Package Dependencies…** に `https://github.com/Corvelis/irodori-tts-coreml.git` を入力し、Exact Version **0.2.0** を選びます。アプリtargetへ **IrodoriTTS** productを追加してください。

```swift
import Foundation
import IrodoriTTS

func makeWAV(engine: IrodoriEngine, models: URL, output: URL) async throws {
    try await engine.prepare(modelDirectory: models)
    try await engine.registerReference(nil)
    let audio = try await engine.synthesize(
        "こんにちは。今日はいい天気ですね。",
        caption: "落ち着いた、やさしい話し方。",
        splitSentences: false
    )
    try audio.writeWAV(to: output)
    print("RTF:", audio.rtf)
}
```

`models` はモデル一式の親フォルダ、`output` はアプリが書き込めるWAVの保存先です。出力先の親フォルダを作成してから呼び出します。`IrodoriEngine()` を保持して生成ごとに再利用し、使い終わったら `await engine.release()` を呼びます。音声再生はアプリ側で実装します。

## ドキュメント

| 目的 | ガイド |
|---|---|
| モデルを取得する | [モデル取得と配置](docs/HUGGINGFACE.md) |
| SDKをXcodeへ追加する | [導入ガイド](docs/GETTING_STARTED.md) / [API](docs/API.md) |
| 録音・再生する | [サンプル操作](docs/SAMPLES.md) / [音声登録と削除](docs/VOICE_REGISTRATION.md) |
| 音声の透かしを使う | [透かしの付与と検出](docs/WATERMARK.md) |
| チャンク通知・停止を実装する | [再生と停止](docs/STREAMING.md) |
| CLIで生成・速度を測る | [CLI](docs/CLI.md) / [性能の測定と制約](docs/VALIDATION.md) |
| エラーを解決する | [トラブル対処](docs/TROUBLESHOOTING.md) |
| モデルを再変換する | [変換の参考実装](docs/CONVERSION.md) |
| 軽量モデルと音質比較 | [軽量版の構成](docs/COMPACT_MODELS.md) / [音質の測定](docs/QUALITY.md) |
| 配布物と利用条件を確認する | [配布内容と互換性](docs/RELEASE.md) / [ライセンス](docs/LICENSE_REVIEW.md) |

## ライセンス

SDK・サンプルの新規部分はApache-2.0です。モデルと上流由来部分にはMIT / Apache-2.0の部品別条件が適用されます。[LICENSE](LICENSE)、[NOTICE](NOTICE)、[部品別ライセンス](THIRD_PARTY_NOTICES.md)を参照してください。コミュニティによる変換・実装で、AratakoやAppleの公式提供ではありません。

使用許可のある声を使い、[上流モデルの使用条件](https://huggingface.co/Aratako/Irodori-TTS-v4.1-Small-MF)に従ってください。合成音声を本人の実際の発話として偽らないでください。
