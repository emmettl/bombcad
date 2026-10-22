"""Original cudaPrepare on actual captured words; no PDE kernel or arithmetic helper."""
import argparse
import ctypes as C
import hashlib
import importlib.util
import json
from pathlib import Path
import time


def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def module(name,p):
    spec=importlib.util.spec_from_file_location(name,p);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m


def main():
    p=argparse.ArgumentParser();p.add_argument('root',type=Path);p.add_argument('manifest',type=Path)
    p.add_argument('--lock',required=True);p.add_argument('--stage',choices=['own','cross'],required=True)
    args=p.parse_args();root=args.root.resolve();config=json.loads(args.manifest.read_text())
    for path,h in config['pins'].items():assert sha(root/path)==h,path
    if args.stage=='cross':
        for b in ['metal','cuda']:assert json.loads((root/(b+'-own/receipt.json')).read_text())['allOwnWordsExact']
    helper=module('original_lock',root/'worker/remote-train.py');start=time.monotonic()
    while not helper.acquire(args.lock,'native captured selector '+args.stage,helper.boot_id()):
        if time.monotonic()-start>4800:raise RuntimeError('shared lock wait expired')
        time.sleep(5)
    try:
        import numpy as np
        import torch
        compiler=module('original_compiler',root/'worker/compile.py');trace=module('original_trace',root/'worker/trace_columns.py')
        source=(root/'worker/solver.cu').read_text();source+=trace.trace_source(source)+trace.input_source()
        assert hashlib.sha256(source.encode()).hexdigest()==config['sourceSHA256']
        for path,h in config['runtimePins'].items():assert sha(path)==h,path
        torch.cuda.init();anchor=torch.empty(1,device='cuda');driver=C.CDLL('libcuda.so.1')
        def check(code):
            if code:raise RuntimeError('CUDA driver error '+str(code))
        output=root/('out-'+args.stage);output.mkdir(exist_ok=False)
        report=dict(status='running',stage=args.stage,rows=[],compile=[],sourceSHA256=config['sourceSHA256'],
            device=torch.cuda.get_device_name(),torchVersion=torch.__version__,selectedRuntimePins=config['runtimePins'])
        def save():(output/'receipt.json').write_text(json.dumps(report,indent=2)+'\n')
        modules={};save()
        try:
            origin='cuda' if args.stage=='own' else 'metal'
            for item in config['rows']:
                if item['origin']!=origin:continue
                cut=bool(item['cutCells']);label=item['label'];frames=item['frames'];folder=root/item['folder']
                if cut not in modules:
                    architecture='compute_'+''.join(map(str,torch.cuda.get_device_capability()))
                    ptx=compiler.compile_ptx(source,architecture,cut_cells=cut);h=hashlib.sha256(ptx).hexdigest()
                    assert h==config['expectedPTX'][str(int(cut))]
                    (output/('cut-'+str(int(cut))+'.ptx')).write_bytes(ptx)
                    handle=C.c_void_p();check(driver.cuModuleLoadData(C.byref(handle),ptx))
                    function=C.c_void_p();check(driver.cuModuleGetFunction(C.byref(function),handle,b'cudaPrepare'))
                    modules[cut]=(handle,function);report['compile'].append(dict(cutCells=cut,ptxSHA256=h,architecture=architecture,
                        flags=['--std=c++17','--fmad=false','--prec-div=true','--prec-sqrt=true','--ftz=false']))
                def tensor(name):return torch.from_numpy(np.fromfile(folder/(name+'.bin'),dtype='u1')).to('cuda')
                controls=tensor('control');speed=tensor('speed');uniforms=tensor('uniforms')
                assert controls.numel()==frames*72 and speed.numel()==frames*8 and uniforms.numel()==frames*276
                for i in range(frames):
                    pointers=[C.c_uint64(controls.data_ptr()+i*72),C.c_uint64(speed.data_ptr()+i*8),C.c_uint64(uniforms.data_ptr()+i*276)]
                    params=(C.c_void_p*3)(*(C.addressof(v) for v in pointers))
                    check(driver.cuLaunchKernel(modules[cut][1],1,1,1,128,1,1,0,C.c_void_p(torch.cuda.current_stream().cuda_stream),params,None))
                actual=np.concatenate([controls.cpu().numpy().view('<u4').reshape(frames,18),
                    speed.cpu().numpy().view('<u4').reshape(frames,2)],axis=1)
                dest=output/label;dest.mkdir();actual.astype('<u4',copy=False).tofile(dest/'outputs.bin')
                row=dict(label=label,frames=frames,outputWords=int(actual.size),outputSHA256=sha(dest/'outputs.bin'))
                if args.stage=='own':
                    expected=np.concatenate([np.fromfile(folder/'expectedControl.bin',dtype='<u4').reshape(frames,18),
                        np.fromfile(folder/'expectedSpeed.bin',dtype='<u4').reshape(frames,2)],axis=1)
                    different=np.flatnonzero(actual.ravel()!=expected.ravel());row.update(wordDifferences=len(different),
                        firstDifferences=[dict(index=int(i),actual=int(actual.ravel()[i]),expected=int(expected.ravel()[i])) for i in different[:16]])
                report['rows'].append(row);save();del controls,speed,uniforms
            report.update(status='complete-all-outcomes',allOwnWordsExact=args.stage=='own' and len(report['rows'])==3 and all(r['wordDifferences']==0 for r in report['rows']))
        except BaseException as error:
            report.update(status='failed',error=repr(error));save();raise
        finally:
            for handle,_ in modules.values():check(driver.cuModuleUnload(handle))
        for path,h in config['runtimePins'].items():assert sha(path)==h,path
        save()
    finally:
        helper.release(args.lock)


if __name__=='__main__':main()
