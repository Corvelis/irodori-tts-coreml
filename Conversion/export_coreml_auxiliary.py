"""Export remaining Irodori ONNX components to FP32 Core ML packages.

This is an experimental converter. It checks dynamic-shape Torch parity before
exporting; validate_coreml_auxiliary.py checks actual Core ML predictions.
Existing models are never overwritten. Input/output names are recorded in a
sidecar so runtime integration does not depend on Core ML name sanitization.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
from pathlib import Path
import sys

# These conversions do not use TensorFlow. Avoid importing an unrelated local
# TensorFlow installation through coremltools' optional frontend discovery.
sys.modules.setdefault("tensorflow", None)

import numpy as np
import onnx
from onnx import TensorProto, helper, numpy_helper
import onnxruntime as ort
import torch
from onnx2torch import convert
import coremltools as ct


def input_shape(value, tokens=9, speaker=30, frames=57, samples=48000):
    sizes = {"batch": 1, "text_len": tokens, "caption_len": tokens,
             "spk_len": speaker, "ref_len": frames, "time": frames,
             "samples": samples}
    return tuple(d.dim_value or sizes[d.dim_param]
                 for d in value.type.tensor_type.shape.dim)


def feeds_for(model, *, tokens=9, speaker=30, frames=57, samples=48000):
    rng = np.random.default_rng(20260928)
    feeds = {}
    for value in model.graph.input:
        shape = input_shape(value, tokens, speaker, frames, samples)
        if value.type.tensor_type.elem_type == TensorProto.INT64:
            data = rng.integers(1, 20000, shape, dtype=np.int64)
        elif "mask" in value.name or value.name.startswith("has_"):
            data = np.ones(shape, dtype=np.float32)
            if "caption" in value.name:
                data.fill(0)
        else:
            data = rng.normal(0, .2, shape).astype(np.float32)
        feeds[value.name] = data
    return feeds


def clean_graph(model):
    used = {name for node in model.graph.node for name in node.input}
    for i in reversed(range(len(model.graph.input))):
        if model.graph.input[i].name not in used:
            del model.graph.input[i]
    return model


def errors(reference, actual):
    if reference.shape != actual.shape or not np.isfinite(actual).all():
        raise ValueError(f"Invalid output shape/values: {reference.shape}, {actual.shape}")
    difference = actual.astype(np.float64) - reference.astype(np.float64)
    power = np.sum(reference.astype(np.float64) ** 2)
    noise = np.sum(difference ** 2)
    return {"max_abs": float(np.max(np.abs(difference))),
            "snr_db": float(10 * np.log10(max(power, 1e-30) / max(noise, 1e-30)))}


def fold_constant_reciprocals(model):
    """Keep Snake's 1/alpha constants exact before Core ML compilation.

    Core ML CPU execution of constant reciprocal introduced ~1e-4 errors,
    amplified by the encoder's periodic activations. Evaluate only constants,
    using IEEE Float32 division; do not change learned weights or activations.
    """
    model = copy.deepcopy(model)
    constants = {v.name: numpy_helper.to_array(v) for v in model.graph.initializer}
    folded = 0
    for node in model.graph.node:
        if node.op_type == "Constant":
            for attribute in node.attribute:
                if attribute.name == "value":
                    constants[node.output[0]] = numpy_helper.to_array(attribute.t)
        elif node.op_type == "Identity" and node.input[0] in constants:
            constants[node.output[0]] = constants[node.input[0]]
        elif node.op_type == "Reciprocal" and node.input[0] in constants:
            value = np.reciprocal(constants[node.input[0]])
            if value.dtype != np.float32 or not np.isfinite(value).all():
                raise ValueError("Invalid constant reciprocal")
            constants[node.output[0]] = value
            replacement = helper.make_node("Constant", [], list(node.output), name=node.name,
                                           value=numpy_helper.from_array(value))
            node.CopyFrom(replacement)
            folded += 1
    return model, folded


def export(source: Path, output: Path, checkpoint: Path | None = None, source_root: Path | None = None):
    torch.set_num_threads(2)
    name = source.stem
    destination = output / f"{name}.mlpackage"
    if destination.exists():
        raise FileExistsError(destination)
    output.mkdir(parents=True, exist_ok=True)
    model = clean_graph(onnx.load(str(source)))
    onnx.checker.check_model(model)
    input_names = [v.name for v in model.graph.input]
    output_names = [v.name for v in model.graph.output]
    if checkpoint is not None:
        from coreml_auxiliary_modules import build
        module = build(name, checkpoint, source_root, input_names)
    else:
        rewritten, folded = fold_constant_reciprocals(model)
        print(f"Folded {folded} constant Float32 reciprocals", flush=True)
        module = convert(rewritten).eval()
    session_options = ort.SessionOptions()
    session_options.intra_op_num_threads = 2
    session = ort.InferenceSession(model.SerializeToString(), session_options,
                                   providers=["CPUExecutionProvider"])
    feeds = feeds_for(model)
    inputs = tuple(torch.from_numpy(feeds[key]) for key in input_names)
    with torch.no_grad():
        traced = torch.jit.trace(module, inputs, check_trace=False, strict=False)
    checks = []
    for tokens, speaker, frames, samples in [(3, 2, 13, 24960), (9, 30, 57, 48000),
                                           (44, 54, 520, 228480)]:
        case = feeds_for(model, tokens=tokens, speaker=speaker, frames=frames, samples=samples)
        reference = session.run(None, case)
        with torch.no_grad():
            actual = traced(*(torch.from_numpy(case[key]) for key in input_names))
        if isinstance(actual, torch.Tensor):
            actual = [actual]
        if len(actual) != len(reference):
            raise ValueError("Output count changed")
        checks.append([errors(a, b.numpy()) for a, b in zip(reference, actual)])
        if any(item["max_abs"] > 1e-3 for item in checks[-1]):
            raise ValueError(f"Torch trace differs from ONNX: {checks[-1]}")
    del session
    print(f"{name}: dynamic Torch parity passed", flush=True)
    ranges = {"batch": 1, "text_len": (1, 256, 9), "caption_len": (1, 256, 9),
              "spk_len": (1, 751, 30), "ref_len": (4, 3000, 57),
              "time": (13, 768, 57), "samples": (1920, 5760000, 48000)}
    types = []
    for value in model.graph.input:
        shape = []
        for dim in value.type.tensor_type.shape.dim:
            size = dim.dim_value or ranges[dim.dim_param]
            shape.append(ct.RangeDim(*size) if isinstance(size, tuple) else size)
        dtype = np.int32 if value.type.tensor_type.elem_type == TensorProto.INT64 else np.float32
        types.append(ct.TensorType(name=value.name, shape=tuple(shape), dtype=dtype))
    coreml_outputs = [f"out_{i}" for i in range(len(output_names))]
    converted = ct.convert(traced, source="pytorch", convert_to="mlprogram",
        inputs=types, outputs=[ct.TensorType(name=n, dtype=np.float32) for n in coreml_outputs],
        compute_precision=ct.precision.FLOAT32, compute_units=ct.ComputeUnit.CPU_ONLY,
        minimum_deployment_target=ct.target.iOS17, skip_model_load=True)
    converted.save(str(destination))
    metadata = {"name": name, "source": str(source.resolve()),
                "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
                "compute_precision": "float32", "inputs": input_names,
                "outputs": dict(zip(output_names, coreml_outputs)),
                "torch_checks": checks, "validated_coreml": False}
    destination.with_suffix(".json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(f"Saved {destination}", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--checkpoint", type=Path)
    parser.add_argument("--source-root", type=Path)
    args = parser.parse_args()
    if bool(args.checkpoint) != bool(args.source_root):
        parser.error("--checkpoint and --source-root must be supplied together")
    export(args.source, args.output, args.checkpoint, args.source_root)
