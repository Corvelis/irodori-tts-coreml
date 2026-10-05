# 性能の測定と制約

[CLIで測定する](https://github.com/Corvelis/irodori-tts-coreml/blob/v0.2.0/docs/CLI.md) · [API](https://github.com/Corvelis/irodori-tts-coreml/blob/v0.2.0/docs/API.md) · [トラブル対処](https://github.com/Corvelis/irodori-tts-coreml/blob/v0.2.0/docs/TROUBLESHOOTING.md)

## RTFと再生開始時間

RTFは合成処理時間を出力音声の長さで割った値です。10秒の音声を2秒で生成するとRTFは0.2です。モデルの準備、参照登録、ASR、LLM、WAV保存、スピーカーの遅延はRTFに含みません。

SDKの `firstPCMMilliseconds` は、合成開始から最初のPCMが用意されるまでの時間です。実際に音が聞こえるまでの時間はプレイヤーと音声出力にも依存します。GUIサンプルは全文生成後に再生するため、全文の合成時間が待ち時間に加わります。

## 初回と反復生成

初回はCore MLのコンパイル・ロードが必要です。準備済みでも、新しい入力形状では特殊化による追加時間が発生する場合があります。同じengineを再利用し、初回と反復時の結果を分けて測ってください。

参照特徴は再利用されます。`ReferenceRegistration.cacheHit` またはサンプルの「キャッシュ」を確認してください。短文は固定の処理時間に対して音声長が短いため、長文よりRTFが高くなることがあります。

## 比較の条件

端末・OS、Release / Debug、SDK版、モデルcommit、文章、参照音声、Voice Design指示、文分割の有無を揃えます。同時処理、電源・熱状態も結果に影響します。

CLIの `benchmark` で短文・通常文・短文反復後の長文を測れます。例とJSON項目は[CLIガイド](https://github.com/Corvelis/irodori-tts-coreml/blob/v0.2.0/docs/CLI.md#短文長文の反復測定)を参照してください。アプリの応答時間は、入力受付から最初の再生までを別途測定します。

固定seedでも異なる端末・OS・演算先でPCMが完全一致するとは限りません。数値比較に加え、保存WAVで発音・欠落・余分な発話・音の崩れを確認してください。

## 音声と入力の制約

- 本文はBOSを含め256トークン、潜在系列は768フレームまでです。文字数から上限を一律には判定できません。
- サンプルの全文モードは、上限超過をエラーとして返します。SDKの既定の文分割モードは、対応する上限エラーで文章を分割します。
- 漢字の読み辞書・ルビ指定APIはありません。読みを固定する場合は、読み上げ用テキストをかなへ置き換えます。
- 参照には3〜10秒程度の、1人が明瞭に話す音声を推奨します。長い無音、複数話者、BGM、クリッピングは声質に影響します。
- Voice Designの指示への追従や、参照音声との完全な声質一致は保証されません。

## メモリと容量

v1の約2.99 GBは配布ファイルのサイズで、実行時RAMの値ではありません。[重み共有形式](COMPACT_MODELS.md)では配布容量を削減できます。Core MLの実行状態、中間テンソル、完成PCM、再生バッファ、他のモデルがメモリを使用します。

SDKはチャンク通知を使う場合も完成PCMを保持します。48 kHz mono PCM16は1分あたり約5.76 MBです。不要な結果・プレイヤーバッファを保持し続けず、engineの重複作成を避けてください。`release()` はセッションを解放しますが、OSのメモリ回収を即時に保証しません。

ディスクにはモデル原本、アプリ内コピー、コンパイルキャッシュ、参照音声・特徴キャッシュが保存されます。[音声登録と削除](https://github.com/Corvelis/irodori-tts-coreml/blob/v0.2.0/docs/VOICE_REGISTRATION.md)を参照してください。

AudioSeal透かしは標準で有効です。RTFと最初のPCM時間に処理を含めます。PCM通知では0.5秒分の音声を先読みします。[透かしの処理と制約](https://github.com/Corvelis/irodori-tts-coreml/blob/v0.2.0/docs/WATERMARK.md)を参照してください。

## 軽量INT8版の比較

軽量版の数値誤差、ASR文字誤り率、音響差と再測定手順は[音質測定](QUALITY.md)を参照してください。容量削減率を音質劣化率と解釈せず、測定した指標を個別に評価します。
