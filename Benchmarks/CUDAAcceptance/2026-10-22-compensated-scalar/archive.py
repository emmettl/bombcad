"""Retain and verify the complete scalar corpus; only the executable stays external."""
import gzip
import hashlib
import json
from pathlib import Path
import shutil

here = Path(__file__).resolve().parent
root = Path('/Volumes/StudioData/bombcad/experiments/2026-10-22-compensated-scalar')
sha = lambda data: hashlib.sha256(data).hexdigest()
run = json.loads((root/'run.json').read_text())
assert run['status'] == 'complete'
for name, digest in run['sourceSHA256'].items():
    assert sha((root/'sources'/name).read_bytes()) == digest == sha((here/name).read_bytes())
assert sha((root/'probe').read_bytes()) == run['executableSHA256']
assert sha((root/'fixtures.json').read_bytes()) == run['fixtureSHA256']
for name, entry in run['retainedFiles'].items():
    data = (root/name).read_bytes()
    assert sha(data) == entry['sha256'] and len(data) == entry['bytes']
files = [p for p in sorted(root.rglob('*')) if p.is_file() and 'archive' not in p.relative_to(root).parts]
rows = []
for path in files:
    name = path.relative_to(root)
    data = path.read_bytes()
    packed = gzip.compress(data, mtime=0)
    destination = root/'archive'/Path(str(name)+'.gz')
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(packed)
    assert gzip.decompress(destination.read_bytes()) == data
    published = name != Path('probe')
    if published:
        copy = here/'evidence'/Path(str(name)+'.gz')
        copy.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(destination, copy)
        assert sha(copy.read_bytes()) == sha(packed)
    rows.append(dict(path=str(name),sha256=sha(data),bytes=len(data),compressedSHA256=sha(packed),compressedBytes=len(packed),published=published))
report = dict(status='complete',rawRoot=str(root),files=rows,rawFiles=len(rows),rawBytes=sum(r['bytes'] for r in rows),compressedBytes=sum(r['compressedBytes'] for r in rows),publishedFiles=sum(r['published'] for r in rows),publishedCompressedBytes=sum(r['compressedBytes'] for r in rows if r['published']))
(here/'archive.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({k:v for k,v in report.items() if k!='files'},indent=2))
