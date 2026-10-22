"""Freeze an optional CPU-only capture around original CUDA prepare, without changing kernels."""
import ast
from pathlib import Path
import shutil

from run_metal import ROOT, HERE, BASE, sha, load


def main():
    old = ROOT.parent / '2026-10-22-phase-pressure-inputs'
    archive = load(HERE.parent / old.name / 'archive.json')['files']
    worker = ROOT / 'cuda-worker'
    variant = ROOT / 'cuda-variant'
    worker.mkdir(exist_ok=False)
    variant.mkdir(exist_ok=False)
    consumed = {}
    for name in ['run.py', 'solver.cu', 'job.py', 'compile.py', 'trace_columns.py', 'remote-train.py']:
        path = old / 'worker' / name
        assert sha(path) == archive['worker/' + name]['sha256']
        consumed[str(path)] = sha(path)
        shutil.copyfile(path, worker / name)
        shutil.copyfile(path, variant / name)
    source = (variant / 'run.py').read_text()

    def replace(a, b):
        nonlocal source
        assert source.count(a) == 1, a
        source = source.replace(a, b)

    replace('def run(folder, source_path, out, cache_dir=None, trace_columns=None, full_grid_cooling=False):',
        'def run(folder, source_path, out, cache_dir=None, trace_columns=None, full_grid_cooling=False, trace_clock=False):')
    replace('    steps=0;dt_history=[]', '''    steps=0;dt_history=[]
    clock_rows=[];clock_steps=[]
    clock_stream=None
    clock_c=C.sizeof(Control)//4;clock_u=len(bytes(u))//4
    clock_width=14+2*clock_c+clock_u
    if trace_clock:
        clock_stream=Path(out).with_name(Path(out).name+'-clock-inputs.partial.bin').open('xb',buffering=0)
        Path(out).with_name(Path(out).name+'-clock-inputs.partial.json').write_text(json.dumps(dict(
            format='bombcad-native-clock-inputs-partial-1',dtype='<u4',complete=False,
            recordWords=clock_width,controlWords=clock_c,uniformWords=clock_u,
            tileContext='absent in full-grid CUDA prepare; four zero placeholders before/after'),indent=2)+'\\n')''')
    replace("        launch('cudaPrepare',[controls,speed,prepare_uniforms],1)", '''        if trace_clock:
            if len(clock_rows)>=32768:
                raise RuntimeError('native clock capture overflow; no complete output')
            clock_pre=controls.cpu().numpy().tobytes()
            clock_speed=speed.cpu().numpy().tobytes()
            clock_uniform=bytes(prepared)
        launch('cudaPrepare',[controls,speed,prepare_uniforms],1)
        if trace_clock:
            clock_post=controls.cpu().numpy().tobytes()
            clock_speed_post=speed.cpu().numpy().tobytes()
            clock_row=np.concatenate([
                np.frombuffer(clock_speed,dtype='<u4'),np.zeros(4,dtype='<u4'),
                np.frombuffer(clock_pre,dtype='<u4'),np.frombuffer(clock_uniform,dtype='<u4'),
                np.frombuffer(clock_post,dtype='<u4'),np.frombuffer(clock_speed_post,dtype='<u4'),
                np.zeros(4,dtype='<u4'),np.array([0x43505245,0x43504F53],dtype='<u4')])
            assert len(clock_row)==clock_width
            clock_stream.write(clock_row.tobytes())
            clock_rows.append(clock_row);clock_steps.append(steps)''')
    replace("    if steps==meta['steps'] and sum(dt_history)", "    if clock_stream is not None:clock_stream.close()\n    if steps==meta['steps'] and sum(dt_history)")
    replace("    (out/'result.json').write_text", '''    if trace_clock:
        clock_array=np.stack(clock_rows).astype('<u4',copy=False)
        clock_array.tofile(out/'clock-inputs.bin')
        assert hashlib.sha256((out/'clock-inputs.bin').read_bytes()).hexdigest()==hashlib.sha256(
            Path(out).with_name(Path(out).name+'-clock-inputs.partial.bin').read_bytes()).hexdigest()
        (out/'clock-inputs.json').write_text(json.dumps(dict(
            format='bombcad-native-clock-inputs-1',dtype='<u4',complete=True,
            samples=len(clock_rows),recordWords=clock_width,controlWords=clock_c,uniformWords=clock_u,
            encodedSteps=clock_steps,batchBaseSteps=[0]*len(clock_rows),maxSamples=32768,
            offsets=dict(speedBefore=0,tilesBefore=2,controlBefore=6,uniforms=6+clock_c,
                controlAfter=6+clock_c+clock_u,speedAfter=6+2*clock_c+clock_u,
                tilesAfter=8+2*clock_c+clock_u,markers=clock_width-2),
            tileContext='absent in full-grid CUDA prepare; four zero placeholders before/after',
            sampling='actual pre/post prepare CPU copies; original CUDA activeSteps cumulative across batches; original relative zero epoch retained'),indent=2)+'\\n')
    report['nativeClockCapture']=dict(enabled=trace_clock,samples=len(clock_rows),
        source='optional CPU readbacks; original CUDA source/compiler/flags unchanged')
    (out/'result.json').write_text''')
    replace("    p.add_argument('--lock',type=Path,help='shared remote-train lock directory')",
        "    p.add_argument('--lock',type=Path,help='shared remote-train lock directory')\n    p.add_argument('--trace-clock-inputs',action='store_true')")
    replace('run(a.job,a.source,a.out,a.cache_dir,a.trace_columns,a.full_grid_cooling)',
        'run(a.job,a.source,a.out,a.cache_dir,a.trace_columns,a.full_grid_cooling,a.trace_clock_inputs)')
    ast.parse(source)
    (variant / 'run.py').write_text(source)
    preparation = dict(status='frozen-no-GPU', consumed=consumed, originalWorkerSHA256=sha(worker/'run.py'),
        workerSHA256={p.name: sha(p) for p in variant.iterdir()},
        noKernelCompilerOrPhysicsChanges=True, preservedOriginalControlAndSafety=True,
        inputSource=str(old), pins={str(p): sha(p) for folder in [worker,variant] for p in folder.iterdir()})
    import json
    preparation['pins'][str(Path(__file__).resolve())] = sha(__file__)
    (ROOT/'cuda-preparation.json').write_text(json.dumps(preparation,indent=2)+'\n')
    print('Original CUDA worker and optional CPU clock variant frozen; no GPU run')


if __name__ == '__main__':
    main()
