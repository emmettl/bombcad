#!/usr/bin/env python3
"""Summarize read-only phase traces and replay their float32 recorder decisions.

A one-sample zero-pressure counterfactual is a sensitivity experiment only. It
changes neither solver state nor an accepted target and is not a proposed rule.
"""
import argparse
import array
import gzip
import json
import math
from pathlib import Path
import struct
from compare_dataset import npy
from trace_columns import FIELDS


def f32(value):
    return struct.unpack('<f',struct.pack('<f',value))[0]


def load(folder):
    folder=Path(folder);meta=json.loads((folder/'trace.json').read_text())
    if (folder/'trace.npy').exists():
        shape,data=npy(folder/'trace.npy')
        if shape!=(len(meta['times']),len(meta['columns']),8):
            raise ValueError('trace dimensions do not match metadata')
    else:
        data=array.array('f')
        if (folder/'trace.bin').exists(): raw=(folder/'trace.bin').read_bytes()
        else: raw=gzip.decompress((folder/'trace-f32.bin.gz').read_bytes())
        data.frombytes(raw)
        if __import__('sys').byteorder!='little': data.byteswap()
    if not meta['times'] or not meta['columns'] or meta['fields']!=FIELDS or not all(math.isfinite(x) for x in [*meta['times'],*data]):
        raise ValueError('invalid or non-finite trace metadata/data')
    if len(data)!=len(meta['times'])*len(meta['columns'])*8:
        raise ValueError('trace data length mismatch')
    return meta,data


def summarize(meta,data, overrides=None):
    count=len(meta['columns']);result=[]
    for q,column in enumerate(meta['columns']):
        def row(step): return list(data[(step*count+q)*8:(step*count+q+1)*8])
        transitions=[];last=None
        for step,t in enumerate(meta['times']):
            r=row(step)
            if r[5]!=last:
                transitions.append({'sample':step,'time':t,'values':r});last=r[5]
        initial=row(0)
        def replay(zero_at=None, replacement=0.):
            x,y,z,w=initial[1:5];going=initial[5];different=0;maximum=0.
            closing=[]
            for step in range(1,len(meta['times'])):
                r=row(step);p=replacement if step==zero_at else r[0];dt=r[6]
                if dt>0:
                    y=f32(y+f32(max(p,0.)*dt));x=max(x,p)
                    if going:
                        if p<0: going=0.;closing.append(step)
                        else: z=y;w=max(w,p)
                    if p>0 and w<.5*x:z=y;w=p;going=1.
                for a,b in zip([x,y,z,w,going],r[1:6]):
                    different+=a!=b;maximum=max(maximum,abs(a-b))
            return {'finalFirstPhaseImpulse':z,'recorderValuesDifferent':different,
                    'maxRecorderDifference':maximum,'closingSamples':closing}
        normal=replay()
        windows=[];counterfactuals=[]
        for t in transitions:
            if t['sample'] and t['values'][5]==0:
                i=t['sample']
                windows.append({'closingSample':i,'samples':[{'sample':j,'time':meta['times'][j],
                    'values':row(j)} for j in range(max(0,i-2),min(len(meta['times']),i+3))]})
                counterfactuals.append({'zeroPressureAtSample':i,**replay(i)})
        specified=None
        if overrides and column in overrides:
            sample,pressure=overrides[column]
            if not 1<=sample<len(meta['times']) or not math.isfinite(pressure):
                raise ValueError('invalid offline counterfactual sample/pressure')
            specified={'sample':sample,'replacementPressure':pressure,'offlineOnly':True,**replay(sample,pressure)}
        result.append({'column':column,'final':row(len(meta['times'])-1),'transitions':transitions,
                       'float32Replay':normal,'closingWindows':windows,
                       'oneSampleZeroCounterfactuals':counterfactuals,'specifiedCounterfactual':specified})
    return {'columns':result,'samples':len(meta['times']),'fields':meta['fields']}


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('traces',type=Path,nargs='+')
    p.add_argument('--out',type=Path,required=True)
    p.add_argument('--replace',action='append',default=[],metavar='COLUMN:SAMPLE:PA',help='offline single-sample sensitivity experiment only')
    a=p.parse_args();overrides={}
    for item in a.replace:
        try:
            column,sample,pressure=item.split(':');column=int(column);sample=int(sample);pressure=float(pressure)
        except ValueError: p.error('--replace requires COLUMN:SAMPLE:PA')
        if column in overrides: p.error('one replacement per column')
        overrides[column]=(sample,pressure)
    result={str(folder):summarize(*load(folder),overrides) for folder in a.traces}
    found={c['column'] for r in result.values() for c in r['columns']}
    if not set(overrides)<=found: p.error('replacement column is absent from every trace')
    with a.out.open('x') as f:json.dump(result,f,indent=2);f.write('\n')
