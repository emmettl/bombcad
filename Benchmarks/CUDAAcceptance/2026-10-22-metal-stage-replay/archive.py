"""Archive all rejected-stage payloads; exclude public arrays only by kind."""
import hashlib
import json
from pathlib import Path
import tarfile

ROOT=Path('/Volumes/StudioData/bombcad/experiments/2026-10-22-metal-stage-replay')
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
        for m in tar:
            h=hashlib.sha256();f=tar.extractfile(m)
            while b:=f.read(1048576):h.update(b)
            assert h.hexdigest()==pins[m.name]['sha256']
    return dict(path=str(path),files=len(files),bytes=path.stat().st_size,sha256=sha(path),everyDecompressedMemberVerified=True)


def main():
    r=json.loads((ROOT/'run.json').read_text());assert r['status']=='complete-all-outcomes' and len(r['rows'])==432
    files=sorted(p for p in ROOT.rglob('*') if p.is_file());pins={str(p.relative_to(ROOT)):dict(bytes=p.stat().st_size,sha256=sha(p)) for p in files}
    public=[p for p in files if p.suffix in ['.json','.log','.txt','.py','.swift','.metal','.md'] and 'runtime' not in p.relative_to(ROOT).parts]
    external=pack(ROOT.with_name(ROOT.name+'-archive')/'all-raw.tar.gz',files,pins);metadata=pack(HERE/'evidence/metadata.tar.gz',public,pins)
    for p in files:assert sha(p)==pins[str(p.relative_to(ROOT))]['sha256']
    report=dict(schema='bombcad-metal-stage-replay-archive-1',rawRoot=str(ROOT),rawFiles=len(files),rawBytes=sum(p['bytes'] for p in pins.values()),files=pins,
        fullArchive=external,publicMetadata=metadata,
        scope='Every own file retained, including every incompatible component payload. Arrays/runtime binaries excluded publicly by kind, not outcome. Inherited packed inputs, native expected fluxes and accepted face-only outputs remain immutable in the separately verified parent archive. Compiler caches stay outside own raw root; no hermetic SDK/driver claim.')
    with (HERE/'archive.json').open('x') as f:json.dump(report,f,indent=2);f.write('\n')
    print(json.dumps({k:v for k,v in report.items() if k!='files'},indent=2))


if __name__=='__main__':main()
