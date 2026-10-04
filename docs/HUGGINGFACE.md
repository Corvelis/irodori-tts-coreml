# モデルの取得と配置

[README](../README.md) · [SDK導入](GETTING_STARTED.md) · [サンプル操作](SAMPLES.md)

SDKとCore MLモデルは別配布です。生成には13個のCore MLパッケージ、tokenizer、configと補助metadataを含むフォルダ一式が必要です。

## 対応モデル

| 項目 | 内容 |
|---|---|
| モデル | Irodori TTS v4.1 Small MF Core ML |
| SDK / bundleVersion | `0.1.0` |
| 配布先 | [AILogDev/Irodori-TTS-v4.1-Small-MF-CoreML](https://huggingface.co/AILogDev/Irodori-TTS-v4.1-Small-MF-CoreML) |
| 固定commit | `b95d39710d9e3ac4435983fe89f9acd6c02658e9` |
| manifestのSHA-256 | `d12a4f0b97453db2e903dbbb55720790de6859bf3a68cc593b49aa054d39a744` |

CLI、SDKの `ModelDownloader`、サンプルの「URLからダウンロード」には次のURLを使います。

```text
https://huggingface.co/AILogDev/Irodori-TTS-v4.1-Small-MF-CoreML/resolve/b95d39710d9e3ac4435983fe89f9acd6c02658e9/manifest.json
```

## MacのCLIで取得する

ソースを取得して `swift build -c release` を実行した後、リポジトリのルートで次を実行します。

```sh
.build/release/irodori download --manifest 'https://huggingface.co/AILogDev/Irodori-TTS-v4.1-Small-MF-CoreML/resolve/b95d39710d9e3ac4435983fe89f9acd6c02658e9/manifest.json' --destination ../Irodori-TTS-v4.1-Small-MF-CoreML
.build/release/irodori verify --models ../Irodori-TTS-v4.1-Small-MF-CoreML
```

保存先は未作成のフォルダを指定します。取得済みなら `verify` で確認して利用します。中断した取得は、同じURLと保存先で再実行すると検証済みファイルを再利用します。ファイルサイズとSHA-256は取得時に検証されます。

## サンプルから取得する

1. サンプルの「モデル」設定を開きます。
2. 「URLからダウンロード」に上のmanifest URLを貼り付けます。
3. 「ダウンロードして検証」を押し、取得と検証が完了するまで待ちます。
4. 「生成して再生」で音声を生成します。

取得済みなら「フォルダを選ぶ」で取り込みます。iPhoneへMacから渡す場合は、Finderのファイル共有でサンプルへフォルダをコピーし、「ファイル」→「このiPhone内」→「Irodori Core ML」から選択できます。

## SDKから取得する

```swift
import Foundation
import IrodoriTTS

func downloadModels(to newDirectory: URL) async throws {
    let manifest = URL(string:
        "https://huggingface.co/AILogDev/Irodori-TTS-v4.1-Small-MF-CoreML/resolve/b95d39710d9e3ac4435983fe89f9acd6c02658e9/manifest.json"
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

配布フォルダは約2.90 GBです。サンプルへの取り込みはアプリ内コピーを作り、初回準備でCore MLコンパイルキャッシュも作成します。原本の容量に加えて数GBの空き容量を確保してください。モデル取得後の音声生成に通信は不要です。
