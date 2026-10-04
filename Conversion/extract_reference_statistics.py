"""Extract DACVAE mean/scale for Core ML, retaining sampled reference latents.

Sampling runs in the native host with the deployed ONNX seed=0 sequence.
This is specific to the checked v4.1 Small MF graph; refuse unknown graphs.
"""
import argparse
from pathlib import Path

import onnx


def extract(source: Path, destination: Path):
    if destination.exists():
        raise FileExistsError(destination)
    model = onnx.load(str(source))
    nodes = {node.name: node for node in model.graph.node}
    random = [node for node in nodes.values() if node.op_type == "RandomNormalLike"]
    if len(random) != 1 or list(random[0].input) != ["/Slice_output_0"]:
        raise ValueError("Unexpected DACVAE sampler")
    names = {name for node in nodes.values() for name in node.output}
    if "/Add_1_output_0" not in names:
        raise ValueError("Missing DACVAE scale")
    destination.parent.mkdir(parents=True, exist_ok=True)
    onnx.utils.extract_model(str(source), str(destination), ["waveform"],
                             ["/Slice_output_0", "/Add_1_output_0"])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    extract(args.source, args.destination)
