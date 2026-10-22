"""Preserve every completed local outcome, including the rejected candidate and CPU preflight."""
import hashlib
from pathlib import Path
import shutil
import tarfile

from selector_runtime_prepare import ROOT, load, save, sha, files

HERE = Path(__file__).resolve().parent


def main():
    result = load(ROOT / 'trajectory-results.json')
    assert result['status'] == 'complete-all-outcomes'
    assert not result['allCandidatesPassExistingFixedReference']
    assert load(ROOT / 'trajectory-verification.json')['status'] == 'fresh-all-inventories-and-gates-verified'
    for p, digest in result['consumed'].items(): assert sha(p) == digest, p
    original = load(HERE / 'implementation-archive.json')
    for name, item in original['manifest'].items(): assert sha(ROOT / name) == item['sha256'], name
    publication = ROOT / 'publication-sources'; publication.mkdir(exist_ok=False)
    for p in HERE.iterdir():
        if p.suffix in ['.py', '.json', '.md']: shutil.copyfile(p, publication / p.name)
    repo = HERE.parents[2]
    for name in ['cuda-backend.md', 'heterogeneous-compute.md']:
        shutil.copyfile(repo / 'docs' / name, publication / ('docs-' + name))
    out = ROOT.with_name(ROOT.name + '-complete-archive'); out.mkdir(exist_ok=False)
    manifest = {str(p.relative_to(ROOT)): dict(sha256=sha(p),bytes=p.stat().st_size) for p in sorted(files(ROOT))}
    metadata = [n for n in manifest if Path(n).suffix in ['.py','.md','.json','.log']]
    (HERE / 'evidence').mkdir(exist_ok=True)
    archives = []
    for target, names in [(out / 'all-raw.tar.gz',list(manifest)),(HERE / 'evidence/metadata.tar.gz',metadata)]:
        assert not target.exists()
        with tarfile.open(target,'w:gz',compresslevel=6) as tar:
            for n in names: tar.add(ROOT / n,arcname=n,recursive=False)
        with tarfile.open(target,'r:gz') as tar:
            assert [m.name for m in tar.getmembers()] == names
            for member in tar.getmembers():
                stream=tar.extractfile(member); assert stream is not None
                h=hashlib.sha256(); count=0
                for block in iter(lambda:stream.read(1048576),b''):h.update(block);count+=len(block)
                assert dict(sha256=h.hexdigest(),bytes=count)==manifest[member.name]
        archives.append(dict(path=str(target),bytes=target.stat().st_size,sha256=sha(target),members=len(names)))
    for n,r in manifest.items():assert sha(ROOT / n)==r['sha256'],n
    report=dict(status='all-members-and-local-raw-rehash-verified',root=str(ROOT),manifest=manifest,
        archives=archives,rawFiles=len(manifest),rawBytes=sum(r['bytes'] for r in manifest.values()),
        limits='All local implementation/scalar/analytic/district outputs, failed analysis preflight and source/runtime versions retained. Full analytic states stored; district 3D fidelity is whole-buffer hashes rather than locally archived district states. Original CUDA data remain in qualified parent archives/jobs. Public archive contains metadata/postprocessing. Candidate rejected; no reference/default/tolerance/mask/phase/index/admission change.')
    save(HERE / 'archive.json',report);save(out / 'archive.json',report)
    print({k:v for k,v in report.items() if k!='manifest'})


if __name__=='__main__':main()
