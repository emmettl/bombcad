#!/usr/bin/env python3
"""Compile a generated air sweep with an existing CUDA NVRTC installation."""
import argparse
import ctypes
import glob
import hashlib
import json
import os
import tempfile
from pathlib import Path
import sys


def cache_key(source, flags, compiler_hash):
    contract={'sourceSHA256':hashlib.sha256(source.encode()).hexdigest(),
              'flags':[f.decode() for f in flags],'compilerSHA256':compiler_hash}
    return hashlib.sha256(json.dumps(contract,sort_keys=True).encode()).hexdigest()


def cached_ptx(path, key):
    try:
        item=json.loads(path.read_text())
        ptx=item['ptx'].encode()
        if item['key']==key and item['ptxSHA256']==hashlib.sha256(ptx).hexdigest():
            return ptx
    except (OSError,ValueError,KeyError,TypeError,AttributeError):
        pass
    return None


def store_ptx(path, key, ptx):
    path.parent.mkdir(parents=True,exist_ok=True)
    temporary=None
    try:
        with tempfile.NamedTemporaryFile(mode='w',dir=path.parent,delete=False) as f:
            temporary=Path(f.name)
            json.dump({'key':key,'ptxSHA256':hashlib.sha256(ptx).hexdigest(),'ptx':ptx.decode()},f)
        os.replace(temporary,path)
    finally:
        if temporary is not None: temporary.unlink(missing_ok=True)


def compile_ptx(source, architecture='compute_86', cut_cells=False, cache_dir=None):
    libraries = glob.glob(str(Path(sys.prefix) / 'lib/python*/site-packages/nvidia/cuda_nvrtc/lib/libnvrtc.so*'))
    if not libraries:
        raise RuntimeError('NVRTC not found in this Python environment')
    flags = [b'--std=c++17', f'--gpu-architecture={architecture}'.encode(), b'--fmad=false',
             b'--prec-div=true', b'--prec-sqrt=true', b'--ftz=false',
             f'-DBOMBCAD_CUDA_CUT_CELLS={int(cut_cells)}'.encode()]
    cache_path=None
    if cache_dir is not None:
        h=hashlib.sha256()
        # NVRTC can load its companion builtins library; key both compiler binaries.
        compiler_files=sorted({Path(p).resolve() for p in glob.glob(str(Path(libraries[0]).parent/'libnvrtc*.so*'))})
        for library in compiler_files:
            h.update(library.name.encode()+b'\0')
            with library.open('rb') as f:
                for block in iter(lambda:f.read(1048576),b''): h.update(block)
        key=cache_key(source,flags,h.hexdigest())
        cache_path=Path(cache_dir)/(key+'.json')
        cached=cached_ptx(cache_path,key)
        if cached is not None: return cached
    lib = ctypes.CDLL(libraries[0])
    program = ctypes.c_void_p()
    def check(result):
        if result:
            raise RuntimeError(f'NVRTC error {result}')
    check(lib.nvrtcCreateProgram(ctypes.byref(program), source.encode(), b'air.cu', 0, None, None))
    try:
        options = (ctypes.c_char_p * len(flags))(*flags)
        result = lib.nvrtcCompileProgram(program, len(flags), options)
        size = ctypes.c_size_t()
        check(lib.nvrtcGetProgramLogSize(program, ctypes.byref(size)))
        log = ctypes.create_string_buffer(size.value)
        check(lib.nvrtcGetProgramLog(program, log))
        if result:
            raise RuntimeError(log.value.decode())
        check(lib.nvrtcGetPTXSize(program, ctypes.byref(size)))
        ptx = ctypes.create_string_buffer(size.value)
        check(lib.nvrtcGetPTX(program, ptx))
        if cache_path is not None: store_ptx(cache_path,key,ptx.value)
        return ptx.value
    finally:
        lib.nvrtcDestroyProgram(ctypes.byref(program))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--architecture', default='compute_86')
    parser.add_argument('--cut-cells', action='store_true')
    parser.add_argument('--cache-dir',type=Path,help='opt-in checksummed PTX cache keyed by source, flags and compiler binary')
    args = parser.parse_args()
    args.out.write_bytes(compile_ptx(args.source.read_text(), args.architecture, args.cut_cells,args.cache_dir))
