"""Retain all replay outcomes and startup failures; publish metadata by kind."""
import hashlib
import json
from pathlib import Path
import tarfile

ROOT=Path('/Volumes/StudioData/bombcad/experiments/2026-10-22-metal-stencil-replay')
HERE=Path(__file__).resolve().parent


def sha(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for b in iter(lambda:f.read(1048576),b''):h.update(b)
    return h.hexdigest()


def pack(path,files,pins):
    path.parent.mkdir(exist_ok=True,parents=True)
    with tarfile.open(path,'x:gz') as tar:
        for p in files:tar.add(p,arcname=str(p.relative_to(ROOT)),recursive=False)
    with tarfile.open(path,'r:gz') as tar:
        assert len(tar.getmembers())==len(files)
        for m in tar:
            h=hashlib.sha256();f=tar.extractfile(m)
            while b:=f.read(1048576):h.update(b)
            assert h.hexdigest()==pins[m.name]['sha256']
    return dict(path=str(path),files=len(files),bytes=path.stat().st_size,sha256=sha(path),everyDecompressedMemberVerified=True)


def main():
    run=json.loads((ROOT/'run.json').read_text());assert run['status']=='complete-all-outcomes' and len(run['rows'])==432
    files=sorted(p for p in ROOT.rglob('*') if p.is_file())
    pins={str(p.relative_to(ROOT)):dict(bytes=p.stat().st_size,sha256=sha(p)) for p in files}
    public=[p for p in files if p.suffix in ['.json','.log','.txt','.py','.swift','.metal','.md'] and 'runtime' not in p.relative_to(ROOT).parts]
    external=pack(ROOT.with_name(ROOT.name+'-archive')/'all-raw.tar.gz',files,pins)
    metadata=pack(HERE/'evidence/metadata.tar.gz',public,pins)
    for p in files:assert sha(p)==pins[str(p.relative_to(ROOT))]['sha256']
    report=dict(schema='bombcad-metal-stencil-replay-archive-1',rawRoot=str(ROOT),rawFiles=len(files),rawBytes=sum(p['bytes'] for p in pins.values()),files=pins,
        fullArchive=external,publicMetadata=metadata,
        scope='Every own file retained, including four full failed preflights and their inherited copies. Numerical arrays and all runtime binaries excluded publicly by kind, never status. Compiler module cache is outside own raw root; inherited complete source records remain pinned in their prior verified archive. Selected pins do not make the SDK/driver environment hermetic.')
    with (HERE/'archive.json').open('x') as f:json.dump(report,f,indent=2);f.write('\n')
    print(json.dumps({k:v for k,v in report.items() if k!='files'},indent=2))


if __name__=='__main__':main()
