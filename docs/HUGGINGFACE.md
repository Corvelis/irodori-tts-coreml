# モデルの取得と配置

[README](../README.md) · [SDK導入](GETTING_STARTED.md) · [サンプル操作](SAMPLES.md)

SDKとCore MLモデルは別配布です。生成には選択した版のすべてのCore MLパッケージ、tokenizer、configと補助metadataを含むフォルダ一式が必要です。

## 対応モデル

| 項目 | 内容 |
|---|---|
| モデル | Irodori TTS v4.1 Small MF Core ML |
| 現行版 | bundleVersion `0.1.0`、約2.99 GB、SDK 0.1.0以降 |
| 軽量INT8版 | bundleVersion `0.2.0-int8`、約1.96 GB、SDK 0.2.0以降、iOS 18 / macOS 15以降 |
| 配布先 | [AILogDev/Irodori-TTS-v4.1-Small-MF-CoreML](https://huggingface.co/AILogDev/Irodori-TTS-v4.1-Small-MF-CoreML) |
| 固定commit | `b02a670f0cb41c382844672fa8f0f03b3b9b8082` |
| manifestのSHA-256 | `f98e77d857c20e977358ec9c9d513721b37e1af0d7e12359c05de26c90ae7186` |

上記の固定commitは現行版です。軽量INT8版のversioned manifestは次です。

```text
https://huggingface.co/AILogDev/Irodori-TTS-v4.1-Small-MF-CoreML/resolve/v0.2.0-int8/manifest.json
```

CLIでは `download --variant standard` または `download --variant light-int8` を指定できます。各版の保存先を分けてください。

CLI、SDKの `ModelDownloader`、サンプルの「URLからダウンロード」には次のURLを使います。

```text
https://huggingface.co/AILogDev/Irodori-TTS-v4.1-Small-MF-CoreML/resolve/b02a670f0cb41c382844672fa8f0f03b3b9b8082/manifest.json
```

## MacのCLIで取得する

ソースを取得して `swift build -c release` を実行した後、リポジトリのルートで次を実行します。

```sh
.build/release/irodori download --manifest 'https://huggingface.co/AILogDev/Irodori-TTS-v4.1-Small-MF-CoreML/resolve/b02a670f0cb41c382844672fa8f0f03b3b9b8082/manifest.json' --destination ../Irodori-TTS-v4.1-Small-MF-CoreML
.build/release/irodori verify --models ../Irodori-TTS-v4.1-Small-MF-CoreML
```

保存先は未作成のフォルダを指定します。取得済みなら `verify` で確認して利用します。中断した取得は、同じURLと保存先で再実行すると検証済みファイルを再利用します。ファイルサイズとSHA-256は取得時に検証されます。

## サンプルから取得する

1. サンプルの「モデル」設定を開きます。
2. 「取得するモデル」で現行版または軽量INT8版を選びます。
3. 「モデルをダウンロード」を押し、取得と検証が完了するまで待ちます。独自配布先には「URLからダウンロード」を使用します。
4. 「生成して再生」で音声を生成します。

取得済みなら「フォルダを選ぶ」で取り込みます。iPhoneへMacから渡す場合は、Finderのファイル共有でサンプルへフォルダをコピーし、「ファイル」→「このiPhone内」→「Irodori Core ML」から選択できます。

## SDKから取得する

```swift
import Foundation
import IrodoriTTS

func downloadModels(to newDirectory: URL) async throws {
    let manifest = URL(string:
        "https://huggingface.co/AILogDev/Irodori-TTS-v4.1-Small-MF-CoreML/resolve/b02a670f0cb41c382844672fa8f0f03b3b9b8082/manifest.json"
    )!
    try await ModelDownloader().download(manifestURL: manifest, to: newDirectory)
}
```

`newDirectory` はアプリが書き込める新しい保存先です。取得後のフォルダURLを `engine.prepare(modelDirectory:)` へ渡します。

## フォルダ構成と容量

```text
Irodori-TTS-v4.1-Small-MF-CoreML/
  manifest.json
  coreml-only.json
  config.json
  tokenizer/
  text_encoder.json
  text_encoder.mlpackage/
  dit_step_cached_mixed_linear_768.mlpackage/
  ...
  LICENSES/
  NOTICE
  THIRD_PARTY_NOTICES.md
```

`.mlpackage` 1つだけでは生成できません。フォルダ一式を保持し、ファイル名・階層を変更したり別版のファイルを混ぜたりしないでください。ZIPを使う場合は先に展開します。

配布フォルダは現行版約2.99 GB、軽量INT8版約1.96 GBです。サンプルへの取り込みはアプリ内コピーを作り、初回準備でCore MLコンパイルキャッシュも作成します。原本の容量に加えて数GBの空き容量を確保してください。モデル取得後の音声生成に通信は不要です。
