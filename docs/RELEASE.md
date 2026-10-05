# 配布内容と互換性

Version **0.2.0** · [GitHub Release](https://github.com/Corvelis/irodori-tts-coreml/releases/tag/v0.2.0) · [モデル取得ガイド](https://github.com/Corvelis/irodori-tts-coreml/blob/v0.2.0/docs/HUGGINGFACE.md)

## ソース配布

`irodori-tts-coreml-source-0.2.0.zip` にSwift SDK、iPhone / Macサンプル、Mac CLI、変換の参考コード、ドキュメントとライセンスを含みます。モデルは別途取得してください。

ZIPを展開するとルートに `Package.swift` と `Examples/IrodoriSamples.xcodeproj` があります。SDKはXcodeのPackage DependenciesからExact Version `0.2.0`を指定して追加することもできます。

ZIPの照合にはReleaseにある `.zip.sha256` を同じフォルダへ保存し、次を実行します。

```sh
shasum -a 256 -c irodori-tts-coreml-source-0.2.0.zip.sha256
```

## モデル配布

[Hugging Faceのモデル一式](https://huggingface.co/AILogDev/Irodori-TTS-v4.1-Small-MF-CoreML)は、選択した版のCore MLパッケージ、tokenizer、config、補助metadata、manifestと部品別ライセンスを含みます。現行版は約2.99 GB / bundleVersion `0.1.0`、軽量INT8版は約1.96 GB / bundleVersion `0.2.0-int8`です。

Hugging Faceリポジトリのルートに現行版、`int8/` に軽量版を配置します。各manifestは自身のモデルだけを対象とし、SDK/CLIは選択した一式だけを取得します。モデルの種類はフォルダで分け、取得する版はタグ・固定commitで指定します。

SDK `0.2.0`は両方の一式を読み込めます。軽量版にはiOS 18 / macOS 15以降が必要です。取得URLと固定commitは[モデル取得ガイド](https://github.com/Corvelis/irodori-tts-coreml/blob/v0.2.0/docs/HUGGINGFACE.md)にあります。manifestの各ファイルサイズ・SHA-256はCLIの `verify` またはSDKの `ModelBundle.validate(at:verifyHashes: true)` で照合できます。

## 音声の透かし

AudioSeal付与・検出モデルを含み、SDKとサンプルは生成音声への付与を標準で有効にします。再生PCMと保存WAVには同じ透かしが含まれます。[透かしの利用](https://github.com/Corvelis/irodori-tts-coreml/blob/v0.2.0/docs/WATERMARK.md)を参照してください。

## 実行要件と制約

iOS 17以降 / macOS 14以降が対象です。開発にはApple Silicon MacとXcodeを使用します。実行時はAppleフレームワークを使用し、出力は48 kHz mono PCM16です。参照音声と日本語のVoice Design指示は任意です。

本文はBOSを含め256トークン、潜在系列は768フレームまでです。GUIサンプルは全文を一度に合成し、完成したWAVを再生します。上限を超える文章は短くしてください。SDKでは文分割とPCMチャンク通知を利用できます。

速度と使用メモリは実行環境・文章・参照音声によって変わります。初回準備と反復生成は分けて測定してください。[性能の測定と制約](https://github.com/Corvelis/irodori-tts-coreml/blob/v0.2.0/docs/VALIDATION.md)を参照してください。保存容量はモデル原本に加え、アプリ内コピーとコンパイルキャッシュ分も必要です。

変換コードは参考実装です。一般利用には配布済みモデルを使い、独自に再変換したモデルは生成音声と数値誤差を検証してください。

## 利用条件

SDK・サンプルの新規部分はApache-2.0です。モデルと上流由来部分にはMIT / Apache-2.0の部品別条件が適用されます。同梱の `LICENSES/`、`NOTICE`、`THIRD_PARTY_NOTICES.md` を保持してください。

使用許可のある声を使い、[上流モデルの使用条件](https://huggingface.co/Aratako/Irodori-TTS-v4.1-Small-MF)に従ってください。
