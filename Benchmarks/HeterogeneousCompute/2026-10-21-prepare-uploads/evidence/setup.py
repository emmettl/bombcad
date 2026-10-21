"""Use exact retained numerical inputs; source/input attestation occurs before timing."""
from pathlib import Path
import hashlib,json
root=Path(__file__).resolve().parent;old=Path.home()/'bombcad-graphs-01a15d45'
def sha(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for b in iter(lambda:f.read(1048576),b''):h.update(b)
 return h.hexdigest()
(root/'solver.cu').write_bytes((old/'solver.cu').read_bytes())
r={}
for name in ['cooling32','blast64','cooling64','terrain256','flat512','beirut512']:
 p=root/name;p.symlink_to((old/name).resolve(),target_is_directory=True)
 r[name]=dict(path=str(p.resolve()),meta=json.loads((p/'job.json').read_text()),files={str(q.relative_to(p)):sha(q) for q in p.rglob('*') if q.is_file()})
(root/'inputs.json').write_text(json.dumps(dict(sourceSHA256=sha(root/'solver.cu'),jobs=r),indent=2)+'\n')
