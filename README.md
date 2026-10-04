# Irodori TTS Core ML

Irodori TTS v4.1 Small MF を iPhone / Apple Silicon Mac で動かす、コミュニティ版の共通ランタイムとサンプルです。Local AI で使用している推論エンジンから切り出しました。

**現在は配布準備版 `0.1.0-draft` です。** [Hugging Faceのモデル用リポジトリ](https://huggingface.co/AILogDev/Irodori-TTS-v4.1-Small-MF-CoreML)は作成済みで、Privateの準備版をアップロードし、全ファイルの再ダウンロードとサイズ・SHA-256検証を完了しました。正式公開はまだ完了していません。SDK・サンプル・変換コードは [Corvelis/irodori-tts-coreml](https://github.com/Corvelis/irodori-tts-coreml) に配置します。現在は両リポジトリともPrivateの準備版です。DACVAE元重みもApache-2.0とするMetaの回答を確認し、[ライセンス確認記録](docs/LICENSE_REVIEW.md)へ保存しました。初版で対象にしたiPhone/Macの操作・試聴確認は完了し、公開先からの取得確認が残っています。[公開準備の状態](docs/RELEASE.md)を参照してください。コードは Apache-2.0、モデルと派生部分は[部品ごとの条件](THIRD_PARTY_NOTICES.md)を維持します。

## ドキュメント

| やりたいこと | ガイド |
|---|---|
| 自分のアプリへSDKを組み込む | [Xcodeへの導入と最初のWAV生成](docs/GETTING_STARTED.md) |
| iPhone / Macのサンプルを動かす | [署名・モデル取り込み・操作手順](docs/SAMPLES.md) |
| 声を録音・登録・削除する | [音声登録、0 ms表示、保存場所](docs/VOICE_REGISTRATION.md) |
| テキストで声・話し方を指定する | [Voice Designの引数と制約](docs/API.md#声話し方の指示voice-design) |
| APIの引数・返り値を調べる | [Swift APIリファレンス](docs/API.md) |
| 生成しながら再生・停止する | [ストリーミングとLLMへの接続](docs/STREAMING.md) |
| Macで測定する | [CLIとベンチマーク](docs/CLI.md) |
| エラー・読み・速度を切り分ける | [トラブル対処とFAQ](docs/TROUBLESHOOTING.md) |
| モデルを再変換・配布する | [変換](docs/CONVERSION.md) / [Hugging Faceへのアップロード](docs/HUGGINGFACE.md) / [公開準備](docs/RELEASE.md) / [検証記録](docs/VALIDATION.md) |
| Read in English | [English getting started](docs/README.en.md) |

## 入っているもの

- `Sources/IrodoriTTS`：Swift API、文章整形、参照音声、モデル検証・取得。
- `Sources/IrodoriNative`：検証済み Objective-C++ / Core ML 推論エンジン。
- `Examples/IrodoriSamples.xcodeproj`：iPhone / Mac 共通の SwiftUI サンプル。
- `Sources/IrodoriCLI`：Mac用WAV生成・検証・ベンチマークCLI。
- `Conversion`：固定revisionからの取得と、変換・部品検証スクリプト。
- `Distribution`：Hugging Faceモデルカード、モデル全ファイルのロック、出典情報。

実行時に Python / PyTorch / ONNX Runtime は不要です。音声は48 kHz・モノラル・16 bit PCMです。約2.90 GBのモデルはコードと分けて置きます。標準DiT版は含みません。

## Macで動かす

Apple Silicon Mac、XcodeとCommand Line Toolsを使用してください。ビルド対象はmacOS 14以降 / iOS 17以降ですが、全OS版・全端末での動作を確認した意味ではありません。[確認範囲](docs/VALIDATION.md)に記載しています。

ソースは [GitHub](https://github.com/Corvelis/irodori-tts-coreml) から取得します。現在のPrivate準備版へアクセスするにはGitHubの認証が必要です。

```sh
git clone https://github.com/Corvelis/irodori-tts-coreml.git
cd irodori-tts-coreml
```

モデル配布フォルダは `manifest.json`、`coreml-only.json`、13個の `.mlpackage` が直接並ぶフォルダです。準備済みモデルを隣に置いた場合:

```sh
swift build -c release
.build/release/irodori verify --models ../Irodori-TTS-v4.1-Small-MF-CoreML
.build/release/irodori synthesize \
  --models ../Irodori-TTS-v4.1-Small-MF-CoreML \
  --text 'こんにちは。今日はいい天気ですね。' \
  --reference /path/to/your-authorized-voice.wav \
  --output /tmp/irodori-output.wav --report /tmp/irodori-report.json
afplay /tmp/irodori-output.wav
```

`--reference` を省くと参照音声なしで生成します。モデル・参照の準備時間とRTFは別に報告します。初回はCore MLのコンパイルと特殊化に時間がかかります。表示する「最初のPCM」は生成コールバックまでの時間で、スピーカーから音が出るまでの実測ではありません。

モデルの配布先は [AILogDev/Irodori-TTS-v4.1-Small-MF-CoreML](https://huggingface.co/AILogDev/Irodori-TTS-v4.1-Small-MF-CoreML)です。アップロード・公開後は、HF commit SHAに固定した `manifest.json` のHTTPS URLで取得できます。以下のURLはサイズ・SHA-256を検証済みの準備版commitに固定しています。現時点でPrivateのリポジトリはSDKの認証なしURL取得では使用できません。

```sh
.build/release/irodori download \
  --manifest 'https://huggingface.co/AILogDev/Irodori-TTS-v4.1-Small-MF-CoreML/resolve/af30c0101ebd6f714160b900d205b395845e43a6/manifest.json' \
  --destination /path/to/new-model-folder
```

各ファイルをディスクへ保存し、サイズとSHA-256を検証してから使用可能にします。再試行時は完了済みファイルを再利用します。ダウンロード途中の1ファイルは取り直します。

## iPhone / Macのサンプル

```sh
open Examples/IrodoriSamples.xcodeproj
```

Macは `IrodoriMac`、iPhoneは `IrodoriiOS` schemeを選択します。iPhone実機では自分のSigning Teamと一意のBundle Identifierを設定してください。

1. モデルフォルダをFiles経由で取り込むか、固定revisionのmanifest URLから取得。
2. 自分の声・許可のある声を録音または選択。参照なしでも実行できます。
3. 文章を入力し「生成して再生」。入力全体を一度に合成し、完成WAVを再生します。RTF・生成時間・音声長を表示し、一時停止・再開・WAV保存ができます。
4. 「登録音声とキャッシュを削除」で、このサンプルが保持する登録音声と特徴キャッシュを削除。

サンプルは句読点による分割・先行再生を行いません。SDKの文分割・PCM通知は任意の組み込み用として残ります。Macは2列、iPhoneは縦配置の画面です。

取り込み元ファイルは保持し、アプリ内にコピーします。モデル原本に加え、アプリ内コピーとCore MLコンパイルキャッシュの空き容量が必要です。少なくとも複数GBの余裕を確保してください。署名済みアプリ、TestFlight、App Store配布は今回の対象に含めていません。

## 自分のアプリから呼ぶ

ローカルSwift Packageとして追加し、`IrodoriTTS` productをリンクします。公開後は同じ構成でGitHubのtagを指定できます。

```swift
import IrodoriTTS

let engine = IrodoriEngine() // 会話ごとに保持し、発話のたびに作り直さない
try await engine.prepare(modelDirectory: modelURL)
try await engine.registerReference(referenceURL) // URL?。nilなら参照なし
let result = try await engine.synthesize("**様々**な方法を試します。") { chunk in
    // 推論キューから呼ばれる48 kHz mono PCM16。UI更新はMainActorへ渡す。
    // 最小の再生例は Examples/Shared/PCMPlayer.swift を参照。
}
try result.writeWAV(to: outputURL)
print(result.rtf, result.firstPCMMilliseconds)
await engine.release()
```

Xcodeへの追加からは [SDK導入](docs/GETTING_STARTED.md)、録音と削除は [音声登録](docs/VOICE_REGISTRATION.md)、再生コードは [ストリーミング](docs/STREAMING.md) を参照してください。公開APIは [APIリファレンス](docs/API.md)、再変換は [変換手順](docs/CONVERSION.md) にあります。

## 検証

```sh
swift test -c release
python3 -m unittest discover -s Scripts/tests
.build/release/irodori benchmark \
  --models ../Irodori-TTS-v4.1-Small-MF-CoreML \
  --cases Benchmarks/cases.json --reference /path/to/your-authorized-voice.wav \
  --repeat 3 --report /tmp/irodori-benchmark.json --output-directory /tmp/irodori-benchmark-audio \
  --irodori-fixed-seed --irodori-seed 11 --irodori-diagnostics
```

モデルの精度設定、ステップ数、デコーダ処理を保った切り出しです。元PyTorchモデルとの完全一致や、任意の入力での音質・速度を保証するものではありません。ベンチマークはTTS単体で、ASR/LLMは含みません。生成音声・参照音声はGitに追加しないでください。

## English overview

A community Core ML runtime for Irodori TTS v4.1 Small MF, with a shared Swift
package, iOS/macOS SwiftUI samples, a macOS WAV CLI, and conversion tooling.
The runtime uses Apple frameworks only. Model weights are a separate ~2.90 GB
bundle of 13 ML Programs. Clone/open the Xcode project or build with SwiftPM;
model preparation is required before synthesis. This is a local distribution
draft. Meta has explicitly clarified that DACVAE model weights are Apache-2.0;
see docs/LICENSE_REVIEW.md. Preserve the component licenses and notices.
The initial iPhone/Mac operation and trial-listening checks are complete; GitHub publication, public model release and fresh public-download validation remain pending. No voice recordings or model weights are in this code
repository, and the code license does not override upstream model terms.

For the complete English quick start, see [docs/README.en.md](docs/README.en.md).
