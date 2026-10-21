#!/usr/bin/env python3
"""Summarize read-only phase traces and replay their float32 recorder decisions.

A one-sample zero-pressure counterfactual is a sensitivity experiment only. It
changes neither solver state nor an accepted target and is not a proposed rule.
"""
import argparse
import array
import ctypes
import ctypes.util
import gzip
import json
import math
from pathlib import Path
import struct
from compare_dataset import npy
from trace_columns import FIELDS


def f32(value):
    return struct.unpack('<f',struct.pack('<f',value))[0]


def fused_sum(a,b,c):
    # Native IEEE float32 FMA, not a double intermediate or a tolerance approximation.
    if not hasattr(fused_sum,'function'):
        library=ctypes.CDLL(ctypes.util.find_library('m'))
        function=library.fmaf;function.argtypes=[ctypes.c_float]*3;function.restype=ctypes.c_float
        fused_sum.function=function
    return fused_sum.function(a,b,c)


def load(folder):
    folder=Path(folder)
    pressure=(folder/'pressure-trace.json').exists()
    if not pressure and not (folder/'trace.json').exists() and (folder/'production-trace.json').exists():
        raise ValueError('recorder-only production trace has no consumed pressure to replay')
    meta=json.loads((folder/('pressure-trace.json' if pressure else 'trace.json')).read_text())
    if pressure and (meta.get('format')!='bombcad-production-pressure-trace-1' or meta.get('complete') is not True):
        raise ValueError('complete versioned consumed-pressure trace required')
    if pressure or (folder/'trace.npy').exists():
        shape,data=npy(folder/('pressure-trace.npy' if pressure else 'trace.npy'))
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
    if pressure:
        seeds=meta.get('seedRecords')
        if not isinstance(seeds,list) or len(seeds)!=len(meta['columns']) or any(
                not isinstance(row,list) or len(row)!=5 or not all(isinstance(v,(int,float)) and math.isfinite(v) for v in row)
                for row in seeds):
            raise ValueError('finite five-field seeded recorder state required for each column')
        try:meta['seedRecords']=[[f32(v) for v in row] for row in seeds]
        except (OverflowError,struct.error) as error:raise ValueError('seed state must fit float32') from error
        if not 1<=len(meta['columns'])<=64 or any(type(v) is not int or v<0 for v in meta['columns']) or len(meta['times'])>32768:
            raise ValueError('bounded nonnegative consumed-pressure column indices and sample count required')
        if meta.get('steps')!=list(range(len(meta['times']))) or len(set(meta['columns']))!=len(meta['columns']):
            raise ValueError('distinct columns and consecutive initialized pressure samples required')
        if any(data[q*8+6]!=0 for q in range(len(meta['columns']))) or any(
                data[(step*len(meta['columns'])+q)*8+6]<=0
                for step in range(1,len(meta['times'])) for q in range(len(meta['columns']))):
            raise ValueError('zero-dt initialization followed by positive active dt required')
        if any(b<=a for a,b in zip(meta['times'],meta['times'][1:])):
            raise ValueError('pressure sample times must increase')
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
        def replay(zero_at=None, replacement=0., fused=False):
            consumed=meta.get('format')=='bombcad-production-pressure-trace-1'
            x,y,z,w,going=meta['seedRecords'][q] if consumed else initial[1:6]
            different=0;maximum=0.
            closing=[]
            for step in range(0 if consumed else 1,len(meta['times'])):
                r=row(step);p=replacement if step==zero_at else r[0];dt=r[6]
                if dt>0 or (consumed and step==0):
                    y=fused_sum(max(p,0.),dt,y) if fused else f32(y+f32(max(p,0.)*dt));x=max(x,p)
                    if going:
                        if p<0: going=0.;closing.append(step)
                        else: z=y;w=max(w,p)
                    if p>0 and w<.5*x:z=y;w=p;going=1.
                for a,b in zip([x,y,z,w,going],r[1:6]):
                    different+=a!=b;maximum=max(maximum,abs(a-b))
            return {'finalFirstPhaseImpulse':z,'recorderValuesDifferent':different,
                    'maxRecorderDifference':maximum,'closingSamples':closing}
        normal=replay()
        fused_normal=replay(fused=True) if meta.get('format')=='bombcad-production-pressure-trace-1' else None
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
                       'float32Replay':normal,'float32FusedReplay':fused_normal,
                       'exactAccumulationPolicies':[name for name,value in [('separate',normal),('fused',fused_normal)]
                                                    if value is not None and value['recorderValuesDifferent']==0],
                       'counterfactualAccumulation':'separate; fused replay is separately reported, not an instruction attestation',
                       'closingWindows':windows,
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
