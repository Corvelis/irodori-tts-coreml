"""Prepare a local Hub update: preserve standard files, add int8/, update the card.

The output is an overlay, not a standalone standard model bundle. Apply all its
files in one commit without deleting existing root files. No upload is performed.
"""
import argparse
import copy
import json
from pathlib import Path
import shutil
import tempfile

import stage_model as models

BASELINE_MANIFEST_SHA256 = 'f98e77d857c20e977358ec9c9d513721b37e1af0d7e12359c05de26c90ae7186'
REPOSITORY = Path(__file__).resolve().parents[1]


def checked_sources(standard, light):
    if models.checksum(models.safe_file(standard, 'manifest.json')) != BASELINE_MANIFEST_SHA256:
        raise ValueError('Standard bundle differs from the original published manifest')
    baseline = models.verify(standard)
    candidate = models.verify(light)
    metadata = json.loads(models.safe_file(light, 'text_encoder.json').read_text())
    if baseline['format'] != 'irodori-coreml-distribution-v1':
        raise ValueError('The root must contain the original standard model')
    if (candidate['format'] != 'irodori-coreml-distribution-v2' or
            candidate['bundleVersion'] != '0.2.0-int8' or
            metadata.get('weight_storage') != 'int8-symmetric-block128-float32-compute'):
        raise ValueError('The int8 directory must contain the validated light model')
    if any(row['path'].split('/')[0] == 'int8' for row in baseline['files']):
        raise ValueError('The standard manifest must not include the other variant')
    return baseline, candidate


def root_manifest(baseline, overlay):
    manifest = copy.deepcopy(baseline)
    replaced = False
    for index, row in enumerate(manifest['files']):
        if row['path'] == 'README.md':
            manifest['files'][index] = models.entry(overlay, 'README.md')
            replaced = True
    if not replaced:
        raise ValueError('The standard manifest must cover its model card')
    manifest['totalFileBytes'] = sum(row['bytes'] for row in manifest['files'])
    return manifest


def verify(overlay, standard):
    """Check an overlay against the exact published standard and nested model."""
    baseline, candidate = checked_sources(standard, overlay / 'int8')
    updated = json.loads(models.safe_file(overlay, 'manifest.json').read_text())
    if updated != root_manifest(baseline, overlay):
        raise ValueError('Root manifest does not match the updated card and original files')
    expected = {'README.md', 'manifest.json', 'int8/manifest.json'} | {
        'int8/' + row['path'] for row in candidate['files']}
    actual = {p.relative_to(overlay).as_posix() for p in overlay.rglob('*')
              if p.is_file() or p.is_symlink()}
    if actual != expected:
        raise ValueError('Unexpected or missing files in the Hub update')
    if updated['bundleVersion'] != baseline['bundleVersion']:
        raise ValueError('Changing documentation must not change the standard model version')
    return updated, candidate


def stage(standard, light, destination, repository=REPOSITORY):
    if destination.exists():
        raise FileExistsError(destination)
    baseline, candidate = checked_sources(standard, light)
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix='.irodori-hub-', dir=destination.parent))
    try:
        shutil.copy2(repository / 'Distribution/HuggingFace/README-repository.md', temporary / 'README.md')
        nested = temporary / 'int8'
        for relative in ['manifest.json'] + [row['path'] for row in candidate['files']]:
            target = nested / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(models.safe_file(light, relative), target)
        models.write_json(temporary / 'manifest.json', root_manifest(baseline, temporary))
        updated, candidate = verify(temporary, standard)
        temporary.rename(destination)
        return updated, candidate
    except BaseException:
        shutil.rmtree(temporary)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest='command', required=True)
    prepare = subcommands.add_parser('stage')
    prepare.add_argument('--standard', type=Path, required=True)
    prepare.add_argument('--int8', type=Path, required=True)
    prepare.add_argument('--destination', type=Path, required=True)
    check = subcommands.add_parser('verify')
    check.add_argument('directory', type=Path)
    check.add_argument('--standard', type=Path, required=True)
    args = parser.parse_args()
    if args.command == 'stage':
        baseline, candidate = stage(args.standard, args.int8, args.destination)
    else:
        baseline, candidate = verify(args.directory, args.standard)
    print(f'Verified standard root ({len(baseline["files"])} entries) and int8/ ({len(candidate["files"])} entries).')


if __name__ == '__main__':
    main()
