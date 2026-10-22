"""Archive every own pressure-input outcome; preserve full remote-output provenance."""
import hashlib
import json
from pathlib import Path
import tarfile

ROOT=Path('/Volumes/StudioData/bombcad/experiments/2026-10-22-phase-pressure-inputs')
HERE=Path(__file__).resolve().parent


def sha(p):
    h=hashlib.sha256()
    with p.open('rb') as f:
        for b in iter(lambda:f.read(1048576),b''):h.update(b)
    return h.hexdigest()


def pack(path,files,pins):
    path.parent.mkdir(exist_ok=True,parents=True)
    with tarfile.open(path,'x:gz') as t:
        for p in files:t.add(p,arcname=str(p.relative_to(ROOT)),recursive=False)
    with tarfile.open(path,'r:gz') as t:
        assert len(t.getmembers())==len(files)
        for m in t:
            h=hashlib.sha256();f=t.extractfile(m)
            while b:=f.read(1048576):h.update(b)
            assert h.hexdigest()==pins[m.name]['sha256']
    return dict(path=str(path),files=len(files),bytes=path.stat().st_size,sha256=sha(path),everyDecompressedMemberVerified=True)


def main():
    r=json.loads((ROOT/'run.json').read_text());a=json.loads((ROOT/'analysis-results.json').read_text())
    assert r['status']==a['status']=='complete-all-outcomes' and r['allThreeCaptured'] and a['allThreeInputAndNativeReplayGatesPass']
    files=sorted(p for p in ROOT.rglob('*') if p.is_file());pins={str(p.relative_to(ROOT)):dict(bytes=p.stat().st_size,sha256=sha(p)) for p in files}
    public=[p for p in files if p.suffix in ['.json','.log','.txt','.py','.md','.cu']]
    full=pack(ROOT.with_name(ROOT.name+'-archive')/'all-raw.tar.gz',files,pins);metadata=pack(HERE/'evidence/metadata.tar.gz',public,pins)
    for p in files:assert sha(p)==pins[str(p.relative_to(ROOT))]['sha256']
    report=dict(schema='bombcad-phase-pressure-inputs-archive-1',rawRoot=str(ROOT),rawFiles=len(files),rawBytes=sum(v['bytes'] for v in pins.values()),files=pins,fullArchive=full,publicMetadata=metadata,
        scope='Every own outcome retained; binary/native/conditional arrays excluded publicly by kind. Full-grid PC outputs remain at recorded remote paths with complete numeric/dt hashes. Immutable physical inputs and preceding references remain in their prior archive. No admission or physical-validation claim.')
    with (HERE/'archive.json').open('x') as f:json.dump(report,f,indent=2);f.write('\n')
    print(json.dumps({k:v for k,v in report.items() if k!='files'},indent=2))


if __name__=='__main__':main()
