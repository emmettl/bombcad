// The envelope recorders' kernels, appended to Solver.metal at compile time (ShaderLibrary): the
// exposure plane, the faces' exposure and each component's load.

// Fixed Eulerian coarse-cell probes. Fine state has been conservatively restricted before
// this sample. Positive impulse uses a right-endpoint sum over complete fluid intervals.
kernel void sampleExposurePlane(const device Cell *state [[buffer(0)]],
                               const device uchar *mask [[buffer(1)]],
                               const device StepControl &control [[buffer(2)]],
                               device float4 *exposure [[buffer(3)]],
                               constant SolverUniforms &u [[buffer(4)]],
                               constant float4 &probe [[buffer(5)]],
                               constant float &weight [[buffer(6)]],
                               constant float4 &sampling [[buffer(7)]],
                               const device int *patchOfTile [[buffer(8)]],
                               const device Cell *fine [[buffer(9)]],
                               const device uchar *fineMask [[buffer(10)]],
                               const device int *childPatches [[buffer(11)]],
                               const device Cell *childFine [[buffer(12)]],
                               const device uchar *childMask [[buffer(13)]],
                               uint2 tid [[thread_position_in_grid]]) {
    if (tid.x >= uint(sampling.x) || tid.y >= uint(sampling.y) || (control.dt <= 0 && probe.w == 0)) {
        return;
    }
    uint point = tid.x + uint(sampling.x) * tid.y;
    float2 coordinate = sampling.z == u.dx ? float2(tid)
                                         : clamp((float2(tid) + 0.5f) * sampling.z / u.dx - 0.5f,
                                                 float2(0), float2(u.nx - 1, u.ny - 1));
    uint2 lower = uint2(floor(coordinate));
    float2 fraction = coordinate - float2(lower);
    float4 record = exposure[point];
    bool solid = false;
    float pressure = 0;
    for (uint k = 0; k < 2; ++k) {
        for (uint j = 0; j < 2; ++j) {
            for (uint i = 0; i < 2; ++i) {
                float w = (k == 0 ? 1 - weight : weight)
                          * (j == 0 ? 1 - fraction.y : fraction.y)
                          * (i == 0 ? 1 - fraction.x : fraction.x);
                if (w <= 0) {
                    continue;
                }
                uint x = min(lower.x + i, u.nx - 1);
                uint y = min(lower.y + j, u.ny - 1);
                uint z = uint(probe.x) + k;
                uint cell = x + u.nx * (y + u.ny * z);
                solid = solid || mask[cell] != 0;
                Cell c = state[cell];
                float rho = max(c.rho, u.densityFloor);
                float kinetic = 0.5f * (c.mx * c.mx + c.my * c.my + c.mz * c.mz) / rho;
                pressure += w * gasPressure(rho, c.energy - kinetic, u.airModel, u.gamma);
            }
        }
    }
    // Where the air is refined, the finest cell holding the point, in place of the coarse cells'
    // blend.
    if (!solid && u.refineRatio != 0) {
        float3 at = float3((coordinate + 0.5f) * u.dx, (probe.x + 0.5f + weight) * u.dx);
        int3 cell = clamp(int3(floor(at / u.dx)), int3(0), int3(u.nx, u.ny, u.nz) - 1);
        RefinedAir air = {patchOfTile, fine, fineMask, childPatches, childFine, childMask};
        float finest;
        if (mask[cell.x + u.nx * (cell.y + u.ny * cell.z)] == 0 && finestPointPressure(cell, at, u, air, finest)) {
            pressure = finest;
        }
    }
    if (solid) {
        record.w = 1;
    } else {
        float overpressure = max(pressure - u.ambientPressure, 0.0f);
        record.x = max(record.x, overpressure);
        record.y += overpressure * control.dt;
        if (record.z < 0 && overpressure >= probe.y) {
            record.z = runClockSeconds(control);
        }
    }
    exposure[point] = record;
}

// Read-only stationary voxel-face diagnostic; pressure at the adjacent fluid cell centre,
// not a Riemann wall flux. Each face has one writer, so no floating-point atomics are needed.
kernel void sampleEnvelopeExposure(const device Cell *state [[buffer(0)]],
                                  const device uchar *mask [[buffer(1)]],
                                  const device StepControl &control [[buffer(2)]],
                                  const device uint4 *faces [[buffer(3)]],
                                  device float4 *records [[buffer(4)]],
                                  device float *signedImpulse [[buffer(5)]],
                                  constant SolverUniforms &u [[buffer(6)]],
                                  constant uint4 &parameters [[buffer(7)]],
                                  const device uchar *tileFlags [[buffer(8)]],
                                  const device int *patchOfTile [[buffer(9)]],
                                  const device Cell *fine [[buffer(10)]],
                                  const device uchar *fineMask [[buffer(11)]],
                                  const device int *childPatches [[buffer(12)]],
                                  const device Cell *childFine [[buffer(13)]],
                                  const device uchar *childMask [[buffer(14)]],
                                  uint index [[thread_position_in_grid]]) {
    if (index >= parameters.x || (control.dt <= 0 && parameters.y == 0)) return;
    uint4 face = faces[index];
    // A face whose air is in a still tile has held the still air since the start (tiles do not
    // fall asleep again): read that, not the cell; and where it is ambient, nothing changes at all.
    bool still = false;
    if (parameters.z != 0 && u.tileNx > 0) {
        uint i = face.y % u.nx;
        uint j = (face.y / u.nx) % u.ny;
        uint k = face.y / (u.nx * u.ny);
        still = tileFlags[i / 8 + u.tileNx * (j / 8 + u.tileNy * (k / 8))] == tileStill;
    }
    if (!still && (mask[face.x] == 0 || mask[face.y] != 0)) {
        float4 record = records[index];
        record.w = 1;
        records[index] = record;
        return;
    }
    float rho;
    float3 momentum;
    float energy;
    if (still) {
        rho = u.stillRho;
        momentum = float3(u.stillMx, u.stillMy, u.stillMz);
        energy = u.stillEnergy;
    } else {
        Cell c = state[face.y];
        rho = c.rho;
        momentum = float3(c.mx, c.my, c.mz);
        energy = c.energy;
    }
    rho = max(rho, u.densityFloor);
    float kinetic = 0.5f * (momentum.x * momentum.x + momentum.y * momentum.y + momentum.z * momentum.z) / rho;
    float p = gasPressure(rho, energy - kinetic, u.airModel, u.gamma) - u.ambientPressure;
    // Where the air is refined, its finest cells against the face.
    float refined;
    if (!still
        && refinedFaceOverpressure(face.y, face.x, u, patchOfTile, fine, fineMask, childPatches, childFine,
                                   childMask, refined)) {
        p = refined;
    }
    // Zero, its record stays as it is, as it would adding nothing.
    if (still && as_type<uint>(p) == 0u) return;
    float4 record = records[index];
    record.x = p;
    record.y = max(record.y, max(p, 0.0f));
    record.z += max(p, 0.0f) * control.dt;
    signedImpulse[index] += p * control.dt;
    records[index] = record;
}

// Envelope components (EnvelopeComponentRecorder): after each complete fluid step, each
// component's two sides' area-weighted mean overpressure (its faces all have the cell's area).
// First every face's pressure, a thread a face, into a list laid out a component and a side at a
// time; then a SIMD group of 32 lanes a component, `componentsPerGroup` to a threadgroup, each lane
// summing every 32nd of its side's faces, a fixed tree of shuffles adding the lanes' sums, so the
// result repeats bit for bit. Each step's value, its right endpoint, is integrated into the bins
// it overlaps, [i w, (i + 1) w) from t = 0; the peaks are kept from every step.
struct ComponentRecording {
    uint components;
    uint capacity;
    uint initial;
    uint maxima;
    float binWidth;
    uint faces;
    uint fromArrival;      // 1: a component's bins start when its air first moves
    uint readsRefined;     // 1: faces in refined air read its finest cells against them
    uint skipStill;        // 1: read a face in a still tile as the still air (no gravity)
    float arrivalPa;       // With `fromArrival`: the side's overpressure that starts the bins; 0, the air's first moving
};

// A component's first bin before its air has moved, with `fromArrival`: nothing is binned.
constant uint notStarted = 0xFFFFFFFFu;

constant uint componentLanes = 32;
// A face whose solid/fluid pair has changed, compared by its bits (fast math may drop a NaN test).
constant uint brokenFace = 0xFFFFFFFFu;

// The sum of a side's faces' pressures, a lane taking every 32nd; a fixed tree of shuffles adds
// the lanes' sums.
static inline float sideSum(const device float *pressures, uint first, uint count, uint lane, thread uint &broken) {
    float sum = 0.0f;
    for (uint n = lane; n < count; n += componentLanes) {
        float p = pressures[first + n];
        if (as_type<uint>(p) == brokenFace) {
            broken = 1u;
        } else {
            sum += p;
        }
    }
    return sum;
}

// The same sum for a side whose faces all hold the still air, without reading them: the value
// comes from a row of copies, an entry a turn, so that fast math cannot fold the additions.
static inline float stillSum(const device float *still, uint count, uint lane) {
    float sum = 0.0f;
    for (uint n = lane; n < count; n += componentLanes) {
        sum += still[(n / componentLanes) % componentLanes];
    }
    return sum;
}

// A component's step, from its lanes' sums: the sides' means, their peaks and the net's, and the
// bins the step overlaps. Lane 0 writes. The divisions are exact and the bins' sums explicit
// fused multiply-adds, so this rounds the same in each kernel that calls it.
// Where the steps have reached: the bin the coming step starts in, and how far into it. Advanced
// once a step by `advanceEnvelopeClock`, by the step's own length, so the bins a step falls in do
// not depend on how the steps were cut into batches.
struct ComponentClock {
    uint bin;
    float fraction;
};

static inline void finishComponent(uint index, float2 sum, uint broken, uint4 side, uint lane,
                                   const device StepControl &control, constant ComponentRecording &r,
                                   const device ComponentClock &clock, device uint *starts, device float4 *peaks,
                                   device float2 *bins, device float2 *maxima, device atomic_uint *truncated,
                                   device float2 *current) {
    for (ushort offset = componentLanes / 2; offset > 0; offset /= 2) {
        sum += simd_shuffle_down(sum, offset);
        broken |= simd_shuffle_down(broken, offset);
    }
    if (lane != 0) return;
    float outer = side.y > 0 ? precise::divide(sum.x, float(side.y)) : 0.0f;
    float inner = side.w > 0 ? precise::divide(sum.y, float(side.w)) : 0.0f;
    float4 peak = peaks[index];
    peak.x = max(peak.x, outer);
    peak.y = max(peak.y, inner);
    peak.z = max(peak.z, outer - inner);
    peak.w = broken != 0 ? 1.0f : peak.w;
    peaks[index] = peak;
    // The step's two sides, for what reads them before the next (`stepEnvelopePanes`).
    current[index] = float2(outer, inner);
    uint start = starts[index];
    // The blast's arrival: either side's overpressure past the threshold, this step's bin the first.
    if (r.fromArrival != 0 && start == notStarted && r.arrivalPa > 0.0f && max(outer, inner) > r.arrivalPa) {
        start = clock.bin;
        starts[index] = start;
    }
    if (start == notStarted) return;
    float dt = r.initial != 0 ? 0.0f : control.dt;
    // The step, in seconds from the start of the bin it begins in.
    float begin = clock.fraction;
    float end = begin + dt;
    int last = r.initial != 0 ? 0 : max(int(ceil(end / r.binWidth)) - 1, 0);
    for (int k = 0; k <= last; ++k) {
        float overlap = min(end, float(k + 1) * r.binWidth) - max(begin, float(k) * r.binWidth);
        if (overlap <= 0.0f && r.initial == 0) continue;
        uint slot = clock.bin + uint(k) - start;
        if (slot >= r.capacity) {
            atomic_store_explicit(truncated, 1u, memory_order_relaxed);
            break;
        }
        ulong at = ulong(index) * ulong(r.capacity) + slot;
        float2 bin = bins[at];
        float share = max(overlap, 0.0f);
        bins[at] = float2(fma(outer, share, bin.x), fma(inner, share, bin.y));
        if (r.maxima != 0) {
            maxima[at] = max(maxima[at], float2(outer, inner));
        }
    }
}

// Each component's step begins here, a SIMD group a component: whether its air has woken, from the
// flags of the tiles its faces lie in. One whose tiles are all still holds the still air on every
// face, and after the first sample, which makes the row of the still air's pressure, it is finished
// here. The others are listed, in an order that varies, for the faces' pass and the sums, both
// dispatched indirectly: a step with nothing awake costs this one dispatch. At the first sample
// every component goes to the sums, after the faces' pass has made the row.
kernel void markEnvelopeComponents(const device StepControl &control [[buffer(2)]],
                                   const device uint2 *tileRanges [[buffer(3)]],
                                   const device uint *tiles [[buffer(4)]],
                                   const device uint4 *sides [[buffer(5)]],
                                   const device uchar *tileFlags [[buffer(7)]],
                                   device uint *awake [[buffer(8)]],
                                   constant SolverUniforms &u [[buffer(9)]],
                                   constant ComponentRecording &r [[buffer(10)]],
                                   device atomic_uint *faceDispatch [[buffer(11)]],
                                   device uint *faceList [[buffer(12)]],
                                   device atomic_uint *sumDispatch [[buffer(13)]],
                                   device uint *sumList [[buffer(14)]],
                                   const device float *stillPressure [[buffer(15)]],
                                   device float4 *peaks [[buffer(16)]],
                                   device float2 *bins [[buffer(17)]],
                                   device float2 *maxima [[buffer(18)]],
                                   device atomic_uint *truncated [[buffer(19)]],
                                   const device ComponentClock &clock [[buffer(20)]],
                                   device uint *starts [[buffer(21)]],
                                   device float2 *current [[buffer(22)]],
                                   uint group [[threadgroup_position_in_grid]],
                                   uint simd [[simdgroup_index_in_threadgroup]],
                                   uint groups [[simdgroups_per_threadgroup]],
                                   uint lane [[thread_index_in_simdgroup]]) {
    uint index = group * groups + simd;
    if (index >= r.components || (control.dt <= 0 && r.initial == 0)) return;
    // Whether any of its tiles is awake; without tiles, all air counts as moving.
    bool moved = u.tileNx == 0;
    uint2 range = tileRanges[index];
    bool waking = r.fromArrival != 0 && r.arrivalPa <= 0.0f;
    bool look = r.skipStill != 0 || (waking && starts[index] == notStarted);
    for (uint n = lane; look && !moved && n < range.y; n += componentLanes) {
        moved = tileFlags[tiles[range.x + n]] != tileStill;
    }
    moved = simd_any(moved);
    bool woken = r.skipStill == 0 || moved;
    uint start = starts[index];
    if (waking && start == notStarted && moved) {
        start = clock.bin;
    }
    if (lane == 0) {
        starts[index] = start;
        awake[index] = woken ? 1u : 0u;
        // At the first sample the faces' pass's first threadgroup makes the still air's row.
        if (woken) {
            faceList[atomic_fetch_add_explicit(faceDispatch, 1u, memory_order_relaxed) - r.initial] = index;
        }
        if (woken || r.initial != 0) {
            sumList[atomic_fetch_add_explicit(sumDispatch, 1u, memory_order_relaxed)] = index;
        }
    }
    if (woken || r.initial != 0) return;
    uint4 side = sides[index];
    float2 sum = float2(stillSum(stillPressure, side.y, lane), stillSum(stillPressure, side.w, lane));
    finishComponent(index, sum, 0u, side, lane, control, r, clock, starts, peaks, bins, maxima, truncated,
                    current);
}

// Every face's pressure: a threadgroup an awake component, its threads taking every
// `componentFaceThreads`th face; at the first sample, a threadgroup first that takes the still air,
// through the same instructions, as a row of 32 copies for components asleep.
constant uint componentFaceThreads = 256;

kernel void sampleEnvelopeComponentFaces(const device Cell *state [[buffer(0)]],
                                         const device uchar *mask [[buffer(1)]],
                                         const device StepControl &control [[buffer(2)]],
                                         const device uint2 *faces [[buffer(3)]],
                                         device float *pressures [[buffer(4)]],
                                         constant SolverUniforms &u [[buffer(5)]],
                                         constant ComponentRecording &r [[buffer(6)]],
                                         const device uchar *tileFlags [[buffer(7)]],
                                         const device uint4 *sides [[buffer(8)]],
                                         const device uint *faceList [[buffer(9)]],
                                         device float *stillPressure [[buffer(10)]],
                                         const device int *patchOfTile [[buffer(11)]],
                                         const device Cell *fine [[buffer(12)]],
                                         const device uchar *fineMask [[buffer(13)]],
                                         const device int *childPatches [[buffer(14)]],
                                         const device Cell *childFine [[buffer(15)]],
                                         const device uchar *childMask [[buffer(16)]],
                                         const device float *weights [[buffer(17)]],
                                         uint group [[threadgroup_position_in_grid]],
                                         uint local [[thread_index_in_threadgroup]]) {
    if (control.dt <= 0 && r.initial == 0) return;
    bool row = r.initial != 0 && group == 0;
    uint first = 0;
    uint count = componentLanes;
    if (!row) {
        uint4 side = sides[faceList[group - r.initial]];
        first = side.x;
        count = side.y + side.w;
    }
    for (uint n = local; n < count; n += componentFaceThreads) {
        bool still = row;
        uint2 face = still ? uint2(0) : faces[first + n];
        if (!still) {
            if (mask[face.x] != 0 || (face.y != 0xFFFFFFFFu && mask[face.y] == 0)) {
                pressures[first + n] = as_type<float>(brokenFace);
                continue;
            }
            // A cell in a still tile holds the still air: read that, not the cell.
            uint i = face.x % u.nx;
            uint j = (face.x / u.nx) % u.ny;
            uint k = face.x / (u.nx * u.ny);
            still = r.skipStill != 0 && u.tileNx > 0
                    && tileFlags[i / 8 + u.tileNx * (j / 8 + u.tileNy * (k / 8))] == tileStill;
            // Refined air: the finest cells against the face.
            float refined;
            if (!still && r.readsRefined != 0
                && refinedFaceOverpressure(face.x, face.y, u, patchOfTile, fine, fineMask, childPatches,
                                           childFine, childMask, refined)) {
                // Each face's weight: 1 for a component's own faces (the same bits), its share of
                // an equivalent load's otherwise.
                pressures[first + n] = refined * weights[first + n];
                continue;
            }
        }
        float rho;
        float3 momentum;
        float energy;
        if (still) {
            rho = u.stillRho;
            momentum = float3(u.stillMx, u.stillMy, u.stillMz);
            energy = u.stillEnergy;
        } else {
            Cell c = state[face.x];
            rho = c.rho;
            momentum = float3(c.mx, c.my, c.mz);
            energy = c.energy;
        }
        rho = max(rho, u.densityFloor);
        float kinetic = 0.5f * (momentum.x * momentum.x + momentum.y * momentum.y + momentum.z * momentum.z) / rho;
        float p = gasPressure(rho, energy - kinetic, u.airModel, u.gamma) - u.ambientPressure;
        if (row) {
            stillPressure[n] = p;
        } else {
            pressures[first + n] = p * weights[first + n];
        }
    }
}

// The sums of the components listed, a threadgroup of one SIMD group each: awake ones from their
// faces, and at the first sample the others from the still air's row. Its first thread clears both
// counts for the next step (they were read as the passes were dispatched).
kernel void sampleEnvelopeComponents(const device float *pressures [[buffer(0)]],
                                     const device uint *awake [[buffer(1)]],
                                     const device StepControl &control [[buffer(2)]],
                                     const device uint4 *sides [[buffer(3)]],
                                     const device uint *sumList [[buffer(4)]],
                                     device float4 *peaks [[buffer(5)]],
                                     device float2 *bins [[buffer(6)]],
                                     device float2 *maxima [[buffer(7)]],
                                     device atomic_uint *truncated [[buffer(8)]],
                                     device float2 *current [[buffer(9)]],
                                     constant ComponentRecording &r [[buffer(10)]],
                                     const device float *stillPressure [[buffer(11)]],
                                     device uint *faceDispatch [[buffer(12)]],
                                     device uint *sumDispatch [[buffer(13)]],
                                     const device ComponentClock &clock [[buffer(14)]],
                                     device uint *starts [[buffer(15)]],
                                     uint group [[threadgroup_position_in_grid]],
                                     uint lane [[thread_index_in_simdgroup]]) {
    if (group == 0 && lane == 0) {
        faceDispatch[0] = 0u;
        sumDispatch[0] = 0u;
    }
    if (control.dt <= 0 && r.initial == 0) return;
    uint index = sumList[group];
    uint4 side = sides[index];
    uint broken = 0u;
    float2 sum;
    if (awake[index] != 0) {
        sum = float2(sideSum(pressures, side.x, side.y, lane, broken),
                     sideSum(pressures, side.z, side.w, lane, broken));
    } else {
        sum = float2(stillSum(stillPressure, side.y, lane), stillSum(stillPressure, side.w, lane));
    }
    finishComponent(index, sum, broken, side, lane, control, r, clock, starts, peaks, bins, maxima,
                    truncated, current);
}

// After a step's components: the clock moves on by the step.
kernel void advanceEnvelopeClock(const device StepControl &control [[buffer(2)]],
                                 constant ComponentRecording &r [[buffer(10)]],
                                 device ComponentClock &clock [[buffer(14)]],
                                 uint index [[thread_position_in_grid]]) {
    if (index > 0 || r.initial != 0 || control.dt <= 0) return;
    float fraction = clock.fraction + control.dt;
    uint bin = clock.bin;
    while (fraction >= r.binWidth) {
        fraction -= r.binWidth;
        bin += 1;
    }
    clock.bin = bin;
    clock.fraction = fraction;
}
