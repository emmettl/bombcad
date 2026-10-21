"""Read-only mixed-precision Euler audit. No numerical gate or GPU replay claim."""
from pathlib import Path
import hashlib,json,math,os
import numpy as np
here=Path(__file__).resolve().parent;repo=Path.cwd();root=Path(os.environ.get('BOMBCAD_DATA','/Volumes/StudioData/bombcad'))/'experiments/2026-10-22-mixed-precision'
run=json.loads((root/'run.json').read_text());assert run['status']=='complete' and not run['live'] and len(run['jobs'])==72
for name,pin in run['retainedFiles'].items():
 p=root/name;assert p.stat().st_size==pin['bytes'] and hashlib.sha256(p.read_bytes()).hexdigest()==pin['sha256'],name
for pin in run['sources']:assert hashlib.sha256(Path(pin['frozen']).read_bytes()).hexdigest()==pin['sha256']
previous=json.loads((repo/'Benchmarks/CUDAAcceptance/2026-10-22-acoustic-controls/results.json').read_text())
def phase(p,dt):
 peak=max(0.,float(np.max(p)));impulse=0.;risen=False;closing=None
 for i,(v,w) in enumerate(zip(p,dt)):
  if peak>0 and v>=.5*peak:risen=True
  if risen and v<0:closing=i;break
  impulse+=max(float(v),0)*float(w)
 return dict(peak=peak,impulse=impulse,closingSample=closing)
old_stage=repo/'Benchmarks/CUDAAcceptance/2026-10-22-euler-precision'
old_report=json.loads((old_stage/'results.json').read_text())
old_root=Path('/Volumes/StudioData/bombcad/experiments/2026-10-22-euler-precision')
baselines=[]
rows=[]
for job in run['jobs']:
 assert job['returncode']==0
 out=Path(job['output']);meta=json.loads(Path(job['input']).with_suffix('.json').read_text());result=json.loads((out/'result.json').read_text());assert result['status']=='complete' and result['completedSteps']==result['requestedSteps']
 assert result['inputSHA256']==hashlib.sha256(Path(job['input']).read_bytes()).hexdigest()
 assert result['arraySHA256']==hashlib.sha256((out/'arrays.npz').read_bytes()).hexdigest()
 with np.load(out/'arrays.npz') as data:pressure=data['pressurePa'];common=data['commonDoublePressurePa'];times=data['times'];state=data['finalState']
 if job['mode'] in ['s32-e32','s64-e64']:
  old_mode='float32-retained' if job['mode']=='s32-e32' else 'float64-retained'
  old_folder=old_root/'outputs'/(job['label']+'-'+old_mode)
  for name in ['arrays.npz','result.json']:
   pin=old_report['rawReceipt']['retainedFiles'][str((old_folder/name).relative_to(old_root))]
   assert hashlib.sha256((old_folder/name).read_bytes()).hexdigest()==pin['sha256']
  with np.load(old_folder/'arrays.npz') as data:
   equality={k:v.dtype==data[k].dtype and v.shape==data[k].shape and v.tobytes()==data[k].tobytes() for k,v in [('pressurePa',pressure),('times',times),('finalState',state)]}
  old_result=json.loads((old_folder/'result.json').read_text())
  equality.update({k:result[k]==old_result[k] for k in ['completedSteps','gamma','updateDiagnostics','initialTotalsPerArea','finalTotalsPerArea','boundaryIntegralPerArea','balanceResidualPerArea','reconstructionFallback']})
  baselines.append(dict(case=job['label'],mode=job['mode'],exact=equality))
 with np.load(job['input']) as data:dt=data['dt'];x=data['x'];metal=data['metalPressurePa'];metal_times=data['metalTimes'];indices=data['indices']
 assert np.isfinite(common).all() and common.shape==pressure.shape and np.isfinite(pressure).all() and np.isfinite(state).all() and pressure.shape==metal.shape==(len(dt),2) and np.all(np.diff(times)>0)
 assert len(dt)-1==result['completedSteps'] and state.shape==(meta['nx'],3)
 c=math.sqrt(1.4*101325/1.225);a=meta['amplitudePa']
 for q,position in enumerate(x):
  p=pressure[:,q];summary=phase(p,dt);common_summary=phase(common[:,q],dt);reference=np.zeros(len(times))
  for shift in [position+c*times-8,c*times-position-8]:reference+=np.where(np.abs(shift)<1,-a*np.sin(math.pi*shift),0)
  nominal=phase(reference,dt);expected=meta['analyticImpulse'][q]
  old=next(v for v in previous['columns'] if v['matrix']=='default-cfl'+meta['cfl'] and v['amplitudePa']==a and v['nx']==meta['nx'] and not v['tiled'] and v['column']==int(indices[q]))
  rows.append(dict(case=job['label'],mode=job['mode'],amplitudePa=a,nx=meta['nx'],cfl=meta['cfl'],column=int(indices[q]),x=float(position),steps=result['completedSteps'],gamma=result['gamma'],model=summary,commonDouble=common_summary,commonImpulseRelativeError=common_summary['impulse']/meta['analyticImpulse'][q]-1,commonPeakRelativeError=common_summary['peak']/meta['analyticPeak'][q]-1,readoutDifferenceLinf=float(np.max(np.abs(p-common[:,q]))),analyticImpulse=expected,analyticPeak=meta['analyticPeak'][q],impulseRelativeError=summary['impulse']/expected-1,peakRelativeError=summary['peak']/meta['analyticPeak'][q]-1,nominalSampled=nominal,closingTime=float(times[summary['closingSample']]) if summary['closingSample'] is not None else None,pressureErrorLinf=float(np.max(np.abs(p-reference))),modelMinusMetalPressureLinf=float(np.max(np.abs(p-metal[:,q]))),clockDifferenceToMetal=float(np.max(np.abs(times-metal_times))),metalImpulseRelativeError=old['streamingRelativeError'],metalPeakRelativeError=old['peakRelativeError'],updateDiagnostics=result['updateDiagnostics'],balanceResidualPerArea=result['balanceResidualPerArea'],initialTotalsPerArea=result['initialTotalsPerArea'],reconstructionFallback=result['reconstructionFallback']))
assert len(rows)==144 and len(baselines)==36
pin_paths=[Path(__file__).resolve(),repo/'Scripts/reference/planar_euler.py',repo/'Scripts/reference/test-planar-euler.py']
report=dict(status='complete',scope=__doc__,runs=72,receiverHistories=144,unclosedNativeHistories=sum(x['model']['closingSample'] is None for x in rows),unclosedCommonHistories=sum(x['commonDouble']['closingSample'] is None for x in rows),noPositiveNativeHistories=sum(x['model']['peak']<=0 for x in rows),baselines=baselines,allBaselineExact=all(all(x['exact'].values()) for x in baselines),allClosed=all(x['model']['closingSample'] is not None and x['commonDouble']['closingSample'] is not None for x in rows),fallbacks=sum(json.loads((Path(j['output'])/'result.json').read_text())['reconstructionFallback'] for j in run['jobs']),rows=rows,sourceSHA256={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in pin_paths},rawReceipt=run,limits='Independent vectorized NumPy Euler scheme, not a GPU bit/instruction replay, exact PDE solution, full nonlinear error bound or production/default/admission change.')
(here/'results.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({k:v for k,v in report.items() if k not in ['rows','sourceSHA256','rawReceipt','baselines']},indent=2))
for x in rows:
 if x['column']==0:
  d=x['updateDiagnostics'];print(x['case'],x['mode'],'wall native I%',100*x['impulseRelativeError'],'common I%',100*x['commonImpulseRelativeError'],'peak%',100*x['peakRelativeError'],'energy absorbed counts',d['absorbed'][2],'abs absorbed dE',d['absAbsorbed'][2])
