#!/usr/bin/env python3
"""Execute a generated production sweep on CUDA; this is not a parity acceptance test."""
import argparse
import ctypes as C
import re
from pathlib import Path
import numpy as np
import torch


def scalar_layout(source, name):
    body = re.search(r'struct ' + name + r'\s*\{(.*?)\};', source, re.S).group(1)
    fields = re.findall(r'^\s*(float|uint)\s+(\w+)\s*;', body, re.M)
    # Fail rather than silently ignoring newly introduced non-scalar ABI fields.
    stripped = re.sub(r'//[^\n]*', '', body)
    if len(fields) != stripped.count(';'):
        raise ValueError(f'{name} no longer has a scalar-only ABI')
    return type(name, (C.Structure,), {'_fields_': [(n, C.c_float if t == 'float' else C.c_uint32) for t,n in fields]})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--ptx', type=Path, required=True)
    parser.add_argument('--size', type=int, default=16)
    args = parser.parse_args()
    torch.cuda.init()
    context_anchor = torch.empty(1, device="cuda")
    driver = C.CDLL('libcuda.so.1')
    def check(code):
        if code:
            raise RuntimeError(f'CUDA driver error {code}')
    module = C.c_void_p()
    check(driver.cuModuleLoadData(C.byref(module), args.ptx.read_bytes()))
    function = C.c_void_p()
    check(driver.cuModuleGetFunction(C.byref(function), module, b'cudaSweep'))
    source = args.source.read_text()
    Uniforms, Control = (scalar_layout(source, n) for n in ('SolverUniforms','StepControl'))
    n = args.size
    u = Uniforms()
    u.nx=u.ny=u.nz=n; u.dx=1; u.gamma=1.4; u.cfl=0.4
    u.ambientPressure=101325; u.densityFloor=1e-6; u.pressureFloor=1e-6
    u.limiterTheta=1.5; u.axis=0; u.finalSweep=1
    control = Control(); control.dt=0.0001
    def blob(value):
        return torch.tensor(list(bytes(value)), dtype=torch.uint8, device='cuda')
    uniforms, controls = blob(u), blob(control)
    state = torch.zeros((n**3,5),device='cuda',dtype=torch.float32)
    state[:,0]=1.225; state[:,4]=101325/(float(u.gamma)-1)
    target=state.clone(); mask=torch.zeros(n**3,device='cuda',dtype=torch.uint8)
    peak=torch.zeros(n**3,device='cuda'); impulse=peak.clone()
    speed=torch.zeros(2,device='cuda',dtype=torch.int32)
    species=torch.zeros((n**3,2),device='cuda'); other=species.clone()
    dummy=torch.zeros(16,device="cuda",dtype=torch.uint8)
    buffers=[state,target,mask,peak,impulse,controls,speed,uniforms,species,other]+[dummy]*5
    values=[C.c_uint64(t.data_ptr()) for t in buffers]
    params=(C.c_void_p*len(values))(*(C.addressof(v) for v in values))
    stream=C.c_void_p(torch.cuda.current_stream().cuda_stream)
    check(driver.cuLaunchKernel(function,(n**3+127)//128,1,1,128,1,1,0,stream,params,None))
    torch.cuda.synchronize()
    difference=(target-state).abs().max().item()
    if not torch.isfinite(target).all() or difference != 0:
        raise RuntimeError(f'still-air sweep changed state: {difference}')
    print(f'PASS {n}^3 still air, {torch.cuda.get_device_name()}, max state difference={difference}')
    print(f'ABI: SolverUniforms={C.sizeof(u)}, StepControl={C.sizeof(control)}')
    check(driver.cuModuleUnload(module))


if __name__ == '__main__':
    main()
