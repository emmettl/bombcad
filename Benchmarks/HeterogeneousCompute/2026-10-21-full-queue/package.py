"""Audit and retain all state, deduplicating immutable payload bytes as tar hard links."""
import hashlib,importlib.util,json,shutil,sys,tarfile
from pathlib import Path
repo=Path.cwd();sys.path.insert(0,str(repo/'Scripts/cuda'));s=importlib.util.spec_from_file_location('q',repo/'Scripts/cuda/field-queue.py');q=importlib.util.module_from_spec(s);s.loader.exec_module(q)
root=Path('/Volumes/StudioData/bombcad/experiments/2026-10-21-full-queue-v2');tmp=Path('/private/tmp/bombcad-full-queue');dest=repo/'Benchmarks/HeterogeneousCompute/2026-10-21-full-queue';dest.mkdir(exist_ok=True)
r=q.read(root/'study.json');assert r['status']=='complete' and len(r['references'])==8 and len(r['calibration'])==6 and len(r['trials'])==8
included=[x for x in r['trials'] if x.get('included')];assert len(included)==6
for name in ['study.py','continue.py','package.py','study.log','continue.log','initial-study.py.txt','initial-study.log','continue-preflight-failed.log']:shutil.copy2(tmp/name,dest/name)
for name in ['study.json','calibrated-costs.json','interrupted-study.json']:shutil.copy2(root/name,dest/name)
audit=dict(status='complete',acceptedExecutions=0,includedExecutions=0,terminalGroups=[],numericalHashes={},clockAudits=[],predictions=[],monitorSamples=0)
for row in [*r['calibration'],*r['trials']]:
 queue=Path(row['queue']);c=q.read(queue/'contract.json');q.verify_contract(c)
 for j in c['jobs']:
  state=q.case_state(queue,c,j);assert state['status']=='accepted' and state['attempts']==1
  v=q.object_receipt(queue,state['object'],c,j);audit['acceptedExecutions']+=1
  if row in r['calibration'] or row.get('included'):audit['includedExecutions']+=1
  hashes=audit['numericalHashes'].setdefault(v['backend'],{n:set() for n in ['inputs.npy','mask.npy','targets.npy']})
  for name in hashes:hashes[name].add(v['filesSHA256'][name])
  if v['backend']=='cuda':
   a=v['provenance']['result']['clockAudit'];audit['clockAudits'].append(dict(queue=str(queue),case=j['id'],included=row in r['calibration'] or row.get('included',False),rawSeconds=a['rawSeconds'],adjustedMonotonicSeconds=a['adjustedMonotonicSeconds'],adjustedRawPPM=(a['adjustedMonotonicSeconds']/a['rawSeconds']-1)*1e6))
  prepared=queue/'cases'/j['key']/'prepared'
  if prepared.exists():q.verify_prepared(prepared,c,j)
 for p in queue.glob('cases/*/attempts/*/process.json'):
  process=q.read(p);assert not q.tracked_alive(process);audit['terminalGroups'].append(dict(pid=process['pid'],pgid=process['pgid'],alive=False,processFile=str(p)))
 if row.get('included'):
  for sample in row['slotOwnershipSamples']:assert not sample['external']
  audit['monitorSamples']+=len(row['slotOwnershipSamples'])
  states={j['key']:dict(status='pending',eligibleBackends=j['backends'],retryAfter=0,active=[]) for j in c['jobs']}
  proposals=q.plan_dispatch(c,states,row['before']['mac'],row['before']['pc'],now=0)
  audit['predictions'].append(dict(name=row['name'],policy=row['policy'],predictedMakespanSeconds=max(v['estimatedFinishSeconds'] for v in proposals),controllerSeconds=row['controllerSeconds'],assignments={j['id']:row['receipts'][j['id']]['backend'] for j in c['jobs']},proposals=proposals))
for files in audit['numericalHashes'].values():
 for name,values in files.items():assert len(values)==1;files[name]=sorted(values)
assert audit['acceptedExecutions']==70 and audit['includedExecutions']==54 and len(audit['terminalGroups'])==70
q.atomic(dest/'audit.json',audit)
original=Path(r['referenceSource']);args=q.read(original/'meta.json')['arguments'];osm=Path(args[args.index('--osm')+1])
entries=[(osm,'inputs/district.osm')]+[(p,'historical-reference/'+p.name) for p in sorted(original.iterdir()) if p.is_file()]+[(p,'study/'+str(p.relative_to(root))) for p in sorted(root.rglob('*'))]
seen={};manifest={};links=0
with tarfile.open(dest/'state.tar.gz','w:gz') as archive:
 for path,name in entries:
  info=archive.gettarinfo(str(path),arcname=name)
  if info.isfile():
   h=q.digest(path);manifest[name]=h;key=(h,info.size,info.mode)
   if path.suffix in ('.npy','.bin','.cu','.metal') and info.size>=4096 and key in seen:
    info.type=tarfile.LNKTYPE;info.linkname=seen[key];info.size=0;archive.addfile(info);links+=1
   else:
    if path.suffix in ('.npy','.bin','.cu','.metal') and info.size>=4096:seen[key]=name
    with path.open('rb') as data:archive.addfile(info,data)
  elif info.isdir():archive.addfile(info)
  else:raise ValueError('unexpected nonregular state entry: '+str(path))
q.atomic(dest/'archive-files.json',manifest)
actual={}
with tarfile.open(dest/'state.tar.gz','r|gz') as archive:
 for info in archive:
  if info.isfile():
   digest=hashlib.sha256();stream=archive.extractfile(info)
   while True:
    block=stream.read(1048576)
    if not block:break
    digest.update(block)
   actual[info.name]=digest.hexdigest()
  elif info.islnk():actual[info.name]=actual[info.linkname]
assert actual==manifest
q.atomic(dest/'archive-audit.json',dict(status='complete',filesVerified=len(actual),deduplicatedPayloadLinks=links,acceptedFilesVerified=70*4))
print('Accepted',audit['acceptedExecutions'],'included',audit['includedExecutions'],'terminal',len(audit['terminalGroups']),'ownership samples',audit['monitorSamples'])
print('Archive', (dest/'state.tar.gz').stat().st_size,'bytes; verified files',len(actual),'payload hard links',links)
print(json.dumps(r['summary'],indent=2));print('clock ppm',[x['adjustedRawPPM'] for x in audit['clockAudits']])
