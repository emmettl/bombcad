"""Retain staged sweep protocol controls and exact candidate sources; no host job launches."""
import hashlib,json,shutil,tarfile
from pathlib import Path
repo=Path.cwd();tmp=Path('/private/tmp/bombcad-sweep-snapshots');base=Path('/Volumes/StudioData/bombcad/experiments')
roots=[base/name for name in ['2026-10-21-sweep-snapshots','2026-10-21-sweep-snapshots-v2','2026-10-21-sweep-snapshots-final','2026-10-21-sweep-snapshots-payload']]
dest=repo/'Benchmarks/HeterogeneousCompute/2026-10-21-sweep-snapshots';dest.mkdir(exist_ok=True)
def digest(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def write(p,v):p.write_text(json.dumps(v,indent=2)+'\n')
audit=dict(status='complete',variants=[],scope='Protocol identity/ownership/recovery controls only; repeated CPU fixture work is not independent physical evidence or a performance benchmark.')
for root in roots:
 r=json.loads((root/'study.json').read_text());assert r['status']=='complete' and r['matchesPreviousCPUStudyExactly'] and r['recoveryArraysBitIdentical']
 for c in r['commands']:
  expected=2 if c['label']=='existing-destination' else 1 if c['label'] in ['corrupt-output','corrupt-input'] else 0
  assert c['returncode']==expected,(root,c)
 if root==roots[-1]:assert r['payloadNamesPinned'] and r['declaredInputTamperingRefused'] and r['corruptedOutputRefused'] and r['retrievalFilesVerified']
 audit['variants'].append(dict(name=root.name,runnerSHA256=r['runnerSHA256'],commands=r['commands'],runInvocation=r['runInvocation'],testInvocation=r.get('testInvocation'),payloadNamesPinned=r.get('payloadNamesPinned'),retrievalFilesVerified=r.get('retrievalFilesVerified')))
for root,name in zip(roots,['protocol-initial.py.txt','protocol-checksum.py.txt','protocol-guard.py.txt','protocol-payload.py.txt']):
 r=json.loads((root/'study.json').read_text());assert digest(tmp/name)==r['runnerSHA256'];shutil.copy2(tmp/name,dest/name)
for name in ['smoke-initial.py.txt','smoke-v2.py','smoke-final.py','smoke-payload.py','package.py','forced-stop.py','forced-stop.json','forced-stop.log','unit.log','unit-observer-failed.log','payload-before.json','payload-after.json','smoke.log','smoke-v2.log','smoke-final.log','smoke-payload.log']:shutil.copy2(tmp/name,dest/name)
assert json.loads((tmp/'forced-stop.json').read_text())['staleRecoveryOnlyAfterGroupDeath']
assert json.loads((tmp/'payload-before.json').read_text())==dict(inputPayloadPinned=False,resultPayloadPinned=False)
assert json.loads((tmp/'payload-after.json').read_text())==dict(inputPayloadPinned=True,resultPayloadPinned=True)
write(dest/'audit.json',audit)
entries=[(p,root.name+'/'+str(p.relative_to(root))) for root in roots for p in sorted(root.rglob('*'))]
files={}
with tarfile.open(dest/'state.tar.gz','w:gz') as archive:
 for p,name in entries:
  info=archive.gettarinfo(str(p),arcname=name)
  if info.isfile():
   files[name]=digest(p)
   with p.open('rb') as f:archive.addfile(info,f)
  elif info.isdir():archive.addfile(info)
  else:raise ValueError(str(p))
actual={}
with tarfile.open(dest/'state.tar.gz','r|gz') as archive:
 for info in archive:
  if info.isfile():actual[info.name]=hashlib.sha256(archive.extractfile(info).read()).hexdigest()
assert actual==files
write(dest/'archive-files.json',files);write(dest/'archive-audit.json',dict(status='complete',filesVerified=len(files),archiveBytes=(dest/'state.tar.gz').stat().st_size))
print('Verified',len(files),'files',(dest/'state.tar.gz').stat().st_size,'bytes across',len(roots),'protocol candidates')
