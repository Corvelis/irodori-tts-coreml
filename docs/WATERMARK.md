# 音声の透かし

[English](WATERMARK.en.md) · [API](API.md) · [CLI](CLI.md)

SDK・CLI・サンプルは、生成した音声へ **AudioSealの透かしを標準で付与**します。再生用のPCMチャンクと完成PCM、保存したWAVに同じ透かしが含まれます。音声を聞くだけで識別するものではなく、AudioSealの検出モデルで分析します。

## SDKで使う

通常の呼び出しで有効です。モデル一式には `audioseal_generator.mlpackage`、`audioseal_detector.mlpackage`、`audioseal.json` が必要です。

```swift
let audio = try await engine.synthesize("こんにちは。今日はいい天気ですね。")
try audio.writeWAV(to: outputURL)
print(audio.watermark?.identifier as Any) // 18770 = 0x4952
print(audio.watermark?.processingMilliseconds as Any)
```

16ビットの識別値は指定できます。値は下位ビットから格納します。

```swift
let audio = try await engine.synthesize(
    "こんにちは。",
    watermark: WatermarkOptions(identifier: 1234)
)
```

比較などで付与を無効にする場合は `watermark: nil` を指定します。既存の音声へ重ねて付与しないでください。

```swift
let audio = try await engine.synthesize("こんにちは。", watermark: nil)
```

## 検出する

生成済みPCMは、準備済みengineで分析できます。

```swift
let detection = try await engine.detectWatermark(in: audio.pcm16)
print(detection.detected, detection.score, detection.identifier)
```

TTS本体をロードせず、透かしの付与・検出だけを使う場合は `AudioWatermarker` を利用します。

```swift
let marker = AudioWatermarker()
try await marker.prepare(modelDirectory: models)
let marked = try await marker.apply(to: originalPCM16)
let detection = try await marker.detect(in: marked.pcm16)
try marked.writeWAV(to: outputURL)
await marker.release()
```

入力はWAVヘッダーを除いた48 kHz、mono、little-endian PCM16です。`ReferenceAudio.read` の戻り値はFloat32なので、そのまま渡してはいけません。

`score` は、分析したサンプルのうち検出モデルの正の確率が0.5を超えた割合です。SDKはscore 0.5以上を `detected: true` とします。`bitProbabilities` は16ビットの各確率、`identifier` はそれらを0.5で二値化した値です。検出されない場合の識別値は使用しないでください。

## CLI

```sh
.build/release/irodori synthesize --models ./Models --text 'こんにちは。今日はいい天気ですね。' --output ./speech.wav
.build/release/irodori detect-watermark --models ./Models --input ./speech.wav
```

識別値の変更は `--watermark-id 1234`、無効化は `--no-watermark` です。既定値は18770です。`--report` の各runにはalgorithm、identifier、processingMsを記録します。

## 処理と制約

原音を48 kHzのまま保持し、16 kHzに変換した分析信号から透かしを生成します。透かし信号だけを48 kHzへ戻して加算します。TTSモデルの重み・生成ステップ数は変更しません。無音付近では透かし信号を減衰し、完全な無音に新たな音を加えません。

2秒の固定窓から中央1秒分を出力します。PCMチャンク通知では0.5秒分の音声を先読みするため、透かしなしの場合より最初の通知が遅くなることがあります。これは音声の長さであり、壁時計で0.5秒待つという意味ではありません。サンプルの全文生成・完成WAV再生の方式は同じです。

`synthesisMilliseconds`・RTF・`firstPCMMilliseconds` は透かし処理を含みます。`watermark.processingMilliseconds` は透かし処理だけの時間で、再生コールバック内の処理は含みません。モデル準備時の透かしモデルのコンパイル・ロード・初期推論はRTFに含みません。検出モデルは分析時にロードします。

透かしは波形を微小に変更します。聴感への影響と処理時間は音声・端末によって変わります。極端に短い音声、無音、強い加工・圧縮では検出や識別値の復元が不安定になることがあります。16ビットの識別値と検出スコアは署名や本人確認ではなく、改変不能な出所証明でもありません。

[AudioSeal公式実装](https://github.com/facebookresearch/audioseal)と[モデル](https://huggingface.co/facebook/audioseal)はMITです。同梱の[ライセンス](../LICENSES/AudioSeal-MIT.txt)と[部品別表示](../THIRD_PARTY_NOTICES.md)を保持してください。
