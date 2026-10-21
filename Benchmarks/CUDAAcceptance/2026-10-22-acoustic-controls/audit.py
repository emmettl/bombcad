"""All-outcome CPU audit of the predeclared fine-resolution/arithmetic/CFL controls."""
from pathlib import Path
import array,gzip,hashlib,importlib.util,json,math,os,sys
from characteristics import split,pressure_at
repo=Path.cwd();here=Path(__file__).resolve().parent
sys.path.insert(0,str(repo/'Scripts/cuda'))
spec=importlib.util.spec_from_file_location('phase',repo/'Scripts/cuda/diagnose-phase.py');phase=importlib.util.module_from_spec(spec);spec.loader.exec_module(phase)
root=Path(os.environ.get('BOMBCAD_DATA','/Volumes/StudioData/bombcad'))/'experiments/2026-10-22-acoustic-controls'
run=json.loads((root/'run.json').read_text());assert run['status']=='complete' and 'liveProcess' not in run
assert len(run['commands'])==4 and all(x['returncode']==0 for x in run['commands'])
for name,pin in run['retainedFiles'].items():
 p=root/name;assert p.stat().st_size==pin['bytes'] and hashlib.sha256(p.read_bytes()).hexdigest()==pin['sha256'],name
for p in run['frozenSources']:assert hashlib.sha256(Path(p['path']).read_bytes()).hexdigest()==p['sha256']
def whole(p,dt):
 peak=max([0.]+p);total=0.;risen=False;closing=None
 for i,(v,w) in enumerate(zip(p,dt)):
  if peak>0 and v>=.5*peak:risen=True
  if risen and v<0:closing=i;break
  total+=max(v,0)*w
 return dict(impulse=total,closingSample=closing,peak=peak)
def streaming(p,dt):
 peak=total=selected=phase_peak=0.;opened=False;closing=None
 for i,(v,w) in enumerate(zip(p,dt)):
  total+=max(v,0)*w;peak=max(peak,v)
  if opened:
   if v<0:opened=False;closing=i
   else:selected=total;phase_peak=max(phase_peak,v)
  if v>0 and phase_peak<.5*peak:selected=total;phase_peak=v;opened=True;closing=None
 return dict(impulse=selected,closingSample=closing)
def read(path):return json.loads(path.read_text())
rows=[];pairs=[];baseline=[]
for item in run['commands']:
 label=item['label'];folder=root/label
 for a in [1,10,100]:
  for nx in [512,1024,2048]:
   pair_modes=[]
   for tiled in [False,True]:
    name=f'a{a}-n{nx}-'+('tiled' if tiled else 'full')
    plain=read(folder/(name+'-plain.json'));observed=read(folder/(name+'-observed.json'));trace=read(folder/(name+'-trace.json'))
    assert trace['complete'] and plain['stable'] and observed['stable']
    assert trace['steps']==list(range(observed['steps']+1)) and len(trace['values'])==len(trace['times'])==len(trace['steps'])
    assert all(b>a for a,b in zip(trace['times'],trace['times'][1:]))
    assert all(len(v)==2 and all(len(w)==8 and all(math.isfinite(z) for z in w) for w in v) for v in trace['values'])
    values=[[[phase.f32(z) for z in v] for v in row] for row in trace['values']]
    assert all(v[6]==0 for v in values[0]) and all(v[6]>0 for row in values[1:] for v in row)
    meta=dict(format='bombcad-production-pressure-trace-1',columns=trace['columns'],times=trace['times'],seedRecords=[[phase.f32(z) for z in row] for row in trace['seedRecords']],fields=phase.FIELDS)
    replay=phase.summarize(meta,array.array('f',[z for row in values for v in row for z in v]))
    parity={k:plain[k]==observed[k] for k in ['steps','time','initialHashes','finalHashes','records','initialConservedRhoMxEnergy','initialHostProjectedOverpressurePa']}
    pair_modes.append(plain)
    if label=='default-cfl0.45' and nx==512:
     previous=repo/'Benchmarks/CUDAAcceptance/2026-10-22-weak-acoustic/evidence/matrix'
     for mode,current in [('plain',plain),('observed',observed)]:
      old=json.loads(gzip.decompress((previous/(name+'-'+mode+'.json.gz')).read_bytes()))
      baseline.append(dict(case=name,mode=mode,same=all(old[k]==current[k] for k in ['steps','time','initialHashes','finalHashes','records','initialHostProjectedOverpressurePa'])))
     old=json.loads(gzip.decompress((previous/(name+'-trace.json.gz')).read_bytes()))
     baseline.append(dict(case=name,mode='pressure-history',same=all(old[k]==trace[k] for k in ['steps','times','values','seedRecords','columns','x'])))
    conserved=[[phase.f32(z) for z in v] for v in plain['initialConservedRhoMxEnergy']]
    velocity=[mx/rho for rho,mx,e in conserved]
    gamma=phase.f32(plain['gamma']);host=[phase.f32(z) for z in plain['initialHostProjectedOverpressurePa']]
    reconstructed=[(gamma-1)*(e-.5*mx*mx/rho)-101325 for rho,mx,e in conserved]
    c=trace['soundSpeed'];dx=trace['dx'];times=trace['times']
    models={k:split(p,velocity,1.225,c) for k,p in [('hostProjected',host),('conservedDouble',reconstructed)]}
    for q,(column,x) in enumerate(zip(trace['columns'],trace['x'])):
     data=[v[q] for v in values];p=[v[0] for v in data];dt=[v[6] for v in data]
     nominal=[sum(-a*math.sin(math.pi*s) if abs(s)<1 else 0 for s in [x+c*t-8,c*t-x-8]) for t in times]
     references={}
     for key,parts in models.items():
      projected=[pressure_at(parts,dx,c,x,t) for t in times]
      references[key]=dict(**whole(projected,dt),measuredPressureLinf=max(abs(v-w) for v,w in zip(p,projected)),initialPressureLinf=max(abs(v-w) for v,w in zip(host if key=='hostProjected' else reconstructed,[(-a*math.sin(math.pi*s) if abs(s)<1 else 0) for s in [(i+.5)*dx-8 for i in range(nx)]])))
     offline=whole(p,dt);expected=trace['analyticFirstImpulse'][q]
     rows.append(dict(matrix=label,amplitudePa=a,nx=nx,tiled=tiled,column=column,x=x,steps=observed['steps'],time=observed['time'],dtSumMinusClock=math.fsum(dt)-times[-1],observationParity=parity,exactReplayPolicies=replay['columns'][q]['exactAccumulationPolicies'],analyticPeak=trace['analyticPeak'][q],measuredPeak=data[-1][1],peakRelativeError=data[-1][1]/trace['analyticPeak'][q]-1,analyticImpulse=expected,measuredStreamingImpulse=data[-1][3],streamingRelativeError=data[-1][3]/expected-1,offline=offline,closingTime=times[offline['closingSample']] if offline['closingSample'] is not None else None,analyticFirstZeroTime=(8-x if x>=1 else 8)/c,closingTimeErrorS=times[offline['closingSample']]-(8-x if x>=1 else 8)/c if offline['closingSample'] is not None else None,streamingDouble=streaming(p,dt),nativeMinusDoubleStreamingImpulse=data[-1][3]-streaming(p,dt)['impulse'],nominalSampled=whole(nominal,dt),projectedReferences=references,finalOpen=data[-1][5],negativeSamples=sum(v<0 for v in p)))
   pairs.append(dict(matrix=label,amplitudePa=a,nx=nx,same=all(pair_modes[0][k]==pair_modes[1][k] for k in ['steps','time','initialHashes','finalHashes','records','initialConservedRhoMxEnergy','initialHostProjectedOverpressurePa'])))
assert len(rows)==144 and len(baseline)==18 and len(pairs)==36
sources=[Path(__file__).resolve(),here/'characteristics.py',here/'test_characteristics.py',repo/'Scripts/cuda/diagnose-phase.py',repo/'Scripts/cuda/trace_columns.py',repo/'Scripts/cuda/compare_dataset.py']
report=dict(semanticMismatchColumns=sum(x['offline']['impulse']!=x['streamingDouble']['impulse'] or x['offline']['closingSample']!=x['streamingDouble']['closingSample'] for x in rows),status='complete',scope=__doc__,allObservationParity=all(all(x['observationParity'].values()) for x in rows),allTiledFullParity=all(x['same'] for x in pairs),allBaselineParity=all(x['same'] for x in baseline),allReplay=all(x['exactReplayPolicies'] for x in rows),allClosed=all(x['offline']['closingSample'] is not None and x['finalOpen']==0 for x in rows),columns=rows,tiledFullPairs=pairs,baseline=baseline,sourceSHA256={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},rawReceipt=run,limits='Linear characteristic transport of two declared initial-state projections, not a nonlinear Double Euler calculation, CUDA validation, hot-air/terrain validation or a selected numerical policy.')
(here/'results.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({k:v for k,v in report.items() if k not in ['columns','rawReceipt','tiledFullPairs','sourceSHA256','baseline']},indent=2))
for x in rows:
 if not x['tiled']:print(x['matrix'],x['amplitudePa'],x['nx'],x['column'],'peak%',100*x['peakRelativeError'],'I%',100*x['streamingRelativeError'])
