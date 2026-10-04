# 配布内容と互換性

Version **0.1.0** · [GitHub Release](https://github.com/Corvelis/irodori-tts-coreml/releases/tag/v0.1.0) · [モデル取得ガイド](https://github.com/Corvelis/irodori-tts-coreml/blob/v0.1.0/docs/HUGGINGFACE.md)

## ソース配布

`irodori-tts-coreml-source-0.1.0.zip` にSwift SDK、iPhone / Macサンプル、Mac CLI、変換の参考コード、ドキュメントとライセンスを含みます。モデルは別途取得してください。

ZIPを展開するとルートに `Package.swift` と `Examples/IrodoriSamples.xcodeproj` があります。SDKはXcodeのPackage DependenciesからExact Version `0.1.0`を指定して追加することもできます。

ZIPの照合にはReleaseにある `.zip.sha256` を同じフォルダへ保存し、次を実行します。

```sh
shasum -a 256 -c irodori-tts-coreml-source-0.1.0.zip.sha256
```

## モデル配布

[Hugging Faceのモデル一式](https://huggingface.co/AILogDev/Irodori-TTS-v4.1-Small-MF-CoreML)は、13個のCore MLパッケージ、tokenizer、config、補助metadata、manifestと部品別ライセンスを含みます。約2.90 GB、bundleVersion `0.1.0`です。

SDK `0.1.0`には対応するbundleVersion `0.1.0`の一式を使ってください。取得URLと固定commitは[モデル取得ガイド](https://github.com/Corvelis/irodori-tts-coreml/blob/v0.1.0/docs/HUGGINGFACE.md)にあります。manifestの各ファイルサイズ・SHA-256はCLIの `verify` またはSDKの `ModelBundle.validate(at:verifyHashes: true)` で照合できます。

## 実行要件と制約

iOS 17以降 / macOS 14以降が対象です。開発にはApple Silicon MacとXcodeを使用します。実行時はAppleフレームワークを使用し、出力は48 kHz mono PCM16です。参照音声と日本語のVoice Design指示は任意です。

本文はBOSを含め256トークン、潜在系列は768フレームまでです。GUIサンプルは全文を一度に合成し、完成したWAVを再生します。上限を超える文章は短くしてください。SDKでは文分割とPCMチャンク通知を利用できます。

速度と使用メモリは実行環境・文章・参照音声によって変わります。初回準備と反復生成は分けて測定してください。[性能の測定と制約](https://github.com/Corvelis/irodori-tts-coreml/blob/v0.1.0/docs/VALIDATION.md)を参照してください。保存容量はモデル原本に加え、アプリ内コピーとコンパイルキャッシュ分も必要です。

変換コードは参考実装です。一般利用には配布済みモデルを使い、独自に再変換したモデルは生成音声と数値誤差を検証してください。

## 利用条件

SDK・サンプルの新規部分はApache-2.0です。モデルと上流由来部分にはMIT / Apache-2.0の部品別条件が適用されます。同梱の `LICENSES/`、`NOTICE`、`THIRD_PARTY_NOTICES.md` を保持してください。

使用許可のある声を使い、[上流モデルの使用条件](https://huggingface.co/Aratako/Irodori-TTS-v4.1-Small-MF)に従ってください。本モデルによる透かし付与はありません。
