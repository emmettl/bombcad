"""Retain completed numerical controls; deduplicate only immutable binary payloads."""
import hashlib, importlib.util, json, shutil, sys, tarfile
from pathlib import Path
repo=Path.cwd(); sys.path.insert(0,str(repo/'Scripts/cuda'))
s=importlib.util.spec_from_file_location('q',repo/'Scripts/cuda/field-queue.py');q=importlib.util.module_from_spec(s);s.loader.exec_module(q)
from job import validate
root=Path('/Volumes/StudioData/bombcad/experiments/2026-10-21-independent-portability')
tmp=Path('/private/tmp/bombcad-independent-portability')
dest=repo/'Benchmarks/CUDAAcceptance/2026-10-21-independent-portability';dest.mkdir(exist_ok=True)
r=q.read(root/'study.json');assert r['status']=='complete' and len(r['groups'])==4
smoke=q.read(tmp/'smoke/smoke.json');assert smoke['status']=='complete' and len(smoke['controls'])==9
audit=dict(status='complete',groups=[],scope='Within-grid numerical controls; no performance, cross-grid convergence or new dataset admission claim.')
def failure_locations(reference,candidate):
 shape,a=q.npy(reference/'targets.npy');_,b=q.npy(candidate/'targets.npy');_,mask=q.npy(reference/'mask.npy');plane=shape[1]*shape[2]
 rows=[]
 for c in range(shape[0]):
  for i,valid in enumerate(mask):
   if valid:
    x,y=a[c*plane+i],b[c*plane+i];error=abs(x-y);tolerance=.05+.002*abs(x)
    if error>tolerance:rows.append(dict(channel=c,columnIndex=i,row=i//shape[2],column=i%shape[2],reference=x,candidate=y,absoluteError=error,tolerance=tolerance))
 return rows
for g in r['groups']:
 assert len(g['variants'])==10 and g['observerArraysBitIdentical']
 base=root/g['name'];reference=base/'plain-reference'
 assert {n:q.digest(reference/n) for n in q.DATA_FILES}==g['reference']['filesSHA256']
 rows=[]
 for v in g['variants']:
  folder=base/(v['mode']+'-'+v['path'])
  initial,_=validate(base/(v['mode']+'-'+v['path']+'-initial'),(root/'solver.cu').read_text())
  assert {k:initial.get(k) for k in g['baselineInitial']}==v['initialState']
  assert {n:q.digest(folder/n) for n in q.DATA_FILES}==v['filesSHA256']
  assert q.compare(reference,folder)==v['comparisonToDefaultTiled']
  rows.append(dict(mode=v['mode'],path=v['path'],initialMatchesDefault=v['initialMatchesDefault'],comparison=v['comparisonToDefaultTiled'],failures=failure_locations(reference,folder)))
 cuda=base/'cuda-result/dataset'
 assert {n:q.digest(cuda/n) for n in q.DATA_FILES}==g['cuda']['filesSHA256']
 assert q.compare(reference,cuda)==g['cuda']['comparisonToDefaultTiled']
 for mode in ['default','fast-on','fast-off','safe-on','safe-off']:
  assert q.compare(base/(mode+'-tiled'),cuda)==g['cuda'][mode+'Comparison']
 prepared,_=validate(base/'cuda-input',(root/'solver.cu').read_text())
 prepared_matches={k:prepared.get(k) for k in g['baselineInitial']}==g['baselineInitial']
 audit['groups'].append(dict(name=g['name'],observerArraysBitIdentical=True,allPhysicalInitialStatesMatch=all(v['initialMatchesDefault'] for v in g['variants']),cudaPreparedInitialStateMatchesDefault=prepared_matches,variants=rows,withinModeTiledFull=g['withinModeTiledFull'],cuda=g['cuda']['comparisonToDefaultTiled'],cudaFailures=failure_locations(reference,cuda)))
 if g['name']=='terrain-h200-dx4':
  historical=Path('/Volumes/StudioData/bombcad/ml/datasets/main-fp/runs')/g['originalCase']
  audit['groups'][-1]['historicalArraysBitIdentical']=all(q.digest(historical/n)==q.digest(reference/n) for n in ['inputs.npy','mask.npy','targets.npy'])
  audit['groups'][-1]['historicalComparison']=q.compare(historical,reference)
live=q.read(root/'live-process.json');assert live['boot']!=q.boot_id() or not q.group_alive(live['pgid'])
audit['lastOwnedProcessTerminal']=live
q.atomic(dest/'audit.json',audit)
for name in ['study.py','package.py','smoke.py','study.log','smoke.log']:shutil.copy2(tmp/name,dest/name)
shutil.copy2(root/'study.json',dest/'study.json');shutil.copy2(tmp/'smoke/smoke.json',dest/'smoke.json')
entries=[(p,'study/'+str(p.relative_to(root))) for p in sorted(root.rglob('*'))]
entries += [(p,'smoke/'+str(p.relative_to(tmp/'smoke'))) for p in sorted((tmp/'smoke').rglob('*'))]
inputs={path for g in r['groups'] for path in g['inputSHA256']}
entries += [(Path(p),'inputs/'+str(i)+'-'+Path(p).name) for i,p in enumerate(sorted(inputs))]
for original in sorted({g['originalCase'] for g in r['groups']}):
 historical=Path('/Volumes/StudioData/bombcad/ml/datasets/main-fp/runs')/original
 entries += [(historical/'meta.json','original-metadata/'+original+'.json')]
 if original=='made-perimeter-s3-1':entries += [(historical/n,'historical-terrain/'+n) for n in q.DATA_FILES]
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
  else:raise ValueError('unexpected archive entry '+str(path))
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
q.atomic(dest/'archive-audit.json',dict(status='complete',filesVerified=len(actual),deduplicatedPayloadLinks=links,archiveBytes=(dest/'state.tar.gz').stat().st_size))
print(json.dumps(audit,indent=2));print('Verified archive bytes', (dest/'state.tar.gz').stat().st_size)
