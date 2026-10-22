"""Read-only parity-gated audit of actual GPU sweep variables; arithmetic models are not instructions."""
from pathlib import Path
import hashlib,importlib.util,json,os,sys
import numpy as np
repo=Path.cwd();here=Path(__file__).resolve().parent
sys.path.insert(0,str(repo/'Scripts/cuda'))
spec=importlib.util.spec_from_file_location('phase',repo/'Scripts/cuda/diagnose-phase.py');phase=importlib.util.module_from_spec(spec);spec.loader.exec_module(phase)
root=Path(os.environ.get('BOMBCAD_DATA','/Volumes/StudioData/bombcad'))/'experiments/2026-10-22-gpu-updates'
run=json.loads((root/'run.json').read_text());assert run['status']=='complete' and 'liveProcess' not in run
assert len(run['commands'])==2 and all(x['returncode']==0 for x in run['commands'])
for name,pin in run['retainedFiles'].items():
 p=root/name;assert p.stat().st_size==pin['bytes'] and hashlib.sha256(p.read_bytes()).hexdigest()==pin['sha256'],name
for pin in run['frozenSources']:assert hashlib.sha256(Path(pin['path']).read_bytes()).hexdigest()==pin['sha256']
old=json.loads((repo/'Benchmarks/CUDAAcceptance/2026-10-22-acoustic-controls/results.json').read_text())
oldroot=Path('/Volumes/StudioData/bombcad/experiments/2026-10-22-acoustic-controls')
fields=['oldRho','oldMx','oldMy','oldMz','oldEnergy','newRho','newMx','newMy','newMz','newEnergy','lowMass','lowMx','lowMy','lowMz','lowEnergy','highMass','highMx','highMy','highMz','highEnergy','lambda','dt','axis','batchActiveStep']
def load(p):return json.loads(p.read_text())
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
rows=[];numeric_runs=0
for command in run['commands']:
 label=command['label'];folder=root/label
 for a in [1,10,100]:
  for nx in [512,1024,2048]:
   for tiled in [False,True]:
    name=f'a{a}-n{nx}-'+('tiled' if tiled else 'full')
    snapshots=[load(folder/(name+'-'+mode+'.json')) for mode in ['plain','observed','updates']]
    assert all(x['stable'] for x in snapshots);numeric_runs+=3
    keys=['steps','time','initialHashes','finalHashes','records','initialConservedRhoMxEnergy','initialHostProjectedOverpressurePa']
    parity={k:all(snapshots[0][k]==x[k] for x in snapshots[1:]) for k in keys}
    previous={}
    for suffix in ['-plain.json','-observed.json','-trace.json']:
     path=oldroot/label/(name+suffix);pin=old['rawReceipt']['retainedFiles'][str(path.relative_to(oldroot))];assert sha(path)==pin['sha256']
     previous[suffix]=load(path)
    baseline={mode:all(snapshots[q][k]==previous['-'+mode+'.json'][k] for k in keys) for q,mode in enumerate(['plain','observed'])}
    pressure_file=folder/(name+'-trace.json');update_pressure_file=folder/(name+'-update-pressure-trace.json')
    pressure_parity=sha(pressure_file)==sha(update_pressure_file)
    baseline_pressure=sha(pressure_file)==old['rawReceipt']['retainedFiles'][str((oldroot/label/(name+'-trace.json')).relative_to(oldroot))]['sha256']
    pressure=load(update_pressure_file);trace=load(folder/(name+'-update-trace.json'))
    assert trace['format']=='bombcad-production-sweep-updates-1' and trace['complete'] and trace['fields']==fields and trace['valueEncoding']=='uint32-ieee754-binary32'
    assert trace['steps']==list(range(1,snapshots[2]['steps']+1)) and trace['times']==pressure['times'][1:]
    words=np.asarray(trace['valueBits'],dtype=np.uint32);v=words.view(np.float32)
    executed=np.asarray(trace['executed'],dtype=bool);indices=trace['indices'];n=len(trace['steps']);m=len(indices)
    assert words.shape==(n,m,24) and executed.shape==(n,m) and np.isfinite(v).all()
    assert m==5 and len(set(indices))==m and indices==[0,nx//4,nx//2-1,nx//2,nx//2+1]
    initial=np.asarray(trace['initialStateBits'],dtype=np.uint32);final=np.asarray(trace['finalStateBits'],dtype=np.uint32)
    assert initial.shape==final.shape==(m,5)
    known=initial.copy();discontinuities=0
    for step in range(n):
     active=executed[step]
     discontinuities+=int(np.count_nonzero(words[step,active,:5]!=known[active]))
     known[active]=words[step,active,5:10]
     assert np.all(words[step,~active]==0), 'skipped slots must not contain stale/fabricated states'
    final_matches=bool(np.array_equal(known,final))
    active_values=v[executed];active_words=words[executed]
    assert np.all(active_values[:,22]==0) and np.all(active_values[:,21]>0) and np.all(active_values[:,23]>=1) and np.all(active_values[:,23]<=256)
    dt=np.asarray(trace['dt'],dtype=np.float32)
    assert np.all(dt>0) and np.all(v[:,:,21][executed]==np.broadcast_to(dt[:,None],(n,m))[executed])
    delta=active_values[:,20,None]*(active_values[:,15:20]-active_values[:,10:15])
    separate=active_values[:,:5]-delta
    difference=active_values[:,15:20]-active_values[:,10:15]
    fused=np.fromiter((phase.fused_sum(-float(l),float(d),float(o)) for l,row,oldrow in zip(active_values[:,20],difference,active_values[:,:5]) for d,o in zip(row,oldrow)),dtype=np.float32,count=len(active_values)*5).reshape(-1,5)
    actual=active_words[:,5:10]
    models={name:dict(differentByComponent=np.count_nonzero(candidate.view(np.uint32)!=actual,axis=0).tolist(),different=int(np.count_nonzero(candidate.view(np.uint32)!=actual))) for name,candidate in [('separate',separate),('fused',fused)]}
    policies=[name for name,model in models.items() if model['different']==0]
    cells=[]
    for q,index in enumerate(indices):
     valid=executed[:,q];values=v[valid,q];bits=words[valid,q]
     differences=values[:,15:20]-values[:,10:15];increments=values[:,20,None]*differences
     nonzero=increments!=0;unchanged=bits[:,:5]==bits[:,5:10];absorbed=nonzero&unchanged
     cells.append(dict(index=index,executed=int(np.count_nonzero(valid)),skipped=int(n-np.count_nonzero(valid)),nonzeroModeledIncrement=np.count_nonzero(nonzero,axis=0).tolist(),observedUnchangedWithNonzeroModeledIncrement=np.count_nonzero(absorbed,axis=0).tolist(),sumAbsoluteModeledIncrement=np.sum(np.abs(increments),axis=0,dtype=np.float64).tolist(),sumAbsoluteUnchangedModeledIncrement=np.sum(np.where(absorbed,np.abs(increments),0),axis=0,dtype=np.float64).tolist()))
    parity_valid=all(parity.values()) and all(baseline.values()) and pressure_parity and baseline_pressure
    rows.append(dict(case=name,matrix=label,amplitudePa=a,nx=nx,tiled=tiled,steps=n,parity=parity,baseline=baseline,pressureTraceBytesIdentical=pressure_parity,baselinePressureTraceBytesIdentical=baseline_pressure,eligibleAsOrdinaryRunObservation=parity_valid,prePostDiscontinuities=discontinuities,finalSelectedStatesMatch=final_matches,arithmeticModels=models,wholeTraceCompatibleUpdatePolicies=policies,cells=cells,interpretation='Only parity-eligible cases can represent ordinary runs; modeled increment counters do not attest emitted instructions or physical dissipation.'))
assert numeric_runs==108 and len(rows)==36
pins=[Path(__file__).resolve(),repo/'Scripts/cuda/diagnose-phase.py',repo/'Scripts/cuda/compare_dataset.py',repo/'Scripts/cuda/trace_columns.py']
report=dict(status='complete',scope=__doc__,numericalRuns=numeric_runs,cases=len(rows),allOrdinaryObservationParity=all(x['eligibleAsOrdinaryRunObservation'] for x in rows),allContinuity=all(x['prePostDiscontinuities']==0 and x['finalSelectedStatesMatch'] for x in rows),allWholeTraceArithmeticCompatible=all(x['wholeTraceCompatibleUpdatePolicies'] for x in rows),rows=rows,sourceSHA256={str(p):sha(p) for p in pins},rawReceipt=run,limits='Actual stored variables in observed 1-D ideal-gas sweeps under explicit parity gates, not a GPU instruction/Float64 truth attestation, broad product/CUDA validation or a changed target policy.')
(here/'results.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({k:v for k,v in report.items() if k not in ['rows','sourceSHA256','rawReceipt']},indent=2))
for row in rows:print(row['matrix'],row['case'],'parity',row['eligibleAsOrdinaryRunObservation'],'update policies',row['wholeTraceCompatibleUpdatePolicies'],'energy counts',[(c['index'],c['observedUnchangedWithNonzeroModeledIncrement'][4],c['nonzeroModeledIncrement'][4]) for c in row['cells']])
