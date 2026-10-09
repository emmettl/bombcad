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

// A cell's temperature if it is air at least `luminous` kelvin hot, and otherwise zero, as the
// CPU's `BlastSolver.fireball` works it out.
static inline float luminousTemperatureOf(Cell c, float luminous, constant SolverUniforms &u) {
    float3 velocity = float3(c.mx, c.my, c.mz) / c.rho;
    float kinetic = 0.5f * c.rho * dot(velocity, velocity);
    float pressure = gasPressure(c.rho, c.energy - kinetic, u.airModel, u.gamma);
    // Dissociating air is never hotter than this, so it bounds the search.
    float bound = pressure / (c.rho * airGasConstant);
    if (!finiteBits(bound) || !(bound >= luminous)) {
        return 0.0f;
    }
    float t = airModelOf(u.airModel) == airDissociating ? dissociatingTemperatureAt(c.rho, pressure) : bound;
    if (!finiteBits(t) || !(t >= luminous)) {
        return 0.0f;
    }
    return t;
}

// The luminous gas in one block of two cells a side, block `id`: for a block with any cell at
// least `luminous` kelvin, its index, how many of its cells are luminous, the sum of their
// temperatures to the fourth power and the hottest; the sums of their i, j and k + 1/2; and how
// many of its cells are air. Appended in whatever order the threads reach them, after `count`
// others; the host sorts them by index, so the fireball is the same from one run to the next.
kernel void extractFireballBlocks(
    device const StepControl &control [[buffer(0)]],
    device const Cell *state [[buffer(1)]],
    device const uchar *mask [[buffer(2)]],
    device uint4 *blocks [[buffer(3)]],
    device atomic_uint *count [[buffer(4)]],
    constant float &luminous [[buffer(5)]],
    constant SolverUniforms &u [[buffer(6)]],
    uint3 id [[thread_position_in_grid]])
{
    uint3 dims = (uint3(u.nx, u.ny, u.nz) + 1u) / 2u;
    if (control.stopped != 2 || id.x >= dims.x || id.y >= dims.y || id.z >= dims.z) {
        return;
    }
    uint3 low = 2u * id;
    uint3 high = min(low + 2u, uint3(u.nx, u.ny, u.nz));
    float cells = 0.0f;
    float air = 0.0f;
    float3 position = float3(0.0f);
    float fourth = 0.0f;
    float hottest = 0.0f;
    for (uint k = low.z; k < high.z; ++k) {
        for (uint j = low.y; j < high.y; ++j) {
            for (uint i = low.x; i < high.x; ++i) {
                uint index = i + u.nx * (j + u.ny * k);
                if (mask[index] != 0) {
                    continue;
                }
                air += 1.0f;
                float t = luminousTemperatureOf(state[index], luminous, u);
                if (t == 0.0f) {
                    continue;
                }
                cells += 1.0f;
                position += float3(i, j, k) + 0.5f;
                float square = t * t;
                fourth += square * square;
                hottest = max(hottest, t);
            }
        }
    }
    if (cells == 0.0f) {
        return;
    }
    uint slot = atomic_fetch_add_explicit(count, 1u, memory_order_relaxed);
    uint index = id.x + dims.x * (id.y + dims.y * id.z);
    blocks[2 * slot] = uint4(index, as_type<uint>(cells), as_type<uint>(fourth), as_type<uint>(hottest));
    blocks[2 * slot + 1] = as_type<uint4>(float4(position, air));
}
