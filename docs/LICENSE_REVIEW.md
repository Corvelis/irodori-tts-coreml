# 配布ライセンスの確認記録

確認日: 2026-10-02。対象: `0.1.0-draft` のSDK・サンプル・変換器と、ロックした元データから作成したCore MLモデル。公開済みの一次資料を確認した記録です。実機品質や全変換手順の確認は別です。

## 結論

今回の構成は、各部品のMIT / Apache-2.0と上流モデルカードの使用条件を保持して、コードとCore ML変換済みモデルを配布する根拠が確認できました。DACVAE元重みを「条件未確定」としていた旧記録は訂正します。SDKの新規部分は既存のApache-2.0方針を維持し、モデル全体を単一のMITとして扱いません。

## DACVAEの表記の食い違い

[公式Hugging FaceのLicense discussion #1](https://huggingface.co/facebook/dacvae-watermarked/discussions/1)で、Meta組織のメンバーとして表示されるMatt Le (`lematt1991`) が、2025-12-19、重みもApache-2.0であると回答しています。

> Yes, also apache-2.0. Updated the model card

これは「モデルの重みのライセンスは？」という質問への回答です。APIでも `isOrgMember: true` と確認しました。対象回答のevent IDは `69458aa9682b3352e8a576e3`、時刻は `2025-12-19T17:26:01.000Z` です。

[モデルREADME](https://huggingface.co/facebook/dacvae-watermarked/blob/8680102d141858a21bd533543966a2eb2e569f92/README.md)にはSAM表記が今も残っていますが、metadataはApache-2.0です。[README訂正PR #2](https://huggingface.co/facebook/dacvae-watermarked/discussions/2)もあります。READMEが更新されたと断定せず、この明示的な重みの回答と[公式実装のApache-2.0 LICENSE](https://github.com/facebookresearch/dacvae/blob/main/LICENSE)を根拠として記録します。

## 部品別の確認

| 配布対象 | 確認した条件・出典 |
|---|---|
| SDK・サンプルの新規部分 | 既存のApache-2.0。上流由来部分の条件・帰属を保持 |
| Irodori MF重み・Irodori由来の変換モジュール | [MFモデルカード](https://huggingface.co/Aratako/Irodori-TTS-v4.1-Small-MF)はMIT。[使用コードのLICENSE](https://github.com/Aratako/Irodori-TTS/blob/89f9d8fbd4d51ea019867ee1197725ede1df13c5/LICENSE)もMIT |
| ModernBERTのエンコーダー・辞書 | [固定revisionのLICENSE](https://huggingface.co/sbintuitions/modernbert-ja-310m/blob/77675fc96a7e445e982e2ba90246b816efc74ec6/LICENSE)はMIT、SB Intuitionsの著作権表示 |
| 日本語Semantic-DACVAEの追加・変更部分 | [モデルカード](https://huggingface.co/Aratako/Semantic-DACVAE-Japanese-32dim)はMIT。Meta由来の部品の条件は保持 |
| Meta DACVAEの実装と元重み | Apache-2.0。元重みも対象であることは上記のMeta回答で確認 |
| Descript DAC由来部分 | [公式LICENSE](https://github.com/descriptinc/descript-audio-codec/blob/main/LICENSE)はMIT |
| OnseiのONNX中間成果物 | [配布元](https://huggingface.co/raratu/Onsei-iOS-Models)の部品別条件と帰属を維持。v4.1 MFに含まれるModernBERTを使用し、旧版llm-jp辞書は同梱しない |

使用したrevisionと取得資料のSHA-256は機械可読のlicense-review.jsonに記録します。元モデルや変換入力の全ファイルのロックは変更していません。

## 配布時に保持するもの

[Apache-2.0の第2・4節](https://www.apache.org/licenses/LICENSE-2.0)は変更・派生成果物の配布を認め、ライセンスの写し、帰属・NOTICE、変更の明示を要求します。したがってCore ML変換自体のために追加の許可を得る必要はないと判断します。これは公開資料と条文からの判断です。MIT部品でもライセンスと著作権表示を保持します。

配布には `LICENSES/`、`NOTICE`、`THIRD_PARTY_NOTICES.md`、この確認記録、provenanceとmanifestを含めます。変換内容・元revision・FP32/FP16構成を明示し、公式提供や上流の推薦と誤認させません。モデル全体のカードは `license: other` とし、MITとApache-2.0の部品別条件へ案内します。

[Irodoriモデルカードの使用条件](https://huggingface.co/Aratako/Irodori-TTS-v4.1-Small-MF#ethical-restrictions)に従い、声の本人の許可、なりすまし・誤情報の禁止、合成音声としての表示を維持します。個人の参照音声や生成デモ音声を配布物に追加する許可は、このモデルライセンス確認には含みません。現在の配布物には個人の音声を含めていません。SilentCipherやAudioSealによる透かし付与は保証しません。

## 変換ツールと依存パッケージ

独自の変換スクリプトはコードリポジトリに配布できます。Irodori由来の実装はMITの帰属を保持します。coremltoolsは[BSD-3-Clause](https://github.com/apple/coremltools/blob/main/LICENSE.txt)、onnx2torchは[Apache-2.0](https://github.com/ENOT-AutoDL/onnx2torch/blob/main/LICENSE)です。これらをimportするツールを配ることと、依存パッケージ自体を同梱することは別です。現行ソースZIPにPython環境、依存パッケージ、Apple SDK、ONNX Runtimeのバイナリーは含めません。

## 公開準備の状態

ライセンス確認の保留項目は解消しました。公開・動作検証はまだ完了していません。モデル取得、サンプルの実機操作、音声品質・速度、新規環境での一括変換、公開URLの固定はRELEASE_STATUS.md（コード側 docs/RELEASE.md）とVALIDATION.mdを参照してください。状態値は `draft-license-reviewed` であり、正式公開済み・全検証済みを意味しません。
