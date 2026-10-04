"""Export a clean source tree/archive without models, private audio or build caches."""
import argparse
from pathlib import Path
import shutil
import zipfile

ROOT = Path(__file__).resolve().parents[1]
TOP = ('.github', '.gitignore', 'Package.swift', 'README.md', 'LICENSE', 'LICENSES',
       'NOTICE', 'THIRD_PARTY_NOTICES.md', 'Sources', 'Examples', 'Tests', 'Scripts',
       'Conversion', 'Distribution', 'Benchmarks', 'docs')
FORBIDDEN = {'.git', '.build', '.swiftpm', '__pycache__', 'xcuserdata', '.DS_Store', '.env'}
EXTENSIONS = {'.wav','.f32','.pcm','.onnx','.safetensors','.mlmodelc','.mlpackage','.gguf','.p8','.pem','.pyc'}


def export(destination, archive=None):
    if destination.exists(): raise FileExistsError(destination)
    if archive and archive.exists(): raise FileExistsError(archive)
    files = []
    for name in TOP:
        source = ROOT / name
        for file in ([source] if source.is_file() else source.rglob('*')):
            relative = file.relative_to(ROOT)
            if any(part in FORBIDDEN for part in relative.parts): continue
            if file.is_symlink(): raise ValueError(f'Unexpected symlink: {relative}')
            if not file.is_file(): continue
            if any(Path(part).suffix in EXTENSIONS for part in relative.parts):
                raise ValueError(f'Private/model file in source export: {relative}')
            if file.stat().st_size > 10 * 1024 * 1024: raise ValueError(f'Unexpected large source file: {relative}')
            files.append((file, relative))
    for file, relative in files:
        target = destination / relative; target.parent.mkdir(parents=True, exist_ok=True); shutil.copy2(file, target)
    if archive:
        with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED) as output:
            for _, relative in sorted(files): output.write(destination / relative, Path(destination.name) / relative)
    print(f'Exported {len(files)} source files to {destination}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--destination', type=Path, required=True)
    parser.add_argument('--archive', type=Path)
    args = parser.parse_args(); export(args.destination, args.archive)
