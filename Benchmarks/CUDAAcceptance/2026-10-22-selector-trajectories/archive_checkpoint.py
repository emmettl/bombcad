"""Freeze the completed implementation controls while allowing separately named later stages."""
import hashlib
import json
from pathlib import Path
import shutil
import tarfile

from run_tests import HERE, ROOT, save, sha


def main():
    audit = json.loads((ROOT / 'control-audit.json').read_text())
    assert audit['status'] == 'verified-controls-only' and audit['allIndependentOriginalBoundsPass']
    for name, digest in audit['consumed'].items(): assert sha(name) == digest, name
    analysis = ROOT / 'analysis'
    for p in HERE.iterdir():
        if p.suffix in ['.py', '.md', '.json']:
            dest = analysis / p.name
            assert not dest.exists()
            shutil.copyfile(p, dest)
    out = ROOT.with_name(ROOT.name + '-implementation-archive'); out.mkdir(exist_ok=False)
    files = sorted(p for p in ROOT.rglob('*') if p.is_file())
    manifest = {str(p.relative_to(ROOT)): dict(sha256=sha(p), bytes=p.stat().st_size) for p in files}
    metadata = [n for n in manifest if Path(n).suffix in ['.py', '.md', '.json', '.log']]
    (HERE / 'implementation-evidence').mkdir(exist_ok=True)
    archives = []
    for target, names in [(out / 'all-raw.tar.gz', list(manifest)),
                          (HERE / 'implementation-evidence/metadata.tar.gz', metadata)]:
        assert not target.exists()
        with tarfile.open(target, 'w:gz', compresslevel=6) as tar:
            for n in names: tar.add(ROOT / n, arcname=n, recursive=False)
        with tarfile.open(target, 'r:gz') as tar:
            assert [m.name for m in tar.getmembers()] == names
            for m in tar.getmembers():
                f = tar.extractfile(m); assert f is not None
                h = hashlib.sha256(); count = 0
                for block in iter(lambda: f.read(1048576), b''): h.update(block); count += len(block)
                assert dict(sha256=h.hexdigest(), bytes=count) == manifest[m.name]
        archives.append(dict(path=str(target), bytes=target.stat().st_size, sha256=sha(target), members=len(names)))
    for n, r in manifest.items(): assert sha(ROOT / n) == r['sha256'], n
    report = dict(status='checkpoint-all-members-and-raw-verified', root=str(ROOT), manifest=manifest,
        rawFiles=len(files), rawBytes=sum(r['bytes'] for r in manifest.values()), archives=archives,
        limits='Implementation/scalar/analytic controls only; later district stage may add files without modifying these checkpoint members. Complete local analytic fields, test binaries/resources, commands and source-version provenance retained externally. Public archive contains metadata/postprocessing. No district target pass, production policy or admission claim.')
    save(HERE / 'implementation-archive.json', report); save(out / 'archive.json', report)
    print(json.dumps({k: v for k, v in report.items() if k != 'manifest'}, indent=2))


if __name__ == '__main__': main()
