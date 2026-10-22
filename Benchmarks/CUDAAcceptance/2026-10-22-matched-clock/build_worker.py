"""Python-only clock override; compiled CUDA source and numerical kernels unchanged."""
import ast
import hashlib
import json
from pathlib import Path
import shutil

HERE = Path(__file__).resolve().parent
ROOT = Path('/Volumes/StudioData/bombcad/experiments/2026-10-22-matched-clock')


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    preflight = json.loads((ROOT / 'preflight.json').read_text())
    assert preflight['status'] == 'preflight-pass-no-GPU-solves'
    for name, digest in preflight['pins'].items():
        assert sha(name) == digest, name
    out = ROOT / 'variant'
    out.mkdir(exist_ok=False)
    for path in (ROOT / 'worker').iterdir():
        shutil.copyfile(path, out / path.name)
    p = out / 'run.py'
    source = p.read_text()
    original = sha(p)
    def replace(a, b):
        nonlocal source
        assert source.count(a) == 1, a
        source = source.replace(a, b)
    replace('def run(folder, source_path, out, cache_dir=None, trace_columns=None, full_grid_cooling=False):',
            'def run(folder, source_path, out, cache_dir=None, trace_columns=None, full_grid_cooling=False, forced_dt_path=None):')
    replace('    import torch\n    source=Path(source_path).read_text()', '''    import torch
    import struct as clock_struct
    forced_dt=None
    forced_dt_sha=None
    if forced_dt_path is not None:
        forced_dt=np.load(forced_dt_path,allow_pickle=False)
        if forced_dt.dtype!=np.dtype('<f4') or forced_dt.ndim!=1 or len(forced_dt)==0 or not np.isfinite(forced_dt).all() or not (forced_dt>0).all():
            raise ValueError('finite positive one-dimensional Float32 dt history required')
        forced_dt_sha=hashlib.sha256(Path(forced_dt_path).read_bytes()).hexdigest()
    clock_events=[]
    source=Path(source_path).read_text()''')
    replace('        prepare_uniforms=blob(prepared)', '''        if forced_dt is not None:
            if steps>=len(forced_dt):
                raise RuntimeError('forced schedule exhausted without original stopping condition')
            prepared.forcedStep=float(forced_dt[steps])
        prepare_uniforms=blob(prepared)''')
    replace('        control=Control.from_buffer_copy(controls.cpu().numpy().tobytes())', '''        control=Control.from_buffer_copy(controls.cpu().numpy().tobytes())
        raw_control=bytes(control)
        clock_events.append(dict(activeBefore=steps,dt=float(control.dt),
            dtWord=clock_struct.unpack_from('<I',raw_control,Control.dt.offset)[0],
            clockTicks=(int(control.clockHigh)<<32)|int(control.clockLow),
            batchTime=float(control.batchTime),stepIndex=int(control.stepIndex),
            activeSteps=int(control.activeSteps),stopped=int(control.stopped),
            maxOverpressureWord=clock_struct.unpack_from('<I',raw_control,Control.maxOverpressure.offset)[0]))
        if len(clock_events)%128==0:
            Path(out).with_name(Path(out).name+'-clock-progress.json').write_text(
                json.dumps(dict(forced=forced_dt is not None,events=clock_events),indent=2)+'\\n')''')
    replace("    (out/'result.json').write_text", '''    (out/'clock-events.json').write_text(json.dumps(dict(
        schema='bombcad-clock-events-1',forced=forced_dt is not None,
        historySHA256=forced_dt_sha,events=clock_events,
        scope='Actual relative device clock and controls; original raw pressure-trace times retained'),indent=2)+'\\n')
    report['forcedClockDiagnostic']=dict(enabled=forced_dt is not None,historySHA256=forced_dt_sha,
        requestedSteps=None if forced_dt is None else len(forced_dt),
        source='existing prepare-uniform forcedStep; no new CUDA source or kernel')
    (out/'result.json').write_text''')
    replace("    p.add_argument('--lock',type=Path,help='shared remote-train lock directory')",
            "    p.add_argument('--lock',type=Path,help='shared remote-train lock directory')\n    p.add_argument('--dt-history',type=Path,help='diagnostic captured Float32 active dt schedule')")
    replace('run(a.job,a.source,a.out,a.cache_dir,a.trace_columns,a.full_grid_cooling)',
            'run(a.job,a.source,a.out,a.cache_dir,a.trace_columns,a.full_grid_cooling,a.dt_history)')
    ast.parse(source)
    p.write_text(source)
    for name in ['solver.cu', 'compile.py', 'trace_columns.py', 'job.py', 'remote-train.py']:
        assert sha(out / name) == sha(ROOT / 'worker' / name)
    shutil.copyfile(__file__, ROOT / 'analysis/build_worker.py')
    report = dict(status='built-not-run', originalWorkerSHA256=original,
                  workerSHA256={p.name: sha(p) for p in out.iterdir()},
                  sourceAndCompilerUnchanged=True, variant='Python prepare-uniform override plus passive control ledger',
                  originalBatchStoppingClippingAndSafetyRetained=True,
                  noHistoryMode='No prepare value changes; all original numeric/trace byte parity required.')
    (ROOT / 'worker-build.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
