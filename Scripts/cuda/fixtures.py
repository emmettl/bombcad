#!/usr/bin/env python3
"""Small deterministic acceptance jobs, without NumPy or GPU dependencies."""
import argparse
import array
import hashlib
import json
import math
from pathlib import Path
from job import FORMAT

KINDS=('still','shock','blast','obstacle','hot','burning','farfield','closed','cooling')


def make(folder, source, kind, n=32):
    if kind not in KINDS:
        raise ValueError(kind)
    folder=Path(folder);folder.mkdir(parents=True,exist_ok=False)
    u={'dx':0.25,'gamma':1.4,'cfl':0.4,'ambientPressure':101325.,'densityFloor':1e-6,
       'pressureFloor':1e-4,'limiterTheta':1.5,'riemannSolver':0,'boundaryFlags':63,
       'airModel':1 if kind in ('hot','burning','cooling') else 0,
       'stillRho':1.225,'stillEnergy':101325./(float(array.array('f',[1.4])[0])-1.)}
    if kind=='farfield':
        u['boundaryFlags']=64
    if kind in ('burning','cooling'):
        u.update(afterburnEnergy=3e6,oxygenPerFuel=0.5,afterburnRate=500.)
    state=array.array('f');species=array.array('f');mask=bytearray()
    for z in range(n):
        for y in range(n):
            for x in range(n):
                r=math.sqrt((x-n*.3)**2+(y-n*.5)**2+(z-n*.5)**2)
                rho=1.225; p=101325.;vx=vy=vz=0.
                if kind=='shock' and x<n//2:
                    rho=2.45;p=405300.
                elif kind not in ('still','shock'):
                    p+=2e6*math.exp(-r*r/(n*.12)**2)
                    vx=12*math.sin(x*.17)*math.cos(y*.13)
                    vy=8*math.sin(y*.11);vz=4*math.cos(z*.23)
                e=p/(float(array.array('f',[u['gamma']])[0])-1.)
                state.extend([rho,rho*vx,rho*vy,rho*vz,e+0.5*rho*(vx*vx+vy*vy+vz*vz)])
                species.extend([0.15*math.exp(-r*r/(n*.15)**2) if kind in ('burning','cooling') else 0.,0.28])
                solid=kind=='obstacle' and n//2<=x<n//2+2 and n//4<=y<3*n//4
                mask.append(int(solid))
    zero=array.array('f',[0.])*(n**3)
    data={'state.bin':state.tobytes(),'species.bin':species.tobytes(),'mask.bin':bytes(mask),
          'peak.bin':zero.tobytes(),'impulse.bin':zero.tobytes(),
          'columns.bin':array.array('f',[2.,3.,0.,1.]*(n*n)).tobytes(),
          'records.bin':array.array('f',[0.]*(n*n*4)).tobytes(),
          'open.bin':array.array('f',[0.]*(n*n)).tobytes()}
    if __import__('sys').byteorder!='little':
        raise RuntimeError('fixtures require little endian host')
    meta={'format':FORMAT,'sourceSHA256':hashlib.sha256(source.encode()).hexdigest(),
          'shape':[n,n,n],'uniforms':u,'axes':[0,1,2],'steps':10000,'duration':0.002,
          'above':0.625,'startTime':0,'description':kind,
          'files':{k:hashlib.sha256(v).hexdigest() for k,v in data.items()}}
    if kind=='cooling':
        meta['cooling']={'interval':4,'luminous':1500.,'absorption':.1,'sootAbsorption':.18675,
                         'hasSpecies':1,'largestShare':.25,'luminousEnergy':1e6,'capacity':0}
    for name,value in data.items():
        (folder/name).write_bytes(value)
    (folder/'job.json').write_text(json.dumps(meta,indent=2)+'\n')


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--source',type=Path,required=True)
    p.add_argument('--out',type=Path,required=True);p.add_argument('--size',type=int,default=32)
    a=p.parse_args()
    for kind in KINDS:
        make(a.out/kind,a.source.read_text(),kind,a.size)
