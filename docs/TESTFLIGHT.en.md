# Distribute the iPhone sample with TestFlight

[日本語](TESTFLIGHT.md) · [Sample walkthrough](SAMPLES.en.md) · [Privacy](PRIVACY.en.md)

Use an Apple Developer Program account to distribute the iPhone sample through TestFlight. Models are downloaded from Hugging Face inside the app and are not embedded in the binary.

## Signing and archiving

1. Add your developer account in Xcode Settings → Accounts.
2. Open `Examples/IrodoriSamples.xcodeproj`, choose the `IrodoriiOS` target, and configure your own Team and unique Bundle Identifier. Replace the `org.example.*` template identifier.
3. Create an iOS app in [App Store Connect](https://appstoreconnect.apple.com/) with the same Bundle ID. Choose an available app name, primary language and SKU. See [Apple's app registration guide](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app/).
4. Select `IrodoriiOS` and Any iOS Device, then choose Product → Archive. Alternatively, run this from the repository root with your own values:

```sh
./Scripts/archive-ios.sh \
  --team YOUR_TEAM_ID \
  --bundle-id com.yourcompany.irodori.sample \
  --version 0.2.1 \
  --build 3
```

The script creates a signed Release archive. It does not upload or submit it. Increase the build number for every upload and use `--output` to keep an existing archive. Team IDs and credentials need not be committed to source.

In Xcode Organizer, run Validate App, then Distribute App → App Store Connect. Do not choose an internal-only distribution method if you plan to invite external testers.

## Beta description

> Try the Core ML edition of Irodori TTS v4.1 Small MF on iPhone. The app supports Japanese speech synthesis, on-device Voice Cloning from a reference recording, and text instructions for speaking style. Download a model inside the app on first use; speech generation then runs on your device. Generated audio includes an AudioSeal watermark.

Suggested “What to Test” text:

> Please test first-use model download, pause/retry, speech generation and playback, reference recording/import, WAV export, and model switching/deletion. Standard FP32 is approximately 2.99 GB; light INT8 is approximately 1.96 GB and requires iOS 18 or later. Additional space is needed for Core ML caches. Keep the app open while downloading. The first synthesis requires device-specific model preparation.

Provide your own reachable feedback email and review contact. No account or review login is required in the app. In review notes, describe the first-use flow: choose a model → download → generate and play. Explain that the reviewer can use the app without a reference voice; microphone permission is requested only for recording.

## Privacy and licensing

Text, recordings and reference audio are processed on-device and are not uploaded to the model host. Model requests expose ordinary connection information to the hosting server. External links and system sharing are user initiated. See [the privacy policy](PRIVACY.en.md); its public URL can be used as the policy URL.

The app and SDK include privacy manifests declaring file metadata, elapsed-time measurement, storage checks and app settings as applicable. Update the declarations if you add features. The sample declares no non-exempt encryption for its standard TLS/Apple-provided API configuration; reassess [export compliance](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/) if you add encryption features. Preserve [component licenses](LICENSE_REVIEW.md) and [third-party notices](../THIRD_PARTY_NOTICES.md).

## Device verification and distribution

Use a dedicated test bundle ID to verify a fresh start without deleting existing data. Confirm model download and verification, interruption/relaunch/retry, no-reference synthesis, reference recording/import, style instructions, WAV export, model switching/deletion and downloading again after all models are removed. Deletion must preserve external originals, registered voices and exported WAVs.

After device and Organizer validation, distribute to internal testers and verify installation and the initial download flow. For external testers, submit the first build for TestFlight review, then share invitations or a public link after approval. Builds can be tested for up to 90 days. See [Apple's TestFlight workflow](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/).
