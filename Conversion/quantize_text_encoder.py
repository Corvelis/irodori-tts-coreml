"""Compress text-encoder weight storage to INT8, keeping FP32 computation.

Requires coremltools 9.0 and iOS 18 / macOS 15 for the resulting model.
Numerical and generated-speech validation must follow conversion.
"""
import argparse
import json
from pathlib import Path
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Scripts'))
from stage_model import checksum, package_checksum


def quantize(source, destination):
    if destination.exists(): raise FileExistsError(destination)
    # Avoid importing optional TensorFlow adapters for an ML Program transform.
    sys.modules.setdefault('tensorflow', None)
    import coremltools as ct
    from coremltools.optimize.coreml import OptimizationConfig, OpLinearQuantizerConfig, linear_quantize_weights
    from coremltools.proto import Model_pb2
    if ct.__version__ != '9.0': raise ValueError('Use coremltools 9.0 for this conversion recipe')
    spec = Model_pb2.Model()
    spec.ParseFromString((source / 'Data/com.apple.CoreML/model.mlmodel').read_bytes())
    interface = spec.description.SerializeToString(deterministic=True)
    spec.specificationVersion = 9
    for function in spec.mlProgram.functions.values():
        if len(function.block_specializations) != 1: raise ValueError('Unexpected ML Program specializations')
        old = next(iter(function.block_specializations))
        if old != 'CoreML8':
            function.block_specializations['CoreML8'].CopyFrom(function.block_specializations[old])
            del function.block_specializations[old]
        function.opset = 'CoreML8'
    model = ct.models.MLModel(spec, weights_dir=str(source / 'Data/com.apple.CoreML/weights'), skip_model_load=True)
    config = OptimizationConfig(global_config=OpLinearQuantizerConfig(
        mode='linear_symmetric', dtype='int8', granularity='per_block', block_size=128, weight_threshold=4096))
    start = time.perf_counter()
    compressed = linear_quantize_weights(model, config=config)
    if compressed.get_spec().description.SerializeToString(deterministic=True) != interface:
        raise ValueError('Quantization changed the model interface')
    compressed.save(str(destination))
    return {'format': 'irodori-int8-conversion-v1', 'coremltoolsVersion': ct.__version__,
        'scope': 'text_encoder weights only', 'dtype': 'int8', 'mode': 'linear_symmetric',
        'granularity': 'per_block', 'blockSize': 128, 'weightThreshold': 4096,
        'computePrecision': 'float32', 'activationQuantization': False,
        'sourcePackageSha256': package_checksum(source), 'targetPackageSha256': package_checksum(destination),
        'modelSha256': checksum(destination / 'Data/com.apple.CoreML/model.mlmodel'),
        'weightsSha256': checksum(destination / 'Data/com.apple.CoreML/weights/weight.bin'),
        'sourceBytes': sum(p.stat().st_size for p in source.rglob('*') if p.is_file()),
        'targetBytes': sum(p.stat().st_size for p in destination.rglob('*') if p.is_file()),
        'conversionSeconds': time.perf_counter() - start, 'minimumOS': {'iOS': '18.0', 'macOS': '15.0'}}


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('source', type=Path); p.add_argument('destination', type=Path)
    p.add_argument('--report', required=True, type=Path)
    a = p.parse_args()
    if a.report.exists(): raise FileExistsError(a.report)
    report = quantize(a.source, a.destination)
    a.report.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
