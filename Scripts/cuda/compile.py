#!/usr/bin/env python3
"""Compile a generated air sweep with an existing CUDA NVRTC installation."""
import argparse
import ctypes
import glob
from pathlib import Path
import sys


def compile_ptx(source, architecture='compute_86', cut_cells=False):
    libraries = glob.glob(str(Path(sys.prefix) / 'lib/python*/site-packages/nvidia/cuda_nvrtc/lib/libnvrtc.so*'))
    if not libraries:
        raise RuntimeError('NVRTC not found in this Python environment')
    lib = ctypes.CDLL(libraries[0])
    program = ctypes.c_void_p()
    def check(result):
        if result:
            raise RuntimeError(f'NVRTC error {result}')
    check(lib.nvrtcCreateProgram(ctypes.byref(program), source.encode(), b'air.cu', 0, None, None))
    try:
        flags = [b'--std=c++17', f'--gpu-architecture={architecture}'.encode(), b'--fmad=false',
                 b'--prec-div=true', b'--prec-sqrt=true', b'--ftz=false',
                 f'-DBOMBCAD_CUDA_CUT_CELLS={int(cut_cells)}'.encode()]
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
        return ptx.value
    finally:
        lib.nvrtcDestroyProgram(ctypes.byref(program))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--architecture', default='compute_86')
    parser.add_argument('--cut-cells', action='store_true')
    args = parser.parse_args()
    args.out.write_bytes(compile_ptx(args.source.read_text(), args.architecture, args.cut_cells))
