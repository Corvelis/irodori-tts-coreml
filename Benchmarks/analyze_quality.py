"""Measure ASR character errors and acoustic differences for matched WAVs.

CER is scored after Japanese reading normalization. The FP32 generated WAV is
a comparison, not a clean recorded reference. No metric is a human MOS score
or an overall perceptual degradation percentage.
"""
import argparse
from collections import defaultdict
from math import gcd
import json
from pathlib import Path
import unicodedata
import hashlib

import numpy as np
import soundfile as sf
from scipy.signal import resample_poly, stft


def edit_distance(reference, hypothesis):
    previous=list(range(len(hypothesis)+1))
    for i,a in enumerate(reference,1):
        current=[i]
        for j,b in enumerate(hypothesis,1):
            current.append(min(previous[j]+1,current[-1]+1,previous[j-1]+(a!=b)))
        previous=current
    return previous[-1]


def reading(text):
    import pyopenjtalk
    kana=pyopenjtalk.g2p(unicodedata.normalize('NFKC',text),kana=True)
    return ''.join(c for c in kana if unicodedata.category(c)[0] in ('L','N') or c=='ー')


def resample(audio,rate,target=16000):
    divisor=gcd(rate,target)
    return resample_poly(audio,target//divisor,rate//divisor)


def mel_features(audio,rate):
    x=resample(audio,rate)
    _,_,z=stft(x,fs=16000,nperseg=400,noverlap=240,nfft=512,boundary='zeros')
    hz_to_mel=lambda f:2595*np.log10(1+f/700)
    mel_to_hz=lambda m:700*(10**(m/2595)-1)
    edges=mel_to_hz(np.linspace(hz_to_mel(80),hz_to_mel(7600),82))
    frequency=np.arange(257)*16000/512
    bank=np.maximum(0,np.minimum((frequency[None,:]-edges[:-2,None])/(edges[1:-1,None]-edges[:-2,None]),
        (edges[2:,None]-frequency[None,:])/(edges[2:,None]-edges[1:-1,None])))
    energy=bank @ np.abs(z)**2
    return 10*np.log10(np.maximum(energy,1e-10))


def acoustic_difference(reference,candidate,rate):
    a,b=mel_features(reference,rate),mel_features(candidate,rate)
    # Align by relative duration. This is not phoneme alignment or DTW.
    index=np.linspace(0,b.shape[1]-1,a.shape[1])
    b=np.stack([np.interp(index,np.arange(b.shape[1]),row) for row in b])
    active=np.max(a,axis=0)>np.max(a)-45
    rmse=float(np.sqrt(np.mean((a[:,active]-b[:,active])**2)))
    rms_a=float(np.sqrt(np.mean(reference.astype(np.float64)**2)))
    rms_b=float(np.sqrt(np.mean(candidate.astype(np.float64)**2)))
    return {'durationChangePercent':100*(len(candidate)/len(reference)-1),
        'rmsLevelChangeDb':20*float(np.log10(max(rms_b,1e-12)/max(rms_a,1e-12))),
        'normalizedTimeLogMelRmseDb':rmse}


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--input',type=Path,required=True)
    p.add_argument('--asr-models',type=Path,required=True)
    p.add_argument('--encoder-file',default='encoder-epoch-35-avg-1.int8.onnx')
    p.add_argument('--decoder-file',default='decoder-epoch-35-avg-1.int8.onnx')
    p.add_argument('--joiner-file',default='joiner-epoch-35-avg-1.int8.onnx')
    p.add_argument('--report',type=Path,required=True)
    a=p.parse_args()
    if a.report.exists(): raise FileExistsError(a.report)
    import sherpa_onnx
    root=a.asr_models
    recognizer=sherpa_onnx.OfflineRecognizer.from_transducer(
        encoder=str(root/a.encoder_file),decoder=str(root/a.decoder_file),
        joiner=str(root/a.joiner_file),tokens=str(root/'tokens.txt'),num_threads=2)
    cases={row['name']:row for row in json.loads((a.input/'cases.json').read_text())}
    generation=json.loads((a.input/'generation.json').read_text())
    rows=[]
    for group in ['default','reference']:
        for seed in generation['seeds']:
            reports={}; audio={}; paths={}
            for variant in ['baseline','int8']:
                directory=a.input/f'{group}-seed-{seed}-{variant}'
                reports[variant]=json.loads((directory/'report.json').read_text())
                audio[variant]={}; paths[variant]={}
                for index,run in enumerate(reports[variant]['runs']):
                    if run['name'].startswith('warmup-'): continue
                    path=directory/'wav'/f'pass-0-case-{index}.wav'
                    waveform,sr=sf.read(path,dtype='float32')
                    audio[variant][run['name']]=(waveform,sr,run)
                    paths[variant][run['name']]=path.relative_to(a.input).as_posix()
            for name in audio['baseline']:
                row={'case':name,'group':group,'seed':seed,'expectedText':cases[name]['text']}
                reference=reading(row['expectedText']); arrays={}
                for variant in ['baseline','int8']:
                    waveform,sr,run=audio[variant][name]; arrays[variant]=waveform
                    stream=recognizer.create_stream()
                    stream.accept_waveform(16000,np.pad(resample(waveform,sr),(14400,14400)))
                    recognizer.decode_stream(stream)
                    recognized=stream.result.text; normalized=reading(recognized)
                    errors=edit_distance(reference,normalized)
                    row[variant]={'recognized':recognized,'reading':normalized,'expectedCharacters':len(reference),
                        'characterErrors':errors,'cerPercent':100*errors/max(len(reference),1),
                        'audioSeconds':len(waveform)/sr,'finite':bool(np.isfinite(waveform).all()),
                        'clippedSamples':int(np.count_nonzero(np.abs(waveform)>=32767/32768)),
                        'samples':len(waveform),'firstPcmMs':run['firstPcmMs'],'rtf':run['rtf'],
                        'streamMatchesCompletedPcm':run['streamMatchesCompletedPcm'],'wav':paths[variant][name]}
                row['cerDeltaPercentagePoints']=row['int8']['cerPercent']-row['baseline']['cerPercent']
                row['recognizedReadingMatchesBaseline']=row['int8']['reading']==row['baseline']['reading']
                row['acoustic']=acoustic_difference(arrays['baseline'],arrays['int8'],sr)
                rows.append(row)
                print(json.dumps({'case':name,'seed':seed,'cerDelta':row['cerDeltaPercentagePoints']},ensure_ascii=False),flush=True)
    total=sum(row['baseline']['expectedCharacters'] for row in rows)
    cer={v:100*sum(row[v]['characterErrors'] for row in rows)/total for v in ['baseline','int8']}
    # Cluster by text: repeated seeds of the same text are not independent samples.
    grouped=defaultdict(list)
    for row in rows: grouped[row['case']].append(row)
    clusters=list(grouped.values()); rng=np.random.default_rng(20261005); deltas=[]
    for _ in range(5000):
        sample=[row for i in rng.integers(0,len(clusters),len(clusters)) for row in clusters[i]]
        denominator=sum(row['baseline']['expectedCharacters'] for row in sample)
        deltas.append(100*sum(row['int8']['characterErrors']-row['baseline']['characterErrors'] for row in sample)/denominator)
    summary={'caseCount':len(cases),'seedCount':len(generation['seeds']),'pairedComparisons':len(rows),
        'expectedCharacters':total,'baselineCerPercent':cer['baseline'],'int8CerPercent':cer['int8'],
        'cerDeltaPercentagePoints':cer['int8']-cer['baseline'],
        'cerDeltaClusterBootstrap95CI':np.percentile(deltas,[2.5,97.5]).tolist(),
        'matchingRecognizedReadings':sum(row['recognizedReadingMatchesBaseline'] for row in rows),
        'pairsWithIncreasedCer':sum(row['cerDeltaPercentagePoints']>0 for row in rows),
        'pairsWithDecreasedCer':sum(row['cerDeltaPercentagePoints']<0 for row in rows),
        'allFinite':all(row[v]['finite'] for row in rows for v in ['baseline','int8']),
        'clippedSamples':{v:sum(row[v]['clippedSamples'] for row in rows) for v in ['baseline','int8']},
        'allStreamPcmMatches':all(row[v]['streamMatchesCompletedPcm'] for row in rows for v in ['baseline','int8']),
        'absoluteDurationChangePercentMedian':float(np.median([abs(row['acoustic']['durationChangePercent']) for row in rows])),
        'absoluteDurationChangePercentMax':max(abs(row['acoustic']['durationChangePercent']) for row in rows),
        'logMelRmseDbMedian':float(np.median([row['acoustic']['normalizedTimeLogMelRmseDb'] for row in rows])),
        'absoluteRmsLevelChangeDbMedian':float(np.median([abs(row['acoustic']['rmsLevelChangeDb']) for row in rows]))}
    model_files=[]
    for path in sorted(root.glob('*')):
        if path.is_file():model_files.append({'name':path.name,'bytes':path.stat().st_size,'sha256':hashlib.sha256(path.read_bytes()).hexdigest()})
    report={'format':'irodori-generated-audio-comparison-v1','asrModelFiles':model_files,
        'scope':'Japanese, fixed seeds, one synthetic reference voice, AudioSeal enabled.',
        'limitations':['ASR recognition and dictionary reading normalization can introduce errors.',
            'CER measures recognized content, not timbre, naturalness or human MOS.',
            'Log-mel RMSE uses normalized-time interpolation, not phoneme alignment.',
            'Generated FP32 audio is not a clean recorded ground-truth reference.',
            'A 95% bootstrap interval describes this corpus; it does not guarantee all voices, languages or devices.'],
        'summary':summary,'cases':rows}
    a.report.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps(summary,indent=2),flush=True)


if __name__=='__main__': main()
