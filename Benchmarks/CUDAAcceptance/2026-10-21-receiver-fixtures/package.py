"""Verify and retain the paired CPU study without launching more assessments."""
import hashlib,json,shutil,tarfile
from pathlib import Path
repo=Path.cwd();tmp=Path('/private/tmp/bombcad-receiver-fixtures');root=Path('/Volumes/StudioData/bombcad/experiments/2026-10-21-receiver-fixtures');dest=repo/'Benchmarks/CUDAAcceptance/2026-10-21-receiver-fixtures';dest.mkdir(exist_ok=True)
def digest(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def write(p,v):p.write_text(json.dumps(v,indent=2)+'\n')
r=json.loads((root/'study.json').read_text());a=json.loads((root/'analysis.json').read_text());pins=json.loads((root/'runtime-pins.json').read_text())
assert a['status']=='complete' and set(a['hosts'])=={'here','bombcad-pc'}
for p,h in {**pins,**r['sourceSHA256']}.items():assert digest(p)==h,p
assert '0 file(s) disagree' in (tmp/'compare.log').read_text()
host=json.loads((tmp/'host-pins.json').read_text());assert host['status']=='complete' and not host['sweepLockExists']
counts={}
for name in a['hosts']:
 s=json.loads((root/'results'/('receiver-fixtures-20261021-'+name)/'sweep.json').read_text());assert len(s['cases'])==3 and all(c['exitCode']==0 for c in s['cases'])
 assert a['hosts'][name]['rows']==1920 and not a['hosts'][name]['assessmentFailures'] and not a['hosts'][name]['levelChanges']
 counts[name]=dict(assessments=1920,comparisons=len(a['hosts'][name]['comparisons']),levelChanges=0,maxRotationDeltaDeg=a['hosts'][name]['maxRotationDeltaDeg'],maxRawImpulseRelativeError=a['hosts'][name]['maxRawImpulseRelativeError'])
summary=dict(status='complete',scope=r['scope'],hosts=counts,binWidthSensitivity=a['binWidthSensitivity'],duplicateControlsIdentical=a['duplicateControlsIdentical'],crossHostNumericTolerance=1e-9,hostAudit=host,highlights=json.loads((root/'response-highlights.json').read_text()))
write(root/'audit.json',summary)
r.update(status='complete',completion='Both original sweep handles returned zero; all six cases exit zero; saved-output/source audits complete. No rerun of assessments.',localExecutableSHA256=digest(Path('.build/release/blastmodel').resolve()),localExecutable=str(Path('.build/release/blastmodel').resolve()))
write(root/'study.json',r)
for name in ['prepare.py','analyse.py','package.py','prepare.log','mac.log','pc.log','compare.log','tests.log','analysis.log','host-pins.py','host-pins.json','sweep-lock-issue.md']:shutil.copy2(tmp/name,dest/name)
for name in ['audit.json','study.json','runtime-pins.json']:shutil.copy2(root/name,dest/name)
files={}
with tarfile.open(dest/'state.tar.gz','w:gz') as archive:
 for p in sorted(root.rglob('*')):
  name='study/'+str(p.relative_to(root));info=archive.gettarinfo(str(p),arcname=name)
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
print('Verified archive',len(files),'files',(dest/'state.tar.gz').stat().st_size,'bytes');print(counts)
