# 変換コードの参考実装

[README](../README.md) · [CLIでの比較](CLI.md) · [性能の測定と制約](VALIDATION.md)

通常の利用は変換済みモデルから始めてください。変換にはApple Silicon Mac、Python 3.11、Xcode/Command Line Tools、gitと多めのディスク空き容量が必要です。元チェックポイントとONNXだけで約6 GBあり、中間モデルと複製も作成します。

```sh
python3.11 -m venv .venv
. .venv/bin/activate
python -m pip install -r Conversion/requirements.txt
python Conversion/fetch_sources.py artifacts/sources
python Conversion/convert_all.py --sources artifacts/sources --output artifacts/conversion --dry-run
python Conversion/convert_all.py --sources artifacts/sources --output artifacts/conversion
```

`requirements.txt` は既存の変換に使用した主要依存のバージョンを固定しています。すべての推移依存を固定したlockではありません。変換コードは参考実装です。再変換の成功や任意の環境での互換性を保証するものではありません。PyTorch 2.11 / coremltools 9.0 の組み合わせはcoremltools側の公式検証範囲を超える警告が出るため、出力の数値検証を省かないでください。

`fetch_sources.py` はHF revisionとSHA-256を固定して入力を取得します。検証済みファイルは再利用し、不一致ファイルは上書きせず停止します。公式実装も指定commitの未変更checkoutを要求します。

一括変換にはAudioSeal付与・検出モデルのFP32変換と数値検証も含みます。`audioseal.sources.json` が公式重みのrevision・SHA-256と実装版を固定します。透かし部分だけの変換は `python Conversion/export_audioseal.py --destination artifacts/audioseal` で実行できます。

一括変換はcontext KV分割、decoder段分割、参照統計抽出、補助7モデルのFP32変換・動的形状検証、cached mixed-linear DiT、既存FP16 decoderタイルの変換を順に実行します。ログは出力フォルダに保存します。補助モデルのCore ML対ONNX最大絶対誤差 `1e-3` 以下、およびstage 1タイルの一致を検証します。これは全体の音質判定の代わりにはなりません。

実行時はCore MLだけですが、変換工程では元のONNXとPyTorchチェックポイントを使用します。全段を公式PyTorchから直接変換するツールではありません。

既存のstage 1デコーダー3モデルの同一重みを共有する場合は、[重み共有形式のガイド](COMPACT_MODELS.md)に従って `share_decoder_weights.py` を実行してください。重みの精度は変えず、iOS 18 / macOS 15以降のmultifunctionモデルを作成します。

## 配布候補の作成

`Distribution/artifacts.lock.json` は配布版モデルのファイルサイズとSHA-256を定義します。

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

lockはファイルの同一性を検査するmetadataです。再変換したモデルの音質・速度と利用条件は別途確認してください。
短文、通常文、短文反復後の長文、参照切り替え、参照なし、停止後の再生成を確認してください。
他の推論・変換プロセスを同時実行すると速度比較が変わるため、順番に測定します。

再配布する場合は[部品別ライセンス](../THIRD_PARTY_NOTICES.md)を保持してください。

## INT8の軽量版

`Conversion/make_light_bundle.py` は重み共有とINT8テキスト重みを組み合わせたiPhone / Mac共通構成を作成します。[軽量モデルの変換](COMPACT_MODELS.md)を参照してください。`quantize_text_encoder.py` と `validate_quantized_text.py` は個別にも実行できます。量子化モデルには専用の数値検証レポートが必要で、配布ツールは元FP32の検証済みフラグだけでは受け入れません。
