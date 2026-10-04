"""Create a model distribution bundle from reviewed, unmodified artifacts.

No upload command is provided. A manifest is integrity metadata, not a grant of
redistribution rights. License evidence is in docs/LICENSE_REVIEW.md; remaining
release checks are in docs/RELEASE.md.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import tempfile

REPOSITORY = Path(__file__).resolve().parents[1]
AUXILIARY = ('text_encoder', 'speaker_encoder', 'duration', 'context_kv_text',
             'context_kv_speaker', 'decoder_stage_0', 'dacvae_encode_stats')
OTHERS = ('dit_step_cached_mixed_linear_768', 'decoder_stage_1_2d_fixed_w64',
          'decoder_stage_1_2d_fixed_w57', 'decoder_stage_1_2d_w128',
          'decoder_stage_2_2d_fixed_w256', 'decoder_stage_3_2d_w511')
PACKAGE_FILES = ('Manifest.json', 'Data/com.apple.CoreML/model.mlmodel',
                 'Data/com.apple.CoreML/weights/weight.bin')
RUNTIME_FILES = tuple(sorted(['config.json', 'coreml-only.json', 'tokenizer/tokenizer.json',
                             'tokenizer/tokenizer_config.json'] +
    [name + '.json' for name in AUXILIARY] +
    [name + '.mlpackage/' + file for name in AUXILIARY + OTHERS for file in PACKAGE_FILES]))


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


def inventory(source):
    rows = [entry(source, name) for name in RUNTIME_FILES]
    # Check the original auxiliary numerical validation applies to these exact packages.
    core = json.loads((source / 'coreml-only.json').read_text())
    if core.get('format') != 'irodori-coreml-only-v1': raise ValueError('Wrong runtime bundle format')
    for name in AUXILIARY:
        meta = json.loads((source / (name + '.json')).read_text())
        digest = hashlib.sha256()
        for file in sorted(PACKAGE_FILES):
            digest.update(file.encode() + b'\0')
            with safe_file(source, name + '.mlpackage/' + file).open('rb') as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b''): digest.update(chunk)
        if (meta.get('compute_precision') != 'float32' or meta.get('validated_coreml') is not True or
            meta.get('validated_package_sha256') != digest.hexdigest() or
            core.get('components', {}).get(name, {}).get('package_sha256') != digest.hexdigest()):
            raise ValueError(f'Unvalidated auxiliary package: {name}')
    return rows


def write_json(file, value):
    file.write_text(json.dumps(value, indent=2, ensure_ascii=False) + '\n')


def stage(source, destination, lock_path, repository=REPOSITORY):
    if destination.exists(): raise FileExistsError(destination)
    lock = json.loads(lock_path.read_text())
    rows = inventory(source)
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
        shutil.copy2(repository / 'Distribution/HuggingFace/README.md', staging / 'README.md')
        shutil.copy2(repository / 'docs/RELEASE.md', staging / 'RELEASE_STATUS.md')
        shutil.copy2(repository / 'docs/VALIDATION.md', staging / 'VALIDATION.md')
        shutil.copy2(repository / 'docs/LICENSE_REVIEW.md', staging / 'LICENSE_REVIEW.md')
        shutil.copy2(repository / 'Distribution/license-review.json', staging / 'license-review.json')
        provenance = json.loads((repository / 'Distribution/provenance.json').read_text())
        provenance['bundleVersion'] = lock['bundleVersion']
        provenance['reviewedArtifactsLockSha256'] = checksum(lock_path)
        write_json(staging / 'provenance.json', provenance)
        paths = sorted(p.relative_to(staging).as_posix() for p in staging.rglob('*') if p.is_file())
        manifest = {'format': 'irodori-coreml-distribution-v1', 'bundleVersion': lock['bundleVersion'],
                    'releaseStatus': provenance['releaseStatus'],
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
    if manifest.get('format') != 'irodori-coreml-distribution-v1': raise ValueError('Wrong manifest format')
    paths = [x['path'] for x in rows]
    if len(set(paths)) != len(paths) or not set(RUNTIME_FILES).issubset(paths): raise ValueError('Incomplete manifest')
    for item in rows:
        if entry(root, item['path']) != item: raise ValueError(f"Checksum mismatch: {item['path']}")
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
        print(f"Staged {len(manifest['files'])} files, {manifest['totalFileBytes']} bytes; public release is pending.")
    else:
        manifest = verify(args.directory); print(f"Verified {len(manifest['files'])} files.")


if __name__ == '__main__': main()
