"""Archive every own raw file; publish metadata by kind, retaining all outcomes."""
import hashlib
import json
from pathlib import Path
import tarfile

ROOT=Path('/Volumes/StudioData/bombcad/experiments/2026-10-22-corrected-beirut-trace')
HERE=Path(__file__).resolve().parent


def sha(path):
    h=hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda:stream.read(1048576),b''):h.update(block)
    return h.hexdigest()


def archive(path,files,pins):
    path.parent.mkdir(exist_ok=True,parents=True)
    with tarfile.open(path,'x:gz') as tar:
        for p in files:tar.add(p,arcname=str(p.relative_to(ROOT)),recursive=False)
    with tarfile.open(path,'r:gz') as tar:
        members=tar.getmembers();assert len(members)==len(files)
        for member in members:
            h=hashlib.sha256();stream=tar.extractfile(member)
            while block:=stream.read(1048576):h.update(block)
            assert h.hexdigest()==pins[member.name]['sha256']
    return dict(path=str(path),files=len(files),bytes=path.stat().st_size,sha256=sha(path),everyDecompressedMemberVerified=True)


def main():
    run=json.loads((ROOT/'run.json').read_text());analysis=json.loads((ROOT/'analysis-results.json').read_text())
    assert run['status']==analysis['status']=='complete'
    assert run['metalObserverParity'] and run['cudaNumericAndTimestepsParity'] and analysis['stillRejected']
    files=sorted(p for p in ROOT.rglob('*') if p.is_file())
    pins={str(p.relative_to(ROOT)):dict(bytes=p.stat().st_size,sha256=sha(p)) for p in files}
    public=[p for p in files if p.suffix not in ['.npy','.bin','.npz','.pyc']]
    full=archive(ROOT.with_name(ROOT.name+'-archive')/'all-raw.tar.gz',files,pins)
    metadata=archive(HERE/'evidence/metadata.tar.gz',public,pins)
    for p in files:assert sha(p)==pins[str(p.relative_to(ROOT))]['sha256']
    report=dict(schema='bombcad-corrected-beirut-trace-archive-1',rawRoot=str(ROOT),files=pins,
        fullArchive=full,publicMetadata=metadata,rawFiles=len(files),rawBytes=sum(p['bytes'] for p in pins.values()),
        scope='Every own raw file retained, including failed offline report version. Runtime and physical input are pinned immutable dependencies in the separately archived fixed-reference study. Full PC output remains at recorded remote paths; all nine original numeric files and dt were independently rehashed. Public exclusions are by numeric/binary kind, never status.')
    with (HERE/'archive.json').open('x') as stream:json.dump(report,stream,indent=2);stream.write('\n')
    print(json.dumps({k:v for k,v in report.items() if k!='files'},indent=2))


if __name__=='__main__':main()
