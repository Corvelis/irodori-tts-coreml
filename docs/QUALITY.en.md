# INT8 quality and speed measurements

[日本語](QUALITY.md) · [Raw results](../Distribution/quality-results) · [Model layout](COMPACT_MODELS.en.md)

Quality is reported using separate numerical, content and acoustic metrics. An encoder error percentage is not an overall perceptual degradation rate.

## Generated speech

Apple M2 MacBook Air (24 GB), macOS 27.2, Release build. We compared 24 Japanese texts with seeds 11, 29 and 47: 72 pairs / 144 WAVs. One engine was resident at a time; model order alternated by seed. Two warmup utterances per load were excluded. AudioSeal was enabled. Text sanitization and sentence splitting were disabled for exact model comparison.

The corpus includes short/ordinary/long text, numbers, place names, four Voice Design conditions and four conditions using one synthetic reference voice.

| Metric | Standard | INT8 | Difference |
|---|---:|---:|---:|
| ASR CER after reading normalization | 6.5217% | 5.5797% | −0.9420 percentage points |
| DNSMOS overall OVRL (estimated) | 3.0365 | 3.0311 | −0.0054 points |
| DNSMOS speech SIG (estimated) | 3.2993 | 3.2917 | −0.0075 points |
| DNSMOS background BAK (estimated) | 4.0024 | 4.0009 | −0.0015 points |
| DNSMOS P.808 (estimated) | 3.6338 | 3.6331 | −0.0006 points |
| PCM saturation sample rate | 0.000140% | 0.000154% | +0.000014 percentage points |

No pair increased CER; four decreased it. Recognized readings matched in 68/72 pairs. Text-cluster bootstrap 95% intervals were −3.0146 to 0.0000 percentage points for CER difference and −0.0189 to +0.0076 points for OVRL difference. All PCM was finite, and callback PCM matched completed PCM throughout.

OVRL differences vary by condition: ordinary text (48 pairs) +0.0045 points, Voice Design (12) −0.0230, synthetic reference voice (12) −0.0276. The worst pair was `reference-normal`, seed 11: **3.1320 → 2.9758, −0.1562 points**. A small overall mean does not imply identical quality in every condition.

Median absolute duration change was 0%, maximum 3.2258%; median absolute RMS level change was 0.0107 dB. Normalized-time log-mel RMSE had median 1.0859 dB. PCM saturation counts were 29/20,780,160 samples for standard and 32/20,802,240 for INT8.

CER uses the same ReazonSpeech INT8 transducer for both models, with pyopenjtalk Japanese reading normalization. ASR omissions/misrecognition and dictionary readings affect the absolute score; omissions common to both models are included. CER is not a human pronunciation or timbre rating.

[Official Microsoft DNSMOS](https://github.com/microsoft/DNS-Challenge/tree/591184a9fcb2cbdec02520fed81a32bbbf9d73ff/DNSMOS) is a speech-quality proxy developed for noise suppression. It is not a human MOS test or a measure of TTS naturalness/voice identity. WAVs were resampled to 16 kHz; the official evaluator repeats clips shorter than 9.01 seconds. Confidence intervals cluster repeated seeds by text and apply to this corpus, not every language, speaker or device. One synthetic reference is not a multi-speaker evaluation.

The measured average quality difference is small; this ASR comparison observed no content regression. We do **not** describe the result as “0% perceptual degradation.” Listening and tests using authorized real reference voices remain useful.

## Encoder numerical comparison

FP32 Core ML versus INT8 weight storage, CPU_ONLY. 28 natural text/caption inputs plus maximum-length and masked-padding cases, 30 inputs / 60 outputs.

| Metric | Result |
|---|---:|
| Maximum relative L2 error, natural inputs | 1.1347% |
| Minimum cosine, natural inputs | 0.9999356 |
| Maximum relative L2 error, all inputs | 2.0045% |
| Maximum absolute error | 0.0789679 |
| Minimum SNR | 33.9599 dB |
| Minimum cosine, all inputs | 0.9997991 |

Relative L2 error is `100 × ||INT8−FP32||₂ / ||FP32||₂`. The percentage measures feature error, not audio quality loss. Reports bind exact model, tokenizer and corpus hashes. Original FP32 Torch/ONNX tolerances are not attributed to the quantized model. Re-running the published converter reproduced identical weight bytes and a semantically identical operation graph; generated UUIDs/protobuf map order can change package bytes.

## iPhone speed

iPhone 17 Pro, iOS 27.0.1, Release, AudioSeal enabled, fixed seed, one resident engine. The full device investigation comprised 120 generations. The repeated-run comparison below used INT8 then standard; values are medians.

| Condition | Runs/model | RTF standard | RTF INT8 | First PCM standard | First PCM INT8 |
|---|---:|---:|---:|---:|---:|
| Ordinary | 5 | 0.1253 | 0.1286 | 460 ms | 480 ms |
| Long single sentence | 4 | 0.1248 | 0.1232 | 1,352 ms | 1,421 ms |
| Reference + caption | 3 | 0.1292 | 0.1362 | 483 ms | 509 ms |

TTS only: ASR, LLM, preparation and physical speaker delay are excluded. First PCM means callback readiness. The GUI waits for completed WAV before playback. Short utterances have greater fixed-cost RTF; compilation/specialization adds first-use latency. Speed varies with device, temperature and input.

## Reproduce

```sh
python -m pip install -r Benchmarks/requirements.txt
python Benchmarks/run_quality.py --cli .build/release/irodori \
  --baseline ../Models-Standard --candidate ../Models-INT8 \
  --reference ./authorized-reference.wav --output artifacts/quality-audio
python Benchmarks/analyze_quality.py --input artifacts/quality-audio \
  --asr-models ../ReazonSpeech-ONNX --report artifacts/audio-quality.json
```

The ASR directory requires the encoder, decoder, joiner and tokens files listed in the [Japanese measurement guide](QUALITY.md#再測定する); exact hashes are in the result JSON. Different filenames can be specified with `--encoder-file`, `--decoder-file` and `--joiner-file`. Exact score reproduction requires matching ASR hashes; distinguish results using different recognizers.

Retrieve DNSMOS separately at the revision recorded in `Benchmarks/dnsmos.sources.json`:

```sh
git clone https://github.com/microsoft/DNS-Challenge.git ../DNS-Challenge
git -C ../DNS-Challenge checkout 591184a9fcb2cbdec02520fed81a32bbbf9d73ff
python Benchmarks/score_dnsmos.py --input artifacts/quality-audio \
  --dnsmos ../DNS-Challenge --report artifacts/dnsmos-quality.json
```

These Python/evaluation models are optional tooling, not app/runtime dependencies. The [corpus](../Benchmarks/quality-cases.json), [inference artifact lock](../Distribution/quality-runtime.lock.json) and [results](../Distribution/quality-results) are provided; recordings/WAVs are excluded from the source archive. Reports may include input text/reference-derived information; review what you share when using your own voice.
