"""Compare FP32 Core ML auxiliary predictions against their original ONNX.

The report is a component-level check, not a claim about end-to-end speech
quality or performance. Run without other conversion/benchmark processes.
"""
import argparse
import hashlib
import json
from pathlib import Path
import statistics
import time

from export_coreml_auxiliary import clean_graph, errors, feeds_for, ct, np, onnx, ort
from make_coreml_only_bundle import fingerprint


def validate(package: Path):
    metadata = json.loads(package.with_suffix(".json").read_text())
    if hashlib.sha256(Path(metadata["source"]).read_bytes()).hexdigest() != metadata["source_sha256"]:
        raise ValueError("ONNX reference changed since export")
    graph = clean_graph(onnx.load(metadata["source"]))
    options = ort.SessionOptions()
    options.intra_op_num_threads = 2
    reference = ort.InferenceSession(graph.SerializeToString(), options,
                                    providers=["CPUExecutionProvider"])
    started = time.perf_counter()
    candidate = ct.models.MLModel(str(package), compute_units=ct.ComputeUnit.CPU_ONLY)
    load_ms = (time.perf_counter() - started) * 1000
    rows = []
    cases = [(3, 2, 13, 24960), (9, 30, 57, 48000), (44, 54, 520, 228480)]
    if metadata["name"] == "speaker_encoder":
        # The original speaker graph truncates to complete four-frame patches.
        cases.extend([(1, 1, 4, 7680), (256, 751, 3000, 1920)])
    elif metadata["name"] == "dacvae_encode_stats":
        cases.append((1, 1, 1, 1920))
    else:
        cases.extend([(1, 1, 13, 1920), (256, 751, 768, 1920)])
    for tokens, speaker, frames, samples in cases:
        for zero_mask in ([False, True] if metadata["name"] == "speaker_encoder" else [False]):
            feeds = feeds_for(graph, tokens=tokens, speaker=speaker, frames=frames, samples=samples)
            if zero_mask:
                feeds["mask"].fill(0)
            core_feeds = {k: v.astype(np.int32) if v.dtype == np.int64 else v
                          for k, v in feeds.items()}
            expected = reference.run(None, feeds)
            actual = candidate.predict(core_feeds)
            comparisons = {name: errors(value, actual[metadata["outputs"][name]])
                for name, value in zip(metadata["outputs"], expected)}
            if any(row["max_abs"] > 1e-3 for row in comparisons.values()):
                raise ValueError(f"Core ML parity failed: {metadata['name']} {comparisons}")
            times = {"onnx_ms": [], "coreml_ms": []}
            for _ in range(5):
                started = time.perf_counter(); reference.run(None, feeds)
                times["onnx_ms"].append((time.perf_counter() - started) * 1000)
                started = time.perf_counter(); candidate.predict(core_feeds)
                times["coreml_ms"].append((time.perf_counter() - started) * 1000)
            row = {"tokens": tokens, "speaker": speaker, "frames": frames,
                   "samples": samples, "zero_mask": zero_mask,
                   "outputs": comparisons,
                   "median_ms": {k: statistics.median(v) for k, v in times.items()}}
            rows.append(row)
            print(metadata["name"], "tokens", tokens, "max_error",
                  max(v["max_abs"] for v in comparisons.values()), row["median_ms"], flush=True)
    report = {"name": metadata["name"], "load_ms": load_ms,
              "source_sha256": metadata["source_sha256"], "package_sha256": fingerprint(package),
              "scope": "component-level FP32 CPU-only parity, dynamic shapes", "checks": rows}
    package.with_suffix(".validation.json").write_text(json.dumps(report, indent=2) + "\n")
    metadata["validated_coreml"] = True
    metadata["validated_package_sha256"] = report["package_sha256"]
    package.with_suffix(".json").write_text(json.dumps(metadata, indent=2) + "\n")
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path)
    validate(parser.parse_args().package)
