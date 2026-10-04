# Mac CLIと測定方法

[README](../README.md) · [検証記録](VALIDATION.md) · [トラブル対処](TROUBLESHOOTING.md)

リポジトリのルートで実行します。`/path/to/...` は実ファイルに置き換えてください。CLIはWAVを生成し、再生はafplay等で行います。

```sh
swift build -c release
.build/release/irodori --help
.build/release/irodori verify --models ../Irodori-TTS-v4.1-Small-MF-CoreML
.build/release/irodori synthesize \
  --models ../Irodori-TTS-v4.1-Small-MF-CoreML \
  --reference /path/to/your-authorized-voice.wav \
  --text 'こんにちは。今日はいい天気ですね。' \
  --output /tmp/irodori-output.wav --report /tmp/irodori-report.json
afplay /tmp/irodori-output.wav
```

`--caption '落ち着いた、やさしい話し方。'` で声・話し方を指定できます。captionは本文として読ませず、独立した条件としてモデルへ渡します。日本語の短い説明を使ってください。参照ありなら、その声に合う感情や話し方を指定します。省略または空文字で無効になり、同じengineでは指示の特徴を再利用します。詳細は[Voice Design](API.md#声話し方の指示voice-design)を参照してください。

`--reference` を省くと参照なしで生成します。`--raw` は文章整形・分割を無効にします。`--repeat N` は同じengine・参照で1〜100回生成し、synthesizeでは最後の音声だけをoutputに保存します。出力WAVとレポートは既存ファイルを置換するため、残したい結果には別名を付けてください。

## モデル取得

配布先は [AILogDev/Irodori-TTS-v4.1-Small-MF-CoreML](https://huggingface.co/AILogDev/Irodori-TTS-v4.1-Small-MF-CoreML)です。以下のURLはサイズ・SHA-256を検証済みの準備版commitに固定しています。Privateの準備版はSDKの認証なしURL取得では使用できません。正式公開と公開URLからの取得検証はまだ完了していません。

```sh
.build/release/irodori download \
  --manifest 'https://huggingface.co/AILogDev/Irodori-TTS-v4.1-Small-MF-CoreML/resolve/af30c0101ebd6f714160b900d205b395845e43a6/manifest.json' \
  --destination /path/to/new-model-folder
```

出力先は未作成のフォルダを指定します。失敗後は同じURLと出力先で再試行すると検証済みファイルを再利用します。取得済みフォルダはdownloadせず、verifyしてからmodelsに指定します。

## 短文・長文の反復測定

```sh
.build/release/irodori benchmark \
  --models ../Irodori-TTS-v4.1-Small-MF-CoreML \
  --cases Benchmarks/cases.json \
  --reference /path/to/your-authorized-voice.wav \
  --repeat 3 --report /tmp/irodori-benchmark.json \
  --output-directory /tmp/irodori-benchmark-audio \
  --irodori-fixed-seed --irodori-seed 11 --irodori-diagnostics
```

音声の出力先ディレクトリは未作成のものを使います。各周の各文章を `pass-0-case-0.wav` のように保存します。casesは `[{"name":"short","text":"はい。"}]` 形式で1〜100件です。

**benchmarkは常にrawTextモードです。** 整形・長文の自動分割を含む通常利用を確認するときは、synthesizeをraw指定なしで使います。固定seedは比較時の診断用で、異なるOS・端末でもPCMが完全一致する保証ではありません。

| JSONの項目 | 意味 |
|---|---|
| `modelLoadMs` / `referenceMs` / `referenceCacheHit` | 準備時間と参照再利用 |
| `runs[].synthesisMs` / `audioSeconds` / `rtf` | 各回の合成時間・音声長・RTF |
| `runs[].firstPcmMs` | 最初のPCMが用意されるまで。実スピーカー開始ではない |
| `runs[].pcmSha256` | 完成PCMの比較用ハッシュ |
| `runs[].streamMatchesCompletedPcm` | 通知チャンクと完成PCMの一致確認 |
| `runs[].metrics` / `diagnostics` | 区間別のネイティブ診断情報 |

測定時は端末、OS、ビルド設定、モデル版、参照音声、文章、cold/warm、LLM等の同時処理を記録します。最初の1回を黙って捨てず、初回と反復時の結果を分けて報告してください。このCLIはASR/LLMを実行しません。

## 開発時の確認コマンド

```sh
swift test -c release
python3 -m unittest discover -s Scripts/tests
IRODORI_TEST_MODELS='/path/to/model-bundle' \
IRODORI_TEST_REFERENCE='/path/to/your-authorized-voice.wav' \
  swift test -c release --filter EngineIntegrationTests
```

通常のSwiftテストはモデルも参照音声もダウンロードせず、上記環境変数のない実モデルテストをskipします。skipを実モデル検証成功と扱わないでください。新しい端末での機能・音質確認は[検証記録](VALIDATION.md)の残項目に沿って実施します。
