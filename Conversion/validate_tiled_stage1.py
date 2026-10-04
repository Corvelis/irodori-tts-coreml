"""Compare overlapping fixed-64 decoder stage 1 against flexible Core ML.

Run on macOS with the converted model directory. A writable TMPDIR may be
needed when Core ML compiles mlpackage files under a filesystem sandbox.
"""

from __future__ import annotations

import argparse
from pathlib import Path

import coremltools as ct
import numpy as np
import onnxruntime as ort


def tiled_stage1(model: ct.models.MLModel, source: np.ndarray) -> np.ndarray:
    width, context, scale = 64, 5, 12
    step = width - context * 2
    total = source.shape[-1]
    output = np.empty((1, 768, total * scale), dtype=np.float32)
    for start in range(0, total, step):
        left = max(0, min(start - context, total - width))
        window = source[:, :, :, left : left + width]
        decoded = model.predict({"stage_input": window})["stage_output"][:, :, 0, :]
        count = min(step, total - start) * scale
        crop = (start - left) * scale
        output[:, :, start * scale : start * scale + count] = decoded[
            :, :, crop : crop + count
        ]
    return output


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("model_directory", type=Path)
    parser.add_argument("--frames", type=int, nargs="+", default=[65, 85, 105, 128])
    args = parser.parse_args()
    root = args.model_directory
    stage0 = ort.InferenceSession(
        str(root / "decoder_stage_0.onnx"), providers=["CPUExecutionProvider"]
    )
    fixed = ct.models.MLModel(
        str(root / "decoder_stage_1_2d_fixed_w64.mlpackage"),
        compute_units=ct.ComputeUnit.CPU_ONLY,
    )
    flexible = ct.models.MLModel(
        str(root / "decoder_stage_1_2d_w128.mlpackage"),
        compute_units=ct.ComputeUnit.CPU_ONLY,
    )
    rng = np.random.default_rng(41)
    for frames in args.frames:
        if not 64 < frames <= 128:
            parser.error("every frame count must be from 65 to 128")
        latent = rng.normal(size=(1, frames, 32)).astype(np.float32)
        source = stage0.run(None, {"latent": latent})[0][:, :, None, :]
        expected = flexible.predict({"stage_input": source})["stage_output"][
            :, :, 0, :
        ]
        actual = tiled_stage1(fixed, source)
        delta = np.max(np.abs(actual - expected))
        print(f"frames={frames} max_abs_error={delta:.9g}")
        if not np.array_equal(actual, expected):
            raise SystemExit("tiled stage 1 differs from the flexible model")


if __name__ == "__main__":
    main()
