"""Generate matched baseline/INT8 WAVs using the released CLI.

Only one engine is resident at a time. Model order alternates between seeds.
Use an authorized reference; the report can contain input text and captions.
"""
import argparse
import json
from pathlib import Path
import subprocess
import hashlib


def main():
    p=argparse.ArgumentParser(description=__doc__)
    for name in ['cli','baseline','candidate','reference','output']: p.add_argument('--'+name,required=True,type=Path)
    p.add_argument('--cases',type=Path,default=Path(__file__).with_name('quality-cases.json'))
    p.add_argument('--seeds',default='11,29,47')
    a=p.parse_args()
    if a.output.exists(): raise FileExistsError(a.output)
    for model in [a.baseline,a.candidate]:
        subprocess.run([str(a.cli.resolve()),'verify','--models',str(model.resolve())],check=True)
    a.output.mkdir(parents=True)
    cases=json.loads(a.cases.read_text()); seeds=[int(s) for s in a.seeds.split(',')]
    (a.output/'cases.json').write_text(json.dumps(cases,ensure_ascii=False,indent=2)+'\n')
    for group,reference in [('default',False),('reference',True)]:
        subset=[row for row in cases if bool(row.get('reference'))==reference]
        # Include two leading warmups; these do not enter the quality summary.
        warmup=[{'name':'warmup-'+str(i),'text':subset[0]['text']} for i in range(2)]
        casefile=a.output/(group+'-cases.json')
        casefile.write_text(json.dumps(warmup+subset,ensure_ascii=False,indent=2)+'\n')
        for index,seed in enumerate(seeds):
            order=['baseline','int8'] if (index+int(reference))%2==0 else ['int8','baseline']
            for variant in order:
                root=a.output/f'{group}-seed-{seed}-{variant}'
                command=[str(a.cli.resolve()),'benchmark','--models',str(getattr(a,'candidate' if variant=='int8' else 'baseline').resolve()),
                    '--cases',str(casefile.resolve()),'--output-directory',str(root/'wav'), '--report',str(root/'report.json'),
                    '--irodori-fixed-seed','--irodori-seed',str(seed),'--irodori-diagnostics']
                if reference: command += ['--reference',str(a.reference.resolve())]
                root.mkdir()
                print(f'{group} seed={seed} {variant}',flush=True)
                with (root/'generation.log').open('w') as log:
                    subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,check=True)
    manifests={variant:hashlib.sha256((root/'manifest.json').read_bytes()).hexdigest() for variant,root in [('baseline',a.baseline),('int8',a.candidate)]}
    (a.output/'generation.json').write_text(json.dumps({'seeds':seeds,'caseCount':len(cases),'inputManifestSha256':manifests,
        'pairedGenerations':len(cases)*len(seeds),'watermarkEnabled':True,
        'scope':'Fixed seeds; one resident engine; two warmup utterances per model load; TTS only; no ASR/LLM or physical speaker timing.'},indent=2)+'\n')


if __name__=='__main__': main()
