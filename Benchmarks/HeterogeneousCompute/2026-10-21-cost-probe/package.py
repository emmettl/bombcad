import importlib.util,json,sys,tarfile,shutil,statistics,hashlib,platform
from pathlib import Path
repo=Path.cwd();sys.path.insert(0,str(repo/'Scripts/cuda'));s=importlib.util.spec_from_file_location('q',repo/'Scripts/cuda/field-queue.py');q=importlib.util.module_from_spec(s);s.loader.exec_module(q)
raw=Path('/Volumes/StudioData/bombcad/experiments/2026-10-21-cost-probe');tmp=Path('/private/tmp/bombcad-cost-probe');dest=repo/'Benchmarks/HeterogeneousCompute/2026-10-21-cost-probe';dest.mkdir(exist_ok=True)
for name in ['study.py','package.py','baseline-field-queue.py.txt','candidate-field-queue.py.txt']:shutil.copy2(tmp/name,dest/name)
audit=dict(status='complete',executions=0,terminalGroups=[],hashes={},summary={})
for version in ['baseline','candidate']:
 root=raw/version;r=q.read(root/'study.json');assert r['status']=='complete' and len(r['trials'])==7
 shutil.copy2(root/'study.json',dest/(version+'-study.json'));shutil.copy2(tmp/(version+'.log'),dest/(version+'.log'))
 for row in r['trials']:
  queue=Path(row['queue']);c=q.read(queue/'contract.json');check=dict(c);assert q.address({k:v for k,v in c.items() if k!='key'})==c['key'] and c['machine']==platform.node()
  for name,h in c['filesSHA256'].items():
   selected=tmp/(version+'-field-queue.py.txt') if name==str(repo/'Scripts/cuda/field-queue.py') else Path(name)
   assert q.digest(selected)==h,(version,name)
  assert hashlib.sha256(q.generate().encode()).hexdigest()==c['numericalSourceSHA256']
  for j in c['jobs']:
   state=q.case_state(queue,c,j);assert state['status']=='accepted' and state['attempts']==1
   v=q.object_receipt(queue,state['object'],c,j);audit['executions']+=1
   group=audit['hashes'].setdefault(j['id'],{}).setdefault(v['backend'],{n:set() for n in ['inputs.npy','mask.npy','targets.npy']})
   for n in group:group[n].add(v['filesSHA256'][n])
  for path in queue.glob('cases/*/attempts/*/process.json'):
   process=q.read(path);assert not q.tracked_alive(process);audit['terminalGroups'].append(dict(version=version,pid=process['pid'],pgid=process['pgid'],alive=False))
  if version=='candidate':
   for request in row['requests']:
    pre=request['observations']['cudaPreflight'];assert pre['probeRequired']==(row['policy']=='cuda-control')
    if row['policy']=='auto':assert 'optimistic PC availability' in request['observations']['cuda']['reason']
 audit['summary'][version]={p:dict(medianSeconds=statistics.median(x['controllerSeconds'] for x in r['trials'] if x['policy']==p),samples=[x['controllerSeconds'] for x in r['trials'] if x['policy']==p]) for p in ['auto','metal','cuda-control']}
 with tarfile.open(dest/(version+'-state.tar.gz'),'w:gz') as a:
  for path in sorted(root.iterdir()):a.add(path,arcname=path.name)
for modes in audit['hashes'].values():
 for files in modes.values():
  for name,v in files.items():assert len(v)==1;files[name]=sorted(v)
assert audit['executions']==98 and len(audit['terminalGroups'])==98
q.atomic(dest/'audit.json',audit);print(json.dumps(audit['summary'],indent=2));print('98 accepted objects verified, all numerical files match per case/backend across versions')
