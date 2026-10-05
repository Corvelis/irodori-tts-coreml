"""Compare quantized text features against an exact validated FP32 package.

This measures encoder numerical error, not a perceptual audio degradation rate.
The report binds the results to both packages and the test corpus by SHA-256.
"""
import argparse
import json
from pathlib import Path
import sys
import unicodedata

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Scripts'))
from stage_model import checksum, package_checksum


def validate(baseline, candidate, tokenizer, cases):
    sys.modules.setdefault('tensorflow', None)
    import coremltools as ct
    import numpy as np
    from tokenizers import Tokenizer
    source_meta = json.loads((baseline.parent / 'text_encoder.json').read_text())
    baseline_sha = package_checksum(baseline)
    if source_meta.get('validated_coreml') is not True or source_meta.get('validated_package_sha256') != baseline_sha:
        raise ValueError('The baseline must be the exact validated FP32 text package')
    tok = Tokenizer.from_file(str(tokenizer))
    corpus = json.loads(cases.read_text())
    texts = list(dict.fromkeys([row['text'] for row in corpus] + [row['caption'] for row in corpus if row.get('caption')]))
    if len(texts) < 24: raise ValueError('Use at least 24 distinct natural text/caption inputs')
    features = []
    for index, text in enumerate(texts):
        ids = np.array([[1] + tok.encode(unicodedata.normalize('NFKC', text), add_special_tokens=False).ids], dtype=np.int32)
        if ids.shape[1] > 256: raise ValueError('Test text exceeds 256 tokens')
        features.append((f'text-{index}', {'input_ids': ids, 'mask': np.ones(ids.shape, dtype=np.float32)}))
    # Maximum sequence and masked padding stress the variable-length interface.
    features.append(('max-length-random', {'input_ids': np.random.default_rng(11).integers(0,102400,size=(1,256),dtype=np.int32), 'mask': np.ones((1,256),dtype=np.float32)}))
    f = features[0][1]; n = 256 - f['input_ids'].shape[1]
    features.append(('masked-padding', {key: np.pad(value, ((0,0),(0,n))) for key,value in f.items()}))
    models = [ct.models.MLModel(str(path), compute_units=ct.ComputeUnit.CPU_ONLY) for path in [baseline,candidate]]
    rows = []
    for name, inputs in features:
        outputs = [model.predict(inputs) for model in models]
        if outputs[0].keys() != outputs[1].keys(): raise ValueError('Output names differ')
        for key, reference in outputs[0].items():
            x, y = reference.astype(np.float64), outputs[1][key].astype(np.float64)
            if x.shape != y.shape or not np.isfinite(x).all() or not np.isfinite(y).all(): raise ValueError('Invalid numerical output')
            energy = float(np.sum(x*x)); error_energy = float(np.sum((x-y)**2))
            ratio = error_energy / max(energy, 1e-30)
            rows.append({'case': name, 'output': key, 'shape': list(x.shape),
                'relativeL2Percent': 100 * float(np.sqrt(ratio)), 'maxAbs': float(np.max(np.abs(x-y))),
                'snrDb': float(-10*np.log10(max(ratio,1e-30))),
                'cosine': float(np.sum(x*y)/max(np.linalg.norm(x)*np.linalg.norm(y),1e-30))})
    summary = {'naturalInputCount':len(texts), 'inputCount':len(features), 'outputCount':len(rows),
        'maxRelativeL2Percent':max(row['relativeL2Percent'] for row in rows),
        'maxAbs':max(row['maxAbs'] for row in rows), 'minSnrDb':min(row['snrDb'] for row in rows),
        'minCosine':min(row['cosine'] for row in rows)}
    limits = {'maxRelativeL2Percent':3.0, 'minSnrDb':30.0, 'minCosine':0.9995, 'minimumNaturalInputs':24}
    passed = summary['maxRelativeL2Percent'] <= 3 and summary['minSnrDb'] >= 30 and summary['minCosine'] >= .9995
    return {'format':'irodori-quantized-text-validation-v1', 'computeUnits':'CPU_ONLY',
        'baselinePackageSha256':baseline_sha, 'candidatePackageSha256':package_checksum(candidate),
        'sourceOnnxSha256':source_meta['source_sha256'], 'corpusSha256':checksum(cases), 'tokenizerSha256':checksum(tokenizer),
        'coremltoolsVersion':ct.__version__, 'scope':'FP32 Core ML versus INT8 weight storage; not ONNX/Torch equality or perceptual audio quality',
        'acceptanceLimits':limits, 'passed':passed, 'summary':summary, 'outputs':rows}


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    for name in ['baseline','candidate','tokenizer','cases']: p.add_argument('--'+name, required=True, type=Path)
    p.add_argument('--report', required=True, type=Path)
    a = p.parse_args()
    if a.report.exists(): raise FileExistsError(a.report)
    report = validate(a.baseline,a.candidate,a.tokenizer,a.cases)
    a.report.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report['summary'], indent=2))
    if not report['passed']: raise SystemExit('Encoder numerical acceptance criteria failed')
