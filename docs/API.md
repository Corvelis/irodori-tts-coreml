# Swift APIリファレンス

[導入](GETTING_STARTED.md) · [音声登録](VOICE_REGISTRATION.md) · [再生と停止](STREAMING.md)

対象は `0.1.0` のSwift APIです。[実装](../Sources/IrodoriTTS)に対応しています。

## IrodoriEngine

`public final class IrodoriEngine: @unchecked Sendable`。`IrodoriEngine()` で作成します。ネイティブ状態を専用の直列キューに閉じ込め、各操作を順番に処理します。同時呼び出しを行っても1つのengine内で推論が並列化されるわけではありません。

| メソッド | 結果・役割 |
|---|---|
| `prepare(modelDirectory: URL) async throws -> Double` | モデル構造を検証しロード。戻り値はロード時間ms。構造検査の時間はこの値に含まない。同じURLを保持中なら0 |
| `registerReference(_ url: URL?) async throws -> ReferenceRegistration` | モデル準備後に呼ぶ。参照を読込・変換し特徴を準備。nilで参照なし |
| `synthesize(_ text: String, caption: String = "", rawText: Bool = false, splitSentences: Bool = true, onChunk: (@Sendable (PCMChunk) -> Void)? = nil) async throws -> SynthesisResult` | 文章から音声を生成。文分割とチャンク通知は任意 |
| `clearReferenceCache() async throws` | 保持中の参照と参照特徴ディスクキャッシュを削除。元音声やモデルは残す |
| `release() async` | モデル・参照セッションを解放。次の合成には再度prepareが必要。ディスクキャッシュは残す |

基本順序は `prepare → registerReference → synthesize` です。会話中はengineとモデルを保持します。声を変えるときに登録を更新し、会話が終わったときに解放します。不要な複数engineはモデル保持を重複させます。

ロード済みモデルを同じパスで上書きしてもprepareは再読込しません。モデルは不変のフォルダで管理し、更新後は新しいURLへ切り替えます。prepareの構造検査と、取り込み時の全ファイルハッシュ検証は別です。

## 声・話し方の指示（Voice Design）

```swift
let audio = try await engine.synthesize(
    "今日はいい天気ですね。",
    caption: "落ち着いた、やさしい話し方。自然な抑揚で話す。"
)
```

`caption` は本文とは別の条件として渡す日本語の説明です。参照音声なしでも利用でき、参照ありなら感情や話し方の調整に使えます。空文字（既定値）で無効になります。本文の整形・分割はcaptionには適用しません。指示はBOSを含め最大256トークンで、超過はPCM通知前にエラーになります。短く、一貫した説明を使ってください。

同じengine内では直前の指示のエンコーダー出力をメモリーに保持し、連続する文や生成で再利用します。指示の変更時は再計算し、空文字・release・モデル変更で破棄します。ディスクには保存しません。初回・変更時の追加時間は `captionEncoderMs`、再利用は `captionCacheHit`、有効状態は `captionEnabled` で確認できます。指示用の状態は最大約512KiBです。

参照と矛盾する声質指定や複雑な指示は、崩れや不自然な音につながる場合があります。参照を使う場合はその声に合う感情・話し方を指定してください。指示への追従は保証されません。[公式MFモデルの制約](https://huggingface.co/Aratako/Irodori-TTS-v4.1-Small-MF#%E2%9A%A0%EF%B8%8F-limitations)も参照してください。対応モデルは4ステップで合成します。

## 入出力の型

### PCMChunk

| プロパティ | 内容 |
|---|---|
| `pcm16: Data` | WAVヘッダーなし、little-endian signed PCM16、mono |
| `sampleRate: Int` | 48,000 Hz |
| `sequence: Int` | 1回のsynthesize内で0から増える番号。文をまたいで継続 |

コールバックは推論キュー上で同期的に呼ばれます。UI更新・再生キューへの投入はMainActorへ渡し、コールバック内で重いI/Oや待機をしないでください。成功時は通知順のチャンクを連結すると `SynthesisResult.pcm16` と一致します。

### SynthesisResult

| プロパティ / メソッド | 内容 |
|---|---|
| `pcm16: Data` | 全文の完成PCM。チャンクを利用する場合もメモリに保持 |
| `preparedText: String` | 整形後の入力。rawText時は渡した文字列 |
| `synthesisMilliseconds: Double` | 各文のネイティブ合成呼び出し周辺の経過時間の合計。長さ制限による再試行と同期コールバックの処理時間も含む |
| `firstPCMMilliseconds: Double` | 整形・初期文分割後から最初のPCMが用意されるまで。キュー待ち、モデル・参照準備、スピーカー遅延は含まない |
| `audioSeconds: Double` | PCMバイト数÷96,000 |
| `rtf: Double` | 合成ミリ秒÷1,000÷音声秒数 |
| `sentenceCount: Int` | 合成に成功した区間数。上限対処の分割により入力の文数より増える場合がある |
| `metrics: [[String: Double]]` | 各成功区間のネイティブ数値診断。キーは固定APIとして保証しない |
| `diagnostics: [[String: String]]` | 各成功区間の文字列診断。キーは実行条件で異なる |
| `writeWAV(to: URL) throws` | 48 kHz mono PCM16 WAVをatomicに書く。親フォルダは呼び出し側で作成。既存ファイルは置換 |

RTFは呼び出し元から見た総待ち時間そのものではありません。ASR/LLMを含む応答時間はアプリ側で別途計測します。完成PCMは1分あたり約5.76 MBあり、モデル・中間テンソル・再生バッファのRAMは別に必要です。

### ReferenceRegistration

`milliseconds: Double` は音声読込・変換から特徴準備までの時間、`cacheHit: Bool` は保持中またはディスク上の特徴を再利用したかどうかです。詳細は[音声登録とキャッシュ](VOICE_REGISTRATION.md)を参照してください。

## 文章整形と長文

`SpeechText.prepare(_ input: String) -> String` はMarkdownやURLを読み上げ用に整えます。`SpeechText.sentences(_ text: String) -> [String]` は渡された文字列を句点・疑問符・感嘆符・改行で分けます。prepareは空白・改行を整理するため、通常のsynthesizeは主に文末記号で分割されます。

| 入力 | 通常モードでの扱い |
|---|---|
| `**様々**な方法` | 装飾を除き「様々な方法」。漢字の読みを辞書で書き換える処理はない |
| `[詳しくはこちら](https://example.com)` | 表示文字だけを残す |
| 単独の `https://example.com` | 「リンク」に置換 |
| `明日（火曜日）です。` | 丸括弧を読点へ置換し、中身を残す |
| 三連バッククォートのコードブロック | 読み上げ対象から除外 |
| 絵文字・装飾記号 | 対象の記号を除去。読める文字が残らなければエラー |

現行DiTの上限はBOSを含むtext 256 tokens、latent 768 framesです。既定の `splitSentences: true` では上限超過の一文を分割し、PCMをまだ出していない場合のみ再試行します。自動分割で間合いが変わる場合があります。別の推論エラーをすべて自動復旧する機能ではありません。

`splitSentences: false` は読み上げ用整形を保ち、入力全体を1回の合成へ渡します。句読点で分割せず、上限超過時の自動分割も行いません。上限超過のエラーはPCM通知前に返します。長さの上限内で利用してください。`onChunk` を省くと完成PCMだけを取得でき、サンプルはこれをWAVに保存してから再生します。指定した場合は、全文一回でもデコーダのPCMチャンクを受け取れます。

```swift
let result = try await engine.synthesize(
    "こんにちは。今日はいい天気ですね。",
    caption: "落ち着いた、やさしい話し方。",
    splitSentences: false
)
try result.writeWAV(to: outputURL)
```

SDKとCLIは、文分割の指定を省くと既定の文分割を使います。

`rawText: true` は整形・文分割・上限時の分割再試行を無効にする比較用モードです。長文やチャット表示文には通常モードを使ってください。ASR、LLM、画像理解、読み辞書はこのSDKに含まれません。Voice Designは上記の `caption` で指定できます。

## モデル検証と取得

| API | 内容 |
|---|---|
| `ModelBundle.validate(at: URL, verifyHashes: Bool = false) throws` | 必須パス・FP32補助モデルmetadataの構造検査。trueならmanifest内の全サイズ・SHA-256も検証 |
| `ModelBundle.manifest(from: Data) throws -> ModelManifest` | manifestの形式、重複パス、必須項目等を検証してデコード |
| `ModelBundle.checksum(_ url: URL) throws -> String` | ファイルのSHA-256。1 MBずつ読み込む |
| `ModelBundle.safeURL(_ path: String, under: URL) throws -> URL` | 相対パス検証。traversalとパス中のsymlinkを拒否 |
| `ModelBundle.requiredPaths: [String]` | ランタイムが必要とする相対パス。auxiliary / decoderAndDiTは構成名一覧 |
| `ModelDownloader().download(manifestURL: URL, to: URL, progress: @Sendable (Int, Int, String) -> Void) async throws` | HTTPS取得、検証、完成フォルダへの移動。progressは省略可能 |

`ModelManifest` はCodable/Sendableで、`format`、`bundleVersion`、`files` を持ちます。各FileEntryは `path: String`、`bytes: Int64`、`sha256: String` です。配布manifestの追加metadataはこの型では公開しません。

Downloaderのprogressは処理済みファイル数、全ファイル数、現在のパスを通知します。バイト数や残り時間ではありません。MainActor上のコールバックではないためUIへ渡す際は切り替えてください。出力先は未作成フォルダを指定します。再試行は同じmanifest URLと出力先で行い、完了済みの検証済みファイルを再利用します。1ファイルの途中からのHTTP再開は実装していません。

manifestは署名ではなく整合性情報です。信頼する公開者のHTTPS URLを不変のcommit SHAに固定してください。モデル一式が揃えば、生成のための通信は不要です。

## 音声ユーティリティとエラー

`ReferenceAudio.read(_ url: URL) throws -> Data` は48 kHz mono Float32へ変換します。`ReferenceAudio.writeWAV(pcm16: Data, to: URL) throws` はPCM16からWAVを書きます。readのFloat32をそのままwriteWAVに渡してはいけません。

入力・モデルの検証エラーは `IrodoriError.invalid(String)`、キャンセルは `CancellationError`、ファイル・Core ML等の失敗は元のErrorとして伝わります。`error.localizedDescription` を表示し、[トラブル対処](TROUBLESHOOTING.md)で切り分けます。

合成Taskのキャンセルは以後のチャンクを破棄しますが、すでにアプリへ渡したPCMや進行中のCore ML予測は取り消しません。再生の停止、古いチャンクの除外、次のリクエストの管理は[再生例](STREAMING.md)を参照してください。
