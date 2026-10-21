#!/usr/bin/env python3
"""Describe full-field spread of declared reference variants; never admits a dataset.

The observed min/max range is not a numerical error bound or confidence interval.
Arithmetic variants are not independent physical observations. Existing tolerance
is used only to put the spread in context; the original gate is reported intact.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
from compare_dataset import compare,npy


def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--reference',action='append',required=True,metavar='NAME=DIR')
    p.add_argument('--canonical',required=True)
    p.add_argument('--candidate',type=Path,required=True)
    p.add_argument('--out',type=Path,required=True);a=p.parse_args()
    refs={}
    for item in a.reference:
        if '=' not in item:p.error('reference requires NAME=DIR')
        name,path=item.split('=',1)
        if not name or name in refs:p.error('reference names must be nonempty and unique')
        refs[name]=Path(path)
    if a.canonical not in refs or len(refs)<2:p.error('canonical must name one of at least two references')
    if a.out.exists():p.error('output must be new')
    canonical=refs[a.canonical]
    shape,original=npy(canonical/'targets.npy');mask_shape,mask=npy(canonical/'mask.npy')
    feature_shape,features=npy(canonical/'inputs.npy');plane=math.prod(shape[1:])
    arrays={};hashes={};metadata={}
    for name,path in {**refs,'candidate':a.candidate}.items():
        if name=='candidate' and name in refs:p.error('candidate is a reserved reference name')
        target_shape,values=npy(path/'targets.npy');mshape,m=npy(path/'mask.npy');fshape,f=npy(path/'inputs.npy')
        if target_shape!=shape or mshape!=mask_shape or m!=mask or fshape!=feature_shape or f!=features:
            raise ValueError('different target shape, mask or input features')
        if not all(math.isfinite(v) for v in values):raise ValueError('nonfinite target')
        arrays[name]=values;hashes[name]={f:digest(path/f) for f in ('inputs.npy','mask.npy','targets.npy')}
        metadata[name]=json.loads((path/'meta.json').read_text())
    if any(m.get('id')!=metadata[a.canonical].get('id') or not m.get('stable') for m in metadata.values()):
        raise ValueError('stable same-case datasets required')
    summaries=[];valid=sum(bool(v) for v in mask)
    for channel in range(shape[0]):
        spreads=[];relative=[];sensitive=outside_range=outside_tolerance=0;largest=[]
        for i,enabled in enumerate(mask):
            if not enabled:continue
            values=[arrays[name][channel*plane+i] for name in refs];low=min(values);high=max(values)
            x=original[channel*plane+i];y=arrays['candidate'][channel*plane+i];spread=high-low
            tolerance=.05+.002*abs(x);spreads.append(spread);sensitive+=spread>tolerance
            excess=max(low-y,y-high,0.);outside_range+=excess>0;outside_tolerance+=excess>tolerance
            if x>(100 if channel==0 else .1):relative.append(spread/x)
            if spread>tolerance:largest.append((spread,i,low,high,x,y,excess))
        spreads.sort();relative.sort();largest.sort(reverse=True)
        summaries.append({'channel':channel,'target':metadata[a.canonical]['targets'][channel],'validTargets':valid,'referenceRangeExceedsOriginalPerValueTolerance':sensitive,
            'maxReferenceRange':spreads[-1] if spreads else 0.,'p99ReferenceRange':spreads[min(len(spreads)-1,int(.99*len(spreads)))] if spreads else 0.,
            'p99RelativeRangeAboveExistingMagnitudeFloor':relative[min(len(relative)-1,int(.99*len(relative)))] if relative else 0.,
            'candidateOutsideObservedRange':outside_range,'candidateOutsideObservedRangeByMoreThanOriginalTolerance':outside_tolerance,
            'largestReferenceRanges':[{'column':i,'range':s,'min':lo,'max':hi,'canonical':x,'candidate':y,'candidateExcessBeyondRange':e}
                                      for s,i,lo,hi,x,y,e in largest[:20]]})
    report={'format':'bombcad-reference-spread-1','case':metadata[a.canonical]['id'],'canonical':a.canonical,
            'referenceNames':list(refs),'uniqueReferenceTargetHashes':len({h['targets.npy'] for name,h in hashes.items() if name in refs}),
            'inputSHA256':hashes,'channels':summaries,'originalCandidateGate':compare(canonical,a.candidate),
            'scope':'Descriptive observed spread only; not a bound, confidence interval, physical validation or admission rule. No tolerance/mask/default change and no policy chosen.',
            'runnerSHA256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}
    with a.out.open('x') as f:json.dump(report,f,indent=2);f.write('\n')


if __name__=='__main__':main()
