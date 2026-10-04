# Hugging Faceへのアップロード

[README](../README.md) · [公開準備の状態](RELEASE.md)

モデル用リポジトリ: [AILogDev/Irodori-TTS-v4.1-Small-MF-CoreML](https://huggingface.co/AILogDev/Irodori-TTS-v4.1-Small-MF-CoreML)

Privateの準備版はアップロードと、固定commit SHAからの全ファイルの再ダウンロード・サイズ・SHA-256検証を完了しました。正式公開と公開URLからの取得検証はまだ完了していません。SDK、サンプル、変換コードは [Corvelis/irodori-tts-coreml](https://github.com/Corvelis/irodori-tts-coreml) へ置きます。両リポジトリを現在はPrivateに保ち、モデルカードとコードのREADMEへ相互リンクを設定します。モデルカードはMIT/Apache-2.0の部品別ライセンスを保持します。

## 1. Macから認証する

`hf` CLIを使います。この準備環境ではインストール済みです。現在インストールしているhuggingface_hub 0.36.2のCLIはトークン入力で認証します。

1. [Access Tokens](https://huggingface.co/settings/tokens)で、対象モデルリポジトリへ書き込めるトークンを作成します。fine-grainedを選ぶ場合は対象リポジトリを限定します。
2. ターミナルで以下を実行し、表示された入力欄へトークンを貼り付けます。入力文字は表示されません。トークンをコマンド引数やドキュメント、チャットには含めません。
3. `Add token as git credential?` は `n` で構いません。この手順はGit経由でアップロードしません。

```sh
hf auth login
hf auth whoami
```

`whoami` で `AILogDev` と表示されることを確認します。対象リポジトリへのアクセスと公開範囲は、アップロード前に認証済みAPIまたはWeb画面で別途確認します。新しいCLIにはブラウザ認証もあります。詳細は[公式CLIガイド](https://huggingface.co/docs/huggingface_hub/guides/cli#hf-auth-login)を参照してください。

## 2. アップロード対象を確認する

約2.90 GBのモデル配布フォルダ全体を使います。ルートには `manifest.json`、`README.md`、13個の `.mlpackage`、tokenizer、sidecar、ライセンスとprovenanceが並びます。`.mlpackage` 内の階層も保持します。SDKソースZIPはこのリポジトリへ入れません。

```sh
python3 Scripts/stage_model.py verify /path/to/Irodori-TTS-v4.1-Small-MF-CoreML
```

現行の配布フォルダは `0.1.0-draft` です。ドキュメントを変更したらmanifestの該当ファイルのサイズとSHA-256も更新し、再検証します。正式版へ切り替える際は版番号、公開状態、GitHub URLを全配布物で合わせてください。

## 3. リポジトリのルートへアップロードする

準備段階ではリポジトリをPrivateに保ち、設定画面または認証済みAPIで公開範囲と既存ファイルを確認します。以下のコマンドは公開範囲を変更しません。

```sh
hf upload AILogDev/Irodori-TTS-v4.1-Small-MF-CoreML \
  /path/to/Irodori-TTS-v4.1-Small-MF-CoreML \
  . --repo-type model --commit-message 'Upload reviewed Core ML distribution draft'
```

最後の `.` は、配布フォルダの中身をリポジトリのルートへ配置する指定です。同名のリモートファイルは更新されるので、最初のアップロード前にも既存内容を確認します。`--delete` は使用しません。CLIが大きなファイルを処理します。[公式アップロード手順](https://huggingface.co/docs/huggingface_hub/guides/upload#upload-from-the-cli)

## 4. 公開と導入を確認する

1. GitHubのコード用リポジトリは `Corvelis/irodori-tts-coreml` に確定しています。正式版を確定し、モデルカードのリンク・版・manifestを合わせます。
2. Files and versionsでモデル一式とライセンスを確認し、アップロードしたcommit SHAを記録します。
3. 公開内容の確認後にモデルリポジトリをPublicへ切り替えます。
4. 次の `COMMIT_SHA` を確定したSHAへ置き換え、SDK CLIで未作成の保存先へ取得します。移動する `main` は使用しません。

```sh
.build/release/irodori download \
  --manifest 'https://huggingface.co/AILogDev/Irodori-TTS-v4.1-Small-MF-CoreML/resolve/COMMIT_SHA/manifest.json' \
  --destination /path/to/new-model-folder
.build/release/irodori verify --models /path/to/new-model-folder
```

取得した一式でモデル準備・音声生成・再生を確認し、コードのreleaseにモデルcommit SHAを記載します。SDK/サンプルのURL取得にはPrivate/gatedリポジトリの認証機能がないため、Privateのままではログインなしのダウンロード確認はできません。

## 準備版のアップロード記録

2026-10-04にPrivateの `0.1.0-draft` をアップロードしました。モデルカードはHugging Face側の検証を通過し、固定commit `8d9a9e193e649ef448f2870a84cf4a729cb51a1e` から配布対象の全63ファイルを新しいキャッシュへダウンロードしてサイズ・SHA-256を検証しました。モデル本体の50ファイルは既存のレビュー済みロックと一致しています。HFが用意する `.gitattributes` を含むリモートのファイル数は64です。

[機械可読の確認記録](../Distribution/HuggingFace/staging-upload.json)にcommitとmanifestのSHA-256を保存しています。認証済みのPrivate取得確認であり、ログインなしでの公開URLからの取得確認は正式公開後に行います。

GitHubリポジトリ作成後に、モデル側のREADME・配布状態・provenance・manifestの4ファイルへコードURLを反映しました。現在のPrivate準備版commitは `af30c0101ebd6f714160b900d205b395845e43a6` です。全63ファイルを固定commitから取得し、サイズ・SHA-256を確認しました。変更のないモデル本体は、初回に全ファイルを新しく取得して検証したキャッシュを再利用しています。コードのREADMEとCLIガイドには、この検証済みcommitのmanifest URLを記載しています。
