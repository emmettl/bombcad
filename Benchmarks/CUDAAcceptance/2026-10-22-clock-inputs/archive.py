"""Preserve every raw capture and analysis file; verify decompressed member bytes."""
import hashlib
import json
from pathlib import Path
import tarfile

ROOT = Path('/Volumes/StudioData/bombcad/experiments/2026-10-22-clock-inputs')
HERE = Path(__file__).resolve().parent


def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def main():
    from audit_capture import verify_pin
    result = json.loads((ROOT / 'capture-audit.json').read_text())
    assert result['allSixOwnBackendCaptureGatesPass']
    assert json.loads((ROOT / 'remote-verification.json').read_text())['status'] == 'verified'
    metal = json.loads((ROOT / 'metal-capture.json').read_text())
    for mapping in [metal['pins'], metal['consumed'], result['consumed']]:
        for name, h in mapping.items():
            verify_pin(name, h)
    for mode in ['baseline', 'capture']:
        state = json.loads((ROOT / (mode+'-controller.json')).read_text())
        assert state['status'] == 'terminal' and state['returncode'] == 0
        for name, h in state['pins'].items():
            verify_pin(name, h)
    out = ROOT.with_name(ROOT.name + '-archive')
    out.mkdir(exist_ok=False)
    files = sorted(p for p in ROOT.rglob('*') if p.is_file())
    manifest = {str(p.relative_to(ROOT)): dict(sha256=digest(p), bytes=p.stat().st_size) for p in files}
    metadata = [n for n in manifest if n.split('/')[0] not in ['runtime', 'sources', 'runtime-metal', 'sources-metal']
                and Path(n).suffix in ['.json', '.log', '.py', '.md']]
    assert not any(n.startswith(('runtime-metal/', 'sources-metal/')) for n in metadata)
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
                   limits='All local capture histories, target maps, full coarse-state hashes, source/runtime snapshots and outcomes retained externally; public archive contains metadata/postprocessing. Complete dense CUDA fields remain on PC under freshly verified inventories. Original full initial states remain in pinned parent archives/jobs. Native selector own/cross replay and attribution remain pending; capture fidelity is not cross-backend acceptance.')
    for path in [HERE / 'archive.json', out / 'archive.json']:
        with path.open('x') as stream:
            json.dump(receipt, stream, indent=2)
            stream.write('\n')
    print(json.dumps({k: v for k, v in receipt.items() if k != 'manifest'}, indent=2))


if __name__ == '__main__':
    main()
