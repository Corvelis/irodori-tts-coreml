# Download and arrange models

[日本語](HUGGINGFACE.md) · [Getting started](README.en.md) · [Light model](COMPACT_MODELS.en.md)

The Swift SDK and models are distributed separately. Each model needs its complete set of Core ML packages, tokenizer/config, sidecars, licenses and manifest.

## Choose a model

The same [Hugging Face repository](https://huggingface.co/AILogDev/Irodori-TTS-v4.1-Small-MF-CoreML) contains the standard model at its root and the light model under `int8/`. A manifest lists only that model's files. Paths in `int8/manifest.json` are relative to `int8/`, not the repository root.

| Model | Repository directory | Size | Minimum OS | SDK |
|---|---|---:|---|---|
| Standard | Root | ~2.99 GB | iOS 17 / macOS 14 | 0.1.0+ |
| Light INT8 | `int8/` | ~1.96 GB | iOS 18 / macOS 15 | 0.2.0+ |

Directories select a variant; tags and commits select a revision. The SDK keeps the standard model pinned to its original commit and selects the nested INT8 manifest at a release tag:

```text
Standard:
https://huggingface.co/AILogDev/Irodori-TTS-v4.1-Small-MF-CoreML/resolve/b02a670f0cb41c382844672fa8f0f03b3b9b8082/manifest.json

Light INT8:
https://huggingface.co/AILogDev/Irodori-TTS-v4.1-Small-MF-CoreML/resolve/v0.2.0-int8/int8/manifest.json
```

The original standard manifest SHA-256 is `f98e77d857c20e977358ec9c9d513721b37e1af0d7e12359c05de26c90ae7186`. The latest repository model card may differ from that historical revision.

## CLI

Build the source with `swift build -c release`, then run one pair of commands:

```sh
# Standard
.build/release/irodori download --variant standard --destination ../Irodori-CoreML-Standard
.build/release/irodori verify --models ../Irodori-CoreML-Standard

# Light INT8 (macOS 15+)
.build/release/irodori download --variant light-int8 --destination ../Irodori-CoreML-INT8
.build/release/irodori verify --models ../Irodori-CoreML-INT8
```

Each destination must be a new, separate directory. File sizes and SHA-256 hashes are checked during download. To retry, use the same URL and destination; verified completed files are reused. Use `--manifest HTTPS_URL` instead of `--variant` for a custom distribution.

## Swift SDK

```swift
import Foundation
import IrodoriTTS

func downloadModels(variant: ModelVariant, to newDirectory: URL) async throws {
    try await ModelDownloader().download(
        manifestURL: variant.manifestURL,
        to: newDirectory
    )
}
```

Choose `.standard` or `.lightINT8`. Pass the completed destination directly to `engine.prepare(modelDirectory:)`. Downloaded contents sit directly inside that destination; no extra `int8/` directory is inserted there.

## iPhone / Mac sample

In the model settings, choose a variant under **取得するモデル**, then press **モデルをダウンロード**. Use **保存済みモデル** to switch installed bundles. Custom manifests can be entered under **URLからダウンロード**.

For an existing complete bundle, press **フォルダを選ぶ**. If you downloaded the entire Hub repository, the root selects standard and its `int8` directory selects light. The sample copies the selected directory, so importing the entire repository also copies the other variant unnecessarily. Prefer downloading only your chosen variant with the SDK, CLI or sample.

To transfer a bundle to iPhone, copy its folder through Finder file sharing and select it in Files → On My iPhone → Irodori Core ML.

## Keep each bundle complete

Each downloaded directory contains `manifest.json`, `coreml-only.json`, packages, tokenizer/config, sidecars and licenses. Do not select one `.mlpackage`, rename internal paths, or mix files from different variants. Extract archives before importing.

Allow additional space for app-owned copies and Core ML compilation caches. Only the selected variant is downloaded by the SDK/CLI. Generation works offline once its files are present.
