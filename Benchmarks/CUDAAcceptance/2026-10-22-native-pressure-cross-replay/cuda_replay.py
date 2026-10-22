"""Native cudaTraceColumns replay; existing shared lock, no PDE evolution."""
import argparse
import ctypes as C
import glob
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys
import time


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('root', type=Path)
    parser.add_argument('manifest', type=Path)
    parser.add_argument('--lock', type=Path, required=True)
    parser.add_argument('--stage', choices=['own', 'cross'], required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    manifest = json.loads(args.manifest.read_text())
    helper = module('shared_lock', root / 'worker/remote-train.py')
    acquired = False
    start = time.monotonic()
    while not acquired:
        acquired = helper.acquire(str(args.lock), 'native pressure replay ' + args.stage, helper.boot_id())
        if not acquired:
            if time.monotonic() - start > 4800:
                raise RuntimeError('Shared GPU lock wait expired before any numerical replay')
            time.sleep(5)
    output = root / ('out-' + args.stage)
    try:
        output.mkdir(exist_ok=False)
        import numpy as np
        import torch
        worker = root / 'worker'
        for name, expected in manifest['workerSHA256'].items():
            assert sha(worker / name) == expected, name
        for name, expected in manifest['inputSHA256'].items():
            assert sha(root / name) == expected, name
        source = (worker / 'solver.cu').read_text()
        trace = module('original_trace', worker / 'trace_columns.py')
        source += trace.trace_source(source) + trace.input_source()
        source_hash = hashlib.sha256(source.encode()).hexdigest()
        assert source_hash == manifest['diagnosticSourceSHA256']
        compiler = module('original_compiler', worker / 'compile.py')
        capability = torch.cuda.get_device_capability()
        architecture = 'compute_' + ''.join(map(str, capability))
        torch.cuda.init()
        anchor = torch.empty(1, device='cuda')
        driver = C.CDLL('libcuda.so.1')
        def check(code):
            if code:
                raise RuntimeError('CUDA driver error ' + str(code))
        modules = {}
        report = dict(status='running', stage=args.stage, pid=os.getpid(), boot=helper.boot_id(),
                      device=torch.cuda.get_device_name(), capability=capability, architecture=architecture,
                      torchVersion=torch.__version__, numpyVersion=np.__version__, python=sys.version,
                      diagnosticSourceSHA256=source_hash, rows=[], compile=[], selectedRuntimePins={})
        def save():
            (output / 'receipt.json').write_text(json.dumps(report, indent=2) + '\n')
        for p in [Path(sys.executable).resolve(), *map(Path, glob.glob(str(Path(sys.prefix) / 'lib/python*/site-packages/nvidia/cuda_nvrtc/lib/libnvrtc*.so*')))]:
            report['selectedRuntimePins'][str(p.resolve())] = sha(p)
        save()
        try:
            for item in manifest['cases']:
                folder = root / item['folder']
                label = item['label']
                dest = output / label
                dest.mkdir(exist_ok=False)
                nx, ny, nz = item['shape']
                columns = item['columns']
                frames, count = item['frames'], len(columns)
                free, _ = torch.cuda.mem_get_info()
                required = nx * ny * nz * 20 + nx * ny * 36 + frames * count * 100 + 16 * 2**20
                assert required <= free * .8, 'Preserve 20% device memory headroom'
                cut = bool(item['cutCells'])
                if cut not in modules:
                    ptx = compiler.compile_ptx(source, architecture, cut_cells=cut)
                    ptx_path = output / ('cut-' + str(int(cut)) + '.ptx')
                    ptx_path.write_bytes(ptx)
                    handle = C.c_void_p()
                    check(driver.cuModuleLoadData(C.byref(handle), ptx))
                    function = C.c_void_p()
                    check(driver.cuModuleGetFunction(C.byref(function), handle, b'cudaTraceColumns'))
                    modules[cut] = (handle, function)
                    report['compile'].append(dict(cutCells=cut, ptxSHA256=sha(ptx_path), compileHelperSHA256=sha(worker / 'compile.py'),
                        flags=['--std=c++17', '--gpu-architecture=' + architecture, '--fmad=false', '--prec-div=true',
                               '--prec-sqrt=true', '--ftz=false', '-DBOMBCAD_CUDA_CUT_CELLS=' + str(int(cut))]))
                def tensor(name, dtype):
                    return torch.from_numpy(np.fromfile(folder / name, dtype=dtype)).to('cuda')
                raw_cpu = np.fromfile(folder / 'inputs.bin', dtype='<f4').reshape(frames, count, 16)
                assert np.isfinite(raw_cpu).all()
                raw = torch.from_numpy(raw_cpu).to('cuda')
                after = tensor('records-after.bin', '<f4').reshape(frames, count, 5)
                all_controls = tensor('controls-cuda.bin', 'u1').reshape(frames, item['cudaControlBytes'])
                uniforms = tensor('uniforms-cuda.bin', 'u1')
                state = torch.zeros((nx * ny * nz, 5), device='cuda', dtype=torch.float32)
                descriptors = torch.zeros((nx * ny, 4), device='cuda', dtype=torch.float32)
                records = torch.zeros((nx * ny, 4), device='cuda', dtype=torch.float32)
                opened = torch.zeros(nx * ny, device='cuda', dtype=torch.float32)
                controls = torch.zeros(item['cudaControlBytes'], device='cuda', dtype=torch.uint8)
                indices = torch.tensor([count, *columns], device='cuda', dtype=torch.int32)
                values = torch.zeros((count, 8), device='cuda', dtype=torch.float32)
                locations = []
                for q, n in enumerate(columns):
                    assert 0 <= n < nx * ny
                    c = raw_cpu[0, q]
                    assert c[3] > 0 and all(0 <= int(k) < nz for k in c[:2])
                    locations.append([n + nx * ny * int(k) for k in c[:2]])
                    descriptors[n].copy_(raw[0, q, :4])
                result = np.empty((frames, count), dtype='<f4')
                for frame in range(frames):
                    controls.copy_(all_controls[frame])
                    for q, n in enumerate(columns):
                        for side in range(2):
                            state[locations[q][side]].copy_(raw[frame, q, 6 + 5 * side:11 + 5 * side])
                        records[n].copy_(after[frame, q, :4])
                        opened[n:n + 1].copy_(after[frame, q, 4:5])
                    buffers = [state, descriptors, records, opened, uniforms, indices, values, controls]
                    pointers = [C.c_uint64(t.data_ptr()) for t in buffers]
                    parameters = (C.c_void_p * len(pointers))(*(C.addressof(v) for v in pointers))
                    check(driver.cuLaunchKernel(modules[cut][1], (count + 127) // 128, 1, 1, 128, 1, 1, 0,
                        C.c_void_p(torch.cuda.current_stream().cuda_stream), parameters, None))
                    result[frame] = values.cpu().numpy()[:, 0]
                assert np.isfinite(result).all()
                result.tofile(dest / 'pressure.bin')
                expected = np.fromfile(folder / 'expected-pressure.bin', dtype='<u4').reshape(frames, count)
                actual = result.view(np.uint32)
                different = np.flatnonzero(actual.reshape(-1) != expected.reshape(-1))
                row = dict(label=label, status='complete', frames=frames, columns=columns, words=int(actual.size),
                           wordDifferences=int(len(different)), numericDifferences=int(np.count_nonzero(result != expected.view(np.float32))),
                           firstDifferences=[dict(flatIndex=int(i), replayedWord=int(actual.flat[i]), nativeWord=int(expected.flat[i])) for i in different[:16]],
                           pressureSHA256=sha(dest / 'pressure.bin'))
                report['rows'].append(row)
                save()
                if item.get('mathematicalControl'):
                    assert not len(different), 'Mathematical control pressure words failed'
                del state, descriptors, records, opened, controls, indices, values, raw, after, all_controls, uniforms
            report.update(status='complete-all-outcomes', ownInputGatePass=all(r['wordDifferences'] == 0 for r in report['rows']) if args.stage == 'own' else None)
        except BaseException as error:
            report.update(status='failed', error=repr(error))
            save()
            raise
        finally:
            for handle, _ in modules.values():
                check(driver.cuModuleUnload(handle))
        for path, digest in report['selectedRuntimePins'].items():
            assert sha(path) == digest
        for name, expected in manifest['inputSHA256'].items():
            assert sha(root / name) == expected, name
        save()
        print(json.dumps({k: v for k, v in report.items() if k != 'selectedRuntimePins'}, indent=2))
    finally:
        helper.release(str(args.lock))


if __name__ == '__main__':
    main()
