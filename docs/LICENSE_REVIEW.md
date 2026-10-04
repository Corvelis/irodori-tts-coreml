# ライセンスと上流モデル

SDK・サンプルの新規部分はApache-2.0です。モデルと上流由来部分には、それぞれMIT / Apache-2.0の条件が適用されます。同梱の `LICENSES/`、`NOTICE`、`THIRD_PARTY_NOTICES.md` を保持してください。

## 部品別の条件

| 部品 | ライセンス・出典 |
|---|---|
| Irodori TTS v4.1 Small MFとIrodori由来の実装 | MIT。[モデル](https://huggingface.co/Aratako/Irodori-TTS-v4.1-Small-MF)、[実装LICENSE](https://github.com/Aratako/Irodori-TTS/blob/89f9d8fbd4d51ea019867ee1197725ede1df13c5/LICENSE) |
| ModernBERT Japaneseのエンコーダー・tokenizer | MIT。[LICENSE](https://huggingface.co/sbintuitions/modernbert-ja-310m/blob/77675fc96a7e445e982e2ba90246b816efc74ec6/LICENSE) |
| Japanese Semantic-DACVAEの追加・変更部分 | MIT。[モデル](https://huggingface.co/Aratako/Semantic-DACVAE-Japanese-32dim)。Meta由来部分の条件を保持 |
| AudioSeal実装・付与/検出の重み | MIT。[公式実装](https://github.com/facebookresearch/audioseal)、[公式モデル](https://huggingface.co/facebook/audioseal)、[同梱LICENSE](https://github.com/Corvelis/irodori-tts-coreml/blob/v0.1.0/LICENSES/AudioSeal-MIT.txt) |
| Meta DACVAEの実装と元重み | Apache-2.0。[実装LICENSE](https://github.com/facebookresearch/dacvae/blob/main/LICENSE)、[重みのライセンスに関するMetaの回答](https://huggingface.co/facebook/dacvae-watermarked/discussions/1) |
| Descript DAC由来部分 | MIT。[LICENSE](https://github.com/descriptinc/descript-audio-codec/blob/main/LICENSE) |
| OnseiのONNX中間成果物 | 上記の部品別条件と帰属を保持。[配布元](https://huggingface.co/raratu/Onsei-iOS-Models) |

DACVAE元重みのREADMEにはSAMの記述がありますが、Metaは上の公式回答で重みもApache-2.0であると明示しています。元revisionと変換構成は `provenance.json` と部品別NOTICEに記載しています。

## 変更と再配布

Core ML変換には、cached attentionを使うDiT、精度設定、補助モデル分割、段階・タイル単位のデコード、Apple向けランタイム統合を含みます。変換後も各部品の著作権表示・ライセンス・NOTICE・変更表示を保持してください。[Apache-2.0](https://www.apache.org/licenses/LICENSE-2.0)と同梱のMIT条文を参照してください。

コミュニティによる変換・実装で、上流作者やAppleとの提携・推薦を意味しません。コードのライセンスはモデル重みや個人の録音の権利を置き換えません。

## 声と生成音声の利用

[Irodoriの使用条件](https://huggingface.co/Aratako/Irodori-TTS-v4.1-Small-MF#ethical-restrictions)に従い、使用許可のある声を使ってください。無断のなりすましや誤情報の拡散に使わず、合成音声を本人の実際の発話として偽らないでください。個人の音声を再配布する権利はモデルライセンスとは別です。



## 変換ツールの依存パッケージ

変換時の依存には [coremltools（BSD-3-Clause）](https://github.com/apple/coremltools/blob/main/LICENSE.txt)、[onnx2torch（Apache-2.0）](https://github.com/ENOT-AutoDL/onnx2torch/blob/main/LICENSE)、PyTorch、NumPy、ONNX、Transformers等を使います。それぞれのライセンスに従って別途インストールしてください。Python環境・依存パッケージ・Apple SDKはソース配布に同梱していません。
