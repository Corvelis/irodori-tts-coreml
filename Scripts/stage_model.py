"""Create a model distribution bundle from reviewed, unmodified artifacts.

No upload command is provided. A manifest is integrity metadata, not a grant of
redistribution rights. Component licenses and use conditions are described in
docs/LICENSE_REVIEW.md.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import tempfile
import re

REPOSITORY = Path(__file__).resolve().parents[1]
AUXILIARY = ('text_encoder', 'speaker_encoder', 'duration', 'context_kv_text',
             'context_kv_speaker', 'decoder_stage_0', 'dacvae_encode_stats')
OTHERS = ('dit_step_cached_mixed_linear_768', 'decoder_stage_1_2d_fixed_w64',
          'decoder_stage_1_2d_fixed_w57', 'decoder_stage_1_2d_w128',
          'decoder_stage_2_2d_fixed_w256', 'decoder_stage_3_2d_w511')
PACKAGE_FILES = ('Manifest.json', 'Data/com.apple.CoreML/model.mlmodel',
                 'Data/com.apple.CoreML/weights/weight.bin')
RUNTIME_FILES = tuple(sorted(['config.json', 'coreml-only.json', 'tokenizer/tokenizer.json',
                             'tokenizer/tokenizer_config.json', 'audioseal.json'] +
    [name + '.json' for name in AUXILIARY] +
    [name + '.mlpackage/' + file for name in AUXILIARY + OTHERS + ('audioseal_generator', 'audioseal_detector') for file in PACKAGE_FILES]))
SHARED_RUNTIME_FILES = tuple(sorted(
    [name for name in RUNTIME_FILES if not any(name.startswith(old + '.mlpackage/')
      for old in OTHERS if old.startswith('decoder_stage_1_'))] +
    ['decoder_stage_1_multifunction.mlpackage/' + file for file in PACKAGE_FILES]))


def runtime_files(format, flexible_stage1_package=None):
    if flexible_stage1_package is not None:
        if format not in ('irodori-coreml-only-v2', 'irodori-coreml-distribution-v2') or flexible_stage1_package != 'decoder_stage_1_2d_w128.mlpackage':
            raise ValueError('Wrong standalone flexible decoder package')
        return tuple(sorted(SHARED_RUNTIME_FILES + tuple(flexible_stage1_package + '/' + file for file in PACKAGE_FILES)))
    if format in ('irodori-coreml-only-v1', 'irodori-coreml-distribution-v1'): return RUNTIME_FILES
    if format in ('irodori-coreml-only-v2', 'irodori-coreml-distribution-v2'): return SHARED_RUNTIME_FILES
    raise ValueError('Wrong runtime bundle format')


def safe_file(root, relative):
    parts = relative.split('/')
    if not relative or any(x in ('', '.', '..') for x in parts) or '\\' in relative or ':' in relative:
        raise ValueError(f'Unsafe path: {relative}')
    current = root
    for part in parts:
        current = current / part
        if current.is_symlink(): raise ValueError(f'Symlinks are not distribution files: {relative}')
    if not current.is_file(): raise FileNotFoundError(relative)
    return current


def checksum(file):
    sha = hashlib.sha256()
    with file.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''): sha.update(chunk)
    return sha.hexdigest()


def entry(root, path):
    file = safe_file(root, path)
    if file.stat().st_size <= 0: raise ValueError(f'Empty file: {path}')
    return {'path': path, 'bytes': file.stat().st_size, 'sha256': checksum(file)}


def package_checksum(package):
    digest = hashlib.sha256()
    for relative in sorted(PACKAGE_FILES):
        digest.update(relative.encode() + b'\0')
        with safe_file(package, relative).open('rb') as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b''): digest.update(chunk)
    return digest.hexdigest()


def quantized_evidence(source, meta, digest):
    if meta.get('quantization_validation') != 'text_encoder-int8-validation.json':
        raise ValueError('Quantized text encoder needs its own numerical validation report')
    report = json.loads(safe_file(source, meta['quantization_validation']).read_text())
    rows = report.get('outputs', [])
    unique_cases = {row.get('case') for row in rows}
    if (report.get('format') != 'irodori-quantized-text-validation-v1' or
        report.get('candidatePackageSha256') != digest or report.get('passed') is not True or
        report.get('sourceOnnxSha256') != meta.get('source_sha256') or
        report.get('tokenizerSha256') != checksum(safe_file(source, 'tokenizer/tokenizer.json')) or
        report.get('summary', {}).get('naturalInputCount', 0) < 24 or len(rows) < 52 or len(unique_cases) < 26 or
        report.get('baselinePackageSha256') != meta.get('source_validation', {}).get('package_sha256')):
        raise ValueError('Invalid or mismatched INT8 numerical evidence')
    import math
    for row in rows:
        if not all(isinstance(row.get(k), (int,float)) and math.isfinite(row[k]) for k in ['relativeL2Percent','snrDb','cosine']):
            raise ValueError('Non-finite INT8 validation metrics')
        if row['relativeL2Percent'] > 3 or row['snrDb'] < 30 or row['cosine'] < .9995:
            raise ValueError('INT8 encoder numerical acceptance criteria failed')
    return entry(source, meta['quantization_validation'])


def inventory(source):
    # Check the original auxiliary numerical validation applies to these exact packages.
    core = json.loads((source / 'coreml-only.json').read_text())
    rows = [entry(source, name) for name in runtime_files(core.get('format'), core.get('flexible_decoder_stage_1_package'))]
    if core.get('format') == 'irodori-coreml-only-v2' and core.get('decoder_stage_1_functions') != {
        'fixed64':'w64', 'fixed57':'w57', 'flexible128':'w128'}:
        raise ValueError('Wrong shared decoder functions')
    for name in AUXILIARY:
        meta = json.loads((source / (name + '.json')).read_text())
        digest = hashlib.sha256()
        for file in sorted(PACKAGE_FILES):
            digest.update(file.encode() + b'\0')
            with safe_file(source, name + '.mlpackage/' + file).open('rb') as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b''): digest.update(chunk)
        quantized = name == 'text_encoder' and meta.get('weight_storage') == 'int8-symmetric-block128-float32-compute'
        validated = meta.get('validated_coreml') is True and meta.get('validated_package_sha256') == digest.hexdigest()
        if quantized:
            if core.get('format') != 'irodori-coreml-only-v2': raise ValueError('INT8 requires the v2 runtime')
            rows.append(quantized_evidence(source, meta, digest.hexdigest()))
            validated = True
        if (meta.get('compute_precision') != 'float32' or not validated or
            core.get('components', {}).get(name, {}).get('package_sha256') != digest.hexdigest()):
            raise ValueError(f'Unvalidated auxiliary package: {name}')
    watermark = json.loads(safe_file(source, 'audioseal.json').read_text())
    if (watermark.get('format') != 'irodori-audioseal-v1' or watermark.get('precision') != 'float32'
        or watermark.get('validatedCoreML') is not True):
        raise ValueError('Unvalidated AudioSeal metadata')
    for name in ('audioseal_generator', 'audioseal_detector'):
        digest = hashlib.sha256()
        for file in sorted(PACKAGE_FILES):
            digest.update(file.encode() + b'\0')
            with safe_file(source, name + '.mlpackage/' + file).open('rb') as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b''): digest.update(chunk)
        if watermark.get('packages', {}).get(name) != digest.hexdigest():
            raise ValueError(f'Unvalidated AudioSeal package: {name}')
    return sorted(rows, key=lambda row: row['path'])


def write_json(file, value):
    file.write_text(json.dumps(value, indent=2, ensure_ascii=False) + '\n')


def copy_document(source, destination, repository):
    """Keep links useful when a docs file is placed at the model bundle root."""
    bundled = {'QUALITY.md','QUALITY.en.md','VALIDATION.md','LICENSE_REVIEW.md',
               'NOTICE','THIRD_PARTY_NOTICES.md','LICENSES'}
    def link(match):
        target = match.group(2)
        if target.startswith(('http:', 'https:', '#', 'mailto:')): return match.group(0)
        path, separator, anchor = target.partition('#')
        if not path or (not path.startswith('../') and path.split('/')[0] in bundled): return match.group(0)
        original = (source.parent / path).resolve()
        try: relative = original.relative_to(repository.resolve()).as_posix()
        except ValueError: return match.group(0)
        kind = 'tree' if original.is_dir() else 'blob'
        url = f'https://github.com/Corvelis/irodori-tts-coreml/{kind}/v0.2.0/{relative}'
        if separator: url += '#' + anchor
        return f'[{match.group(1)}]({url})'
    text = re.sub(r'\[([^\]]+)\]\(([^)]+)\)', link, source.read_text())
    destination.write_text(text)


def stage(source, destination, lock_path, repository=REPOSITORY):
    if destination.exists(): raise FileExistsError(destination)
    lock = json.loads(lock_path.read_text())
    rows = inventory(source)
    core_format = json.loads((source / 'coreml-only.json').read_text())['format']
    shared = core_format == 'irodori-coreml-only-v2'
    if lock.get('format') != 'irodori-reviewed-artifacts-v1' or lock.get('files') != rows:
        raise ValueError('Artifacts differ from the reviewed lock. Validate new artifacts before replacing the lock.')
    destination.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix='.irodori-model-', dir=destination.parent))
    try:
        for item in rows:
            target = staging / item['path']; target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(safe_file(source, item['path']), target)
        for name in ['NOTICE', 'THIRD_PARTY_NOTICES.md']:
            shutil.copy2(repository / name, staging / name)
        shutil.copytree(repository / 'LICENSES', staging / 'LICENSES')
        quantized = json.loads((source / 'text_encoder.json').read_text()).get('weight_storage', '').startswith('int8-')
        model_card = repository / ('Distribution/HuggingFace/README-int8.md' if quantized else 'Distribution/HuggingFace/README-shared.md' if shared else 'Distribution/HuggingFace/README.md')
        shutil.copy2(model_card, staging / 'README.md')
        shutil.copy2(model_card if shared else repository / 'docs/RELEASE.md', staging / 'MODEL_BUNDLE.md')
        copy_document(repository / 'docs/VALIDATION.md', staging / 'VALIDATION.md', repository)
        if quantized:
            for name in ['QUALITY.md','QUALITY.en.md']:
                copy_document(repository / 'docs' / name, staging / name, repository)
        shutil.copy2(repository / 'docs/LICENSE_REVIEW.md', staging / 'LICENSE_REVIEW.md')
        shutil.copy2(repository / 'Distribution/license-review.json', staging / 'license-review.json')
        provenance = json.loads((repository / 'Distribution/provenance.json').read_text())
        provenance['bundleVersion'] = lock['bundleVersion']
        provenance['reviewedArtifactsLockSha256'] = checksum(lock_path)
        if shared:
            provenance['runtimeVersion'] = '0.2.0'
            provenance['minimumOS'] = {'iOS': '18.0', 'macOS': '15.0'}
            provenance['modelLayout'] = 'irodori-coreml-distribution-v2'
            provenance['conversionRecipe'] = 'Conversion/convert_all.py followed by Conversion/share_decoder_weights.py'
            # An artifact candidate need not have a published Git tag.
            provenance['distribution'].pop('codeTag', None)
        if quantized:
            provenance['modelVariant'] = 'light-int8'
            provenance['precision']['textEncoder'] = {'weightStorage':'INT8 symmetric per-block128', 'compute':'FP32', 'activationQuantization':False}
            provenance['precision']['auxiliary'] = 'FP32 computation; text encoder has INT8 weight storage'
            provenance['conversionRecipe'] = 'Conversion/convert_all.py; Conversion/share_decoder_weights.py (separate flexible decoder); Conversion/quantize_text_encoder.py; Conversion/validate_quantized_text.py'
            provenance['quantizationValidation'] = 'text_encoder-int8-validation.json'
        write_json(staging / 'provenance.json', provenance)
        paths = sorted(p.relative_to(staging).as_posix() for p in staging.rglob('*') if p.is_file())
        manifest = {'format': core_format.replace('coreml-only', 'coreml-distribution'), 'bundleVersion': lock['bundleVersion'],
                    'files': [entry(staging, path) for path in paths]}
        # Verify copied inference files before the directory becomes visible.
        actual = {item['path']: item for item in manifest['files']}
        if any(actual[item['path']] != item for item in rows): raise ValueError('Copy changed an artifact')
        manifest['totalFileBytes'] = sum(item['bytes'] for item in manifest['files'])
        write_json(staging / 'manifest.json', manifest)
        staging.rename(destination)
        return manifest
    except BaseException:
        shutil.rmtree(staging)
        raise


def verify(root):
    manifest = json.loads(safe_file(root, 'manifest.json').read_text())
    rows = manifest['files']
    if manifest.get('format') not in ('irodori-coreml-distribution-v1', 'irodori-coreml-distribution-v2'):
        raise ValueError('Wrong manifest format')
    paths = [x['path'] for x in rows]
    core = json.loads(safe_file(root, 'coreml-only.json').read_text())
    if len(set(paths)) != len(paths) or not set(runtime_files(manifest['format'], core.get('flexible_decoder_stage_1_package'))).issubset(paths): raise ValueError('Incomplete manifest')
    core_format = core['format']
    if core_format.replace('coreml-only', 'coreml-distribution') != manifest['format']:
        raise ValueError('Model layout and manifest format differ')
    for item in rows:
        if entry(root, item['path']) != item: raise ValueError(f"Checksum mismatch: {item['path']}")
    expected = {row['path'] for row in inventory(root)}
    if not expected.issubset(paths): raise ValueError('Manifest does not cover validation evidence')
    actual = {p.relative_to(root).as_posix() for p in root.rglob('*') if p.is_file() or p.is_symlink()}
    if actual != set(paths) | {'manifest.json'}: raise ValueError('Unlisted files in distribution')
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    lock = commands.add_parser('lock', help='Record a candidate inventory; this is not a release approval')
    lock.add_argument('--source', type=Path, required=True)
    lock.add_argument('--output', type=Path, required=True)
    lock.add_argument('--version', default='0.1.0')
    pack = commands.add_parser('stage')
    pack.add_argument('--source', type=Path, required=True)
    pack.add_argument('--destination', type=Path, required=True)
    pack.add_argument('--lock', type=Path, default=REPOSITORY / 'Distribution/artifacts.lock.json')
    check = commands.add_parser('verify'); check.add_argument('directory', type=Path)
    args = parser.parse_args()
    if args.command == 'lock':
        if args.output.exists(): raise FileExistsError(args.output)
        write_json(args.output, {'format': 'irodori-reviewed-artifacts-v1', 'bundleVersion': args.version,
                                 'files': inventory(args.source)})
        print('Candidate inventory written; validate performance/audio before distribution.')
    elif args.command == 'stage':
        manifest = stage(args.source, args.destination, args.lock)
        print(f"Staged {len(manifest['files'])} files, {manifest['totalFileBytes']} bytes.")
    else:
        manifest = verify(args.directory); print(f"Verified {len(manifest['files'])} files.")


if __name__ == '__main__': main()
