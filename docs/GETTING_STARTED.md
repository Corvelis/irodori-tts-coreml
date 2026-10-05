# SDKをXcodeに組み込む

[README](../README.md) · [サンプル操作](SAMPLES.md) · [API一覧](API.md)

この手順はSwift SDK `0.2.0`（GitHub tag `v0.2.0`）向けです。コード用リポジトリは [Corvelis/irodori-tts-coreml](https://github.com/Corvelis/irodori-tts-coreml) です。GitHubのタグ指定またはソースを取得してローカルSwift Packageとして追加します。SDKはモデルを内蔵せず、ダウンロードも自動では行いません。

## 1. 用意するもの

| 項目 | 内容 |
|---|---|
| 開発環境 | Apple Silicon Mac、XcodeとCommand Line Tools |
| Deployment Target | iOS 17以降、またはmacOS 14以降 |
| ソース | このリポジトリ全体。ルートに `Package.swift` がある状態 |
| モデル | 現行版 約2.99 GB / 軽量INT8版 約1.96 GBの一式 |
| 参照音声 | 任意。自分の声または使用許可のある音声 |

実行にPythonやONNX Runtimeは不要です。速度・使用メモリは端末と入力条件によって変わります。[性能の測定と制約](VALIDATION.md)を参照してください。

## 2. パッケージを追加する

サンプルやローカルSwift Packageを使う場合は、リポジトリ全体を取得します。

```sh
git clone --branch v0.2.0 --depth 1 https://github.com/Corvelis/irodori-tts-coreml.git
```

GitHubから直接組み込む場合は、Xcodeの **File → Add Package Dependencies…** に `https://github.com/Corvelis/irodori-tts-coreml.git` を入力し、Dependency Ruleを **Exact Version `0.2.0`** にします。product **IrodoriTTS** をアプリtargetへ追加してください。

取得したソースやソースZIPを使う場合は、次のローカル追加手順を使います。

1. 自分のアプリのXcodeプロジェクトを開きます。
2. **File → Add Package Dependencies… → Add Local…** から、このリポジトリのルートフォルダを選びます。Xcodeの版によって表示名は異なります。
3. ライブラリproduct **IrodoriTTS** をアプリのtargetに追加します。CLI product `irodori` をアプリへ追加する必要はありません。
4. Swiftファイルで `import IrodoriTTS` が解決することを確認します。

`Sources/IrodoriNative` を別途コピーしたり、モデルからSwiftクラスを生成したりする必要はありません。GitHubの `v0.2.0` タグとローカル追加は同じSDKソースを使います。

Xcodeの説明はAppleの[パッケージ依存の追加](https://developer.apple.com/documentation/xcode/adding-package-dependencies-to-your-app)と[ローカルパッケージでの開発](https://developer.apple.com/documentation/xcode/editing-a-package-dependency-as-a-local-package)も参照してください。

## 3. モデルを用意する

[モデル取得ガイド](HUGGINGFACE.md)に従って一式を取得します。`modelURL` はモデルの親フォルダです。1つの `.mlpackage` を指定しないでください。

```text
Irodori-TTS-v4.1-Small-MF-CoreML/
  manifest.json
  coreml-only.json
  config.json
  tokenizer/
  text_encoder.json                  # 補助モデルのsidecar、計7個
  text_encoder.mlpackage/            # 選択した版のCore MLパッケージ一式
  dit_step_cached_mixed_linear_768.mlpackage/
  ...                               # 一式を保持。省略・名前変更はしない
```

アプリからアクセス可能なApplication Support配下などへ一式をコピーします。Filesから選んだURLは、セキュリティスコープを開いている間に検証・コピーし、以後はアプリ内URLを使うのがサンプルの方式です。[実装](../Examples/Shared/SampleModel.swift)を参照してください。

新規取得時は `ModelBundle.validate(at:verifyHashes: true)` で全ファイルを検証します。これは同期I/Oなので、UIのMainActorで実行せずバックグラウンドへ渡します。毎回の発話でモデル全体をハッシュし直す必要はありません。

## 4. 音声を生成する

次の関数は、モデルと任意の参照音声からWAVを作ります。URLはアプリ内の実ファイルを指定し、出力先の親フォルダを事前に作成してください。

```swift
import Foundation
import IrodoriTTS

func makeWAV(engine: IrodoriEngine, modelURL: URL,
             referenceURL: URL?, outputURL: URL) async throws -> SynthesisResult {
    try await engine.prepare(modelDirectory: modelURL)
    try await engine.registerReference(referenceURL)
    let result = try await engine.synthesize("こんにちは。様々な方法を試します。")
    try result.writeWAV(to: outputURL)
    return result
}
```

`IrodoriEngine()` は会話を管理するオブジェクトに1つ保持します。参照なしなら `referenceURL: nil` を渡します。会話中は同じengineを再利用し、使い終わったときに `await engine.release()` を呼びます。

`prepare` は同じモデルを再利用しますが、ロード済みモデルを同じパスで上書きする更新は想定していません。モデル更新時は新しいフォルダへ検証済み一式を配置してください。

この関数はSDKの既定の文分割を使用し、ファイルを作るだけです。GUIサンプルと同じ全文一回の合成にする場合は `engine.synthesize(text, splitSentences: false)` を指定します。読み上げ用整形を保ち、モデル上限の超過は分割せずエラーになります。[全文モードのAPI](API.md#文章整形と長文)を参照してください。

生成しながら再生する例は[ストリーミングと停止](STREAMING.md)、録音・登録・削除は[音声登録](VOICE_REGISTRATION.md)にあります。

## 5. アプリ側の設定

録音する場合は `NSMicrophoneUsageDescription` とマイク許可要求を用意します。MacのサンドボックスアプリではAudio Input、ユーザー選択ファイルのアクセス、モデル取得時のOutgoing Connectionsも使用します。サンプルの [entitlements](../Examples/macOS/IrodoriMac.entitlements) と [プロジェクト設定](../Examples/IrodoriSamples.xcodeproj/project.pbxproj)を参照できます。

録音、再生のAudio Session、着信などの割り込み、バックグラウンド動作、モデル容量管理はアプリ側の責務です。初版SDKには汎用プレイヤー・録音UI・複数話者一覧は含めていません。

## 音声の透かし

生成音声にはAudioSealの透かしを標準で付与します。再生音声と保存WAVは同じPCMです。RTFには透かしの処理時間も含みます。[付与・検出の使い方](WATERMARK.md)を参照してください。

軽量INT8版にはSDK 0.2.0以降とiOS 18 / macOS 15以降が必要です。SDKのDeployment Targetは現行版に合わせたiOS 17 / macOS 14のままです。合成と参照登録APIは共通です。[モデル選択](COMPACT_MODELS.md)を参照してください。
