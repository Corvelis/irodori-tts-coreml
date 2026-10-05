# モデルの取得と配置

[English](HUGGINGFACE.en.md) · [README](../README.md) · [SDK導入](GETTING_STARTED.md) · [サンプル操作](SAMPLES.md)

SDKとCore MLモデルは別配布です。生成には選択した版のすべてのCore MLパッケージ、tokenizer、configと補助metadataを含むフォルダ一式が必要です。

## モデルを選ぶ

同じ[Hugging Faceリポジトリ](https://huggingface.co/AILogDev/Irodori-TTS-v4.1-Small-MF-CoreML)のルートに現行版、`int8/` に軽量版を配置しています。`int8/manifest.json` の各ファイルパスは `int8/` を基準とした相対パスです。各manifestは選択したモデルだけを含み、他方のモデルはダウンロードしません。

| モデル | リポジトリ内の配置 | 容量 | 必要なOS | SDK |
|---|---|---:|---|---|
| 現行版 | ルート | 約2.99 GB | iOS 17 / macOS 14以降 | 0.1.0以降 |
| 軽量INT8版 | `int8/` | 約1.96 GB | iOS 18 / macOS 15以降 | 0.2.0以降 |

フォルダ名はモデルの種類、タグ・commitはその時点のファイルを指定します。SDKの標準取得先は元の固定commitを維持し、軽量版はバージョンタグの `int8/` を指定します。

現行版（bundleVersion `0.1.0`）:

```text
https://huggingface.co/AILogDev/Irodori-TTS-v4.1-Small-MF-CoreML/resolve/b02a670f0cb41c382844672fa8f0f03b3b9b8082/manifest.json
```

この固定commitのmanifest SHA-256は `f98e77d857c20e977358ec9c9d513721b37e1af0d7e12359c05de26c90ae7186` です。リポジトリの最新READMEとこの過去commitのREADMEは異なる場合があります。

軽量INT8版（bundleVersion `0.2.0-int8`）:

```text
https://huggingface.co/AILogDev/Irodori-TTS-v4.1-Small-MF-CoreML/resolve/v0.2.0-int8/int8/manifest.json
```

## MacのCLIで取得する

ソースを取得して `swift build -c release` を実行した後、リポジトリのルートで使用するモデルのコマンドを実行します。

```sh
# 現行版
.build/release/irodori download --variant standard --destination ../Irodori-CoreML-Standard
.build/release/irodori verify --models ../Irodori-CoreML-Standard

# 軽量INT8版（macOS 15以降）
.build/release/irodori download --variant light-int8 --destination ../Irodori-CoreML-INT8
.build/release/irodori verify --models ../Irodori-CoreML-INT8
```

保存先は未作成の別々のフォルダを指定します。取得済みなら `verify` で確認して利用します。中断した取得は、同じURLと保存先で再実行すると検証済みファイルを再利用します。ファイルサイズとSHA-256は取得時に検証されます。独自の配布先には `--variant` の代わりに `--manifest HTTPS_URL` を指定します。

## サンプルから取得する

1. サンプルの「モデル」設定を開きます。
2. 「取得するモデル」で現行版または軽量INT8版を選びます。
3. 「モデルをダウンロード」を押し、取得と検証が完了するまで待ちます。独自配布先には「URLからダウンロード」を使用します。
4. 「生成して再生」で音声を生成します。

取得済みなら「フォルダを選ぶ」で取り込みます。リポジトリ全体を取得した場合、現行版はルート、軽量版は `int8` フォルダを選択します。ただしサンプルは選択したフォルダをコピーするため、リポジトリ全体の取り込みは両版ぶんの余分な容量を使います。通常はCLIかサンプルで必要な版だけを取得してください。

iPhoneへMacから渡す場合は、Finderのファイル共有でサンプルへモデル一式のフォルダをコピーし、「ファイル」→「このiPhone内」→「Irodori Core ML」から選択できます。

## SDKから取得する

```swift
import Foundation
import IrodoriTTS

func downloadModels(variant: ModelVariant, to newDirectory: URL) async throws {
    try await ModelDownloader().download(
        manifestURL: variant.manifestURL,
        to: newDirectory
    )
}
```

`variant` は `.standard` または `.lightINT8`、`newDirectory` はアプリが書き込める新しい保存先です。取得後のフォルダURLを `engine.prepare(modelDirectory:)` へ渡します。選択したモデルの中身が直接保存先に入り、保存先の中にさらに `int8/` が作られるわけではありません。

## フォルダ構成と容量

Hugging Face上の配置:

```text
Irodori-TTS-v4.1-Small-MF-CoreML/
  README.md
  manifest.json                   # 現行版だけのmanifest
  coreml-only.json
  text_encoder.mlpackage/
  tokenizer/
  LICENSES/
  ...                             # 現行版の残りのファイル
  int8/
    README.md
    manifest.json                 # 軽量版だけのmanifest
    coreml-only.json
    text_encoder.mlpackage/
    tokenizer/
    LICENSES/
    ...                           # 軽量版の残りのファイル
```

CLIやSDKで取得した各モデルの保存先:

```text
Irodori-CoreML-INT8/
  manifest.json
  coreml-only.json
  config.json
  tokenizer/
  text_encoder.json
  text_encoder.mlpackage/
  ...
  LICENSES/
  NOTICE
  THIRD_PARTY_NOTICES.md
```

`.mlpackage` 1つだけでは生成できません。フォルダ一式を保持し、ファイル名・階層を変更したり別版のファイルを混ぜたりしないでください。ZIPを使う場合は先に展開します。

サンプルへの取り込みはアプリ内コピーを作り、初回準備でCore MLコンパイルキャッシュも作成します。選択したモデルの原本の容量に加えて数GBの空き容量を確保してください。モデル取得後の音声生成に通信は不要です。
