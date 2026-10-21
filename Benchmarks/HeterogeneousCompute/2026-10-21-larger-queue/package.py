import sys,json,hashlib,importlib.util,tarfile,shutil,statistics
from pathlib import Path
repo=Path.cwd();sys.path.insert(0,str(repo/'Scripts/cuda'));s=importlib.util.spec_from_file_location('q',repo/'Scripts/cuda/field-queue.py');q=importlib.util.module_from_spec(s);s.loader.exec_module(q)
root=Path('/Volumes/StudioData/bombcad/experiments/2026-10-21-larger-queue');dest=repo/'Benchmarks/HeterogeneousCompute/2026-10-21-larger-queue';dest.mkdir(exist_ok=True)
r=q.read(root/'study.json');assert r['status']=='complete' and len(r['calibration'])==48 and len(r['trials'])==9
for name in ['study.json','calibrated-costs.json','slope.asc']:shutil.copy2(root/name,dest/name)
for name in ['study.py','study.log','package.py']:shutil.copy2(Path('/private/tmp/bombcad-larger-queue')/name,dest/name)
audit={'status':'complete','executions':0,'workerGroups':[],'numericalHashes':{},'prediction':[]}
for row in [*r['calibration'],*r['trials']]:
 queue=Path(row['queue']);c=q.read(queue/'contract.json');q.verify_contract(c)
 for p in queue.glob('cases/*/attempts/*/process.json'):
  v=q.read(p);alive=q.tracked_alive(v);assert not alive;audit['workerGroups'].append(dict(pid=v['pid'],pgid=v['pgid'],alive=alive,processFile=str(p)))
 for j in c['jobs']:
  state=q.case_state(queue,c,j);assert state['status']=='accepted' and state['attempts']==1
  v=q.object_receipt(queue,state['object'],c,j);assert v['comparison']['passed'];audit['executions']+=1
  bucket=audit['numericalHashes'].setdefault(j['id'],{}).setdefault(v['backend'],{n:set() for n in ['inputs.npy','mask.npy','targets.npy']})
  for n in bucket:bucket[n].add(v['filesSHA256'][n])
 if row in r['trials']:
  states={j['key']:dict(status='pending',eligibleBackends=j['backends'],retryAfter=0,active=[]) for j in c['jobs']}
  proposals=q.plan_dispatch(c,states,row['before']['mac'],row['before']['pc'],now=0)
  audit['prediction'].append(dict(trial=row['name'],policy=row['policy'],predictedMakespanSeconds=max(x['estimatedFinishSeconds'] for x in proposals),controllerSeconds=row['controllerSeconds'],proposals=proposals,serialWorkerBodySumSeconds=sum(v['totalSecondsBeforePublication'] for v in row['receipts'].values())))
for by_backend in audit['numericalHashes'].values():
 for by_file in by_backend.values():
  for name,values in by_file.items():by_file[name]=sorted(values)
q.atomic(dest/'audit.json',audit);assert audit['executions']==120
for kind in ['cal','policy']:
 for repetition in range(3):
  with tarfile.open(dest/f'{kind}-{repetition}-state.tar.gz','w:gz') as archive:
   for p in sorted(root.glob(f'{kind}-{repetition}-*')):archive.add(p,arcname=p.name)
with tarfile.open(dest/'references.tar.gz','w:gz') as archive:
 for p in sorted(root.iterdir()):
  if '-reference' in p.name:archive.add(p,arcname=p.name)
print('Audited',audit['executions'],'executions and',len(audit['workerGroups']),'terminal groups')
print('Archive sizes',[(p.name,p.stat().st_size) for p in dest.glob('*.gz')])
