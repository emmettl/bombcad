"""Archive every outcome; verify decompressed members and immutable parent bytes."""
import hashlib
from pathlib import Path
import shutil
import tarfile

from prepare import HERE, ROOT, PARENT, load, save, sha


def main():
    assert load(ROOT / 'verification.json')['allFourExpandedGatesPass']
    original = load(HERE.parent / PARENT.name / 'archive.json')['manifest']
    for name, item in original.items():
        assert sha(PARENT / name) == item['sha256'], name
    publication = ROOT / 'publication-sources'
    publication.mkdir(exist_ok=False)
    for p in HERE.iterdir():
        if p.suffix in ['.py', '.md']:
            shutil.copyfile(p, publication / p.name)
    for name in ['histories.json', 'verification.json']:
        shutil.copyfile(ROOT / name, HERE / name)
    out = ROOT.with_name(ROOT.name + '-complete-archive')
    out.mkdir(exist_ok=False)
    manifest = {str(p.relative_to(ROOT)): dict(sha256=sha(p), bytes=p.stat().st_size)
        for p in sorted(ROOT.rglob('*')) if p.is_file() and '__pycache__' not in p.parts}
    metadata = [n for n in manifest if Path(n).suffix in ['.py', '.md', '.json', '.log', '.txt']]
    (HERE / 'evidence').mkdir(exist_ok=True)
    archives = []
    for target, names in [(out / 'all-raw.tar.gz', list(manifest)), (HERE / 'evidence/metadata.tar.gz', metadata)]:
        assert not target.exists()
        with tarfile.open(target, 'w:gz', compresslevel=6) as tar:
            for n in names:
                tar.add(ROOT / n, arcname=n, recursive=False)
        with tarfile.open(target, 'r:gz') as tar:
            assert [m.name for m in tar.getmembers()] == names
            for member in tar.getmembers():
                stream = tar.extractfile(member)
                assert stream is not None
                h = hashlib.sha256()
                count = 0
                for block in iter(lambda: stream.read(1048576), b''):
                    h.update(block)
                    count += len(block)
                assert dict(sha256=h.hexdigest(), bytes=count) == manifest[member.name]
        archives.append(dict(path=str(target), bytes=target.stat().st_size, sha256=sha(target), members=len(names)))
    for n, item in manifest.items():
        assert sha(ROOT / n) == item['sha256'], n
    report = dict(status='all-members-and-local-raw-rehash-verified', root=str(ROOT), manifest=manifest,
        rawFiles=len(manifest), rawBytes=sum(x['bytes'] for x in manifest.values()), archives=archives,
        parentFilesVerifiedUnchanged=len(original), physicalJobs=4, numericalRetries=0,
        limits='Complete selected histories/ordinary arrays/state hashes/clock streams retained. Full district3D states and per-cell peak argmax histories not captured. Original JSON-order controller stop retained. No source/default/reference/tolerance/phase/admission change.')
    save(HERE / 'archive.json', report)
    save(out / 'archive.json', report)
    print({k: v for k, v in report.items() if k != 'manifest'})


if __name__ == '__main__':
    main()
