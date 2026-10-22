"""Freeze and preflight all three common-clock schedules before GPU work."""
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys

import numpy as np
from clock_model import simulate, origin_ticks, TICKS

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
ROOT = Path('/Volumes/StudioData/bombcad/experiments/2026-10-22-matched-clock')
METAL = ROOT.parent / '2026-10-22-metal-pressure-inputs'
CUDA = ROOT.parent / '2026-10-22-phase-pressure-inputs'
BASE = ROOT.parent / '2026-10-22-fixed-terrain-reference'


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def load(path):
    return json.loads(Path(path).read_text())


def main():
    ROOT.mkdir(exist_ok=False)
    for name in ['analysis', 'cases', 'worker']:
        (ROOT / name).mkdir()
    consumed = {}
    mi = load(REPO / 'Benchmarks/CUDAAcceptance/2026-10-22-metal-pressure-inputs/archive.json')['manifest']
    ci = load(REPO / 'Benchmarks/CUDAAcceptance/2026-10-22-phase-pressure-inputs/archive.json')['files']
    parent = load(METAL / 'run.json')
    def dependency(path):
        path = Path(path)
        actual = sha(path)
        if path.is_relative_to(METAL):
            expected = mi[str(path.relative_to(METAL))]['sha256']
        elif path.is_relative_to(CUDA):
            expected = ci[str(path.relative_to(CUDA))]['sha256']
        else:
            expected = parent['pins'][str(path)]
        assert actual == expected, path
        consumed[str(path)] = actual
        return path
    for name in ['prepare.py', 'clock_model.py', 'check_clock.py', 'plan.md']:
        shutil.copyfile(HERE / name, ROOT / 'analysis' / name)
    for name in ['run.py', 'job.py', 'compile.py', 'trace_columns.py', 'solver.cu', 'remote-train.py']:
        shutil.copyfile(dependency(CUDA / 'worker' / name), ROOT / 'worker' / name)
    source = (ROOT / 'worker/solver.cu').read_text()
    tokens = [line.strip() for line in source.splitlines() if 'control.maxOverpressure' in line]
    assert tokens == ['control.maxOverpressure = NAN;',
                      'control.maxOverpressure = bitsFloat(atomic_exchange_explicit(maxSpeed + 1, 0u, memory_order_relaxed));']
    forced = [line.strip() for line in source.splitlines() if 'u.forcedStep' in line]
    assert forced == ['if (u.forcedStep > 0.0f) {', 'dt = u.forcedStep;', 'if (u.forcedStep == 0.0f) {']
    assert 'if (floatBits(fastest) >= 0x7F800000u)' in source
    assert 'atomic_store_explicit(maxSpeed, 0u, memory_order_relaxed);' in source
    speed_second = [line.strip() for line in source.splitlines() if 'maxSpeed + 1' in line]
    assert len(speed_second) == 2 and 'recordWaveSpeed(maxSpeed + 1' in speed_second[0]
    original_worker = (ROOT / 'worker/run.py').read_text()
    assert 'control.maxOverpressure' not in original_worker
    state_path = next(Path(s['snapshot']) for s in parent['snapshots'] if s['original'].endswith('/BlastSolver+State.swift'))
    state_source = dependency(state_path).read_text()
    assert 'clockTicks = UInt64((start / StepControl.tick).rounded())' in state_source
    rows = []
    for case in parent['rows']:
        name = case['id']
        folder = ROOT / 'cases' / name
        folder.mkdir()
        job = load(dependency(BASE / 'cases' / name / 'input/job.json'))
        metal_folder = METAL / 'cases' / name / 'inputs'
        trace = np.load(dependency(metal_folder / 'pressure-trace.npy'), allow_pickle=False)
        meta = load(dependency(metal_folder / 'pressure-trace.json'))
        active = trace[:, 0, 6] > 0
        dt = trace[active, 0, 6]
        assert dt.dtype == np.dtype('<f4') and np.isfinite(dt).all()
        assert np.all(trace[:, :, 6].view(np.uint32) == trace[:, 0:1, 6].view(np.uint32))
        model = simulate(dt, job['duration'])
        assert model['exact'], (name, model['differentIndices'], model['stopped'])
        cuda_trace = np.load(dependency(CUDA / 'cases' / name / 'trace.npy'), allow_pickle=False)
        cuda_dt = cuda_trace[cuda_trace[:, 0, 6] > 0, 0, 6]
        baseline_model = simulate(cuda_dt, job['duration'])
        assert baseline_model['exact']
        reference_times = np.asarray(meta['times'], dtype=np.float64)[active]
        ticks = origin_ticks(job['startTime'])
        prefix = np.cumsum([int(float(x) * TICKS) for x in dt], dtype=np.uint64)
        assert np.array_equal((ticks + prefix).astype(np.float64) / TICKS, reference_times)
        dt.tofile(folder / 'metal-dt.bin')
        np.save(folder / 'metal-dt.npy', dt)
        save = lambda p, v: Path(p).write_text(json.dumps(v, indent=2) + '\n')
        save(folder / 'clock-plan.json', dict(id=name, columns=case['columns'], count=len(dt),
             startTime=job['startTime'], duration=job['duration'], metalOriginTick=ticks,
             rawOriginMinusTickOrigin=job['startTime'] - ticks / TICKS,
             metalActiveTimes=reference_times.tolist(), referenceDT_SHA256=sha(folder / 'metal-dt.npy'),
             model=model, nativeCUDAClockControl=baseline_model))
        rows.append(dict(id=name, activeSteps=len(dt), modelExact=True, nativeCUDAControlExact=True,
                         inactiveModelRows=sum(e['dt'] == 0 for e in model['events']),
                         metalOriginTick=ticks, rawOriginMinusTickOrigin=job['startTime'] - ticks / TICKS,
                         deviceTickAxisReconstructsMetalExactly=True, endTime=float(reference_times[-1])))
    with (ROOT / 'clock-controls.log').open('xb') as log:
        control = subprocess.run([sys.executable, '-B', str(ROOT / 'analysis/check_clock.py')], stdout=log, stderr=subprocess.STDOUT)
    assert control.returncode == 0
    report = dict(status='preflight-pass-no-GPU-solves', rows=rows, controls=4, controlReturncode=control.returncode,
                  consumed=consumed, pins={str(p): sha(p) for p in ROOT.rglob('*') if p.is_file()},
                  forcedStepAudit=dict(maxOverpressureOnlyWritten=True, workerDoesNotReadMaxOverpressure=True,
                    secondSpeedSlotOnlyDiagnostic=True, fastestSpeedAccumulatorResetUnchanged=True,
                    nonphysicalSpeedGuardUnchanged=True, originalBatchAndStoppingUnchanged=True),
                  clockCoordinate='Original raw trace retained; rounded Metal origin comes from frozen native source, not a fitted offset.')
    (ROOT / 'preflight.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({k: v for k, v in report.items() if k not in ['pins', 'consumed']}, indent=2))


if __name__ == '__main__':
    main()
