"""Split static speaker KV from per-text KV without changing ONNX operations.

python export_context_split.py models/irodori-v4.1-small-mf/context_kv.onnx OUTPUT
Keeps the original model intact. Validates every output bit-for-bit and writes
hashes binding the optional split models to their source model.
"""
from __future__ import annotations

import argparse
import gc
import hashlib
import json
from pathlib import Path
import statistics
import time

import numpy as np
import onnx
import onnxruntime as ort


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def session(path: Path) -> ort.InferenceSession:
    options = ort.SessionOptions()
    options.intra_op_num_threads = 2
    options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_EXTENDED
    return ort.InferenceSession(str(path), sess_options=options,
                                providers=["CPUExecutionProvider"])


def export(source: Path, output: Path) -> dict:
    output.mkdir(parents=True, exist_ok=True)
    model = onnx.load(source)
    inputs = [value.name for value in model.graph.input]
    outputs = [value.name for value in model.graph.output]
    expected = {f"{kind}_{part}_{layer}" for layer in range(12)
                for kind in ("text", "speaker", "caption") for part in ("k", "v")}
    if set(outputs) != expected or set(inputs) != {"text_state", "speaker_state", "caption_state"}:
        raise ValueError("Expected the v4.1 Small MF context KV model")
    paths = {}
    for kind in ("speaker", "text"):
        names = [name for name in outputs if name.startswith("speaker_") == (kind == "speaker")]
        # Retain input declarations: the speaker reshape may read text's batch
        # dimension. Validation below varies text values and token lengths.
        subgraph = onnx.utils.Extractor(model).extract_model(inputs, names)
        onnx.checker.check_model(subgraph)
        path = output / f"context_kv_{kind}.onnx"
        onnx.save(subgraph, path)
        paths[kind] = path
    del subgraph, model
    gc.collect()
    full, speaker, text = session(source), session(paths["speaker"]), session(paths["text"])

    def run(model_session, values):
        return dict(zip((value.name for value in model_session.get_outputs()),
                        model_session.run(None, values)))

    rng = np.random.default_rng(20260926)
    checks = []
    for speaker_length in (2, 27, 54):
        speaker_state = rng.normal(size=(1, speaker_length, 768)).astype(np.float32)
        cached = None
        for tokens in (3, 9, 32):
            values = {
                "text_state": rng.normal(size=(1, tokens, 512)).astype(np.float32),
                "speaker_state": speaker_state,
                "caption_state": rng.normal(size=(1, tokens, 512)).astype(np.float32),
            }
            baseline = run(full, values)
            static = run(speaker, values)
            if cached is not None:
                for name in static:
                    if not np.array_equal(static[name], cached[name]):
                        raise ValueError(f"Speaker KV depends on text: {name}")
            cached = static
            candidate = run(text, values) | cached
            for name in outputs:
                if not np.array_equal(baseline[name], candidate[name]):
                    raise ValueError(f"Split changed {name} for {tokens}/{speaker_length}")
            checks.append({"text_tokens": tokens, "speaker_tokens": speaker_length,
                           "all_72_outputs_identical": True})
    timings = {"full_ms": [], "text_only_ms": []}
    for _ in range(12):
        started = time.perf_counter()
        full.run(None, values)
        timings["full_ms"].append((time.perf_counter() - started) * 1000)
        started = time.perf_counter()
        text.run(None, values)
        timings["text_only_ms"].append((time.perf_counter() - started) * 1000)
    manifest = {"version": 1, "sourceSha256": digest(source),
                "files": {path.name: digest(path) for path in paths.values()}}
    (output / "context_kv_split.json").write_text(json.dumps(manifest, indent=2) + "\n")
    report = {"checks": checks, "median_ms": {name: statistics.median(values[1:])
                                             for name, values in timings.items()},
              "manifest": manifest}
    (output / "validation.json").write_text(json.dumps(report, indent=2) + "\n")
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    print(json.dumps(export(args.source, args.output), indent=2))
