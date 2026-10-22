"""Independent native-output, sample-accounting and fresh remote inventory checks."""
import hashlib
import json
from pathlib import Path
import shlex
import subprocess

import numpy as np

ROOT = Path('/Volumes/StudioData/bombcad/experiments/2026-10-22-native-pressure-cross-replay')


def sha(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def main():
    load = lambda path: json.loads(Path(path).read_text())
    mappings = [load(ROOT / 'preparation.json')['pins'], load(ROOT / 'preparation.json')['consumed'],
                load(ROOT / 'cuda-staging.json')['pins'], load(ROOT / 'cuda-staging.json')['consumed'],
                load(ROOT / 'comparison-pins.json')['pins'], load(ROOT / 'matrix-results.json')['consumed']]
    for mapping in mappings:
        for path, expected in mapping.items():
            assert sha(path) == expected, path
    totals = {}
    accounting = []
    for backend, manifest in [('metal', 'metal-own.json'), ('cuda', 'metal-cross.json')]:
        rows = load(ROOT / manifest)['cases']
        assert {r['label'].rsplit('-', 1)[0] for r in rows} == {'made-perimeter-s1-1', 'made-perimeter-s3-1', 'beirut-p0-1'}
        totals[backend] = 0
        for item in rows:
            folder = Path(item['folder'])
            frames, count = item['frames'], len(item['columns'])
            dt = np.fromfile(folder / 'controls.bin', dtype='<f4').reshape(frames, -1)[:, 0]
            totals[backend] += frames * count
            expected = np.fromfile(folder / 'expected-pressure.bin', dtype='<u4')
            native_path = folder / 'metal-pressure.bin' if backend == 'metal' else ROOT / 'cuda-own' / item['label'] / 'pressure.bin'
            native = np.fromfile(native_path, dtype='<u4')
            assert np.array_equal(native, expected)
            accounting.append(dict(label=item['label'], samples=frames, active=int(np.count_nonzero(dt > 0)),
                                   zeroDt=int(np.count_nonzero(dt == 0)), selectedColumns=count))
    assert totals == load(ROOT / 'matrix-results.json')['nativeWordCounts']
    expected = np.fromfile(ROOT / 'controls/ideal/expected-pressure.bin', dtype='<u4')
    for path in [ROOT / 'controls/ideal/metal-pressure.bin', ROOT / 'cuda-own/ideal-interpolation-kinetic-zero-weight/pressure.bin']:
        assert np.array_equal(np.fromfile(path, dtype='<u4'), expected)
    remote = {}
    for stage in ['own', 'cross']:
        config = load(ROOT / ('cuda-' + stage + '-remote.json'))
        folder = ROOT / ('cuda-' + stage)
        wanted = {str(p.relative_to(folder)): dict(sha256=sha(p), bytes=p.stat().st_size) for p in folder.rglob('*') if p.is_file()}
        receipt = load(folder / 'receipt.json')
        payload = dict(remote=config['remote'], stage=stage, wanted=wanted, runtime=receipt['selectedRuntimePins'])
        script = """import hashlib,json,pathlib
c=CONFIG
base=pathlib.Path.home()/c['remote'];out=base/'remote-input'/('out-'+c['stage'])
def digest(p):
 h=hashlib.sha256()
 with p.open('rb') as f:
  for b in iter(lambda:f.read(1048576),b''):h.update(b)
 return h.hexdigest()
actual={str(p.relative_to(out)):dict(sha256=digest(p),bytes=p.stat().st_size) for p in out.rglob('*') if p.is_file()}
assert actual==c['wanted'],'Remote output inventory differs'
for path,h in c['runtime'].items():assert digest(pathlib.Path(path))==h,path
controller=json.loads((base/'controller.json').read_text())
assert controller['status']=='terminal' and controller['returncode']==0
print(json.dumps(dict(files=actual,controller=controller,selectedRuntimePinsStillMatch=True)))
""".replace('CONFIG', repr(payload))
        remote[stage] = json.loads(subprocess.check_output(
            ['ssh', '-o', 'BatchMode=yes', 'bombcad-pc', 'python3 -c ' + shlex.quote(script)], text=True))
    receipt = dict(status='independent-native-words-input-pins-and-fresh-remote-inventories-verified',
                   nativeWords=totals, nativeRecorderWords=5 * sum(totals.values()), sampleAccounting=accounting,
                   nativeControlsPerGPU=expected.view(np.float32).tolist(), remote=remote,
                   sourceSHA256=sha(__file__), limits='Read-only verification; no GPU or PDE rerun. Selected runtime pins are not a hermetic environment.')
    with (ROOT / 'independent-verification.json').open('x') as stream:
        json.dump(receipt, stream, indent=2)
        stream.write('\n')
    print(json.dumps(dict(status=receipt['status'], nativeWords=totals, nativeRecorderWords=receipt['nativeRecorderWords'], remoteStages=list(remote)), indent=2))


if __name__ == '__main__':
    main()
