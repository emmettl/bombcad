#!/usr/bin/env python3
"""Audit host-observed production records against a saved production dataset.

This format intentionally contains no recomputed pressure: open/closed states
come directly from the production recorder. It is distinct from CUDA pressure
traces and cannot be fed to their pressure replay as if it were the same data.
"""
import argparse
import hashlib
import gzip
import tempfile
import json
import math
from pathlib import Path
from compare_dataset import compare,npy

FIELDS=['peak','allPositiveImpulse','firstPhaseImpulse','phasePeak','open',
        'accumulatedPeak','accumulatedImpulse','dt']


def digest(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda:f.read(1048576),b''):h.update(chunk)
    return h.hexdigest()


def summarize(folder,reference,arrays=None):
    folder=Path(folder);reference=Path(reference);arrays=Path(arrays) if arrays else folder
    meta=json.loads((folder/'production-trace.json').read_text())
    if (folder/'production-trace.npy').exists():
        shape,values=npy(folder/'production-trace.npy')
    else:
        with tempfile.TemporaryDirectory(prefix='bombcad-production-trace-') as temp:
            path=Path(temp)/'trace.npy'
            path.write_bytes(gzip.decompress((folder/'production-trace.npy.gz').read_bytes()))
            shape,values=npy(path)
    if meta.get('format')!='bombcad-production-phase-trace-1' or meta['fields']!=FIELDS:
        raise ValueError('unsupported production trace')
    if shape!=(len(meta['times']),len(meta['columns']),8) or len(meta['steps'])!=shape[0] or not shape[0]:
        raise ValueError('inconsistent production trace dimensions')
    if not all(math.isfinite(v) for v in [*meta['times'],*values]):
        raise ValueError('non-finite production trace')
    if meta['steps']!=sorted(set(meta['steps'])):
        raise ValueError('active steps must be unique and increasing')
    summary={'case':json.loads((folder/'meta.json').read_text())['id'],
             'skipStillAir':meta['skipStillAir'],'allTilesInitiallyActive':meta.get('allTilesInitiallyActive',False),
             'fields':FIELDS,'samples':shape[0],
             'arraysBitIdenticalToOriginal':{name:digest(arrays/name)==digest(reference/name) for name in ('inputs.npy','mask.npy','targets.npy')},
             'arraySHA256':{name:digest(arrays/name) for name in ('inputs.npy','mask.npy','targets.npy')},
             'referenceArraySHA256':{name:digest(reference/name) for name in ('inputs.npy','mask.npy','targets.npy')},
             'comparison':compare(reference,arrays),'columns':[]}
    receipt=folder/'summary.json'
    if receipt.exists() and arrays!=folder:
        expected=json.loads(receipt.read_text()).get('arraySHA256')
        if expected!=summary['arraySHA256']:
            raise ValueError('exported arrays do not match archived receipt')
    for q,column in enumerate(meta['columns']):
        def row(j):return list(values[(j*shape[1]+q)*8:(j*shape[1]+q+1)*8])
        transitions=[];previous=None
        for j,t in enumerate(meta['times']):
            r=row(j)
            if r[4]!=previous:
                transitions.append({'kind':'initial' if previous is None else ('closed' if r[4]==0 else 'opened'),
                                    'sample':j,'step':meta['steps'][j],'time':t,'values':r})
                previous=r[4]
        final=row(shape[0]-1)
        peak_sample=next(j for j in range(shape[0]) if row(j)[5]==final[5])
        summary['columns'].append({'column':column,'transitions':transitions,'final':final,
            'accumulatedPeakFirstReached':{'step':meta['steps'][peak_sample],'time':meta['times'][peak_sample]}})
    return summary


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('trace',type=Path);p.add_argument('reference',type=Path)
    p.add_argument('--out',type=Path,required=True)
    p.add_argument('--arrays',type=Path,help='exported arrays when replaying a compressed trace archive; required to recompute gates')
    a=p.parse_args();result=summarize(a.trace,a.reference,a.arrays)
    with a.out.open('x') as f:json.dump(result,f,indent=2);f.write('\n')
