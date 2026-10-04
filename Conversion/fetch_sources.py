"""Download immutable conversion inputs and verify bytes and SHA-256. No uploads."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
from urllib.request import urlopen


def checksum(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def fetch(root):
    lock = json.loads(Path(__file__).with_name('sources.lock.json').read_text())
    root.mkdir(parents=True, exist_ok=True)
    for repo in lock['repositories']:
        for entry in repo['files']:
            path = root / repo['destination'] / entry['destination']
            if path.exists() and path.stat().st_size == entry['bytes'] and checksum(path) == entry['sha256']:
                print('Verified', path.name, flush=True)
                continue
            if path.exists():
                raise ValueError(f'Existing source differs: {path}; move it aside before retrying')
            path.parent.mkdir(parents=True, exist_ok=True)
            temporary = path.with_suffix(path.suffix + '.partial')
            url = f'https://huggingface.co/{repo["id"]}/resolve/{repo["revision"]}/{entry["path"]}'
            print('Downloading', repo['id'], entry['path'], flush=True)
            with urlopen(url, timeout=120) as response, temporary.open('wb') as output:
                while block := response.read(1024 * 1024):
                    output.write(block)
            if temporary.stat().st_size != entry['bytes'] or checksum(temporary) != entry['sha256']:
                raise ValueError(f'Download verification failed: {path.name}')
            temporary.replace(path)
    code = root / 'Irodori-TTS'
    if not code.exists():
        subprocess.run(['git', 'clone', '--no-checkout', lock['upstreamCode']['repository'], str(code)], check=True)
        subprocess.run(['git', '-C', str(code), 'checkout', '--detach', lock['upstreamCode']['revision']], check=True)
    actual = subprocess.check_output(['git', '-C', str(code), 'rev-parse', 'HEAD'], text=True).strip()
    if actual != lock['upstreamCode']['revision']:
        raise ValueError('Upstream source checkout is at a different commit')
    if subprocess.check_output(['git', '-C', str(code), 'status', '--porcelain', '--untracked-files=no'], text=True).strip():
        raise ValueError('Upstream tracked source files were modified')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', type=Path)
    fetch(parser.parse_args().destination)
