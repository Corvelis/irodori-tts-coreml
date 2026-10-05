# 軽量INT8モデル

[English](COMPACT_MODELS.en.md) · [モデル取得](HUGGINGFACE.md) · [音質の比較](QUALITY.md)

軽量INT8版は約1.96 GBで、現行版約2.99 GBから約34%削減しています。テキストエンコーダーの大きな重みをINT8 symmetric / per-block 128で保存し、FP32の計算・入出力を維持します。DiTのmixed-linear、他の補助モデルのFP32、デコーダーの既存精度、AudioSealは共通です。

固定幅のstage 1デコーダーは同じ重みをmultifunctionパッケージで共有します。可変幅デコーダーは独立パッケージとして保持します。配布するv2モデルはこのiPhone / Mac共通構成で、14パッケージを含みます。

| モデル | 形式 | パッケージ数 | 対応OS | SDK |
|---|---|---:|---|---|
| 現行版 約2.99 GB | v1 | 15 | iOS 17 / macOS 14以降 | 0.1.0以降 |
| 軽量INT8版 約1.96 GB | v2 | 14 | iOS 18 / macOS 15以降 | 0.2.0以降 |

合成・参照登録APIは共通です。`prepare(modelDirectory:)` に一式の親フォルダを渡します。登録音声、日本語Voice Design、透かしを両方で利用できます。各版のフォルダとmanifestを保持し、モデルの部品を入れ替えないでください。

ファイル容量と実行時RAMは異なります。Core MLのコンパイルキャッシュや中間テンソルの容量は別です。INT8版のすべての発話・端末で速度や音質が一致するという意味ではありません。測定条件と数値は[音質比較](QUALITY.md)を参照してください。

## 軽量モデルを作る

[変換環境](CONVERSION.md)を用意し、検証済みのv1モデル一式から作成します。新しい保存先を指定してください。

```sh
python Conversion/make_light_bundle.py artifacts/runtime-v1 artifacts/runtime-int8
python Scripts/stage_model.py lock \
  --source artifacts/runtime-int8 --output artifacts/int8.lock.json --version 0.2.0-int8
python Scripts/stage_model.py stage \
  --source artifacts/runtime-int8 --lock artifacts/int8.lock.json --destination artifacts/model-int8
python Scripts/stage_model.py verify artifacts/model-int8
```

変換ツールはデコーダー重みの同一性を確認し、テキストエンコーダーを圧縮した後、自然文と最大長・mask付き入力でFP32版との差を測定します。数値検証レポートはモデルハッシュとtokenizerハッシュに紐づきます。元FP32モデルのTorch検証結果を量子化モデルの結果として扱いません。

再変換後は[音声比較ツール](QUALITY.md#再測定する)で生成音声と速度も比較してください。数値検証の合格やハッシュ一致だけでは、音質と端末上の動作を確認できません。
