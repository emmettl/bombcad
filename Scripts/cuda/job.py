"""Portable, scalar ABI for the uniform training-data worker (no GPU imports)."""
import ctypes as C
import hashlib
import json
import math
import re
from pathlib import Path

FORMAT = 'bombcad-cuda-job-1'
SUPPORTED = {'dx','gamma','cfl','ambientPressure','densityFloor','pressureFloor','limiterTheta',
             'riemannSolver','boundaryFlags','afterburnEnergy','oxygenPerFuel','stillOxygen',
             'afterburnRate','airModel','stillRho','stillMx','stillMy','stillMz','stillEnergy',
             'maxStep','gaugeWalls','refineMargin'}


def scalar_layout(source, name):
    match = re.search(r'struct ' + name + r'\s*\{(.*?)\};', source, re.S)
    if not match:
        raise ValueError(f'missing ABI structure {name}')
    body = re.sub(r'//[^\n]*', '', match.group(1))
    fields = re.findall(r'^\s*(float|uint)\s+(\w+)\s*;', body, re.M)
    if len(fields) != body.count(';'):
        raise ValueError(f'{name} no longer has a scalar-only ABI')
    return type(name, (C.LittleEndianStructure,), {'_fields_': [(n,C.c_float if t=='float' else C.c_uint32) for t,n in fields]})


def validate(folder, source):
    folder = Path(folder)
    meta = json.loads((folder/'job.json').read_text())
    if meta.get('format') != FORMAT:
        raise ValueError('unsupported job version')
    allowed = {'format','sourceSHA256','shape','uniforms','steps','duration','startTime','axes','above','description','files','startStep','dataset','cooling','startupSteps'}
    if set(meta) - allowed:
        raise ValueError(f'unknown job fields: {set(meta)-allowed}')
    if meta['sourceSHA256'] != hashlib.sha256(source.encode()).hexdigest():
        raise ValueError('job and generated CUDA source hashes differ; regenerate both')
    dims = meta['shape']
    if len(dims)!=3 or any(type(x) is not int or x<1 or x>65536 for x in dims):
        raise ValueError('invalid grid shape')
    count = math.prod(dims)
    if count > 2**31-1:
        raise ValueError('grid exceeds signed shader index range')
    U = scalar_layout(source,'SolverUniforms')
    u = U(); u.nx,u.ny,u.nz=dims
    for key,value in meta['uniforms'].items():
        if key not in SUPPORTED:
            raise ValueError(f'unsupported uniform {key}; refusing rather than dropping a feature')
        if not isinstance(value,(int,float)) or not math.isfinite(value):
            raise ValueError(f'invalid uniform {key}')
        field_type=dict(U._fields_)[key]
        if field_type is C.c_uint32 and (type(value) is not int or not 0<=value<=2**32-1):
            raise ValueError(f'invalid integer uniform {key}')
        setattr(u,key,value)
        if not math.isfinite(float(getattr(u,key))):
            raise ValueError(f'uniform {key} overflows its wire type')
    if not (u.dx>0 and u.gamma>1 and 0<u.cfl<=0.5 and u.ambientPressure>=0
            and u.densityFloor>0 and u.pressureFloor>0 and 1<=u.limiterTheta<=2):
        raise ValueError('invalid physical/numerical bounds')
    if u.airModel not in (0,1,2) or u.riemannSolver not in (0,1):
        raise ValueError('unknown gas or Riemann solver')
    if u.boundaryFlags & 64 and (u.stillRho<=0 or u.stillEnergy<=0):
        raise ValueError('far-field boundaries require a physical ambient state')
    if u.boundaryFlags & ~127:
        raise ValueError('unknown boundary flags')
    if any(v<0 for v in (u.afterburnEnergy,u.afterburnRate,u.oxygenPerFuel,u.maxStep)):
        raise ValueError('negative afterburning or step parameter')
    if u.afterburnEnergy and (not u.afterburnRate or not u.oxygenPerFuel):
        raise ValueError('incomplete afterburning configuration')
    if type(meta['steps']) is not int or not 1<=meta['steps']<=10_000_000:
        raise ValueError('invalid step limit')
    if not math.isfinite(meta['duration']) or meta['duration']<=0:
        raise ValueError('invalid duration')
    if not math.isfinite(meta.get('startTime',0)) or meta.get('startTime',0)<0:
        raise ValueError('invalid start time')
    if type(meta.get('startStep',0)) is not int or meta.get('startStep',0)<0:
        raise ValueError('invalid initial step')
    if type(meta.get('startupSteps',1)) is not int or meta.get('startupSteps',1)<1:
        raise ValueError('invalid startup ramp')
    axes=meta['axes']
    if axes != [i for i,n in enumerate(dims) if n>1]:
        raise ValueError('axes must match non-degenerate grid dimensions')
    if not axes:
        raise ValueError('at least one dimension must be swept')
    if not 0<=meta.get('above',0)<dims[2]*u.dx:
        raise ValueError('sample height outside grid')
    sizes={'state.bin':count*20,'mask.bin':count,'species.bin':count*8,
           'peak.bin':count*4,'impulse.bin':count*4,'columns.bin':dims[0]*dims[1]*16,
           'records.bin':dims[0]*dims[1]*16,'open.bin':dims[0]*dims[1]*4}
    if set(meta.get('files',{})) != set(sizes):
        raise ValueError('job manifest must name every required buffer exactly')
    for name,size in sizes.items():
        data=(folder/name).read_bytes()
        if len(data)!=size or hashlib.sha256(data).hexdigest()!=meta['files'][name]:
            raise ValueError(f'buffer length/checksum mismatch: {name}')
    if 'cooling' in meta:
        cooling=meta['cooling']
        if set(cooling)!={'interval','luminous','absorption','sootAbsorption','hasSpecies','largestShare','luminousEnergy','capacity'}:
            raise ValueError('invalid cooling contract')
        if type(cooling['interval']) is not int or cooling['interval']<1 or cooling['capacity']!=0:
            raise ValueError('invalid cooling schedule or storage mode')
        if any(not isinstance(v,(int,float)) or not math.isfinite(v) or v<0 for v in cooling.values()):
            raise ValueError('invalid cooling coefficients')
        if not 0<cooling['largestShare']<=1 or cooling['hasSpecies'] not in (0,1):
            raise ValueError('invalid cooling limit/species flag')
    if 'dataset' in meta:
        if set(meta['dataset']) != {'inputs.npy','mask.npy','meta.json'}:
            raise ValueError('invalid dataset template manifest')
        for name,digest in meta['dataset'].items():
            if hashlib.sha256((folder/name).read_bytes()).hexdigest()!=digest:
                raise ValueError(f'dataset template checksum mismatch: {name}')
    return meta,u
