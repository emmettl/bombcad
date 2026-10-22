"""Stage exact archived CUDA diagnostic source and tiny raw history inputs."""
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
ROOT = Path('/Volumes/StudioData/bombcad/experiments/2026-10-22-native-pressure-cross-replay')
OLD = ROOT.parent / '2026-10-22-phase-pressure-inputs'


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    gate = json.loads((ROOT / 'metal-own-gate.json').read_text())
    assert gate['status'] == 'pass'
    inventory = json.loads((REPO / 'Benchmarks/CUDAAcceptance/2026-10-22-phase-pressure-inputs/archive.json').read_text())['files']
    pack = ROOT / 'remote-input'
    pack.mkdir(exist_ok=False)
    (pack / 'worker').mkdir()
    consumed = {}
    for name in ['solver.cu', 'compile.py', 'trace_columns.py', 'job.py', 'remote-train.py', 'run.py']:
        p = OLD / 'worker' / name
        assert sha(p) == inventory['worker/' + name]['sha256']
        consumed[str(p)] = sha(p)
        shutil.copyfile(p, pack / 'worker' / ('original-worker.py' if name == 'run.py' else name))
    shutil.copyfile(HERE / 'cuda_replay.py', pack / 'worker/cuda_replay.py')
    shutil.copyfile(HERE / 'cuda_replay.py', ROOT / 'analysis/cuda_replay.py')
    shutil.copyfile(__file__, ROOT / 'analysis/stage_cuda.py')
    spec = importlib.util.spec_from_file_location('archived_trace', pack / 'worker/trace_columns.py')
    trace = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(trace)
    source = (pack / 'worker/solver.cu').read_text()
    diagnostic = source + trace.trace_source(source) + trace.input_source()
    source_hash = hashlib.sha256(diagnostic.encode()).hexdigest()
    controls = json.loads((ROOT / 'controls.json').read_text())['cases']
    metal = json.loads((ROOT / 'metal-own.json').read_text())['cases']
    cuda = json.loads((ROOT / 'metal-cross.json').read_text())['cases']
    entries = {}
    for item in [*controls, *metal, *cuda]:
        row = dict(item)
        label = row['label']
        if item in controls:
            relative = 'controls/ideal'
            row.update(cutCells=False, mathematicalControl=True)
        else:
            relative = 'cases/' + label
            name = label.rsplit('-', 1)[0]
            path = OLD / 'cases' / name / 'result.json'
            assert sha(path) == inventory[str(path.relative_to(OLD))]['sha256']
            result = json.loads(path.read_text())
            assert result['diagnosticSourceSHA256'] == source_hash
            row.update(cutCells=result['terrainCutCells'], mathematicalControl=False)
            consumed[str(path)] = sha(path)
        src = Path(item['folder'])
        dest = pack / relative
        dest.mkdir(parents=True, exist_ok=False)
        for name in ['inputs.bin', 'expected-pressure.bin', 'records-after.bin', 'controls-cuda.bin', 'uniforms-cuda.bin']:
            shutil.copyfile(src / name, dest / name)
        row['folder'] = relative
        entries[label] = row
    worker = {p.name: sha(p) for p in (pack / 'worker').iterdir()}
    inputs = {str(p.relative_to(pack)): sha(p) for p in pack.rglob('*') if p.is_file() and p.parent != pack / 'worker'}
    common = dict(workerSHA256=worker, inputSHA256=inputs, diagnosticSourceSHA256=source_hash)
    for stage, items in [('own', [*controls, *cuda]), ('cross', metal)]:
        (pack / (stage + '.json')).write_text(json.dumps(dict(common, cases=[entries[x['label']] for x in items]), indent=2) + '\n')
    (ROOT / 'cuda-staging.json').write_text(json.dumps(dict(status='staged-not-run', consumed=consumed,
        pins={str(p): sha(p) for p in pack.rglob('*') if p.is_file()}, diagnosticSourceSHA256=source_hash), indent=2) + '\n')
    print('Exact archived CUDA compilation source attested:', source_hash)


if __name__ == '__main__':
    main()
