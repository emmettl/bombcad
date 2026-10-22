"""Original native CUDA measure/prepare entries; shared lock; no PDE kernels."""
import argparse
import ctypes as C
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import time


def sha(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as f:
        for b in iter(lambda: f.read(1048576), b''):
            h.update(b)
    return h.hexdigest()


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


def main():
    p = argparse.ArgumentParser()
    p.add_argument('root', type=Path)
    p.add_argument('manifest', type=Path)
    p.add_argument('--lock', required=True)
    p.add_argument('--stage', choices=['own', 'cross'], required=True)
    args = p.parse_args()
    root = args.root.resolve()
    config = json.loads(args.manifest.read_text())
    for path, h in config['pins'].items():
        assert sha(root / path) == h, path
    if args.stage == 'cross':
        for backend in ['metal', 'cuda']:
            assert json.loads((root / (backend+'-own/receipt.json')).read_text())['allFirstDTGatesPass']
    helper = module('original_lock', root / 'worker/remote-train.py')
    start = time.monotonic()
    while not helper.acquire(args.lock, 'native initial clock replay ' + args.stage, helper.boot_id()):
        if time.monotonic() - start > 4800:
            raise RuntimeError('shared lock wait expired')
        time.sleep(5)
    try:
        import numpy as np
        import torch
        compiler = module('original_compiler', root / 'worker/compile.py')
        trace = module('original_trace', root / 'worker/trace_columns.py')
        wire = module('original_wire', root / 'worker/job.py')
        source = (root / 'worker/solver.cu').read_text()
        Control = wire.scalar_layout(source, 'StepControl')
        source += trace.trace_source(source) + trace.input_source()
        assert hashlib.sha256(source.encode()).hexdigest() == config['sourceSHA256']
        torch.cuda.init()
        anchor = torch.empty(1, device='cuda')
        driver = C.CDLL('libcuda.so.1')

        def check(code):
            if code:
                raise RuntimeError('CUDA driver error ' + str(code))

        output = root / ('out-' + args.stage)
        output.mkdir(exist_ok=False)
        report = dict(status='running', stage=args.stage, rows=[], compile=[],
            sourceSHA256=config['sourceSHA256'], python=sys.version, torchVersion=torch.__version__,
            device=torch.cuda.get_device_name(), selectedRuntimePins=config['runtimePins'])

        def save():
            (output / 'receipt.json').write_text(json.dumps(report, indent=2) + '\n')

        for path, h in config['runtimePins'].items():
            assert sha(Path(path)) == h, path
        modules = {}
        save()
        try:
            for item in config['rows']:
                name = item['id']
                cut = bool(item['cutCells'])
                if cut not in modules:
                    architecture = 'compute_' + ''.join(map(str, torch.cuda.get_device_capability()))
                    ptx = compiler.compile_ptx(source, architecture, cut_cells=cut)
                    digest = hashlib.sha256(ptx).hexdigest()
                    assert digest == config['expectedPTX'][str(int(cut))]
                    (output / ('cut-' + str(int(cut)) + '.ptx')).write_bytes(ptx)
                    handle = C.c_void_p()
                    check(driver.cuModuleLoadData(C.byref(handle), ptx))
                    functions = {}
                    for function in ['cudaMeasure', 'cudaPrepare']:
                        pointer = C.c_void_p()
                        check(driver.cuModuleGetFunction(C.byref(pointer), handle, function.encode()))
                        functions[function] = pointer
                    modules[cut] = handle, functions
                    report['compile'].append(dict(cutCells=cut, ptxSHA256=digest, architecture=architecture,
                        flags=['--std=c++17', '--fmad=false', '--prec-div=true', '--prec-sqrt=true', '--ftz=false']))

                def launch(function, tensors, count):
                    values = [C.c_uint64(t.data_ptr()) for t in tensors]
                    params = (C.c_void_p * len(values))(*(C.addressof(v) for v in values))
                    check(driver.cuLaunchKernel(modules[cut][1][function], (count+127)//128, 1, 1,
                        128, 1, 1, 0, C.c_void_p(torch.cuda.current_stream().cuda_stream), params, None))

                def blob(data):
                    return torch.tensor(list(data), dtype=torch.uint8, device='cuda')

                folder = root / 'cases' / name
                dest = output / name
                dest.mkdir()
                inp = Path(item['remoteInput'])
                for filename in ['state.bin', 'mask.bin']:
                    assert sha(inp / filename) == item['physicalFiles'][filename]
                count = int(np.prod(item['shape']))
                assert torch.cuda.mem_get_info()[0] > count*24 + 64*2**20
                state = torch.from_numpy(np.fromfile(inp / 'state.bin', dtype='<f4')).to('cuda')
                mask = torch.from_numpy(np.fromfile(inp / 'mask.bin', dtype='u1')).to('cuda')
                speed = torch.zeros(2, dtype=torch.int32, device='cuda')
                uniforms = blob((folder / 'measure-cuda.bin').read_bytes())
                if args.stage == 'own':
                    launch('cudaMeasure', [state, mask, speed, uniforms], count)
                    speed_data = speed.cpu().numpy().tobytes()
                    (dest / 'measured-speed.bin').write_bytes(speed_data)
                for origin in (['cuda'] if args.stage == 'own' else ['metal', 'cuda']):
                    data = speed_data if args.stage == 'own' else (root / (origin+'-own') / name / 'measured-speed.bin').read_bytes()
                    speed.copy_(torch.from_numpy(np.frombuffer(data, dtype='<i4').copy()).to('cuda'))
                    controls = blob((folder / 'control-cuda.bin').read_bytes())
                    prepared = blob((folder / 'prepare-cuda.bin').read_bytes())
                    launch('cudaPrepare', [controls, speed, prepared], 1)
                    result = controls.cpu().numpy().tobytes()
                    (dest / ('selected-' + origin + '.bin')).write_bytes(result)
                    control = Control.from_buffer_copy(result)
                    actual = int(np.float32(control.dt).view('<u4'))
                    report['rows'].append(dict(id=name, speedOrigin=origin, dtWord=actual,
                        expectedNativeWord=item['expectedFirstDT']['cuda'],
                        nativeFirstDTGate=actual == item['expectedFirstDT']['cuda'] if args.stage == 'own' else True,
                        speedWords=np.frombuffer(data, dtype='<u4').tolist(), controlSHA256=hashlib.sha256(result).hexdigest()))
                del state, mask, speed, uniforms, controls, prepared
                save()
            report.update(status='complete-all-outcomes', allFirstDTGatesPass=all(r['nativeFirstDTGate'] for r in report['rows']))
        except BaseException as error:
            report.update(status='failed', error=repr(error))
            save()
            raise
        finally:
            for handle, _ in modules.values():
                check(driver.cuModuleUnload(handle))
        for path, h in config['runtimePins'].items():
            assert sha(Path(path)) == h
        save()
    finally:
        helper.release(args.lock)


if __name__ == '__main__':
    main()
