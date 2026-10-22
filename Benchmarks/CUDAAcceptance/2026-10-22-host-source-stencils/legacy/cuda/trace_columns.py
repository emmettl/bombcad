#!/usr/bin/env python3
"""Read-only receiver diagnostics derived from the production first-phase pressure expression."""
import argparse
from pathlib import Path

FIELDS=['overpressure','peak','allPositiveImpulse','firstPhaseImpulse','phasePeak','open','dt','batchTime']


def parse_columns(text):
    try:
        values=[int(v) for v in text.split(',')]
    except ValueError as error:
        raise argparse.ArgumentTypeError('comma-separated non-negative column indices required') from error
    if not values or len(values)>64 or len(set(values))!=len(values) or min(values)<0:
        raise argparse.ArgumentTypeError('1–64 distinct non-negative column indices required')
    return values


def trace_source(source, metal=False):
    start=source.index('void portableFirstPhase(')
    start=source.index('    float pressure = 0;',start)
    end=source.index('    float dt = max(control.dt',start)
    pressure=source[start:end]
    if metal:
        declaration='''kernel void referenceTraceColumns(const device Cell *state [[buffer(0)]],
    const device float4 *columns [[buffer(1)]], const device float4 *records [[buffer(2)]],
    const device float *open [[buffer(3)]], constant SolverUniforms &u [[buffer(4)]],
    const device uint *indices [[buffer(5)]], device float *output [[buffer(6)]],
    const device StepControl &control [[buffer(7)]], uint q [[thread_position_in_grid]]) {
'''
    else:
        declaration='''extern "C" __global__ void cudaTraceColumns(const Cell *state,
    const float4 *columns,const float4 *records,const float *open,const SolverUniforms *uniforms,
    const uint *indices,float *output,const StepControl *controls) {
    uint q=blockIdx.x*blockDim.x+threadIdx.x;
    const SolverUniforms &u=*uniforms;
    const StepControl &control=*controls;
'''
    # indices[0] is the count; this layout avoids passing scalars through the generic launch ABI.
    body='''    if(q>=indices[0]) return;
    uint n=indices[q+1];
    uint2 tid=uint2(n%u.nx,n/u.nx);
    float4 column=columns[n];
'''+pressure+'''    float4 record=records[n];
    output[q*8+0]=p; output[q*8+1]=record.x;
    output[q*8+2]=record.y; output[q*8+3]=record.z;
    output[q*8+4]=record.w; output[q*8+5]=open[n];
    output[q*8+6]=control.dt; output[q*8+7]=control.batchTime;
}
'''
    return '\n'+declaration+body


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('source',type=Path);p.add_argument('--metal-out',type=Path,required=True)
    a=p.parse_args();source=a.source.read_text()
    a.metal_out.write_text(source+trace_source(source,metal=True))
