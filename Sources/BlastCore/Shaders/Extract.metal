// What the models alongside the blast need from the air at a frame, cut out on the GPU at the end
// of the batch that lands on the frame, rather than read from the state on the CPU while the GPU
// waits (see FrameExtraction.swift). Each kernel does nothing unless the batch's last step reached
// its time limit, which is how a batch lands on a frame; the host keeps what they wrote only then.

// Whether `x` is a finite number, by its bits: fast maths may take any comparison or isfinite to
// hold for infinities and NaNs.
static inline bool finiteBits(float x) {
    return (as_type<uint>(x) & 0x7f800000u) != 0x7f800000u;
}

// The air at every `stride`-th cell from `first`, `counts` of them along each axis, as half floats,
// five a sample, x fastest: density, velocity, and pressure in MPa, as `AirSlice` holds them. The
// velocity and pressure are worked out as the CPU's `BlastSolver.primitive` does them, without a
// density floor, so a solid cell's stale state reads as it would there.
kernel void extractAirSlice(
    device const StepControl &control [[buffer(0)]],
    device const Cell *state [[buffer(1)]],
    device half *values [[buffer(2)]],
    constant int4 *layout [[buffer(3)]],
    constant SolverUniforms &u [[buffer(4)]],
    uint3 id [[thread_position_in_grid]])
{
    if (control.stopped != 2) {
        return;
    }
    int4 first = layout[0];
    int4 counts = layout[1];
    if (int(id.x) >= counts.x || int(id.y) >= counts.y || int(id.z) >= counts.z) {
        return;
    }
    int3 cell = first.xyz + int3(id) * first.w;
    Cell c = state[uint(cell.x) + u.nx * (uint(cell.y) + u.ny * uint(cell.z))];
    float3 velocity = float3(c.mx, c.my, c.mz) / c.rho;
    float kinetic = 0.5f * c.rho * dot(velocity, velocity);
    float pressure = gasPressure(c.rho, c.energy - kinetic, u.airModel, u.gamma);
    uint n = 5u * (id.x + uint(counts.x) * (id.y + uint(counts.y) * id.z));
    values[n] = half(c.rho);
    values[n + 1] = half(velocity.x);
    values[n + 2] = half(velocity.y);
    values[n + 3] = half(velocity.z);
    values[n + 4] = half(pressure / 1.0e6f);
}

// The luminous gas along one row of cells, (j, k) = id: how many cells are at least `luminous`
// kelvin, the sum of their i + 1/2, of their temperatures to the fourth power, and the hottest.
// The host adds the rows up in double precision in a fixed order, so the fireball is the same
// from one run to the next.
kernel void extractFireballRows(
    device const StepControl &control [[buffer(0)]],
    device const Cell *state [[buffer(1)]],
    device const uchar *mask [[buffer(2)]],
    device float4 *rows [[buffer(3)]],
    constant float &luminous [[buffer(4)]],
    constant SolverUniforms &u [[buffer(5)]],
    uint2 id [[thread_position_in_grid]])
{
    if (control.stopped != 2 || id.x >= u.ny || id.y >= u.nz) {
        return;
    }
    uint base = u.nx * (id.x + u.ny * id.y);
    float count = 0.0f;
    float position = 0.0f;
    float fourth = 0.0f;
    float hottest = 0.0f;
    for (uint i = 0; i < u.nx; ++i) {
        if (mask[base + i] != 0) {
            continue;
        }
        Cell c = state[base + i];
        float3 velocity = float3(c.mx, c.my, c.mz) / c.rho;
        float kinetic = 0.5f * c.rho * dot(velocity, velocity);
        float pressure = gasPressure(c.rho, c.energy - kinetic, u.airModel, u.gamma);
        // Dissociating air is never hotter than this, so it bounds the search.
        float bound = pressure / (c.rho * airGasConstant);
        if (!finiteBits(bound) || !(bound >= luminous)) {
            continue;
        }
        float t = airModelOf(u.airModel) == airDissociating ? dissociatingTemperatureAt(c.rho, pressure) : bound;
        if (!finiteBits(t) || !(t >= luminous)) {
            continue;
        }
        count += 1.0f;
        position += float(i) + 0.5f;
        float square = t * t;
        fourth += square * square;
        hottest = max(hottest, t);
    }
    rows[id.x + u.ny * id.y] = float4(count, position, fourth, hottest);
}
