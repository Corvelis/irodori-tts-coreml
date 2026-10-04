# サンプルアプリのアイコン

[サンプルの使い方](SAMPLES.md)

サンプルはミント色の波形とティール色の背景のアイコンを使います。両targetのアセットカタログに含まれるため、Xcodeからビルドすると適用されます。

## 差し替える

| 対象 | 原稿 | アセット名 |
|---|---|---|
| iPhone | [1024 px PNG](../Examples/Shared/Assets.xcassets/AppIcon-iOS.appiconset/Icon-1024.png) | `AppIcon-iOS` |
| Mac | [1024 px PNG](../Examples/Shared/Assets.xcassets/AppIcon-macOS.appiconset/Icon-1024.png) | `AppIcon-macOS` |

各 `.appiconset/Contents.json` の寸法とscaleに合わせてPNGを用意し、同名画像を置き換えます。iPhone用は透過を含めず四隅まで背景を埋めます。Mac用はタイル外周の透過を保持します。

Xcodeのtarget設定の **App Icon** に上のアセット名を指定します。アセット名を変える場合は、[generate_project.rb](../Scripts/generate_project.rb)の設定も更新してください。
