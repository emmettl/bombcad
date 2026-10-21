#!/usr/bin/env python3
"""Generate the uniform CUDA sweep from the production Metal numerical source.

No equations are maintained here. Unsupported features are explicitly specialised off;
the runtime must reject jobs requesting them rather than silently approximate them.
"""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]


def numerical_source():
    source = (ROOT / 'Sources/BlastCore/Shaders/Solver.metal').read_text()
    sweep = (ROOT / 'Sources/BlastCore/Shaders/SolverSweep.metal').read_text()
    source += '\n' + sweep[:sweep.index('kernel void sweep(')]
    # The CFL preparation and first-phase recorder bodies are production source too.
    step = (ROOT / 'Sources/BlastCore/Shaders/SolverStep.metal').read_text()
    prepare = step[step.index('    float fastest =', step.index('kernel void prepareStep(')):]
    prepare = prepare[:prepare.index('\n}')] + '\n}'
    prepare = re.sub(r'    logGauges\(.*?;\n', '', prepare, flags=re.S)
    source += ('\nstatic inline void portablePrepare(device StepControl &control, '
               'device atomic_uint *maxSpeed, constant SolverUniforms &u) {\n'
               '    uint tiles = 0;\n' + prepare)
    phase = (ROOT / 'Sources/BlastCore/Shaders/SolverEnvelopes.metal').read_text()
    phase = phase[phase.index('kernel void sampleFirstPhase('):]
    phase = phase[phase.index('    if (tid.x >='):]
    phase = phase[:phase.index('\n}')] + '\n}'
    source += ('\nstatic inline void portableFirstPhase(const device Cell *state, '
               'const device StepControl &control, const device float4 *columns, '
               'device float4 *records, device float *open, constant SolverUniforms &u, '
               'uint4 parameters, uint2 tid) {\n' + phase)
    # Cooling is part of recommended air: retain its production medium, ray march and loss.
    extract = (ROOT / 'Sources/BlastCore/Shaders/Extract.metal').read_text()
    for name in ('finiteBits', 'luminousTemperatureOf'):
        start = extract.index('static inline ', extract.index(name) - 30)
        end = extract.index('\n}', start) + 2
        source += '\n' + extract[start:end]
    radiation = (ROOT / 'Sources/BlastCore/Shaders/Radiation.metal').read_text()
    start = radiation.index('struct RadiationUniforms')
    source += '\n' + radiation[start:radiation.index('\n};', start)+3]
    start = radiation.index('constant float radiationFaceWeight')
    end = radiation.index('\n}', radiation.index('static inline float2 radiationMediumOf')) + 2
    source += '\n' + radiation[start:end]
    start = radiation.index('static inline uint3 radiationExtent')
    source += '\n' + radiation[start:radiation.index('\n}', start)+2]
    start = radiation.index('static inline float radiationAbsorbed')
    end = radiation.index('\n}', radiation.index('static inline float radiationExchange')) + 2
    source += '\n' + radiation[start:end]
    start = radiation.index('    int3 low =', radiation.index('kernel void radiationLines('))
    end = radiation.index('\n}', start) + 2
    source += ('\nstatic inline void portableRadiationLines(const device float2 *medium, '
               'const device uchar *mask, device float *loss, const device uint *box, '
               'constant SolverUniforms &u, int4 direction, uint3 tid) {\n' + radiation[start:end])
    start = radiation.index('    int3 cell =', radiation.index('kernel void radiationApply('))
    end = radiation.index('    threadgroup float sums', start)
    # capacity is zero in this backend, so use the production sequential-direction path.
    source += ('\nstatic inline void portableRadiationApply(device Cell *state, '
               'const device float2 *medium, const device float *loss, const device uint *box, '
               'float elapsed, constant SolverUniforms &u, constant RadiationUniforms &r, '
               'const device float *slices, uint3 tid) {\n' + radiation[start:end] + '\n}')
    return source


def generate():
    source = numerical_source()
    source = source.replace('#include <metal_stdlib>', '').replace('using namespace metal;', '')
    # Only the conjugate assignment writes a swizzle. All other swizzles are reads.
    source = source.replace('q.xyz = -q.xyz;', 'q.x = -q.x; q.y = -q.y; q.z = -q.z;')
    source = re.sub(r'constant (uint|bool) (\w+) \[\[function_constant\(\d+\)\]\];', r'constexpr \1 \2 = 0;', source)
    source = re.sub(r'is_function_constant_defined\(\w+\)', 'false', source)
    source = re.sub(r'\b(device|thread)\s+', '', source)
    source = re.sub(r'\bconstant\s+', 'const ', source)
    source = source.replace('static inline', 'static __device__ __forceinline__')
    source = re.sub(r'\.(xyz|yzx|zxy|yzw|xy|zw)\b', r'.\1()', source)
    source = source.replace('as_type<uint>', 'floatBits').replace('as_type<float>', 'bitsFloat')
    return (Path(__file__).with_name('compat.cuh').read_text() + '\n' + source
            + '\n' + Path(__file__).with_name('entry.cuh').read_text())


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--metal-out', type=Path)
    args = parser.parse_args()
    args.out.write_text(generate())

    if args.metal_out:
        args.metal_out.write_text(numerical_source() + '\n' + Path(__file__).with_name('entry.metal').read_text())
