"""Post-stage audit; no GPU work. Preserve rejected gates as results, never admissions."""
from pathlib import Path
import importlib.util,json,sys,hashlib,math
repo=Path.cwd();sys.path.insert(0,str(repo/'Scripts/cuda'));s=importlib.util.spec_from_file_location('queue',repo/'Scripts/cuda/field-queue.py');q=importlib.util.module_from_spec(s);s.loader.exec_module(q)
from job import validate
root=Path('/Volumes/StudioData/bombcad/experiments/2026-10-21-distinct-queue');r=q.read(root/'stage.json');assert r['status']=='complete' and r['allStartedCommandGroupsTerminal'];assert len(r['cases'])==3 and r['fixedMassesKg']==[100400,200800,301200]
for n,h in r['filesSHA256'].items():assert q.digest(n)==h,n
for c in r['commands']:assert c['returncode']==0 and not q.group_alive(c['pgid']),c
source=(root/'solver.cu').read_text();assert hashlib.sha256(source.encode()).hexdigest()==r['sourceSHA256']
rows=[];count=0;total=0
for c in r['cases']:
 base=root/c['id'];args=c['arguments'];assert float(args[args.index('--mass')+1])==c['massKg'];assert float(args[args.index('--height')+1])==236;assert float(args[args.index('--until')+1])==4.51
 ref=base/'reference';obs=base/'observed-reference';out=base/'cuda';data=out/'dataset'
 for folder,record in [(ref,c['reference']['filesSHA256']),(data,c['cudaDatasetSHA256'])]:
  assert {n:q.digest(folder/n) for n in q.DATA_FILES}==record
  for n in ['inputs.npy','mask.npy','targets.npy']:
   shape,values=q.npy(folder/n);assert all(math.isfinite(v) for v in values)
   if n=='mask.npy':assert all(v in (0,1) for v in values)
  count+=len(record);total+=sum((folder/n).stat().st_size for n in record)
 assert all(q.digest(ref/n)==q.digest(obs/n) for n in ['inputs.npy','mask.npy','targets.npy'])
 gate=q.compare(ref,data);assert gate==c['gate'];assert c['reference']['meta']['stable']
 assert c['cudaResult']['sourceSHA256']==r['sourceSHA256'];assert c['cudaResult']['workerFilesSHA256']=={n:q.digest(repo/'Scripts/cuda'/n) for n in ['run.py','job.py','compile.py']}
 a,_=validate(base/'initial',source);b,_=validate(base/'prepared',source)
 assert c['initialMatchesPrepared'] and c['physicalInitialIdentity']=={k:b.get(k) for k in c['physicalInitialIdentity']}=={k:a.get(k) for k in c['physicalInitialIdentity']}
 shape,reference_values=q.npy(ref/'targets.npy');_,candidate_values=q.npy(data/'targets.npy');_,mask=q.npy(ref/'mask.npy');plane=math.prod(shape[1:]);failures=[]
 for channel in range(shape[0]):
  channel_failures=[]
  for i,valid in enumerate(mask):
   if not valid:continue
   a=reference_values[channel*plane+i];b=candidate_values[channel*plane+i];tolerance=.05+.002*abs(a)
   if abs(a-b)>tolerance:channel_failures.append(dict(channel=channel,column=i,row=i//shape[2],x=i%shape[2],reference=a,candidate=b,absoluteError=abs(a-b),tolerance=tolerance,referenceTargets=[reference_values[j*plane+i] for j in range(shape[0])],candidateTargets=[candidate_values[j*plane+i] for j in range(shape[0])]))
  assert len(channel_failures)==gate[str(channel)]['outsideTolerance'];failures+=channel_failures
 rows.append(dict(id=c['id'],massKg=c['massKg'],unchangedGate=gate,failedTargets=failures,initialBuffersMatch=True,observerArraysBitIdentical=True))
assert len({c['reference']['filesSHA256']['targets.npy'] for c in r['cases']})==3
assert len({c['cudaDatasetSHA256']['targets.npy'] for c in r['cases']})==3
report=dict(status='complete',allStartedCommandsTerminal=True,commandCount=len(r['commands']),datasetFileInstancesVerified=count,datasetBytesVerified=total,allThreePhysicalCasesDistinct=True,allUnchangedGatesPass=all(c['unchangedGate']['passed'] for c in rows),cases=rows,scope=__doc__)
q.atomic(root/'audit.json',report);print(json.dumps(report,indent=2))
