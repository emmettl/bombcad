"""Archive metadata and traces only; large numerical arrays remain at their receipted PC paths."""
from pathlib import Path
import hashlib,json,tarfile
root=Path(__file__).resolve().parent
assert json.loads((root/'verification.json').read_text())['status']=='complete'
allowed={'.py','.json','.cu','.patch','.txt','.log','.gz'}
files=[p for p in sorted(root.rglob('*')) if p.is_file() and not p.is_symlink() and p.suffix in allowed and p.name not in ['metadata.tar.gz','metadata-files.json','metadata-audit.json'] and '__pycache__' not in p.parts]
records={str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
with tarfile.open(root/'metadata.tar.gz','w:gz') as archive:
 for p in files:archive.add(p,arcname=str(p.relative_to(root)),recursive=False)
with tarfile.open(root/'metadata.tar.gz') as archive:
 for name,sha in records.items():assert hashlib.sha256(archive.extractfile(name).read()).hexdigest()==sha
(root/'metadata-files.json').write_text(json.dumps(records,indent=2)+'\n')
(root/'metadata-audit.json').write_text(json.dumps(dict(status='complete',fileInstancesVerified=len(records),archiveBytes=(root/'metadata.tar.gz').stat().st_size,scope=__doc__),indent=2)+'\n')
print('Archived and independently verified',len(records),'metadata/trace files')
