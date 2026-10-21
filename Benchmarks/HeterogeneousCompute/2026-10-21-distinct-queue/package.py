"""Retain reproducible metadata, sources and logs; large numerical buffers stay in receipted scratch."""
from pathlib import Path
import json,hashlib,shutil
repo=Path.cwd();root=Path('/Volumes/StudioData/bombcad/experiments/2026-10-21-distinct-queue');scratch=Path('/private/tmp/bombcad-distinct-queue');dest=repo/'Benchmarks/HeterogeneousCompute/2026-10-21-distinct-queue';dest.mkdir(exist_ok=False)
def sha(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for b in iter(lambda:f.read(1048576),b''):h.update(b)
 return h.hexdigest()
assert json.loads((root/'stage.json').read_text())['status']=='complete';assert json.loads((root/'audit.json').read_text())['status']=='complete'
manifest={str(p.relative_to(root)):dict(sha256=sha(p),bytes=p.stat().st_size) for p in sorted(root.rglob('*')) if p.is_file()}
(dest/'retained-files.json').write_text(json.dumps(manifest,indent=2)+'\n')
for name in ['stage.py','continue.py','audit.py','audit.log','package.py','build.log','stage.log','continue.log','plan.md','pressure-gap.md','pressure-issue.md']:shutil.copy2(scratch/name,dest/name)
metadata={}
for p in sorted(root.rglob('*')):
 if p.is_file() and p.suffix in ['.json','.cu','.log']:
  n=p.relative_to(root);to=dest/'evidence'/n;to.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,to);metadata[str(n)]=sha(to);assert metadata[str(n)]==manifest[str(n)]['sha256']
(dest/'metadata-files.json').write_text(json.dumps(metadata,indent=2)+'\n')
(dest/'package-audit.json').write_text(json.dumps(dict(status='complete',rawFileInstancesHashed=len(manifest),rawBytesHashed=sum(x['bytes'] for x in manifest.values()),metadataFilesCopiedAndRehashed=len(metadata),scope=__doc__),indent=2)+'\n');print('retained',len(manifest),'receipts and',len(metadata),'copied metadata files')
