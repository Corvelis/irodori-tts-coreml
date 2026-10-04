"""Combine stage-1 decoder variants without rounding or quantizing weights.

The resulting multifunction ML Program requires iOS 18 / macOS 15.
Validate generated speech and speed on the target devices before distribution.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import sys

VARIANTS = (("decoder_stage_1_2d_fixed_w64", "w64"),
            ("decoder_stage_1_2d_fixed_w57", "w57"),
            ("decoder_stage_1_2d_w128", "w128"))
WEIGHTS = "Data/com.apple.CoreML/weights/weight.bin"


def checksum(file):
    digest = hashlib.sha256()
    with file.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def package_bytes(package):
    return sum(p.stat().st_size for p in package.rglob("*") if p.is_file())


def combine(source, destination):
    if destination.exists():
        raise FileExistsError(destination)
    packages = [source / (name + ".mlpackage") for name, _ in VARIANTS]
    digests = [checksum(p / WEIGHTS) for p in packages]
    if len(set(digests)) != 1:
        raise ValueError("Decoder variants must contain identical weight files")
    import coremltools as ct
    descriptor = ct.utils.MultiFunctionDescriptor()
    for package, (_, function) in zip(packages, VARIANTS):
        descriptor.add_function(str(package), src_function_name="main", target_function_name=function)
    descriptor.default_function_name = "w64"
    ct.utils.save_multifunction(descriptor, str(destination))
    # The current exporter preserves the entire binary weight file. Reject
    # unexpected changes instead of describing a changed export as lossless.
    if checksum(destination / WEIGHTS) != digests[0]:
        raise ValueError("Combined weights differ; validate this exporter before use")
    before = sum(package_bytes(p) for p in packages)
    after = package_bytes(destination)
    return {"format": "irodori-shared-decoder-v1", "originalBytes": before,
            "combinedBytes": after, "savedBytes": before - after,
            "weightsSha256": digests[0], "weightBytesUnchanged": True,
            "functions": {name: function for name, function in VARIANTS},
            "minimumOS": {"iOS": "18.0", "macOS": "15.0"}}


def assemble(source, destination):
    """Create runtime artifacts; stage_model.py supplies notices and a manifest."""
    if destination.exists():
        raise FileExistsError(destination)
    sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Scripts"))
    import stage_model
    core = json.loads((source / "coreml-only.json").read_text())
    if core.get("format") != "irodori-coreml-only-v1":
        raise ValueError("Use an original v1 runtime bundle as input")
    rows = stage_model.inventory(source)
    excluded = {name + ".mlpackage" for name, _ in VARIANTS} | {"coreml-only.json"}
    destination.mkdir(parents=True)
    for row in rows:
        relative = row["path"]
        if relative.split("/")[0] in excluded:
            continue
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(stage_model.safe_file(source, relative), target)
    report = combine(source, destination / "decoder_stage_1_multifunction.mlpackage")
    core.update(format="irodori-coreml-only-v2", experimental=True,
                decoder_stage_1_functions={"fixed64": "w64", "fixed57": "w57", "flexible128": "w128"},
                minimum_os=report["minimumOS"])
    core["model_bytes"] = core["model_bytes"] - report["savedBytes"]
    (destination / "coreml-only.json").write_text(json.dumps(core, indent=2) + "\n")
    stage_model.inventory(destination)
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--runtime-bundle", action="store_true",
                        help="Create a complete runtime folder instead of a single package")
    args = parser.parse_args()
    if args.report.exists():
        raise FileExistsError(args.report)
    report = assemble(args.source, args.destination) if args.runtime_bundle else combine(args.source, args.destination)
    args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
