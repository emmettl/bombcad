"""Preserve every raw capture and analysis file; verify decompressed member bytes."""
import hashlib
import json
from pathlib import Path
import tarfile

ROOT = Path('/Volumes/StudioData/bombcad/experiments/2026-10-22-clock-selection')
HERE = Path(__file__).resolve().parent


def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def main():
    result = json.loads((ROOT / 'results.json').read_text())
    assert result['status'] == 'complete-all-outcomes' and result['allSixFirstDTGatesPass']
    assert json.loads((ROOT / 'verification.json').read_text())['status'] == 'verified'
    prepared = json.loads((ROOT / 'preparation.json').read_text())
    for mapping in [prepared['pins'], prepared['consumed'], result['consumed']]:
        for name, h in mapping.items():
            assert digest(name) == h, name
    out = ROOT.with_name(ROOT.name + '-archive')
    out.mkdir(exist_ok=False)
    files = sorted(p for p in ROOT.rglob('*') if p.is_file())
    manifest = {str(p.relative_to(ROOT)): dict(sha256=digest(p), bytes=p.stat().st_size) for p in files}
    metadata = [n for n in manifest if n.split('/')[0] not in ['runtime', 'sources']
                and Path(n).suffix in ['.json', '.log', '.py', '.md']]
    (HERE / 'evidence').mkdir(exist_ok=True)
    targets = [(out / 'all-raw.tar.gz', list(manifest)), (HERE / 'evidence/metadata.tar.gz', metadata)]
    archives = []
    for path, names in targets:
        assert not path.exists()
        with tarfile.open(path, 'w:gz', compresslevel=6) as tar:
            for name in names:
                tar.add(ROOT / name, arcname=name, recursive=False)
        with tarfile.open(path, 'r:gz') as tar:
            members = tar.getmembers()
            assert [m.name for m in members] == names
            for member in members:
                stream = tar.extractfile(member)
                assert stream is not None
                h = hashlib.sha256()
                count = 0
                for block in iter(lambda: stream.read(1024 * 1024), b''):
                    h.update(block)
                    count += len(block)
                assert dict(sha256=h.hexdigest(), bytes=count) == manifest[member.name]
        archives.append(dict(path=str(path), sha256=digest(path), bytes=path.stat().st_size, members=len(names)))
    for name, value in manifest.items():
        assert digest(ROOT / name) == value['sha256']
    receipt = dict(status='all-members-and-raw-rehash-verified', root=str(ROOT), manifest=manifest, archives=archives,
                   rawFiles=len(manifest), rawBytes=sum(v['bytes'] for v in manifest.values()),
                   limits='Native initial-speed/control outputs, full producer source/PTX, build failures and all local evidence retained externally; public archive contains metadata/postprocessing. No PDE evolution. Complete initial state/mask files remain in the pinned parent archive and original PC jobs; fresh local/remote hashes verified. No exhaustive argmax/tie capture or later-state attribution.')
    for path in [HERE / 'archive.json', out / 'archive.json']:
        with path.open('x') as stream:
            json.dump(receipt, stream, indent=2)
            stream.write('\n')
    print(json.dumps({k: v for k, v in receipt.items() if k != 'manifest'}, indent=2))


if __name__ == '__main__':
    main()
