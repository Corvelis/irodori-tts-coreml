"""Reproduce the Core ML conversion recipe. Existing outputs are never overwritten.

Inspect with --dry-run first. Run on Apple Silicon macOS; Core ML validation
requires Apple's runtime. Conversion uses ONNX intermediates; inference does not.
"""
import argparse
import json
from pathlib import Path
import subprocess
import sys


def commands(sources, output):
    tools = Path(__file__).parent
    onnx = output / 'intermediates'
    coreml = output / 'coreml'
    checkpoint = sources / 'checkpoint/model.safetensors'
    code = sources / 'Irodori-TTS'
    def py(name, *args): return [sys.executable, str(tools / name), *map(str, args)]
    yield py('export_context_split.py', onnx / 'context_kv.onnx', onnx)
    yield py('export_decoder_stages.py', onnx)
    yield py('extract_reference_statistics.py', onnx / 'dacvae_encode.onnx', onnx / 'dacvae_encode_stats.onnx')
    for name in ['text_encoder', 'speaker_encoder', 'duration', 'context_kv_text', 'context_kv_speaker', 'dacvae_encode_stats', 'decoder_stage_0']:
        args = [onnx / (name + '.onnx'), coreml]
        if name not in ('dacvae_encode_stats', 'decoder_stage_0'):
            args += ['--checkpoint', checkpoint, '--source-root', code]
        yield py('export_coreml_auxiliary.py', *args)
        yield py('validate_coreml_auxiliary.py', coreml / (name + '.mlpackage'))
    yield py('export_coreml_dit.py', '--checkpoint', checkpoint, '--source-root', code,
             '--output', coreml / 'dit_step_cached_mixed_linear_768.mlpackage', '--precision', 'mixed-linear',
             '--cached-kv', '--max-frames', '768', '--max-text-tokens', '256', '--max-speaker-tokens', '751')
    for stage, width, fixed in [(1, 64, True), (1, 57, True), (1, 128, False), (2, 256, True), (3, 511, False)]:
        args = [onnx, '--stage', stage, '--width', width, '--precision', 'float16']
        if fixed: args.append('--fixed')
        yield py('export_coreml_decoder_2d.py', *args)
    yield py('validate_tiled_stage1.py', onnx)
    yield py('export_audioseal.py', '--destination', coreml)


def main():
    import shutil
    from fetch_sources import checksum
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sources', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    if args.dry_run:
        for command in commands(args.sources, args.output): print(json.dumps(command))
        return
    if args.output.exists(): raise FileExistsError(args.output)
    lock = json.loads(Path(__file__).with_name('sources.lock.json').read_text())
    for repo in lock['repositories']:
        for item in repo['files']:
            path = args.sources / repo['destination'] / item['destination']
            if path.stat().st_size != item['bytes'] or checksum(path) != item['sha256']:
                raise ValueError(f'Source hash mismatch: {path.name}')
    commit = subprocess.check_output(['git', '-C', str(args.sources / 'Irodori-TTS'), 'rev-parse', 'HEAD'], text=True).strip()
    if commit != lock['upstreamCode']['revision']: raise ValueError('Wrong upstream code revision')
    if subprocess.check_output(['git', '-C', str(args.sources / 'Irodori-TTS'), 'status', '--porcelain', '--untracked-files=no'], text=True).strip():
        raise ValueError('Upstream tracked source files were modified')
    shutil.copytree(args.sources / 'onnx', args.output / 'intermediates')
    for index, command in enumerate(commands(args.sources, args.output)):
        log = args.output / f'{index:02d}-{Path(command[1]).stem}.log'
        print('Running', ' '.join(command[1:]), flush=True)
        with log.open('w') as stream: subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT, check=True)
    intermediate, coreml = args.output / 'intermediates', args.output / 'coreml'
    for path in intermediate.glob('*.mlpackage'): shutil.copytree(path, coreml / path.name)
    # Build the same runtime-compatible bundle with validated auxiliary components.
    for name in ['config.json', 'tokenizer']:
        source, target = intermediate / name, coreml / name
        shutil.copytree(source, target) if source.is_dir() else shutil.copy2(source, target)
    from make_coreml_only_bundle import assemble
    assemble(coreml, coreml, args.output / 'runtime-bundle')
    print('Conversion finished. Run native audio parity and Scripts/stage_model.py before release.')


if __name__ == '__main__': main()
