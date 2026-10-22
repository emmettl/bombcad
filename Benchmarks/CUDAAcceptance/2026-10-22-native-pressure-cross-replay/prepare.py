"""Freeze original producer libraries and captured histories without running a GPU."""
import ctypes
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import shutil
import sys

import numpy as np

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
OLD = Path('/Volumes/StudioData/bombcad/experiments/2026-10-22-metal-pressure-inputs')
CUDA = OLD.parent / '2026-10-22-phase-pressure-inputs'
BASE = OLD.parent / '2026-10-22-fixed-terrain-reference'
ROOT = OLD.parent / '2026-10-22-native-pressure-cross-replay'


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def read(path):
    return json.loads(Path(path).read_text())


def save(path, value):
    Path(path).write_text(json.dumps(value, indent=2) + '\n')


def main():
    ROOT.mkdir(exist_ok=False)
    for name in ['analysis', 'runtime', 'cases', 'controls']:
        (ROOT / name).mkdir()
    old = read(OLD / 'run.json')
    inventory = read(REPO / 'Benchmarks/CUDAAcceptance/2026-10-22-metal-pressure-inputs/archive.json')['manifest']
    assert old['allThreeCaptureGatesPass']
    consumed = {}
    def dependency(path):
        path = Path(path)
        actual = sha(path)
        if path.is_relative_to(OLD):
            assert inventory[str(path.relative_to(OLD))]['sha256'] == actual, path
        elif str(path) in old['pins']:
            assert old['pins'][str(path)] == actual, path
        consumed[str(path)] = actual
        return path

    for name in ['prepare.py', 'replay.swift', 'plan.md']:
        shutil.copyfile(HERE / name, ROOT / 'analysis' / name)
    previous = read(CUDA / 'run.json')
    portable = dependency(CUDA / 'worker/job.py')
    assert sha(portable) == previous['workerSHA256']['job.py']
    shutil.copyfile(portable, ROOT / 'analysis/job.py')
    spec = importlib.util.spec_from_file_location('wire', ROOT / 'analysis/job.py')
    wire = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(wire)
    producer_path = next(Path(x['snapshot']) for x in old['snapshots'] if x['original'].endswith('/StructureTypes+GPU.swift'))
    producer = dependency(producer_path).read_text()
    names = re.findall(r'"([^"]+)"', re.search(r'let files = \[(.*?)\]', producer, re.S).group(1))
    start = producer.index('    static func addingFirstPhasePressureCapture(')
    end = producer.index('    /// `constants`', start)
    transform = producer[start:end].rstrip()
    source = (HERE / 'replay.swift').read_text()
    assert source.count('    // INSERT_FROZEN_PRESSURE_TRANSFORM') == 1
    (ROOT / 'analysis/replay.swift').write_text(source.replace('    // INSERT_FROZEN_PRESSURE_TRANSFORM', transform))
    resource = OLD / 'runtime/BombCAD_BlastCore.bundle/Contents/Resources/Shaders'
    fragments = []
    for name in names:
        src = dependency(resource / (name + '.metal'))
        dest = ROOT / 'analysis' / src.name
        shutil.copyfile(src, dest)
        fragments.append(str(dest))
    prefix = dependency(OLD / 'runtime/ContinuumKit_ContactSearchMetal.bundle/Contents/Resources/Shaders/ContactSearchFunctions.metal')
    shutil.copyfile(prefix, ROOT / 'analysis/ContactSearchFunctions.metal')
    metal_source = (resource / 'Solver.metal').read_text()
    cuda_source = dependency(CUDA / 'worker/solver.cu').read_text()
    for name in ['solver.cu', 'compile.py', 'trace_columns.py', 'run.py']:
        p = dependency(CUDA / 'worker' / name)
        assert sha(p) == previous['workerSHA256'][name]
        shutil.copyfile(p, ROOT / 'analysis' / name.replace('run.py', 'original-worker.py'))
    MU = wire.scalar_layout(metal_source, 'SolverUniforms')
    MC = wire.scalar_layout(metal_source, 'StepControl')
    CU = wire.scalar_layout(cuda_source, 'SolverUniforms')
    CC = wire.scalar_layout(cuda_source, 'StepControl')
    cases = {'metal': [], 'cuda': []}

    def write_case(folder, label, inputs, trace, seeds, shape, columns, uniforms):
        folder.mkdir(exist_ok=False)
        assert inputs.dtype == trace.dtype == np.dtype('<f4')
        frames, count = inputs.shape[:2]
        assert inputs.shape == (frames, count, 16) and trace.shape == (frames, count, 8)
        assert np.isfinite(inputs).all() and np.isfinite(trace).all()
        assert np.all(inputs[:, :, :6].view(np.uint32) == inputs[0:1, :, :6].view(np.uint32))
        inputs.tofile(folder / 'inputs.bin')
        trace[:, :, 0].copy().tofile(folder / 'expected-pressure.bin')
        before = np.empty((frames, count, 5), dtype='<f4')
        before[0] = seeds
        before[1:] = trace[:-1, :, 1:6]
        before.tofile(folder / 'records-before.bin')
        trace[:, :, 1:6].copy().tofile(folder / 'records-after.bin')
        for kind, U, C in [('metal', MU, MC), ('cuda', CU, CC)]:
            u = U()
            for key, value in dict(zip(['nx', 'ny', 'nz'], shape)).items():
                setattr(u, key, value)
            fields = dict(U._fields_)
            for key, value in uniforms.items():
                assert key in fields, key
                setattr(u, key, value)
            (folder / ('uniforms-' + kind + '.bin')).write_bytes(bytes(u))
            controls = []
            for frame in range(frames):
                assert np.all(trace[frame, :, 6:8].view(np.uint32) == trace[frame, 0:1, 6:8].view(np.uint32))
                c = C()
                c.dt = float(trace[frame, 0, 6])
                c.batchTime = float(trace[frame, 0, 7])
                controls.append(bytes(c))
            (folder / ('controls.bin' if kind == 'metal' else 'controls-cuda.bin')).write_bytes(b''.join(controls))
        return dict(label=label, folder=str(folder), frames=frames, columns=columns, shape=shape,
                    controlBytes=ctypes.sizeof(MC), cudaControlBytes=ctypes.sizeof(CC))

    prior = dependency(CUDA / 'analysis-results.json')
    prior = read(prior)
    for row in old['rows']:
        name, columns = row['id'], row['columns']
        job = read(dependency(BASE / 'cases' / name / 'input/job.json'))
        old_cuda = next(r for r in prior['rows'] if r['id'] == name)
        for backend in ['metal', 'cuda']:
            folder = OLD / 'cases' / name / 'inputs' if backend == 'metal' else CUDA / 'cases' / name
            inputs = np.load(dependency(folder / 'pressure-inputs.npy'), allow_pickle=False)
            trace = np.load(dependency(folder / ('pressure-trace.npy' if backend == 'metal' else 'trace.npy')), allow_pickle=False)
            meta = read(dependency(folder / ('pressure-trace.json' if backend == 'metal' else 'trace.json')))
            seeds = meta['seedRecords'] if backend == 'metal' else [c['seed'] for c in old_cuda['nativeColumns']]
            item = write_case(ROOT / 'cases' / (name + '-' + backend), name + '-' + backend,
                              inputs, trace, seeds, job['shape'], columns, job['uniforms'])
            save(Path(item['folder']) / 'times-and-seeds.json', dict(times=meta['times'], seeds=seeds, backend=backend))
            cases[backend].append(item)

    inputs = np.zeros((2, 3, 16), dtype='<f4')
    for i, (fraction, low, high) in enumerate([
        (.25, [1, 0, 0, 0, 200], [1, 0, 0, 0, 400]),
        (.5, [2, 4, 0, 0, 104], [2, 4, 0, 0, 104]),
        (0., [1, 0, 0, 0, 20], [1, 0, 0, 0, 2000]),
    ]):
        inputs[:, i] = [0, 1, fraction, 1, 1 - fraction, fraction, *low, *high]
    trace = np.zeros((2, 3, 8), dtype='<f4')
    trace[:, :, 0] = [125, 50, 10]
    trace[1, :, 6:8] = 1
    control = write_case(ROOT / 'controls/ideal', 'ideal-interpolation-kinetic-zero-weight',
                         inputs, trace, [[0] * 5] * 3, [3, 5, 3], [0, 7, 14],
                         dict(gamma=1.5, ambientPressure=0., densityFloor=1e-6, airModel=0))
    common = dict(prefix=str(ROOT / 'analysis/ContactSearchFunctions.metal'), fragments=fragments,
                  compiledSource=str(ROOT / 'analysis/producer-library.metal'))
    for name, rows in [('controls', [control]), ('metal-own', cases['metal']), ('metal-cross', cases['cuda'])]:
        save(ROOT / (name + '.json'), dict(common, cases=rows))
    pins = {str(p): sha(p) for p in ROOT.rglob('*') if p.is_file()}
    save(ROOT / 'preparation.json', dict(status='prepared-no-numerical-replay', consumed=consumed, pins=pins,
         python=sys.version, numpy=np.__version__, transformSHA256=hashlib.sha256(transform.encode()).hexdigest(),
         uniformBytes=dict(metal=ctypes.sizeof(MU), cuda=ctypes.sizeof(CU)),
         controls=dict(metal=ctypes.sizeof(MC), cuda=ctypes.sizeof(CC)),
         scope='Original gas-read uniforms and pressure-read control fields preserved; unused fields zero. Sparse original-geometry context requires own-input word parity.'))
    print('Frozen native library transform, controls and all six input histories prepared; no GPU replay yet.')


if __name__ == '__main__':
    main()
