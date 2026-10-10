# iPhoneサンプルをTestFlightで配布する

[English](TESTFLIGHT.en.md) · [サンプルの使い方](SAMPLES.md) · [プライバシー](PRIVACY.md)

Apple Developer Programのアカウントを使い、iPhoneサンプルをTestFlightで配布できます。モデルはアプリへ埋め込まず、利用者がアプリ内でHugging Faceから選んだ版を取得します。

## 署名とアプリ登録

1. XcodeのSettings → AccountsへApple Developer Programのアカウントを追加します。
2. `Examples/IrodoriSamples.xcodeproj` の `IrodoriiOS` targetで、自分のTeamと一意のBundle Identifierを指定します。`org.example.*` はテンプレートなので配布には使いません。Team IDや証明書をソースへ共有する必要はありません。
3. [App Store Connect](https://appstoreconnect.apple.com/)のAppsでiOSアプリを作成します。Bundle IDはXcodeと一致させます。アプリ名は「Irodori Core ML」、主言語は日本語を基本にできます。登録時に名前の利用可否を確認してください。

アプリ登録には、アプリ名・Bundle ID・SKUなどが必要です。[Appleの登録手順](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app/)を参照してください。

## Release Archiveを作る

Xcodeで `IrodoriiOS` と「Any iOS Device」を選択して **Product → Archive** を実行します。またはリポジトリのルートで、値を自分のものに置き換えて次を実行します。

```sh
./Scripts/archive-ios.sh \
  --team YOUR_TEAM_ID \
  --bundle-id com.yourcompany.irodori.sample \
  --version 0.2.1 \
  --build 3
```

スクリプトは署名付きのRelease Archiveを作ります。アップロードや審査提出は行いません。アップロードごとにbuild番号を増やし、既存Archiveを残す場合は `--output dist/IrodoriCoreML-build4.xcarchive` などを指定します。

Xcode OrganizerでArchiveを開き、**Validate App** で検証してから **Distribute App → App Store Connect** でアップロードします。外部テストを予定する場合は、内部テスト限定の配布方法を選ばないでください。

モデルを含まないArchiveでも、アプリ内のダウンロードから音声生成まで操作できます。モデル取得元は固定したリビジョンを使い、必要なモデル・設定・利用条件をmanifestに従って検証します。

## TestFlightの説明

以下をベータ版の説明に使えます。

> Irodori TTS v4.1 Small MFのCore ML版をiPhoneで試せるアプリです。日本語の音声合成、参照音声によるVoice Cloning、テキストでの話し方の指定に対応します。モデルは初回にアプリ内でダウンロードし、取得後の音声生成は端末内で行います。生成音声にはAudioSealの透かしを付与します。

「テスト内容」には次を指定できます。

> 初回のモデル取得、ダウンロードの中断と再開、文章の生成・再生、参照音声の録音と取り込み、WAVの保存、モデルの切り替えと削除をご確認ください。標準FP32版は約2.99 GB、軽量INT8版は約1.96 GBです。別途Core MLキャッシュ用の空き容量が必要です。取得中はアプリを開いたままにしてください。初回の音声生成では端末向けの準備に時間がかかります。軽量INT8版にはiOS 18以降が必要です。

フィードバック用メールと審査連絡先には、受信・連絡できる配布者自身の情報を入力します。ログインは不要なので、審査用ログイン情報は不要です。

審査メモでは「初回画面のモデル選択 → モデルをダウンロード → 完了後に生成して再生」と案内します。参照音声なしで試せること、マイクは声の登録時だけ必要なことも伝えてください。

## プライバシーと利用条件

- 入力文章・録音・参照音声は端末内で処理し、モデル配布先へ送信しません。
- ネットワーク通信はモデル取得と、自分で開いた外部リンクに使用します。取得元サーバーには通常の接続情報が届きます。
- OSの共有画面で選んだ保存先・アプリへの送信は、利用者自身の操作で行います。
- アプリとSDKに `PrivacyInfo.xcprivacy` を含めています。UserDefaults、ファイル情報、経過時間測定、モデル取得前の空き容量確認の利用理由を宣言しています。独自機能を追加した場合は宣言とプライバシー説明も見直してください。
- 標準のTLS通信・Apple提供APIを使う構成として、非免除暗号化なしの設定を含めています。暗号化機能を追加する場合は、[Appleの輸出関連の案内](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/)に従って再確認してください。

プライバシーポリシーには[このサンプルのポリシー](PRIVACY.md)の公開URLを指定できます。参照モデル・SDK・AudioSealの利用条件は[ライセンス説明](LICENSE_REVIEW.md)と[第三者表記](../THIRD_PARTY_NOTICES.md)で確認できます。

## 配布前の実機確認

モデルを登録していない状態から、次の操作を確認します。既存の録音やモデルを消す必要はなく、専用のテスト用Bundle IDで確認できます。

| 操作 | 確認する結果 |
|---|---|
| 初回起動 | 上部にモデル取得案内、容量、必要OSを表示 |
| 標準版／INT8版の取得 | 容量の進捗と検証状態を表示し、選んだ版だけを取得 |
| 中断・画面切り替え・再起動 | 再開でき、検証済みファイルを再取得しない |
| 参照なしで生成 | 初回準備後に日本語を再生し、RTF等を表示 |
| 音声登録・話し方指定 | 録音許可、取り込み、参照ありの生成が使える |
| WAV保存 | 保存した音声が再生音声と一致する |
| モデル切り替え・削除 | 使用中セッションを解放し、外部元ファイルや登録音声を消さない |
| 全モデル削除 | 初回の取得案内へ戻り、再取得して生成できる |

実機操作とOrganizerの検証を終えてから、内部テスターへ配布してダウンロードからの動作を確認します。その後、外部テスター用グループで最初のビルドを審査へ提出し、承認後に招待メールまたは公開リンクを作ります。ビルドのTestFlight利用期間は最大90日です。[AppleのTestFlight手順](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/)を参照してください。

## 声の固定と保存の確認

- ランダムで生成し「この声に固定する」を押すと、表示した実際のseedに切り替わる。
- 固定seedの再生成、直接入力、シャッフルを試す。0と4294967295は使え、範囲外や小数は生成を開始しない。
- 参照あり／なしの設定を名前付きで保存し、別の設定へ変えた後とアプリ再起動後に呼び出す。
- 標準版／INT8版を切り替え、保存した声が元のモデルを選ぶことと、モデル削除後は別モデルへ黙って切り替えないことを確認する。
- 個別削除と参照音声の一括削除を確認し、外部の元音声・モデル・書き出したWAVが残ることを確認する。
- 固定seedだけで声IDが保証されるわけではないため、複数の文章で聞き比べる。
