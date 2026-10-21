#!/usr/bin/env python3
"""Compare complete Metal/CUDA fields; fail on discrepancies above declared tolerances."""
import argparse
import array
import json
import math
from pathlib import Path


def floats(path):
    data=array.array('f');data.frombytes(Path(path).read_bytes());return data


def compare(reference,candidate,rtol=0.002,atol=0.05):
    reference=Path(reference);candidate=Path(candidate);report={};passed=True
    for name in ('state','species','peak','impulse','first-phase'):
        a=floats(reference/(name+'.bin'));b=floats(candidate/(name+'.bin'))
        if len(a)!=len(b) or not a:
            raise ValueError(f'{name}: shape mismatch or empty')
        failures=0;maximum=0.;squared=0.;scale=0.;bits=0
        for x,y in zip(a,b):
            error=abs(x-y)
            if not math.isfinite(x) or not math.isfinite(y):
                failures+=1;maximum=float('inf');continue
            failures+=error>atol+rtol*abs(x)
            maximum=max(maximum,error);squared+=error*error;scale+=x*x
            bits+=x!=y
        passed &= failures==0
        report[name]={'count':len(a),'outsideTolerance':failures,'differentValues':bits,
                      'maxAbsolute':maximum,'relativeL2':math.sqrt(squared/max(scale,1e-30))}
    report['passed']=passed;report['rtol']=rtol;report['atol']=atol
    return report


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('reference',type=Path);p.add_argument('candidate',type=Path)
    p.add_argument('--rtol',type=float,default=.002);p.add_argument('--atol',type=float,default=.05)
    a=p.parse_args();r=compare(a.reference,a.candidate,a.rtol,a.atol);print(json.dumps(r,indent=2));raise SystemExit(0 if r['passed'] else 1)
