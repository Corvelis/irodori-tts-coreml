"""Assemble an intermediate fast-only Core ML bundle for local validation.

This is not a release packager. Scripts/stage_model.py adds distribution metadata
and full-file hashes after native audio validation. Public release also needs
the remaining checks described in docs/RELEASE.md; license evidence is recorded
in docs/LICENSE_REVIEW.md.

Only allowlisted models/tokenizer assets are copied, excluding ONNX, standard
DiT, user reference audio, feature caches and benchmark artifacts.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

AUXILIARY = ("text_encoder", "speaker_encoder", "duration", "context_kv_text",
             "context_kv_speaker", "decoder_stage_0", "dacvae_encode_stats")
EXISTING = ("config.json", "tokenizer", "dit_step_cached_mixed_linear_768.mlpackage",
            "decoder_stage_1_2d_fixed_w64.mlpackage", "decoder_stage_1_2d_fixed_w57.mlpackage",
            "decoder_stage_1_2d_w128.mlpackage", "decoder_stage_2_2d_fixed_w256.mlpackage",
            "decoder_stage_3_2d_w511.mlpackage")


def fingerprint(package):
    digest = hashlib.sha256()
    for file in sorted(p for p in package.rglob("*") if p.is_file()):
        digest.update(file.relative_to(package).as_posix().encode() + b"\0")
        with file.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
    return digest.hexdigest()


def assemble(existing, auxiliary, destination, reference_encoder=None, link=False):
    if destination.exists():
        raise FileExistsError(destination)
    sources = []
    validation = {}
    for name in AUXILIARY:
        root = reference_encoder if name == "dacvae_encode_stats" and reference_encoder else auxiliary
        package = root / (name + ".mlpackage")
        metadata = json.loads(package.with_suffix(".json").read_text())
        report = json.loads(package.with_suffix(".validation.json").read_text())
        if metadata.get("compute_precision") != "float32" or not report.get("checks"):
            raise ValueError(f"Unvalidated component: {name}")
        for check in report["checks"]:
            if any(result["max_abs"] > 1e-3 for result in check["outputs"].values()):
                raise ValueError(f"Component parity failed: {name}")
        package_hash = fingerprint(package)
        if report.get("package_sha256") != package_hash:
            raise ValueError(f"Validate this exact package before bundling: {name}")
        validation[name] = {"source_sha256": metadata["source_sha256"],
                            "package_sha256": package_hash}
        sources.extend((package, package.with_suffix(".json")))
    sources.extend(existing / name for name in EXISTING)
    for source in sources:
        if not source.exists():
            raise FileNotFoundError(source)
    destination.mkdir(parents=True)
    for source in sources:
        target = destination / source.name
        if link:
            target.symlink_to(source.resolve(), target_is_directory=source.is_dir())
        elif source.is_dir():
            shutil.copytree(source, target)
        elif source.stem in AUXILIARY and source.suffix == ".json":
            # Runtime needs names/types, not a converter's private filesystem path.
            metadata = json.loads(source.read_text())
            metadata["source_filename"] = Path(metadata.pop("source")).name
            target.write_text(json.dumps(metadata, indent=2) + "\n")
        else:
            shutil.copy2(source, target)
    total = sum(p.stat().st_size for source in destination.iterdir()
                for p in ([source] if source.is_file() else source.rglob("*")) if p.is_file())
    manifest = {"format": "irodori-coreml-only-v1", "experimental": True,
                "release_gate": "pending device performance and listening comparison",
                "model_bytes": total, "components": validation,
                "reference_sampling": "Apple libc++ default_random_engine seed=0, normal<float>",
                "contains_onnx": False, "contains_standard_dit": False}
    (destination / "coreml-only.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps({"path": str(destination), "model_bytes": total}, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("existing", type=Path)
    parser.add_argument("auxiliary", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--reference-encoder", type=Path)
    parser.add_argument("--link", action="store_true", help="Local testing only; use copies for distribution")
    args = parser.parse_args()
    assemble(args.existing, args.auxiliary, args.destination, args.reference_encoder, args.link)
