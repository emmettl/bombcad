"""One CPU-only nonlinear reference run. All modes share the same prescribed step sequence."""
from pathlib import Path
import hashlib,json,sys,time
import numpy as np
from planar_euler import primitive,conserved,advance

input_path=Path(sys.argv[1]);mode=sys.argv[2];out=Path(sys.argv[3]);out.mkdir(exist_ok=False)
meta=json.loads(input_path.with_suffix('.json').read_text());inputs=np.load(input_path)
dtype=np.float32 if mode=='float32-retained' else np.float64
gamma=float(np.float32(meta['gamma']))
state=inputs['initial'].astype(dtype);dt=inputs['dt'].astype(np.float32)
if mode=='float64-analytic':
 gamma=1.4;x=(np.arange(meta['nx'])+.5)*meta['dx'];s=x-8;c=np.sqrt(1.4*101325/1.225)
 perturb=np.where(np.abs(s)<1,-meta['amplitudePa']*np.sin(np.pi*s),0)
 rho=1.225+perturb/c**2;u=-perturb/(1.225*c)
 state=conserved(np.stack((rho,u,101325+perturb),axis=1),gamma)
indices=inputs['indices'];history=[primitive(state,gamma)[indices,2].astype(np.float64)-101325]
start=np.sum(state,axis=0,dtype=np.float64)*meta['dx'];boundary=np.zeros(3)
stats={k:np.zeros(3,dtype=np.int64 if k in ['nonzero','absorbed'] else np.float64) for k in ['nonzero','absorbed','absIncrement','absAbsorbed']}
fallback=0;clock=time.monotonic();status='running';error=None;completed=0
np.seterr(over='raise',invalid='raise',divide='raise',under='ignore')
try:
 for completed,step in enumerate(dt[1:],1):
  state,row=advance(state,float(step),meta['dx'],gamma)
  for k in stats:stats[k]+=row[k]
  fallback+=row['reconstructionFallback'];boundary+=row['boundaryFlux']
  history.append(primitive(state,gamma)[indices,2].astype(np.float64)-101325)
 status='complete'
except BaseException as exc:
 status='failed';error=repr(exc)
finally:
 final=np.sum(state,axis=0,dtype=np.float64)*meta['dx']
 np.savez_compressed(out/'arrays.npz',pressurePa=np.asarray(history),finalState=state,times=np.cumsum(dt[:len(history)],dtype=np.float64))
 report=dict(status=status,error=error,mode=mode,dtype=str(state.dtype),gamma=gamma,completedSteps=len(history)-1,requestedSteps=len(dt)-1,seconds=time.monotonic()-clock,initialTotalsPerArea=start.tolist(),finalTotalsPerArea=final.tolist(),boundaryIntegralPerArea=boundary.tolist(),balanceResidualPerArea=(final-start+boundary).tolist(),updateDiagnostics={k:v.tolist() for k,v in stats.items()},reconstructionFallback=fallback,inputSHA256=hashlib.sha256(input_path.read_bytes()).hexdigest(),arraySHA256=hashlib.sha256((out/'arrays.npz').read_bytes()).hexdigest(),scope='Independent nonlinear Euler model, not GPU arithmetic replay; absolute absorbed increments are diagnostics, not physical dissipation.')
 (out/'result.json').write_text(json.dumps(report,indent=2)+'\n')
if status!='complete':raise RuntimeError(error)
