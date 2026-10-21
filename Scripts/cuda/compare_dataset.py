#!/usr/bin/env python3
"""Score exported training targets with the same mask and channel definitions."""
import argparse
import array
import ast
import json
import math
import struct
from pathlib import Path


def npy(path):
    data=Path(path).read_bytes()
    if data[:8]!=b'\x93NUMPY\x01\x00':raise ValueError('expected NPY v1')
    size=struct.unpack('<H',data[8:10])[0];header=ast.literal_eval(data[10:10+size].decode())
    if header['descr']!='<f4' or header['fortran_order']:raise ValueError('expected float32 C order')
    a=array.array('f');a.frombytes(data[10+size:])
    if len(a)!=math.prod(header['shape']):raise ValueError('truncated NPY')
    return header['shape'],a


def compare(reference,candidate):
    reference=Path(reference);candidate=Path(candidate)
    shape,a=npy(reference/'targets.npy');other,b=npy(candidate/'targets.npy')
    if shape!=other:raise ValueError('target shape mismatch')
    mask_shape,mask=npy(reference/'mask.npy');s,m=npy(candidate/'mask.npy')
    if mask_shape!=s or mask!=m:raise ValueError('mask mismatch')
    _,inputs=npy(reference/'inputs.npy');_,others=npy(candidate/'inputs.npy')
    if inputs!=others:raise ValueError('input features changed')
    plane=math.prod(shape[1:]);report={}
    for c in range(shape[0]):
        errors=[];squared=scale=maximum=0.;failures=0
        for i,valid in enumerate(mask):
            if not valid:continue
            x,y=a[c*plane+i],b[c*plane+i]
            if not math.isfinite(x) or not math.isfinite(y):raise ValueError('nonfinite target')
            e=abs(x-y);maximum=max(maximum,e);squared+=e*e;scale+=x*x
            failures+=e>.05+.002*abs(x)
            if x>(100 if c==0 else .1):errors.append(e/x)
        errors.sort()
        report[str(c)]={'relativeL2':math.sqrt(squared/max(scale,1e-30)), 'maxAbsolute':maximum,
                        'outsideTolerance':failures,'medianRelative':errors[len(errors)//2] if errors else 0,
                        'p99Relative':errors[min(len(errors)-1,int(len(errors)*.99))] if errors else 0}
    report['passed']=all(v['outsideTolerance']==0 for v in report.values())
    return report


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('reference');p.add_argument('candidate');a=p.parse_args()
    report=compare(a.reference,a.candidate);print(json.dumps(report,indent=2));raise SystemExit(0 if report['passed'] else 1)
