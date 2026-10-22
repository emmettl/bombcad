"""Draft Float64 retained-state/timestep oracle worker; no GPU or default mutation."""
import importlib.util
import json
from pathlib import Path
import sys
import numpy as np


def execute(engine_path,input_path,output_path,metadata_path):
    spec=importlib.util.spec_from_file_location('euler',engine_path)
    engine=importlib.util.module_from_spec(spec);spec.loader.exec_module(engine)
    with np.load(input_path,allow_pickle=False) as source:
        initial=source['initial'].copy();dt=source['dt'].copy();clock=source['clock'].copy()
        indices=source['indices'].copy();gamma=float(source['gamma']);dx=float(source['dx'])
    if initial.dtype!=np.float32 or dt.dtype!=np.float32 or clock.dtype!=np.float64:
        raise ValueError('retained Float32 state/dt and Float64 observed clock required')
    if initial.ndim!=2 or initial.shape[1]!=3 or len(clock)!=len(dt)+1 or not np.all(dt>0):
        raise ValueError('invalid state/clock/timestep shape')
    if not (np.isfinite(initial).all() and np.isfinite(dt).all() and np.isfinite(clock).all()):
        raise ValueError('nonfinite input')
    if gamma!=float(np.float32(gamma)) or dx<=0 or not np.all(np.diff(clock)>0):
        raise ValueError('exact retained gamma and increasing recorded clock required')
    if not (np.issubdtype(indices.dtype,np.integer) and np.all(indices>=0) and np.all(indices<len(initial))):
        raise ValueError('invalid receiver indices')
    state=initial.astype(np.float64)
    begin=state.sum(axis=0,dtype=np.float64)*dx
    cumulative=np.zeros(3,dtype=np.float64)
    boundary=np.zeros((len(dt),3),dtype=np.float64)
    totals=np.empty((len(clock),3),dtype=np.float64);totals[0]=begin
    pressure=np.empty((len(clock),len(indices)),dtype=np.float64)
    pressure[0]=engine.primitive(state,gamma)[indices,2]-101325
    maximum=np.zeros(3,dtype=np.float64);fallbacks=0
    changes=np.zeros((len(clock),3),dtype=np.float64)
    for step,width in enumerate(dt):
        previous=state
        state,stats=engine.advance(state,float(width),dx,gamma)
        changes[step+1]=changes[step]+np.sum(state-previous,axis=0,dtype=np.float64)*dx
        boundary[step]=stats['boundaryFlux'];cumulative+=boundary[step]
        totals[step+1]=state.sum(axis=0,dtype=np.float64)*dx
        maximum=np.maximum(maximum,np.abs(changes[step+1]+cumulative))
        fallbacks+=stats['reconstructionFallback']
        pressure[step+1]=engine.primitive(state,gamma)[indices,2]-101325
    physical=np.r_[0.,np.cumsum(dt.astype(np.float64))]
    lag=physical-clock
    np.savez_compressed(output_path,initial=initial,final=state,dt=dt,recordedClock=clock,
        timestepSumTime=physical,indices=indices,pressure=pressure,totals=totals,storedChangeFromSteps=changes,boundaryFluxIntegral=boundary)
    report=dict(status='complete',steps=len(dt),nx=len(initial),gamma=gamma,dx=dx,
        maximumAbsoluteClockLagS=float(np.max(np.abs(lag))),finalTimestepSumMinusRecordedClockS=float(lag[-1]),
        maximumAbsoluteBoundaryBalancedResidual=maximum.tolist(),
        finalBoundaryBalancedResidual=(changes[-1]+cumulative).tolist(),
        conservationNormalization='unit transverse area; kg/m^2, Pa s, J/m^2; per-step stored changes summed before background cancellation',
        reconstructionFallbacks=fallbacks,
        minimumFinalDensity=float(state[:,0].min()),minimumFinalPressure=float(engine.primitive(state,gamma)[:,2].min()),
        scope='Independent nonlinear Float64 Euler, exact retained Float32 initial state/gamma/dt. Output is paired to the actual supplied timestep sequence; separate dt-sum and recorded-clock axes are retained. Not GPU arithmetic replay, exact finite-amplitude PDE truth or an interpolation/extrapolation to unrelated steps.')
    Path(metadata_path).write_text(json.dumps(report,indent=2)+'\n')
    return report


if __name__=='__main__':execute(*sys.argv[1:])
