"""Run the official Microsoft DNSMOS evaluator on matched generated WAVs.

Download the evaluator and models separately; they are not part of this SDK.
DNSMOS estimates speech quality for noise suppression. It is an additional
proxy, not a human MOS test or a guarantee of TTS naturalness/voice similarity.
"""
import argparse
from collections import defaultdict
import importlib.util
import json
from pathlib import Path
import tempfile

import numpy as np
import soundfile as sf
from analyze_quality import resample


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--input',required=True,type=Path)
    p.add_argument('--dnsmos',required=True,type=Path,help='Official DNS-Challenge checkout root')
    p.add_argument('--report',required=True,type=Path)
    a=p.parse_args()
    if a.report.exists():raise FileExistsError(a.report)
    spec=importlib.util.spec_from_file_location('official_dnsmos',a.dnsmos/'DNSMOS/dnsmos_local.py')
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    evaluator=module.ComputeScore(str(a.dnsmos/'DNSMOS/DNSMOS/sig_bak_ovr.onnx'),str(a.dnsmos/'DNSMOS/DNSMOS/model_v8.onnx'))
    generation=json.loads((a.input/'generation.json').read_text());rows=[]
    with tempfile.TemporaryDirectory() as temp:
        file=Path(temp)/'score.wav'
        for group in ['default','reference']:
            for seed in generation['seeds']:
                variants={}
                for variant in ['baseline','int8']:
                    root=a.input/f'{group}-seed-{seed}-{variant}'
                    report=json.loads((root/'report.json').read_text());variants[variant]={}
                    for index,run in enumerate(report['runs']):
                        if run['name'].startswith('warmup-'):continue
                        wave,rate=sf.read(root/'wav'/f'pass-0-case-{index}.wav',dtype='float32')
                        sf.write(file,resample(wave,rate),16000,subtype='FLOAT')
                        score=evaluator(str(file),16000,False)
                        value={key:float(score[key]) for key in ['SIG','BAK','OVRL','P808_MOS']}
                        if not all(np.isfinite(list(value.values()))):raise ValueError('Non-finite DNSMOS score')
                        variants[variant][run['name']]=value
                for name in variants['baseline']:
                    rows.append({'case':name,'seed':seed,'baseline':variants['baseline'][name],'int8':variants['int8'][name]})
                print(f'{group} seed={seed} complete',flush=True)
    grouped=defaultdict(list)
    for row in rows:grouped[row['case']].append(row)
    clusters=list(grouped.values());rng=np.random.default_rng(20261005)
    summary={}
    for metric in ['SIG','BAK','OVRL','P808_MOS']:
        delta=[row['int8'][metric]-row['baseline'][metric] for row in rows]
        bootstrap=[]
        for _ in range(5000):
            sample=[row for i in rng.integers(0,len(clusters),len(clusters)) for row in clusters[i]]
            bootstrap.append(np.mean([row['int8'][metric]-row['baseline'][metric] for row in sample]))
        summary[metric]={'baselineMean':float(np.mean([row['baseline'][metric] for row in rows])),
            'int8Mean':float(np.mean([row['int8'][metric] for row in rows])), 'deltaMean':float(np.mean(delta)),
            'deltaClusterBootstrap95CI':np.percentile(bootstrap,[2.5,97.5]).tolist(), 'worstPairDelta':min(delta)}
    result={'format':'irodori-dnsmos-comparison-v1','pairedComparisons':len(rows),
        'scope':'Official regular DNSMOS evaluator; 16kHz resampling; sub-9.01-second clips repeated by the official evaluator.',
        'limitations':'Estimated quality proxy designed for noise suppression, not human MOS or TTS pronunciation/voice similarity.',
        'summary':summary,'cases':rows}
    a.report.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(summary,indent=2))


if __name__=='__main__':main()
