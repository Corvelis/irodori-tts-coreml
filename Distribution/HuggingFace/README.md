---
language:
- ja
pipeline_tag: text-to-speech
license: other
license_name: mit-and-apache-2.0
license_link: https://huggingface.co/AILogDev/Irodori-TTS-v4.1-Small-MF-CoreML/blob/main/THIRD_PARTY_NOTICES.md
library_name: coreml
base_model:
- Aratako/Irodori-TTS-v4.1-Small-MF
- Aratako/Semantic-DACVAE-Japanese-32dim
- sbintuitions/modernbert-ja-310m
tags:
- coreml
- ios
- macos
- voice-cloning
---

# Irodori TTS v4.1 Small MF — Core ML community conversion

**Release bundle `0.1.0`.** Publication status and unauthenticated download validation
are tracked in the [current release status](https://github.com/Corvelis/irodori-tts-coreml/blob/main/docs/RELEASE.md).
Target model repository: [AILogDev/Irodori-TTS-v4.1-Small-MF-CoreML](https://huggingface.co/AILogDev/Irodori-TTS-v4.1-Small-MF-CoreML).
Meta has explicitly clarified that
DACVAE model weights are Apache-2.0 in the
[official license discussion](https://huggingface.co/facebook/dacvae-watermarked/discussions/1).
The bundle preserves MIT and Apache-2.0 component terms; see
[component notices](THIRD_PARTY_NOTICES.md), [license review](LICENSE_REVIEW.md)
and [release status](RELEASE_STATUS.md). This is not an official Aratako or Apple release.

日本語Irodori TTS v4.1 Small MFのCore ML版です。Local AIで使用する推論構成を保ち、
iPhone / Apple Silicon Macで動作するSwiftサンプルと組み合わせて使います。
SDK・サンプル・変換コード: **[Corvelis/irodori-tts-coreml](https://github.com/Corvelis/irodori-tts-coreml)**。コード用tagは `v0.1.0`、モデルのbundleVersionは `0.1.0` です。リリース作成時点では両リポジトリをPrivateに保ち、一般公開と公開後の取得確認は別の工程です。

## Bundle

13 Core ML ML Programs, tokenizer/config, seven auxiliary I/O sidecars, licenses,
provenance and a full-file SHA-256 manifest. Approximately 2.90 GB before local
compilation caches. No ONNX models, standard DiT, recordings or `.mlmodelc` caches.
Keep the directory structure; all packages are required by this runtime version.

- DiT: cached attention, existing mixed-linear precision, four integration steps.
- Auxiliary/reference modules and decoder stage 0: FP32.
- Decoder stages 1–3: existing FP16 conversion and overlapping tile policy.
- Output: 48 kHz mono PCM. Reference audio is optional.
- No new quantization or retraining in distribution preparation.

The Swift package compiles/caches models locally and optionally combines sentence
splitting with decoder PCM chunks. The iPhone/Mac GUI sample synthesizes a whole
input once and plays the completed WAV, without punctuation-based streaming. It does not implement arbitrary-length autoregressive
streaming, ASR or LLM inference. Japanese Voice Design captions are supported
with the SDK `caption` argument and CLI `--caption`; reference audio is optional.
Targets are iOS 17 / macOS 14 or later; minimum OS targets are not an all-device
validation claim. The extracted package has been exercised on an Apple M2 Mac;
the SDK sample has also been exercised on an iPhone 17 Pro, including Files model/audio import, microphone controls and reference preparation, repeated synthesis/playback controls, reference deletion and Save to Files with byte-identical WAV output. The repeated controlled microphone test passed (envelope correlation 0.9210, required >0.5); the earlier failed attempt remains in the validation history. The user listened to the trial audio and found it acceptable. The signed Mac GUI has been exercised with both its built-in microphone and BlackHole input, recording/registration/synthesis/playback, reference/cache deletion and byte-identical WAV export. The system input was restored after testing; the trial audio has been accepted by the user after listening. These sample checks are separate from Local AI concurrency measurements.
See the code repository's validation report before citing performance numbers.
The [local validation report](VALIDATION.md) records exact normal/long-utterance
parity and unresolved small numerical differences in two short-utterance cases.
Complete quality equivalence is not a verified claim for this release.

Cold compilation and Core ML specialization are excluded from warm synthesis RTF.
The first-PCM metric is callback readiness, not measured physical speaker onset.
This model card makes no AFM/Gemma concurrency or device-independent latency claim.

## Origins and use

`provenance.json` records immutable source revisions and conversion policies.
`manifest.json` records each distributed file's byte count and SHA-256. Select an
immutable HF commit when downloading; the manifest is not a cryptographic
signature of the publisher.

Follow the original [Irodori model card](https://huggingface.co/Aratako/Irodori-TTS-v4.1-Small-MF),
including its voice-consent, impersonation and deceptive-use conditions. Use only
voices you have permission to use. This conversion does not apply SilentCipher
watermarking. Generated speech must not be misrepresented as an authentic human
recording. No reference or demonstration recordings are included in this bundle.

The original Irodori and Japanese DACVAE cards declare MIT, ModernBERT is MIT,
DACVAE implementation code is Apache-2.0, and Descript DAC is MIT.
Meta explicitly confirmed the base weights are Apache-2.0; the README still has
a stale SAM sentence. Preserve the clarification record and all included notices.

## Quick start / 最初の使い方

Clone the [separate code repository](https://github.com/Corvelis/irodori-tts-coreml), with this model folder beside it. Private code repositories require GitHub authentication:

```sh
git clone --branch v0.1.0 --depth 1 https://github.com/Corvelis/irodori-tts-coreml.git
cd irodori-tts-coreml
swift build -c release
.build/release/irodori verify --models ../Irodori-TTS-v4.1-Small-MF-CoreML
.build/release/irodori synthesize --models ../Irodori-TTS-v4.1-Small-MF-CoreML --text 'こんにちは。' --output /tmp/irodori-output.wav
afplay /tmp/irodori-output.wav
```

Add `--reference /path/to/your-authorized-voice.wav` to use a reference voice.
The iPhone/Mac samples can import or record a voice, use it for synthesis, and
delete their reference copies and feature cache. Registration does not train
new weights. See the [sample guide](https://github.com/Corvelis/irodori-tts-coreml/blob/main/docs/SAMPLES.md),
[voice registration](https://github.com/Corvelis/irodori-tts-coreml/blob/main/docs/VOICE_REGISTRATION.md) and
[English quick start](https://github.com/Corvelis/irodori-tts-coreml/blob/main/docs/README.en.md) for instructions.

モデルは1つの.mlpackageだけでは動きません。フォルダ一式を保持し、サンプルの
「フォルダを選ぶ」（選択後は「モデルを変更」）で親フォルダを選択してください。原本約2.90 GBに加え、
アプリ内コピーと端末上のコンパイルキャッシュの空き容量が必要です。音声の登録後は
「準備」または「生成して再生」で参照特徴を準備します。新サンプルでの実機操作の
確認範囲は [VALIDATION.md](VALIDATION.md) に記載しています。
