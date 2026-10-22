"""Verify and archive every own outcome; large numerical arrays remain external."""
import hashlib
import json
from pathlib import Path
import tarfile

ROOT=Path('/Volumes/StudioData/bombcad/experiments/2026-10-22-source-order-controls')
HERE=Path(__file__).resolve().parent


def sha(p):
    h=hashlib.sha256()
    with p.open('rb') as f:
        for b in iter(lambda:f.read(1048576),b''):h.update(b)
    return h.hexdigest()


def pack(path,files,pins):
    path.parent.mkdir(exist_ok=True,parents=True)
    with tarfile.open(path,'x:gz') as tar:
        for p in files:tar.add(p,arcname=str(p.relative_to(ROOT)),recursive=False)
    with tarfile.open(path,'r:gz') as tar:
        assert len(tar.getmembers())==len(files)
        for member in tar:
            h=hashlib.sha256();f=tar.extractfile(member)
            while block:=f.read(1048576):h.update(block)
            assert h.hexdigest()==pins[member.name]['sha256']
    return dict(path=str(path),files=len(files),bytes=path.stat().st_size,sha256=sha(path),everyDecompressedMemberVerified=True)


def main():
    r=json.loads((ROOT/'run.json').read_text());comparison=json.loads((ROOT/'model-equivalence.json').read_text())
    assert r['status']==comparison['status']=='complete-all-outcomes' and len(r['rows'])==432
    files=sorted(p for p in ROOT.rglob('*') if p.is_file())
    pins={str(p.relative_to(ROOT)):dict(bytes=p.stat().st_size,sha256=sha(p)) for p in files}
    public=[p for p in files if p.suffix not in ['.npz','.npy','.bin','.pyc']]
    full=pack(ROOT.with_name(ROOT.name+'-archive')/'all-raw.tar.gz',files,pins)
    metadata=pack(HERE/'evidence/metadata.tar.gz',public,pins)
    for p in files:assert sha(p)==pins[str(p.relative_to(ROOT))]['sha256']
    report=dict(schema='bombcad-written-order-archive-1',rawRoot=str(ROOT),rawFiles=len(files),rawBytes=sum(v['bytes'] for v in pins.values()),
        files=pins,fullArchive=full,publicMetadata=metadata,
        scope='Every own file and every outcome retained. Scientific producer/model/control snapshots and separately versioned postprocessing included. Derived NPZ arrays excluded publicly by kind; inherited complete source cases and selected runtime dependencies remain pinned in their separately verified host-source archive. No GPU/PDE rerun.')
    with (HERE/'archive.json').open('x') as f:json.dump(report,f,indent=2);f.write('\n')
    print(json.dumps({k:v for k,v in report.items() if k!='files'},indent=2))


if __name__=='__main__':main()
