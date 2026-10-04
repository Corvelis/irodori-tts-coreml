"""Extract the four exact DACVAE decoder stages from the Onsei v4.1 MF ONNX.

Usage:
    python Conversion/export_decoder_stages.py /path/to/v4.1-small-mf

Requires: onnx, onnxruntime, numpy. The generated stage models are saved next to
`dacvae_decode.onnx`; the app imports them when that folder is selected.
"""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
import onnx
import onnxruntime as ort


def export(model_dir: Path) -> None:
    source = model_dir / "dacvae_decode.onnx"
    if not source.is_file():
        raise FileNotFoundError(source)
    graph = onnx.load(str(source), load_external_data=False)
    expected = ("/decoder/model.0/Conv", "/decoder/model.1/block.8/Add",
                "/decoder/model.2/block.8/Add")
    cuts = []
    for node_name in expected:
        matches = [node for node in graph.graph.node if node.name == node_name]
        if len(matches) != 1:
            raise ValueError(f"Unexpected decoder graph; missing {node_name}")
        cuts.append(matches[0].output[0])
    names = ["latent", *cuts, "waveform"]
    paths = []
    for index in range(4):
        path = model_dir / f"decoder_stage_{index}.onnx"
        onnx.utils.extract_model(str(source), str(path), [names[index]], [names[index + 1]])
        onnx.checker.check_model(str(path))
        paths.append(path)
        print(f"stage {index}: {path.name} ({path.stat().st_size:,} bytes)")

    fixed = onnx.load(str(paths[3]))
    fixed.graph.input[0].type.tensor_type.shape.dim[0].ClearField("dim_param")
    fixed.graph.input[0].type.tensor_type.shape.dim[0].dim_value = 1
    fixed.graph.input[0].type.tensor_type.shape.dim[2].ClearField("dim_param")
    fixed.graph.input[0].type.tensor_type.shape.dim[2].dim_value = 256
    fixed.graph.output[0].type.tensor_type.shape.dim[0].ClearField("dim_param")
    fixed.graph.output[0].type.tensor_type.shape.dim[0].dim_value = 1
    fixed.graph.output[0].type.tensor_type.shape.dim[2].ClearField("dim_param")
    fixed.graph.output[0].type.tensor_type.shape.dim[2].dim_value = 4096
    fixed = onnx.shape_inference.infer_shapes(fixed)
    fixed_path = model_dir / "decoder_stage_3_256.onnx"
    onnx.save(fixed, str(fixed_path))
    onnx.checker.check_model(str(fixed_path))
    print(f"fixed stage 3: {fixed_path.name} ({fixed_path.stat().st_size:,} bytes)")

    options = ort.SessionOptions()
    options.intra_op_num_threads = 2
    sessions = [ort.InferenceSession(str(path), sess_options=options,
                                    providers=["CPUExecutionProvider"]) for path in paths]
    full = ort.InferenceSession(str(source), sess_options=options,
                                providers=["CPUExecutionProvider"])
    latent = np.random.default_rng(7).standard_normal((1, 57, 32)).astype(np.float32)
    stage = latent
    for session in sessions:
        stage = session.run(None, {session.get_inputs()[0].name: stage})[0]
    reference = full.run(None, {"latent": latent})[0]
    if not np.array_equal(stage, reference):
        raise AssertionError(f"Stage split differs: max={np.max(np.abs(stage-reference))}")

    # Verify the same stage-3 tiling used by the iOS runtime (57*12*10=6840).
    pre3 = latent
    for session in sessions[:3]:
        pre3 = session.run(None, {session.get_inputs()[0].name: pre3})[0]
    tiled = np.empty_like(reference)
    total = pre3.shape[2]
    for start in range(0, total, 236):
        left, right = max(0, start - 10), min(total, start + 246)
        window = pre3[:, :, left:right]
        decoded = sessions[3].run(None, {sessions[3].get_inputs()[0].name: window})[0]
        count = min(236, total - start) * 16
        crop = (start - left) * 16
        tiled[:, :, start * 16:start * 16 + count] = decoded[:, :, crop:crop + count]
    if not np.array_equal(tiled, reference):
        raise AssertionError(f"Tiled final stage differs: max={np.max(np.abs(tiled-reference))}")
    fixed_session = ort.InferenceSession(str(fixed_path), sess_options=options,
                                         providers=["CPUExecutionProvider"])
    middle = pre3[:, :, 100:356]
    dynamic_output = sessions[3].run(None, {sessions[3].get_inputs()[0].name: middle})[0]
    fixed_output = fixed_session.run(None, {fixed_session.get_inputs()[0].name: middle})[0]
    if not np.array_equal(dynamic_output, fixed_output):
        raise AssertionError("Fixed 256-frame stage 3 differs from the dynamic graph")
    print("57-frame four-stage and 29-window outputs match the source exactly")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("model_dir", type=Path)
    export(parser.parse_args().model_dir)
