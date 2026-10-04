"""Convert pinned AudioSeal generator/detector to validated FP32 Core ML models.

Run on Apple Silicon macOS with Conversion/requirements.txt. No existing package
is overwritten. --verify-only validates the packages already in --destination.
The 16 kHz watermark is added to retained 48 kHz audio by the Swift runtime.
"""
from pathlib import Path
import argparse
import hashlib
import json
import sys

sys.modules.setdefault('tensorflow', None)
import numpy as np
import torch
import coremltools as ct
import audioseal
from audioseal import AudioSeal
from audioseal.builder import AudioSealWMConfig, AudioSealDetectorConfig, create_generator, create_detector
from huggingface_hub import hf_hub_download
from scipy.signal import firwin


def checksum(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def fingerprint(package):
    digest = hashlib.sha256()
    for path in sorted(p for p in package.rglob('*') if p.is_file()):
        digest.update(path.relative_to(package).as_posix().encode() + b'\0')
        digest.update(path.read_bytes())
    return digest.hexdigest()


class Generator(torch.nn.Module):
    def __init__(self, model): super().__init__(); self.model = model
    def forward(self, audio, message):
        return self.model.get_watermark(audio, sample_rate=16000, message=message)


class Detector(torch.nn.Module):
    def __init__(self, model): super().__init__(); self.model = model
    def forward(self, audio):
        raw = self.model.detector(audio)
        return torch.softmax(raw[:, :2, :], dim=1)[:, 1:2, :], torch.sigmoid(raw[:, 2:, :].mean(dim=-1))


def convert(destination, cache, verify_only=False):
    lock = json.loads(Path(__file__).with_name('audioseal.sources.json').read_text())
    if audioseal.__version__ != lock['implementation']['version']:
        raise ValueError('Install the pinned AudioSeal implementation first')
    names = ['audioseal_generator', 'audioseal_detector']
    if not verify_only and any((destination / (name + '.mlpackage')).exists() for name in names):
        raise FileExistsError('AudioSeal output already exists')
    destination.mkdir(parents=True, exist_ok=True)
    torch.set_num_threads(4)
    sources, packages, checks = [], {}, {}
    rng = np.random.default_rng(104)
    for kind, item in zip(['generator', 'detector'], lock['files']):
        path = Path(hf_hub_download(lock['repository'], item['filename'], revision=lock['revision'], cache_dir=str(cache)))
        if checksum(path) != item['sha256']: raise ValueError('Source checksum mismatch: ' + item['filename'])
        # Official, hash-verified checkpoints include OmegaConf configuration.
        checkpoint = torch.load(path, map_location='cpu', weights_only=False)
        config_type = AudioSealWMConfig if kind == 'generator' else AudioSealDetectorConfig
        config = AudioSeal.parse_config(checkpoint['xp.cfg'], config_type=config_type, nbits=16)
        model = (create_generator if kind == 'generator' else create_detector)(config).eval()
        model.load_state_dict(checkpoint['model'])
        for module in model.modules():
            try: torch.nn.utils.remove_weight_norm(module)
            except ValueError: pass
        wrapper = (Generator if kind == 'generator' else Detector)(model).eval()
        x = rng.normal(0, .1, (1, 1, 32000)).astype(np.float32)
        message = np.array([[(0x4952 >> i) & 1 for i in range(16)]], dtype=np.int32)
        example = (torch.from_numpy(x),) + ((torch.from_numpy(message),) if kind == 'generator' else ())
        package = destination / ('audioseal_' + kind + '.mlpackage')
        output_names = ['watermark'] if kind == 'generator' else ['probability', 'message_probability']
        if not verify_only:
            traced = torch.jit.trace(wrapper, example, check_trace=False)
            inputs = [ct.TensorType(name='audio', shape=x.shape, dtype=np.float32)]
            if kind == 'generator': inputs.append(ct.TensorType(name='message', shape=(1, 16), dtype=np.int32))
            ml = ct.convert(traced, inputs=inputs,
                outputs=[ct.TensorType(name=n, dtype=np.float32) for n in output_names],
                minimum_deployment_target=ct.target.iOS17, compute_precision=ct.precision.FLOAT32)
            ml.author = 'Meta Platforms, Inc. and affiliates; Core ML conversion by Corvelis'
            ml.license = 'MIT'
            ml.save(str(package))
        ml = ct.models.MLModel(str(package), compute_units=ct.ComputeUnit.CPU_AND_GPU)
        errors = {name: 0.0 for name in output_names}
        for level in [0, .02, .2]:
            audio = rng.normal(0, level, x.shape).astype(np.float32)
            feed = {'audio': audio}
            args = (torch.from_numpy(audio),)
            if kind == 'generator': feed['message'] = message; args += (torch.from_numpy(message),)
            with torch.inference_mode(): reference = wrapper(*args)
            result = ml.predict(feed)
            references = reference if isinstance(reference, tuple) else (reference,)
            for name, tensor in zip(output_names, references):
                actual = result[name]
                if actual.shape != tensor.shape or not np.isfinite(actual).all(): raise ValueError('Invalid Core ML output')
                error = float(np.max(np.abs(actual - tensor.numpy())))
                errors[name] = max(errors[name], error)
                if error > 1e-4: raise ValueError('AudioSeal numerical parity failed: ' + name)
        checks[kind] = errors
        packages['audioseal_' + kind] = fingerprint(package)
        sources.append({'repository': lock['repository'], 'revision': lock['revision'], **item})
    metadata = {'format': 'irodori-audioseal-v1', 'sampleRate': 16000, 'windowSamples': 32000,
        'hopSamples': 16000, 'contextSamples': 8000, 'originalSampleRate': 48000,
        'identifier': 0x4952, 'precision': 'float32', 'validatedCoreML': True,
        'packages': packages, 'validationMaxAbsoluteError': checks, 'sources': sources,
        'fir': firwin(129, 1 / 3, window=('kaiser', 8.6)).astype(np.float32).tolist()}
    (destination / 'audioseal.json').write_text(json.dumps(metadata, indent=2) + '\n')
    print(json.dumps({'packages': packages, 'validation': checks}, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--destination', type=Path, required=True)
    parser.add_argument('--cache-dir', type=Path, default=Path('artifacts/audioseal-sources'))
    parser.add_argument('--verify-only', action='store_true')
    args = parser.parse_args()
    convert(args.destination, args.cache_dir, args.verify_only)
