"""Export the official Irodori v4.1 Small MF DiT to a flexible Core ML model.

Usage:
  python export_coreml_dit.py --checkpoint /path/to/model.safetensors \
    --source-root /path/to/Irodori-TTS --output /path/to/dit_step.mlpackage

The upstream PyTorch checkout and its dependencies must be importable. Tracing
and Core ML conversion run in separate processes to limit peak memory use.
"""

from __future__ import annotations

import argparse
import dataclasses
import json
import subprocess
import sys
import tempfile
import types
from pathlib import Path


def _trace(checkpoint: Path, source_root: Path, traced_path: Path,
           cached_kv: bool, max_frames: int, max_text_tokens: int,
           frame_buckets: tuple[int, ...] = ()) -> None:
    import torch
    from safetensors import safe_open

    try:
        import transformers.initialization  # noqa: F401
    except ImportError:
        from transformers.modeling_utils import no_init_weights

        compatibility = types.ModuleType("transformers.initialization")
        compatibility.no_init_weights = no_init_weights
        sys.modules["transformers.initialization"] = compatibility

    sys.path.insert(0, str(source_root))
    from irodori_tts.config import ModelConfig
    import irodori_tts.model as upstream

    # Core ML cannot represent the upstream complex-valued RoPE. The two real
    # channels below are algebraically equivalent to complex multiplication.
    def real_freqs(dim: int, end: int, theta: float = 10000.0):
        base = 1.0 / (theta ** (torch.arange(0, dim, 2, dtype=torch.float32) / dim))
        angles = torch.outer(torch.arange(end, dtype=torch.float32), base)
        return torch.stack((torch.cos(angles), torch.sin(angles)), dim=-1)

    def real_rope(x, freqs):
        pair = x.float().reshape(*x.shape[:3], -1, 2)
        cosine = freqs[None, :, None, :, 0]
        sine = freqs[None, :, None, :, 1]
        rotated = torch.stack(
            (pair[..., 0] * cosine - pair[..., 1] * sine,
             pair[..., 0] * sine + pair[..., 1] * cosine),
            dim=-1,
        )
        return rotated.reshape_as(x).to(x.dtype)

    with torch.no_grad():
        example = torch.randn(1, 13, 20, 64)
        complex_freqs = upstream.precompute_freqs_cis(64, 13)
        real_output = real_rope(example, real_freqs(64, 13))
        original_output = upstream.apply_rotary_emb(example, complex_freqs)
        error = (real_output - original_output).abs().max().item()
        if error > 1e-5:
            raise RuntimeError(f"RoPE rewrite changed output: max error {error}")
    upstream.precompute_freqs_cis = real_freqs
    upstream.apply_rotary_emb = real_rope

    class Step(torch.nn.Module):
        def __init__(self, core, padded: bool = False):
            super().__init__()
            self.core = core
            self.padded = padded

        def forward(self, x, t, delta_t, text, text_mask, speaker,
                    speaker_mask, caption, caption_mask, *projected_kv):
            latent_mask = None
            if self.padded:
                latent_mask = projected_kv[0] > 0.5
                projected_kv = projected_kv[1:]
            cache = None
            if cached_kv:
                cache = [tuple(projected_kv[index:index + 6])
                         for index in range(0, len(projected_kv), 6)]
            return self.core.forward_with_encoded_conditions(
                x_t=x, t=t, delta_t=delta_t, text_state=text,
                text_mask=text_mask > 0.5, speaker_state=speaker,
                speaker_mask=speaker_mask > 0.5, caption_state=caption,
                caption_mask=caption_mask > 0.5,
                latent_mask=latent_mask,
                context_kv_cache=cache,
            )

    with safe_open(str(checkpoint), framework="pt", device="cpu") as source:
        metadata = source.metadata()
    raw_config = json.loads(metadata["config_json"])
    config_fields = {field.name for field in dataclasses.fields(ModelConfig)}
    config = ModelConfig(**{key: value for key, value in raw_config.items()
                            if key in config_fields})
    if config.flow_parameterization != "meanflow" or config.num_layers != 12:
        raise ValueError("Expected the official v4.1 Small MF checkpoint")
    core = upstream.TextToLatentRFDiT(
        config,
        pretrained_backbone_config=json.loads(metadata["text_encoder_config_json"]),
        load_pretrained_backbone_weights=False,
    )
    # The app supplies encoded text/speaker/caption states. Dropping their
    # encoders avoids carrying unrelated weights into the converted DiT.
    for field in ("pretrained_text_backbone", "text_encoder", "caption_encoder",
                  "speaker_encoder", "duration_predictor"):
        if hasattr(core, field):
            delattr(core, field)
    with safe_open(str(checkpoint), framework="pt", device="cpu") as source:
        with torch.no_grad():
            for name, parameter in core.named_parameters():
                parameter.copy_(source.get_tensor(name))
    core.eval()
    step = Step(core, padded=bool(frame_buckets)).eval()
    torch.manual_seed(41)
    example_inputs = (
        torch.randn(1, max_frames, 32), torch.ones(1), torch.full((1,), 0.25),
        torch.randn(1, 8, 512), torch.ones(1, 8),
        torch.randn(1, 5, 768), torch.ones(1, 5),
        torch.randn(1, 8, 512), torch.zeros(1, 8),
    )
    if frame_buckets:
        example_inputs += (torch.cat((
            torch.ones(1, max_frames // 2),
            torch.zeros(1, max_frames - max_frames // 2)), dim=1),)
    if cached_kv:
        cache = core.build_context_kv_cache(example_inputs[3], example_inputs[5],
                                            example_inputs[7])
        example_inputs += tuple(value for layer in cache for value in layer)
    with torch.no_grad():
        # Prime the maximum-length RoPE table before tracing. Otherwise the
        # trace includes its construction, which Core ML Tools cannot lower.
        step(*example_inputs)
        traced = torch.jit.trace(step, example_inputs, check_trace=False, strict=False)
        for frames, tokens, speaker_tokens in ((57, 8, 5),
                                               (max_frames, max_text_tokens, 26),
                                               (32, 4, 2)):
            inputs = (
                torch.randn(1, frames, 32), torch.ones(1), torch.full((1,), 0.25),
                torch.randn(1, tokens, 512), torch.ones(1, tokens),
                torch.randn(1, speaker_tokens, 768), torch.ones(1, speaker_tokens),
                torch.randn(1, tokens, 512), torch.zeros(1, tokens),
            )
            if frame_buckets:
                inputs += (torch.ones(1, frames),)
            if cached_kv:
                cache = core.build_context_kv_cache(inputs[3], inputs[5], inputs[7])
                inputs += tuple(value for layer in cache for value in layer)
            error = (step(*inputs) - traced(*inputs)).abs().max().item()
            if error > 1e-5:
                raise RuntimeError(f"TorchScript trace changed output: {error}")
        if frame_buckets:
            baseline = Step(core).eval()
            for bucket in frame_buckets:
                real_frames = max(13, bucket - min(7, bucket // 4))
                real_x = torch.randn(1, real_frames, 32)
                padded_x = torch.nn.functional.pad(real_x, (0, 0, 0, bucket - real_frames))
                text = torch.randn(1, 8, 512)
                speaker = torch.randn(1, 5, 768)
                caption = torch.zeros(1, 8, 512)
                conditions = (
                    torch.ones(1), torch.full((1,), 0.25), text,
                    torch.ones(1, 8), speaker, torch.ones(1, 5),
                    caption, torch.zeros(1, 8),
                )
                cache_inputs = ()
                if cached_kv:
                    cache = core.build_context_kv_cache(text, speaker, caption)
                    cache_inputs = tuple(value for layer in cache for value in layer)
                mask = torch.cat((torch.ones(1, real_frames),
                                  torch.zeros(1, bucket - real_frames)), dim=1)
                reference = baseline(real_x, *conditions, *cache_inputs)
                candidate = step(padded_x, *conditions, mask, *cache_inputs)
                error = (reference - candidate[:, :real_frames]).abs().max().item()
                if error > 1e-4:
                    raise RuntimeError(
                        f"Latent masking changed output for {real_frames}/{bucket}: {error}")
                print(f"Padded latent {real_frames}/{bucket} max error {error}", flush=True)
    traced.save(str(traced_path))
    print(f"TorchScript DiT saved: {traced_path}", flush=True)


def _convert(traced_path: Path, output: Path, precision: str,
             cached_kv: bool, max_frames: int, max_text_tokens: int,
             max_speaker_tokens: int,
             frame_buckets: tuple[int, ...] = ()) -> None:
    import coremltools as ct
    from coremltools.converters.mil.mil.passes.defs.quantization import FP16ComputePrecision
    import torch

    traced = torch.jit.load(str(traced_path))
    # Core ML rejects a mixture of enumerated and range inputs. Text and
    # speaker lengths must remain flexible, so the runtime pads the latent to
    # one of frame_buckets while both latent inputs share this range symbol.
    frames = ct.RangeDim(frame_buckets[0] if frame_buckets else 13,
                         max_frames,
                         default=frame_buckets[0] if frame_buckets else 57,
                         symbol="latent_frames")
    tokens = ct.RangeDim(1, max_text_tokens, default=8, symbol="text_tokens")
    speaker = ct.RangeDim(1, max_speaker_tokens, default=5,
                          symbol="speaker_tokens")
    shapes = [
        ("x_t", (1, frames, 32)),
        ("t", (1,)), ("delta_t", (1,)),
        ("text_state", (1, tokens, 512)), ("text_mask", (1, tokens)),
        ("speaker_state", (1, speaker, 768)), ("speaker_mask", (1, speaker)),
        ("caption_state", (1, tokens, 512)), ("caption_mask", (1, tokens)),
    ]
    if frame_buckets:
        shapes.append(("latent_mask", (1, frames)))
    if cached_kv:
        for layer in range(12):
            for kind, length in (("text", tokens), ("speaker", speaker),
                                 ("caption", tokens)):
                for part in ("k", "v"):
                    shapes.append((f"{kind}_{part}_{layer}", (1, length, 20, 64)))
    if precision == "mixed-mlp":
        def is_mlp_projection(op):
            if op.op_type != "linear":
                return False
            weight = op.inputs.get("weight")
            name = getattr(weight, "name", "")
            return any(name.endswith(f"_mlp_w{index}_weight")
                       for index in (1, 2, 3))

        compute_precision = FP16ComputePrecision(op_selector=is_mlp_projection)
    elif precision == "mixed-linear":
        # Keep attention, normalization, residual additions and the external
        # K/V cache in Float32. The linear weights are the large part of the
        # model and can still be stored and computed in Float16.
        compute_precision = FP16ComputePrecision(
            op_selector=lambda op: op.op_type == "linear"
        )
    else:
        compute_precision = (ct.precision.FLOAT16 if precision == "float16"
                             else ct.precision.FLOAT32)
    model = ct.convert(
        traced,
        source="pytorch",
        convert_to="mlprogram",
        inputs=[ct.TensorType(name=name, shape=shape) for name, shape in shapes],
        outputs=[ct.TensorType(name="v_pred")],
        minimum_deployment_target=ct.target.iOS17,
        compute_precision=compute_precision,
        compute_units=ct.ComputeUnit.CPU_AND_NE,
        skip_model_load=True,
    )
    model.save(str(output))
    print(f"Core ML DiT saved: {output}", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--precision", choices=("float16", "float32", "mixed-linear",
                                                "mixed-mlp"),
                        default="float16")
    parser.add_argument("--cached-kv", action="store_true",
                        help="Accept the 72 precomputed K/V tensors from context_kv.onnx")
    parser.add_argument("--max-frames", type=int, default=64,
                        help="Maximum supported latent frames (default: 64)")
    parser.add_argument("--max-text-tokens", type=int, default=64,
                        help="Maximum supported text tokens, including BOS (default: 64)")
    parser.add_argument("--max-speaker-tokens", type=int, default=751,
                        help="Maximum speaker tokens (751 covers 120 s of v4.1 reference audio)")
    parser.add_argument("--frame-buckets", default="",
                        help="Optional comma-separated padded latent lengths for iOS 18+")
    parser.add_argument("--worker", choices=("trace", "convert"))
    parser.add_argument("--traced-path", type=Path)
    args = parser.parse_args()
    frame_buckets = tuple(int(value) for value in args.frame_buckets.split(",")
                          if value.strip())
    if frame_buckets and (sorted(set(frame_buckets)) != list(frame_buckets) or
                          frame_buckets[0] < 13 or frame_buckets[-1] != args.max_frames):
        parser.error("--frame-buckets must be ascending, unique and end at --max-frames")
    if not 64 <= args.max_frames <= 1024:
        parser.error("--max-frames must be between 64 and 1024")
    if not 64 <= args.max_text_tokens <= 256:
        parser.error("--max-text-tokens must be between 64 and 256")
    if not 26 <= args.max_speaker_tokens <= 751:
        parser.error("--max-speaker-tokens must be between 26 and 751")
    if args.worker == "trace":
        _trace(args.checkpoint, args.source_root, args.traced_path,
               args.cached_kv, args.max_frames, args.max_text_tokens,
               frame_buckets)
    elif args.worker == "convert":
        _convert(args.traced_path, args.output, args.precision,
                 args.cached_kv, args.max_frames, args.max_text_tokens,
                 args.max_speaker_tokens, frame_buckets)
    else:
        with tempfile.TemporaryDirectory(prefix="irodori-coreml-") as temporary:
            traced_path = Path(temporary) / "dit_step.pt"
            common = [sys.executable, __file__, "--checkpoint", str(args.checkpoint),
                      "--source-root", str(args.source_root), "--output", str(args.output),
                      "--precision", args.precision, "--traced-path", str(traced_path),
                      "--max-frames", str(args.max_frames),
                      "--max-text-tokens", str(args.max_text_tokens),
                      "--max-speaker-tokens", str(args.max_speaker_tokens)]
            if args.cached_kv:
                common.append("--cached-kv")
            if frame_buckets:
                common.extend(("--frame-buckets", args.frame_buckets))
            subprocess.run([*common, "--worker", "trace"], check=True)
            subprocess.run([*common, "--worker", "convert"], check=True)


if __name__ == "__main__":
    main()
