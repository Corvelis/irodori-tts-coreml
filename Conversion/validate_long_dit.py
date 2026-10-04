"""Smoke-test the extended Irodori Core ML DiT against the 128-frame model."""

from __future__ import annotations

import argparse
from pathlib import Path

import coremltools as ct
import numpy as np


def inputs(frames: int, tokens: int) -> dict[str, np.ndarray]:
    random = np.random.default_rng(41)
    data = {
        "x_t": random.standard_normal((1, frames, 32)).astype(np.float32),
        "t": np.array([1.0], dtype=np.float32),
        "delta_t": np.array([0.25], dtype=np.float32),
        "text_state": random.standard_normal((1, tokens, 512)).astype(np.float32),
        "text_mask": np.ones((1, tokens), dtype=np.float32),
        "speaker_state": random.standard_normal((1, 5, 768)).astype(np.float32),
        "speaker_mask": np.ones((1, 5), dtype=np.float32),
        "caption_state": np.zeros((1, tokens, 512), dtype=np.float32),
        "caption_mask": np.zeros((1, tokens), dtype=np.float32),
    }
    for layer in range(12):
        for kind, length in (("text", tokens), ("speaker", 5),
                             ("caption", tokens)):
            for part in ("k", "v"):
                data[f"{kind}_{part}_{layer}"] = random.standard_normal(
                    (1, length, 20, 64)
                ).astype(np.float32)
    return data


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("model_dir", type=Path)
    parser.add_argument("--precision", choices=("mixed_linear", "fp32"),
                        default="mixed_linear")
    parser.add_argument("--long-frames", type=int, default=621)
    parser.add_argument("--long-tokens", type=int, default=44)
    parser.add_argument("--compare-onnx", action="store_true")
    args = parser.parse_args()
    old = ct.models.MLModel(
        str(args.model_dir / f"dit_step_cached_{args.precision}_128.mlpackage"),
        compute_units=ct.ComputeUnit.CPU_ONLY,
    )
    extended = ct.models.MLModel(
        str(args.model_dir / f"dit_step_cached_{args.precision}_768.mlpackage"),
        compute_units=ct.ComputeUnit.CPU_ONLY,
    )
    short = inputs(57, 8)
    expected = old.predict(short)["v_pred"]
    actual = extended.predict(short)["v_pred"]
    maximum_error = float(np.max(np.abs(expected - actual)))
    print(f"57-frame maximum output difference: {maximum_error:.6f}", flush=True)
    if not np.isfinite(actual).all() or maximum_error > 0.05:
        raise RuntimeError("Extended model changed the short prediction")
    long_inputs = inputs(args.long_frames, args.long_tokens)
    long = extended.predict(long_inputs)["v_pred"]
    print(f"long output shape: {long.shape}, finite: {np.isfinite(long).all()}",
          flush=True)
    if long.shape != (1, args.long_frames, 32) or not np.isfinite(long).all():
        raise RuntimeError("Extended model rejected the long input")
    if args.compare_onnx:
        import onnxruntime as ort

        options = ort.SessionOptions()
        options.intra_op_num_threads = 2
        reference = ort.InferenceSession(
            str(args.model_dir / "dit_step.onnx"),
            sess_options=options,
            providers=["CPUExecutionProvider"],
        )
        onnx_inputs = {
            item.name: (np.ones((12,), dtype=np.float32)
                        if item.name == "speaker_kv_scales"
                        else long_inputs[item.name])
            for item in reference.get_inputs()
        }
        expected_long = reference.run(None, onnx_inputs)[0]
        long_error = float(np.max(np.abs(expected_long - long)))
        print(f"long maximum ONNX output difference: {long_error:.6f}", flush=True)
        if args.precision == "fp32" and long_error > 0.01:
            raise RuntimeError("Extended Float32 model differs from ONNX")


if __name__ == "__main__":
    main()
