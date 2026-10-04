"""Convert Irodori's split DACVAE decoder stages 1-3 to 2D Core ML.

First run export_decoder_stages.py to create decoder_stage_{0..3}.onnx.
The converted packages accept variable input widths. Stage 0 is exported separately to FP32 Core ML by export_coreml_auxiliary.py.

Dependencies: onnx, onnxruntime, onnx2torch, torch, coremltools, numpy.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
import onnx
import onnxruntime as ort
import torch
import coremltools as ct
from coremltools.converters.mil.mil.passes.defs.quantization import FP16ComputePrecision
from onnx import numpy_helper
from onnx2torch import convert


STAGES = {
    1: (1536, 768, 64, 12),
    2: (768, 384, 128, 10),
    3: (384, 1, 256, 16),
}


def to_2d(source: Path, stage: int, length: int) -> onnx.ModelProto:
    input_channels, output_channels, _, scale = STAGES[stage]
    model = onnx.load(str(source))
    for initializer in model.graph.initializer:
        if len(initializer.dims) == 3:
            array = numpy_helper.to_array(initializer)
            initializer.CopyFrom(
                numpy_helper.from_array(array[:, :, None, :], initializer.name)
            )
    for node in model.graph.node:
        if node.op_type not in {"Conv", "ConvTranspose"}:
            continue
        for attribute in node.attribute:
            if attribute.name == "pads":
                attribute.ints[:] = [0, attribute.ints[0], 0, attribute.ints[1]]
            elif attribute.name in {"dilations", "strides", "kernel_shape"}:
                attribute.ints[:] = [1, attribute.ints[0]]
            elif attribute.name == "output_padding":
                attribute.ints[:] = [0, attribute.ints[0]]
    for value, channels, width in (
        (model.graph.input[0], input_channels, length),
        (model.graph.output[0], output_channels, length * scale),
    ):
        shape = value.type.tensor_type.shape
        shape.ClearField("dim")
        for dimension in (1, channels, 1, width):
            shape.dim.add().dim_value = dimension
    model.graph.ClearField("value_info")
    onnx.checker.check_model(model)
    return model


def verify_onnx(source: Path, rewritten: onnx.ModelProto, stage: int,
                length: int) -> None:
    channels = STAGES[stage][0]
    x = np.random.default_rng(41 + stage).standard_normal(
        (1, channels, length)
    ).astype(np.float32) * 0.5
    original_session = ort.InferenceSession(str(source), providers=["CPUExecutionProvider"])
    rewritten_session = ort.InferenceSession(
        rewritten.SerializeToString(), providers=["CPUExecutionProvider"]
    )
    original = original_session.run(None, {original_session.get_inputs()[0].name: x})[0]
    converted = rewritten_session.run(None, {
        rewritten_session.get_inputs()[0].name: x[:, :, None, :]
    })[0][:, :, 0, :]
    error = float(np.max(np.abs(original - converted)))
    if error > 1e-4:
        raise RuntimeError(f"Stage {stage} ONNX 2D rewrite error: {error}")
    print(f"Stage {stage} ONNX 1D/2D max error: {error:.8f}", flush=True)


def export(directory: Path, stage: int, width: int | None = None,
           fixed: bool = False, precision: str = "float16",
           enumerated_widths: list[int] | None = None) -> None:
    channels, _, standard_length, _ = STAGES[stage]
    length = max(enumerated_widths) if enumerated_widths else (width or standard_length)
    source = directory / f"decoder_stage_{stage}.onnx"
    if not source.is_file():
        raise FileNotFoundError(source)
    rewritten = to_2d(source, stage, length)
    verify_onnx(source, rewritten, stage, length)
    module = convert(rewritten).eval()
    example = torch.randn(1, channels, 1, length)
    with torch.no_grad():
        traced = torch.jit.trace(module, example, check_trace=False, strict=False)
        shorter = example[:, :, :, :length - 11]
        trace_error = (module(shorter) - traced(shorter)).abs().max().item()
        if trace_error > 1e-5:
            raise RuntimeError(f"Stage {stage} variable-length trace error: {trace_error}")
    minimum = 13 if stage == 1 else 10
    default = 57 if stage == 1 else length
    model_width = length if fixed else ct.RangeDim(minimum, length, default=default)
    input_shape = (1, channels, 1, model_width)
    if enumerated_widths:
        input_shape = ct.EnumeratedShapes(
            shapes=[(1, channels, 1, item) for item in enumerated_widths],
            default=(1, channels, 1, enumerated_widths[0]),
        )
    if precision == "mixed-conv":
        compute_precision = FP16ComputePrecision(
            op_selector=lambda op: op.op_type in {"conv", "conv_transpose"}
        )
    else:
        compute_precision = (ct.precision.FLOAT16 if precision == "float16"
                             else ct.precision.FLOAT32)
    mlmodel = ct.convert(
        traced,
        source="pytorch",
        convert_to="mlprogram",
        inputs=[ct.TensorType(
            name="stage_input",
            shape=input_shape,
        )],
        outputs=[ct.TensorType(name="stage_output")],
        minimum_deployment_target=ct.target.iOS17,
        compute_precision=compute_precision,
        compute_units=ct.ComputeUnit.CPU_AND_NE,
        skip_model_load=True,
    )
    suffix = ("_enum" if enumerated_widths else
              (f"_{'fixed_' if fixed else ''}w{length}" if width is not None else ""))
    if precision != "float16":
        suffix += "_" + ("fp32" if precision == "float32" else "mixed_conv")
    destination = directory / f"decoder_stage_{stage}_2d{suffix}.mlpackage"
    mlmodel.save(str(destination))
    if enumerated_widths:
        destination.with_suffix(".json").write_text(json.dumps({
            "widths": enumerated_widths,
        }))
    print(f"Saved {destination}", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("model_directory", type=Path)
    parser.add_argument("--stage", type=int, choices=STAGES, action="append",
                        help="Convert only selected stages (default: all three)")
    parser.add_argument("--width", type=int,
                        help="Maximum input width for one selected stage")
    parser.add_argument("--fixed", action="store_true",
                        help="Export a fixed input width (requires --width)")
    parser.add_argument("--enumerated-widths",
                        help="Comma-separated exact input widths for an enumerated Core ML model")
    parser.add_argument("--precision", choices=("float16", "float32", "mixed-conv"),
                        default="float16")
    args = parser.parse_args()
    if args.width is not None and (args.stage is None or len(args.stage) != 1):
        parser.error("--width requires exactly one --stage")
    if args.fixed and args.width is None:
        parser.error("--fixed requires --width")
    if args.enumerated_widths and (args.width is not None or args.fixed or
                                   args.stage is None or len(args.stage) != 1):
        parser.error("--enumerated-widths requires one --stage and excludes --width/--fixed")
    enumerated_widths = None
    if args.enumerated_widths:
        try:
            enumerated_widths = sorted({int(item) for item in
                                        args.enumerated_widths.split(",")})
        except ValueError:
            parser.error("--enumerated-widths must contain integers")
        if len(enumerated_widths) < 2 or enumerated_widths[0] < 13:
            parser.error("--enumerated-widths needs at least two widths >= 13")
    for stage in args.stage or STAGES:
        export(args.model_directory, stage, args.width, args.fixed,
               args.precision, enumerated_widths)


if __name__ == "__main__":
    main()
