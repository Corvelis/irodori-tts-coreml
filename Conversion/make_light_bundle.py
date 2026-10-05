"""Create the iPhone-compatible INT8 runtime from a validated v1 bundle.

Creates a new directory; never edits the input bundle. Performs encoder
numerical validation. Generated-speech and target-device checks follow this
step; use Scripts/stage_model.py to add distribution notices and a manifest.
"""
import argparse
import json
from pathlib import Path
import shutil
import sys

from share_decoder_weights import assemble
from quantize_text_encoder import quantize
from validate_quantized_text import validate
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Scripts'))
from stage_model import package_checksum, inventory, write_json


def attach_metadata(root, validation):
    if not validation['passed']: raise ValueError('INT8 numerical validation failed')
    original=json.loads((root/'text_encoder.json').read_text())
    meta={key:original[key] for key in ['name','source_sha256','compute_precision','inputs','outputs','source_filename']}
    meta.update(weight_storage='int8-symmetric-block128-float32-compute', validated_coreml=False,
        quantization_validation='text_encoder-int8-validation.json',
        source_validation={'package_sha256':validation['baselinePackageSha256'],
                           'scope':'Original FP32 package validated against Torch; those tolerances do not apply to the INT8 package'})
    write_json(root/'text_encoder.json',meta)
    write_json(root/'text_encoder-int8-validation.json',validation)
    core=json.loads((root/'coreml-only.json').read_text())
    core.pop('experimental',None)
    core['model_variant']='light-int8'
    core['components']['text_encoder']['package_sha256']=package_checksum(root/'text_encoder.mlpackage')
    core['model_bytes']=sum(file.stat().st_size for package in root.glob('*.mlpackage') for file in package.rglob('*') if file.is_file())
    write_json(root/'coreml-only.json',core)
    inventory(root)


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('source',type=Path); p.add_argument('destination',type=Path)
    p.add_argument('--cases',type=Path,default=Path(__file__).resolve().parents[1]/'Benchmarks/quality-cases.json')
    a=p.parse_args()
    shared=assemble(a.source,a.destination,keep_flexible=True)
    original=a.destination/'text_encoder.mlpackage'
    compressed=a.destination/'text_encoder-int8.mlpackage'
    compression=quantize(original,compressed)
    report=validate(a.source/'text_encoder.mlpackage',compressed,a.source/'tokenizer/tokenizer.json',a.cases)
    if not report['passed']: raise SystemExit('Numerical validation failed; no distribution lock was created')
    shutil.rmtree(original)
    compressed.rename(original)
    attach_metadata(a.destination,report)
    print(json.dumps({'decoder':shared,'textEncoder':compression,'validation':report['summary']},indent=2))
