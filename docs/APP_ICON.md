# サンプルアプリのアイコン

[サンプルの使い方](SAMPLES.md)

2026-10-04に組み込んだ、ミント色の波形と深いティール色を使ったアイコンです。サンプルのUIに合わせて作成したデザインで、上流プロジェクトの公式ロゴではありません。Codexの組み込みimagegenツールで生成し、macOSの `sips` で必要なピクセル寸法へ縮小しました。CLI/APIでの画像生成は使用していません。

## 配置と変更

- [iPhone用1024 px原稿](../Examples/Shared/Assets.xcassets/AppIcon-iOS.appiconset/Icon-1024.png): 不透明、四隅まで背景を含む正方形。角丸の形状はOSが適用します。
- [Mac用1024 px原稿](../Examples/Shared/Assets.xcassets/AppIcon-macOS.appiconset/Icon-1024.png): 角丸タイルと外周の透過背景。アルファチャンネルを維持します。
- [共通アセットカタログ](../Examples/Shared/Assets.xcassets/Contents.json)を両targetのResourcesに含めています。App Iconの設定値は `IrodoriiOS` が `AppIcon-iOS`、`IrodoriMac` が `AppIcon-macOS` です。

差し替える場合は、各 `.appiconset/Contents.json` の寸法・scaleに合わせてPNGを書き出し、同名画像を置き換えます。iPhone用には透過を含めないでください。Xcodeのtarget設定と [generate_project.rb](../Scripts/generate_project.rb) にも同じアセット名を反映済みなので、プロジェクトを再生成してもアイコン設定が残ります。ソース配布ZIPにすべての画像が含まれ、TTSモデルのダウンロード前からアイコンを表示できます。

## 生成プロンプト

### iPhone用

```text
Use case: logo-brand
Asset type: production app icon artwork for the Irodori Core ML speech synthesis sample app on iPhone and Mac.
Primary request: a refined, instantly readable mint and deep teal voice waveform emblem.
Composition: one centered sculptural waveform made of five generous vertical rounded pill forms, unequal heights forming a fluid speaking rhythm. The central form is tallest. The silhouette occupies about 62% of the square width and 55% of its height, with ample balanced negative space. The pills feel like softly shaped satin ceramic, with restrained dimensional shading. A subtle flowing sense of voice and calm.
Color palette: deep forest teal background (#146E64), gentle teal gradient to #0E4C48 toward the lower edge. Emblem predominantly pale mint (#C5EEDC) with softly warmer ivory highlights. Strong contrast, sophisticated, consistent with a mint and teal audio app.
Style: meticulously polished minimal app identity, crisp edges, very subtle soft depth, no busy texture. Legible at 32 pixels.
Output: a single square 1024 x 1024 full-bleed opaque image. Background extends to all four edges and corners. This is the raw icon asset, not an icon presentation mockup.
Constraints: no letters, no numbers, no text, no watermark, no border, no external scene, no phone or desktop device, no drop shadow outside the square, no baked-in rounded outer corners. Do not imitate an existing commercial brand logo.
```

### Mac用（iPhone用画像を入力して編集）

```text
Use case: precise-object-edit
Asset type: macOS app icon.
Edit target: the supplied teal and mint voice-waveform app icon.
Change only the outer shape of the background: turn the existing full-square artwork into a macOS-style rounded-square tile, centered within a 1024 x 1024 transparent canvas. The tile occupies about 90% of the canvas with generous smooth continuous rounded corners and a restrained soft shadow within the canvas. The exterior around the tile is genuinely transparent.
Keep the existing five pale mint waveform pills, their relative shapes, spacing, symmetry, shading, background gradient and colors unchanged. Scale the entire original design uniformly to fit the tile. Crisp, polished, recognizable at small Dock sizes.
No text, no additional elements, no device or mockup, no opaque background outside the tile.
```
