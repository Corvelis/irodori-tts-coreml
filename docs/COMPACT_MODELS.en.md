# Models with shared decoder weights

[日本語](COMPACT_MODELS.md) · [Model download](HUGGINGFACE.md) · [Conversion](CONVERSION.md)

The `irodori-coreml-distribution-v2` layout combines three stage-1 decoder variants into one Core ML multifunction package. Sharing their identical weights saves approximately 170 MB without adding quantization or rounding. Auxiliary FP32 models, mixed-linear DiT, existing decoder precision and AudioSeal are retained.

| Layout | Core ML packages | Minimum OS | SDK compatibility |
|---|---:|---|---|
| v1 | 15 | iOS 17 / macOS 14 | v0.1.0 and later |
| v2, shared weights | 13 | iOS 18 / macOS 15 | Requires an SDK supporting v2; v0.1.0 does not support it |

The Swift API is unchanged. Pass the complete model folder to `prepare(modelDirectory:)`. The SDK detects its layout and continues to support v1. An unsupported OS produces an error explaining the minimum version. Use the matching manifest and complete bundle; do not mix individual v1 and v2 packages.

Identical stored weights can still produce small numerical differences when Core ML selects different compiled execution paths. Performance, output and memory use vary by device. Initial compilation time and cache storage are separate from download size.

With the [conversion environment](CONVERSION.md) installed, create new runtime artifacts from a validated v1 folder:

```sh
python Conversion/share_decoder_weights.py \
  artifacts/runtime-v1 artifacts/runtime-v2 \
  --runtime-bundle --report artifacts/shared-decoder-report.json
python Scripts/stage_model.py lock \
  --source artifacts/runtime-v2 --output artifacts/shared.lock.json \
  --version 0.2.0-candidate
python Scripts/stage_model.py stage \
  --source artifacts/runtime-v2 --lock artifacts/shared.lock.json \
  --destination artifacts/shared-model
python Scripts/stage_model.py verify artifacts/shared-model
```

The converter requires identical SHA-256 hashes for all three original weight files and the combined weight file. It rejects existing destinations and mismatched inputs. The packager also checks the validated auxiliary and AudioSeal package hashes.

Compare short, normal and long speech, Voice Cloning, voice instructions and watermarked output with a fixed seed. See [validation](VALIDATION.md) for WAV and RTF comparison. Hash equality and an artifact lock do not replace quality and performance testing on target devices.
