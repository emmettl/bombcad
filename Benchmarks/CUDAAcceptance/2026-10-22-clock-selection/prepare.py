"""Freeze histories, native producers and initial-selection inputs; no GPU work."""
import ctypes
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil

import numpy as np

HERE = Path(__file__).resolve().parent
ROOT = Path('/Volumes/StudioData/bombcad/experiments/2026-10-22-clock-selection')
BASE = ROOT.parent / '2026-10-22-fixed-terrain-reference'
CLOCK = ROOT.parent / '2026-10-22-matched-clock'
REPLAY = ROOT.parent / '2026-10-22-native-pressure-cross-replay'
METAL = ROOT.parent / '2026-10-22-metal-pressure-inputs'


def sha(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as f:
        for b in iter(lambda: f.read(1048576), b''):
            h.update(b)
    return h.hexdigest()


def load(path):
    return json.loads(Path(path).read_text())


def save(path, value):
    Path(path).write_text(json.dumps(value, indent=2) + '\n')


def main():
    ROOT.mkdir(exist_ok=False)
    for name in ['analysis', 'runtime', 'cases', 'worker']:
        (ROOT / name).mkdir()
    inventories = {CLOCK: load(HERE.parent / CLOCK.name / 'archive.json')['manifest'],
        REPLAY: load(HERE.parent / REPLAY.name / 'archive.json')['manifest'],
        BASE: load(HERE.parent / BASE.name / 'pilot-archive.json')['files'],
        METAL: load(HERE.parent / METAL.name / 'archive.json')['manifest']}
    consumed = {}

    def pin(path):
        path = Path(path)
        actual = sha(path)
        root = next(r for r in inventories if path.is_relative_to(r))
        assert inventories[root][str(path.relative_to(root))]['sha256'] == actual, path
        consumed[str(path)] = actual
        return path

    for p in HERE.glob('*'):
        if p.suffix in ['.py', '.swift', '.md']:
            shutil.copyfile(p, ROOT / 'analysis' / p.name)
    for name in ['solver.cu', 'compile.py', 'trace_columns.py', 'remote-train.py', 'job.py']:
        shutil.copyfile(pin(CLOCK / 'worker' / name), ROOT / 'worker' / name)
    shutil.copyfile(pin(REPLAY / 'analysis/producer-library.metal'), ROOT / 'analysis/producer-library.metal')
    for name in ['0117-BlastSolver+State.swift', '0118-BlastSolver+Stepping.swift',
                 '0121-BlastSolver.swift', '0210-StructureTypes+GPU.swift']:
        shutil.copyfile(pin(METAL / 'sources' / name), ROOT / 'analysis' / name)
    stepping = (ROOT / 'analysis/0118-BlastSolver+Stepping.swift').read_text()
    assert 'Float(globalStep - rampStart + 1) / Float(max(configuration.startupSteps, 1))' in stepping
    assert 'makeUniforms(cfl: configuration.cfl * ramp)' in stepping
    spec = importlib.util.spec_from_file_location('wire', ROOT / 'worker/job.py')
    wire = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(wire)
    metal = (ROOT / 'analysis/producer-library.metal').read_text()
    cuda = (ROOT / 'worker/solver.cu').read_text()
    rows = []
    remote_rows = load(pin(CLOCK / 'baseline/receipt.json'))['rows']
    for item in remote_rows:
        name = item['id']
        folder = ROOT / 'cases' / name
        folder.mkdir()
        inp = BASE / 'cases' / name / 'input'
        job = load(pin(inp / 'job.json'))
        for filename in ['state.bin', 'mask.bin']:
            assert sha(pin(inp / filename)) == job['files'][filename]
        m = np.load(pin(CLOCK / 'cases' / name / 'metal-dt.npy'))
        c = np.load(pin(CLOCK / 'baseline' / name / 'dt.npy'))
        unequal = np.flatnonzero(m.view('<u4') != c.view('<u4'))
        cfls = []
        for i in range(len(m)):
            numerator = job['startStep'] + i + 1
            denominator = job['startupSteps']
            swift_ramp = min(np.float32(1), np.float32(numerator) / np.float32(denominator))
            cuda_ramp = np.float32(min(1., float(np.float32(numerator / denominator))))
            a = np.float32(np.float32(job['uniforms']['cfl']) * swift_ramp)
            b = np.float32(np.float32(job['uniforms']['cfl']) * cuda_ramp)
            assert a.view('u4') == b.view('u4')
            cfls.append(float(a))
        for backend, source in [('metal', metal), ('cuda', cuda)]:
            U = wire.scalar_layout(source, 'SolverUniforms')
            C = wire.scalar_layout(source, 'StepControl')
            u = U()
            for k, v in zip(['nx', 'ny', 'nz'], job['shape']):
                setattr(u, k, v)
            for k, v in job['uniforms'].items():
                setattr(u, k, v)
            (folder / ('measure-' + backend + '.bin')).write_bytes(bytes(u))
            u.cfl = cfls[0]
            (folder / ('prepare-' + backend + '.bin')).write_bytes(bytes(u))
            control = C()
            control.timeLimit = job['duration']
            if backend == 'metal':
                ticks = load(pin(CLOCK / 'cases' / name / 'clock-plan.json'))['metalOriginTick']
                control.clockLow, control.clockHigh = ticks & 0xffffffff, ticks >> 32
            (folder / ('control-' + backend + '.bin')).write_bytes(bytes(control))
        rows.append(dict(id=name, shape=job['shape'], localInput=str(inp),
            remoteInput=str(Path(item['physicalInput'])), physicalFiles=job['files'],
            expectedFirstDT=dict(metal=int(m.view('<u4')[0]), cuda=int(c.view('<u4')[0])),
            history=dict(activeSteps=len(m), differentWords=len(unequal), firstDifferentActiveStep=int(unequal[0])+1,
                firstMetalWord=int(m.view('<u4')[unequal[0]]), firstCUDAWord=int(c.view('<u4')[unequal[0]]),
                allPreparedCFLWordsEqual=True, firstCFL=cfls[0], firstSixCFL=cfls[:6]),
            cutCells='terrain' in job, controlBytes=ctypes.sizeof(C)))
    source_audit = {}
    for label, source, start, end in [
        ('metal', metal, '    float fastest = as_type<float>(atomic_load_explicit(maxSpeed, memory_order_relaxed));', '    logGauges(gaugeLog, control.stepIndex'),
        ('cuda', cuda, '    float fastest = bitsFloat(atomic_load_explicit(maxSpeed, memory_order_relaxed));', '\n\n    control.dt = dt;')]:
        snippet = source[source.index(start):]
        snippet = snippet[:snippet.index(end)]
        source_audit[label] = snippet
    normalized = source_audit['metal'].replace('as_type<float>', 'bitsFloat').replace('as_type<uint>', 'floatBits')
    assert normalized.strip() == source_audit['cuda'].strip()
    save(ROOT / 'source-audit.json', dict(selectionBodyIdenticalAfterBitcastSpelling=True,
        snippets=source_audit, noAdditionalDTGrowthLimiterInSelectors=True,
        limits='Host startup CFL arithmetic checked wordwise; matching source text does not establish matching device arithmetic.'))
    report = dict(status='prepared-no-GPU', rows=rows, consumed=consumed,
        pins={str(p): sha(p) for p in ROOT.rglob('*') if p.is_file()})
    save(ROOT / 'preparation.json', report)
    print(json.dumps(dict(rows=rows, sourceAudit='selection bodies exact after bitcast spelling'), indent=2))


if __name__ == '__main__':
    main()
