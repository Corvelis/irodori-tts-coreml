# INT8版の音質と速度の比較

[English](QUALITY.en.md) · [軽量版の構成](COMPACT_MODELS.md) · [測定データ](../Distribution/quality-results)

軽量版はテキストエンコーダーの重みをINT8で保存します。音質の差は単一の「劣化率」ではなく、エンコーダーの数値誤差、認識した発話内容、推定音声品質、音響差を個別に測定します。以下はこの条件での比較結果です。

## 生成音声の比較

Apple M2 MacBook Air（24 GB）、macOS 27.2、Release構成で、24種類の日本語文章をseed 11・29・47で生成しました。現行版とINT8版の72組・144本を比較しています。一度に保持するengineは1つで、seedごとにモデル順を入れ替えました。AudioSealは有効です。

短文、通常文、数字、地名、長い一文、複数文、話し方の指示4条件、合成参照音声によるVoice Cloning4条件を含みます。各ロードの先頭2発話はウォームアップとして集計から除きました。本文の整形・文分割を無効にしてモデル間の差を比較しています。

| 指標 | 現行版 | INT8版 | 差 |
|---|---:|---:|---:|
| ASR文字誤り率（読みの正規化後） | 6.5217% | 5.5797% | −0.9420ポイント |
| DNSMOS総合 OVRL（推定値） | 3.0365 | 3.0311 | −0.0054点 |
| DNSMOS音声 SIG（推定値） | 3.2993 | 3.2917 | −0.0075点 |
| DNSMOS背景 BAK（推定値） | 4.0024 | 4.0009 | −0.0015点 |
| DNSMOS P.808（推定値） | 3.6338 | 3.6331 | −0.0006点 |
| PCM飽和サンプル率 | 0.000140% | 0.000154% | +0.000014ポイント |

文字誤り率が増えた組は0/72、減った組は4/72で、認識した読みが一致した組は68/72でした。CER差の文章単位bootstrap 95%区間は **−3.0146〜0.0000ポイント**、DNSMOS OVRL差は **−0.0189〜+0.0076点**です。有限なPCMと通知PCM・完成PCMの一致は全組で確認できました。

### 条件ごとの差

| 条件 | 組数 | OVRL 現行版 | OVRL INT8版 | 平均差 |
|---|---:|---:|---:|---:|
| 通常の本文（短文・長文・数字等） | 48 | 3.0712 | 3.0757 | +0.0045点 |
| 話し方の指示 | 12 | 2.9185 | 2.8956 | −0.0230点 |
| 合成参照音声によるVoice Cloning | 12 | 3.0158 | 2.9882 | −0.0276点 |

最もOVRLが下がった組は `reference-normal` / seed 11で、**3.1320 → 2.9758（−0.1562点）**でした。全体の平均差だけで、すべての条件の品質が同一とは判断しません。

長さの絶対変化は中央値0%、最大3.2258%。音量の絶対差は中央値0.0107 dB、時間を正規化したlog-melスペクトルRMSEは中央値1.0859 dBです。PCM飽和は現行版29/20,780,160サンプル、INT8版32/20,802,240サンプルでした。微小な位相・長さの変化も音響差に含まれます。

### 評価の意味と限界

- ASRはReazonSpeechのINT8 transducerを同じ条件で使い、pyopenjtalkで期待文と認識文の読みを正規化しています。CERは認識内容の指標です。ASRの欠落・誤認識や辞書の読みも影響するため、実際の発音誤り率と同一ではありません。今回の絶対CERには、両モデルに共通する文頭等の認識欠落も含まれます。
- [Microsoft公式DNSMOS](https://github.com/microsoft/DNS-Challenge/tree/591184a9fcb2cbdec02520fed81a32bbbf9d73ff/DNSMOS)は雑音抑制向けに開発された推定音声品質指標です。人が評価したMOS、TTSの自然さ、声の本人一致度の測定ではありません。公式手順に従い16 kHzへ変換し、9.01秒未満の音声は評価器が繰り返して評価します。
- bootstrapは同じ文章のseed違いを1つのclusterとして再抽出しています。この24文章における区間であり、任意の言語・声・端末への保証ではありません。
- 参照音声は1種類の合成音声です。実話者・複数話者の声質を網羅した比較ではありません。聴感と自分の声での確認も併用してください。

測定上、平均の品質差は小さく、今回のASR評価では内容の悪化は観測されませんでした。条件別の差は残るため、「音質劣化率0%」とは表記しません。

## テキスト特徴の数値誤差

FP32 Core MLとINT8重み版をCPU_ONLYで比較しました。28自然文・話し方の指示に、256トークン入力とmask付きpaddingを加えた30入力・60出力です。

| 指標 | 結果 |
|---|---:|
| 自然文の最大相対L2誤差 | 1.1347% |
| 自然文の最低コサイン類似度 | 0.9999356 |
| 全入力の最大相対L2誤差 | 2.0045% |
| 全入力の最大絶対誤差 | 0.0789679 |
| 全入力の最低SNR | 33.9599 dB |
| 全入力の最低コサイン類似度 | 0.9997991 |

相対L2誤差は `100 × ||INT8出力−FP32出力||₂ / ||FP32出力||₂` です。**2.0045%はエンコーダー特徴量の誤差であり、音質が2.0045%悪化したという意味ではありません。** 報告はモデル・tokenizer・比較文章のハッシュに紐づけています。元FP32版のTorch/ONNXとの一致許容値は、量子化版へ流用しません。

公開変換ツールの再実行で、実機試験したINT8モデルと重みbyte列・演算グラフの意味が一致することも確認しています。Core MLの生成UUIDやprotobufのmap格納順により、パッケージのbyte列全体は変わる場合があります。

## iPhoneの速度

iPhone 17 Pro / iOS 27.0.1 / Release、AudioSeal有効、1 engineずつ、固定seedでの再比較です。短文や初回を含む実機試験は合計120生成。以下は反復時の中央値です。

| 条件 | 集計数 / モデル | RTF 現行版 | RTF INT8版 | 最初のPCM 現行版 | 最初のPCM INT8版 |
|---|---:|---:|---:|---:|---:|
| 通常文 | 5 | 0.1253 | 0.1286 | 460 ms | 480 ms |
| 長い一文 | 4 | 0.1248 | 0.1232 | 1,352 ms | 1,421 ms |
| 参照音声＋指示 | 3 | 0.1292 | 0.1362 | 483 ms | 509 ms |

TTSのみの測定で、ASR・LLM・モデル準備・実スピーカーの遅延は含みません。最初のPCMはcallback準備時刻です。全文WAV完成後に再生するサンプルの再生開始時刻ではありません。短文は固定費の影響でRTFが上がり、初回の準備・特殊化にも追加時間がかかります。端末・熱状態・入力による速度差は残ります。

## 再測定する

```sh
python -m pip install -r Benchmarks/requirements.txt
python Benchmarks/run_quality.py \
  --cli .build/release/irodori --baseline ../Models-Standard --candidate ../Models-INT8 \
  --reference ./authorized-reference.wav --output artifacts/quality-audio
python Benchmarks/analyze_quality.py \
  --input artifacts/quality-audio --asr-models ../ReazonSpeech-ONNX \
  --report artifacts/audio-quality.json
```

ASRフォルダには `encoder-epoch-35-avg-1.int8.onnx`、`decoder-epoch-35-avg-1.int8.onnx`、`joiner-epoch-35-avg-1.int8.onnx`、`tokens.txt` を用意します。使用したモデルのSHA-256は測定JSONに記載しています。[ReazonSpeech公式](https://github.com/reazon-research/ReazonSpeech)と[sherpa-onnxのモデル案内](https://k2-fsa.github.io/sherpa/onnx/pretrained_models/offline-transducer/index.html)を参照してください。別名のモデルは `--encoder-file`、`--decoder-file`、`--joiner-file` で指定できます。同じ数値の再現には測定JSONのハッシュと一致するASRを使い、別のASRを使った結果とは区別してください。

DNSMOSは公式リポジトリのcodeと評価モデルを別途取得します。SDK・アプリの実行依存には追加されません。測定に使ったrevisionとファイルハッシュは `Benchmarks/dnsmos.sources.json` に記載しています。

```sh
git clone https://github.com/microsoft/DNS-Challenge.git ../DNS-Challenge
git -C ../DNS-Challenge checkout 591184a9fcb2cbdec02520fed81a32bbbf9d73ff
python Benchmarks/score_dnsmos.py --input artifacts/quality-audio \
  --dnsmos ../DNS-Challenge --report artifacts/dnsmos-quality.json
```

測定結果は[JSON一式](../Distribution/quality-results)、比較文章は[quality-cases.json](../Benchmarks/quality-cases.json)にあります。[inference artifact lock](../Distribution/quality-runtime.lock.json)は測定したモデル構成を定義します。録音やWAVはソース配布に含みません。自分の声を使った測定結果を共有するときは、入力・参照音声の公開範囲を確認してください。
