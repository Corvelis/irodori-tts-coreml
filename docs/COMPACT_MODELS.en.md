# Light INT8 model

[日本語](COMPACT_MODELS.md) · [Quality comparison](QUALITY.en.md)

The light bundle is about 1.96 GB, roughly 34% smaller than the 2.99 GB standard bundle. Large text-encoder weights use symmetric INT8 storage with block size 128; text computation and outputs remain FP32. DiT mixed-linear precision, other auxiliary models, decoder precision and AudioSeal remain unchanged.

The release layout shares fixed-width stage-1 decoder weights and retains the separate flexible decoder. It contains 14 Core ML packages. It requires iOS 18+ / macOS 15+ and SDK 0.2.0+. The standard 15-package v1 model remains supported on iOS 17+ / macOS 14+.

Both use the same prepare, reference registration and synthesis APIs, including Voice Cloning, Japanese Voice Design captions and watermarking. Keep each complete bundle in its own directory. File size does not establish a proportional RAM reduction.

To reproduce the light layout, use the pinned [conversion environment](CONVERSION.md) and a validated v1 bundle:

```sh
python Conversion/make_light_bundle.py artifacts/runtime-v1 artifacts/runtime-int8
python Scripts/stage_model.py lock --source artifacts/runtime-int8 --output artifacts/int8.lock.json --version 0.2.0-int8
python Scripts/stage_model.py stage --source artifacts/runtime-int8 --lock artifacts/int8.lock.json --destination artifacts/model-int8
python Scripts/stage_model.py verify artifacts/model-int8
```

The converter checks identical decoder weight bytes, quantizes the text encoder and compares FP32/INT8 features on natural and maximum-length/masked inputs. The report is bound to exact model and tokenizer hashes. Original Torch/ONNX validation is not attributed to the quantized model. Generated-speech and target-device tests are also required; see [quality measurements](QUALITY.en.md).
