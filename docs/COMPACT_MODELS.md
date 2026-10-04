# 重み共有モデル

[English](COMPACT_MODELS.en.md) · [モデル取得](HUGGINGFACE.md) · [変換コード](CONVERSION.md)

重み共有形式（`irodori-coreml-distribution-v2`）は、デコーダーstage 1の3つのモデルを1つのCore ML multifunctionパッケージにまとめます。同一の重みを共有するため、量子化や重みの丸めを追加せず、モデル一式を約170 MB削減できます。補助モデルのFP32、DiTのmixed-linear、デコーダーの既存精度とAudioSealはそのままです。

## 互換性

| 形式 | Core MLパッケージ数 | 必要なOS | SDK |
|---|---:|---|---|
| v1 | 15 | iOS 17 / macOS 14以降 | v0.1.0以降 |
| v2（重み共有） | 13 | iOS 18 / macOS 15以降 | v2形式を読み込めるSDKが必要。v0.1.0は非対応 |

SDKのAPIは共通です。`prepare(modelDirectory:)` にモデル一式の親フォルダを渡すと形式を判定します。v1も引き続き読み込めます。v2を古いOSで読み込むと、必要なOSを示すエラーになります。個別パッケージをv1/v2間で入れ替えず、対応するmanifestとモデル一式を使用してください。

重みファイルが同一でも、Core MLのコンパイルや実行経路による小さな数値差は起こり得ます。速度・出力・メモリを任意の端末で保証するものではありません。初回コンパイルの時間とキャッシュ容量は、ダウンロード容量とは別です。

## 変換・検証

変換環境は[変換ガイド](CONVERSION.md)を参照してください。検証済みのv1 runtimeフォルダからv2 runtimeを作成します。出力先は新しいフォルダを指定します。

```sh
python Conversion/share_decoder_weights.py \
  artifacts/runtime-v1 artifacts/runtime-v2 \
  --runtime-bundle --report artifacts/shared-decoder-report.json
python Scripts/stage_model.py lock \
  --source artifacts/runtime-v2 --output artifacts/shared.lock.json \
  --version 0.2.0-candidate
python Scripts/stage_model.py stage \
  --source artifacts/runtime-v2 --lock artifacts/shared.lock.json \
  --destination artifacts/shared-model
python Scripts/stage_model.py verify artifacts/shared-model
```

ツールは3つの元モデルと出力モデルの重みファイルのSHA-256が一致することを検査します。元モデルの重みが異なる場合や、指定先が既に存在する場合は停止します。梱包時は補助モデルとAudioSealの検証済みハッシュも確認します。

再変換後は固定seedで短文・通常文・長文、Voice Cloning、音声指示、透かし付き生成を比較してください。WAVの差とRTFの測定方法は[検証ガイド](VALIDATION.md)を参照してください。ハッシュ一致やlockの作成だけでは、生成品質と速度の検証を代替できません。
