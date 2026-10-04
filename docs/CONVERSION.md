# 再変換手順

[README](../README.md) · [CLIでの比較](CLI.md) · [検証記録](VALIDATION.md)

通常の利用は変換済みモデルから始めてください。変換にはApple Silicon Mac、Python 3.11、Xcode/Command Line Tools、gitと多めのディスク空き容量が必要です。元チェックポイントとONNXだけで約6 GBあり、中間モデルと複製も作成します。

```sh
python3.11 -m venv .venv
. .venv/bin/activate
python -m pip install -r Conversion/requirements.txt
python Conversion/fetch_sources.py artifacts/sources
python Conversion/convert_all.py --sources artifacts/sources --output artifacts/conversion --dry-run
python Conversion/convert_all.py --sources artifacts/sources --output artifacts/conversion
```

`requirements.txt` は既存の変換に使用した主要依存のバージョンを固定しています。すべての推移依存を固定したlockではありません。今回整理した一括手順のクリーン環境での全再実行は未完了です。PyTorch 2.11 / coremltools 9.0 の組み合わせはcoremltools側の公式検証範囲を超える警告が出るため、出力の数値検証を省かないでください。

`fetch_sources.py` はHF revisionとSHA-256を固定して入力を取得します。検証済みファイルは再利用し、不一致ファイルは上書きせず停止します。公式実装も指定commitの未変更checkoutを要求します。

一括変換はcontext KV分割、decoder段分割、参照統計抽出、補助7モデルのFP32変換・動的形状検証、cached mixed-linear DiT、既存FP16 decoderタイルの変換を順に実行します。ログは出力フォルダに保存します。補助モデルのCore ML対ONNX最大絶対誤差 `1e-3` 以下、およびstage 1タイルの一致を検証します。これは全体の音質判定の代わりにはなりません。

実行時はCore MLだけですが、変換工程では元のONNXとPyTorchチェックポイントを使用します。全段を公式PyTorchから直接変換するツールではありません。

## 配布候補の作成

既に検証した現在のモデルには `Distribution/artifacts.lock.json` が対応しています。

```sh
python Scripts/stage_model.py stage \
  --source /path/to/validated-runtime-bundle \
  --destination /path/to/new-Irodori-TTS-v4.1-Small-MF-CoreML
python Scripts/stage_model.py verify /path/to/new-Irodori-TTS-v4.1-Small-MF-CoreML
```

再変換したモデルのbyte列は、Core MLの生成UUIDやツール版で変わる場合があります。
その場合は別のcandidate lockを作り、元モデルと固定seedで音声・RTFを比較した後、そのlockを指定してローカル候補を梱包します。

```sh
python Scripts/stage_model.py lock \
  --source artifacts/conversion/runtime-bundle \
  --output artifacts/candidate.lock.json --version 0.1.0-candidate
python Scripts/stage_model.py stage \
  --source artifacts/conversion/runtime-bundle \
  --lock artifacts/candidate.lock.json --destination artifacts/candidate-model
```

lockはbyte列の記録です。作成できたことは品質・速度・再配布条件の承認ではありません。
短文、通常文、短文反復後の長文、参照切り替え、参照なし、停止後の再生成を確認してください。
他の推論・変換プロセスを同時実行すると速度比較が変わるため、順番に測定します。

[公開前の条件](RELEASE.md)を確認してから公開先へ進んでください。このリポジトリに自動アップロード処理はありません。
