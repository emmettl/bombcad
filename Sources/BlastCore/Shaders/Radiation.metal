// Radiative cooling of the luminous gas, appended to Solver.metal (after Extract.metal) at compile
// time. Off unless `SolverConfiguration.radiativeCooling` is set; then, after every `interval`
// steps' sweeps (and a batch's last), for the time since it was last taken:
//
//   1. every cell of the awake tiles gets the medium the thermal radiation's volume sees in it:
//      zero unless it is air at least `luminous` kelvin hot, and then its absorption coefficient
//      kappa (the hot gas's own plus its soot's) and its radiance as a black body, B = sigma T^4 / pi;
//      the box holding the luminous cells is found as it goes;
//   2. along 26 directions, the 13 lines of the lattice and both ways along each, the radiance is
//      carried through the box cell by cell, starting from zero (cold surroundings, a cold ground,
//      and cold, black solids, which stop it). A cell a beam crosses over a path s takes from it
//      I (1 - exp(-kappa s)) and gives it B (1 - exp(-kappa s)), so the beam leaves it with
//      I + (B - I)(1 - exp(-kappa s)): constant kappa and B across the cell, and what the beam gains
//      is exactly what the cell loses. Each direction stands for its share of the sphere, so a
//      cell loses sum_d w_d (B - I_d)(1 - exp(-kappa s_d)) / s_d a cubic metre: 4 kappa sigma T^4 when
//      the gas is thin, as it should, and from an opaque fireball sigma T^4 over its surface;
//   3. each luminous cell's energy falls by what it lost over that time, and what all of them lost
//      is added up, in a fixed order, as the energy radiated.
//
// The lines follow the lattice through the cells' centres, each cell on one line a direction, so
// a cell the beam crosses diagonally is crossed over a path of sqrt(2) or sqrt(3) cells; a line in
// direction d stands for a tube of dx^3 / s_d in cross-section, so the beams leaving the box carry
// away exactly what the cells lost. Each step's sum runs in a fixed order, so runs repeat exactly.

struct RadiationUniforms {
    float luminous;         // K: the gas is luminous at or above this
    float absorption;       // 1/m: the hot gas's own absorption
    float sootAbsorption;   // 1/(m K) per kg/m^3 of unburnt products: 1817 x the soot yield / 1800
    uint hasSpecies;        // whether the air carries unburnt products
    float largestShare;     // the most of a cell's internal energy one step may take
    float luminousEnergy;   // J/kg: no gas with less internal energy is luminous
    uint capacity;          // box cells the 13 directions' slices hold
};

// The lattice's 13 lines, each followed both ways.
constant int3 radiationDirections[13] = {
    int3(1, 0, 0), int3(0, 1, 0), int3(0, 0, 1), int3(1, 1, 0), int3(1, -1, 0), int3(1, 0, 1), int3(1, 0, -1),
    int3(0, 1, 1), int3(0, 1, -1), int3(1, 1, 1), int3(1, 1, -1), int3(1, -1, 1), int3(1, -1, -1),
};

// The 26 directions' shares of the sphere, steradians: the cones of directions nearer each than
// any other (by Monte Carlo, four million directions), along a cell's faces, edges and corners.
// They add up to 4 pi to a few millionths.
constant float radiationFaceWeight = 0.57506f;
constant float radiationEdgeWeight = 0.46493f;
constant float radiationCornerWeight = 0.44210f;
constant float stefanBoltzmann = 5.670374e-8f;

// The medium in one cell: its absorption coefficient (x) and black-body radiance (y), zero
// unless it is luminous air.
static inline float2 radiationMediumOf(uint index, const device Cell *state, const device uchar *mask,
                                       const device float2 *species, constant SolverUniforms &u,
                                       constant RadiationUniforms &r) {
    if (mask[index] != 0) {
        return float2(0.0f);
    }
    // Most cells are far too cool, which their energy shows without solving for their temperature.
    Cell c = state[index];
    float internal = c.energy - 0.5f * (c.mx * c.mx + c.my * c.my + c.mz * c.mz) / c.rho;
    if (!(internal >= r.luminousEnergy * c.rho)) {
        return float2(0.0f);
    }
    float t = luminousTemperatureOf(c, r.luminous, u);
    if (t == 0.0f) {
        return float2(0.0f);
    }
    float products = r.hasSpecies != 0u ? max(species[index].x, 0.0f) : 0.0f;
    float kappa = r.absorption + r.sootAbsorption * products * t;
    float square = t * t;
    return float2(kappa, stefanBoltzmann * square * square / M_PI_F);
}

// Adds the step's time to the time since the cooling was last taken, after every step.
kernel void radiationClock(const device StepControl &control [[buffer(0)]],
                           device float &elapsed [[buffer(1)]],
                           uint tid [[thread_position_in_grid]]) {
    if (tid == 0) {
        elapsed += max(control.dt, 0.0f);
    }
}

// Clears the box of luminous cells before step 1.
kernel void radiationReset(device atomic_uint *box [[buffer(0)]], uint tid [[thread_position_in_grid]]) {
    if (tid != 0) {
        return;
    }
    for (uint a = 0; a < 3; ++a) {
        atomic_store_explicit(box + a, 0xFFFFFFFFu, memory_order_relaxed);
        atomic_store_explicit(box + 4 + a, 0u, memory_order_relaxed);
    }
}

// Widens the box to hold [low, high], once a SIMD group (a lane with nothing luminous holds an
// empty range, which leaves the box as it is).
static inline void radiationWiden(device atomic_uint *box, uint3 low, uint3 high) {
    low = uint3(simd_min(low.x), simd_min(low.y), simd_min(low.z));
    high = uint3(simd_max(high.x), simd_max(high.y), simd_max(high.z));
    if (simd_is_first() && low.x != 0xFFFFFFFFu) {
        for (uint a = 0; a < 3; ++a) {
            atomic_fetch_min_explicit(box + a, low[a], memory_order_relaxed);
            atomic_fetch_max_explicit(box + 4 + a, high[a], memory_order_relaxed);
        }
    }
}

// Step 1 over the awake tiles, laid out as `sweepTiles` takes them.
kernel void radiationMediumTiles(const device Cell *state [[buffer(0)]],
                                 const device uchar *mask [[buffer(1)]],
                                 const device float2 *species [[buffer(2)]],
                                 device float2 *medium [[buffer(3)]],
                                 device atomic_uint *box [[buffer(4)]],
                                 const device float &elapsed [[buffer(5)]],
                                 constant SolverUniforms &u [[buffer(6)]],
                                 constant RadiationUniforms &r [[buffer(7)]],
                                 const device uint *tiles [[buffer(8)]],
                                 uint3 group [[threadgroup_position_in_grid]],
                                 uint3 local [[thread_position_in_threadgroup]],
                                 uint3 groupSize [[threads_per_threadgroup]]) {
    uint3 low = uint3(0xFFFFFFFFu);
    uint3 high = uint3(0u);
    if (elapsed > 0.0f) {
        uint tile = tiles[group.x];
        uint3 origin = uint3(tile % u.tileNx, (tile / u.tileNx) % u.tileNy, tile / (u.tileNx * u.tileNy))
            * uint(tileSize);
        for (uint z = local.z; z < uint(tileSize); z += groupSize.z) {
            uint3 cell = origin + uint3(local.x, local.y, z);
            if (cell.x < u.nx && cell.y < u.ny && cell.z < u.nz) {
                uint index = cell.x + u.nx * (cell.y + u.ny * cell.z);
                float2 m = radiationMediumOf(index, state, mask, species, u, r);
                medium[index] = m;
                if (m.x > 0.0f) {
                    low = min(low, cell);
                    high = max(high, cell);
                }
            }
        }
    }
    radiationWiden(box, low, high);
}

// Step 1 over every cell, when still air is not skipped.
kernel void radiationMedium(const device Cell *state [[buffer(0)]],
                            const device uchar *mask [[buffer(1)]],
                            const device float2 *species [[buffer(2)]],
                            device float2 *medium [[buffer(3)]],
                            device atomic_uint *box [[buffer(4)]],
                            const device float &elapsed [[buffer(5)]],
                            constant SolverUniforms &u [[buffer(6)]],
                            constant RadiationUniforms &r [[buffer(7)]],
                            uint3 tid [[thread_position_in_grid]]) {
    uint3 low = uint3(0xFFFFFFFFu);
    uint3 high = uint3(0u);
    if (elapsed > 0.0f && tid.x < u.nx && tid.y < u.ny && tid.z < u.nz) {
        uint index = tid.x + u.nx * (tid.y + u.ny * tid.z);
        float2 m = radiationMediumOf(index, state, mask, species, u, r);
        medium[index] = m;
        if (m.x > 0.0f) {
            low = tid;
            high = tid;
        }
    }
    radiationWiden(box, low, high);
}

// Threads a threadgroup of the lines and the cooling, over the box.
constant uint3 radiationGroup = uint3(8, 8, 4);

// The box's extent, zero when nothing is luminous.
static inline uint3 radiationExtent(const device uint *box) {
    return box[0] > box[4] ? uint3(0u) : uint3(box[4], box[5], box[6]) - uint3(box[0], box[1], box[2]) + 1u;
}

// Turns the box into the threadgroup counts of the dispatches over it (none when nothing is
// luminous, or no time has passed): the cooling's (arguments 0 to 2); and the lines', all 13
// directions in one dispatch, one after another along z (3 to 5), while the box fits the slices,
// or else one direction a dispatch (6 to 8).
kernel void radiationPrepare(const device uint *box [[buffer(0)]],
                             device uint *arguments [[buffer(1)]],
                             const device float &elapsed [[buffer(2)]],
                             constant RadiationUniforms &r [[buffer(3)]],
                             uint tid [[thread_position_in_grid]]) {
    if (tid != 0) {
        return;
    }
    uint3 extent = elapsed > 0.0f ? radiationExtent(box) : uint3(0u);
    uint3 groups = (extent + radiationGroup - 1u) / radiationGroup;
    bool fits = extent.x * extent.y * extent.z <= r.capacity;
    for (uint a = 0; a < 3; ++a) {
        arguments[a] = groups[a];
        arguments[3 + a] = fits ? (a == 2 ? 13u * groups.z : groups[a]) : 0u;
        arguments[6 + a] = fits ? 0u : groups[a];
    }
}

// 1 - exp(-x), accurate also for small x.
static inline float radiationAbsorbed(float x) {
    return x < 1e-2f ? x * (1.0f - x * (0.5f - x / 6.0f)) : 1.0f - exp(-x);
}

// What a cell takes from a beam of radiance `beam` crossing it over `path` metres, a cubic metre
// of it and per steradian, and the beam as it leaves.
static inline float radiationExchange(float2 m, float path, thread float &beam) {
    float a = radiationAbsorbed(m.x * path);
    float gained = (m.y - beam) * a;
    beam += gained;
    return gained / path;
}

// Step 2 along one of the 13 lines of the lattice, `direction`, both ways, when the box is too
// large for the slices: one thread a line,
// the one starting at its cell. Each cell's loss, W/m^3, is set by the first direction and added
// to by the rest; every cell of the box lies on one line of each, so nothing else writes it.
kernel void radiationLines(const device float2 *medium [[buffer(0)]],
                           const device uchar *mask [[buffer(1)]],
                           device float *loss [[buffer(2)]],
                           const device uint *box [[buffer(3)]],
                           constant SolverUniforms &u [[buffer(4)]],
                           constant int4 &direction [[buffer(5)]],
                           uint3 tid [[thread_position_in_grid]]) {
    int3 low = int3(box[0], box[1], box[2]);
    int3 high = int3(box[4], box[5], box[6]);
    int3 start = low + int3(tid);
    int3 d = direction.xyz;
    if (any(start > high) || all(clamp(start - d, low, high) == start - d)) {
        return;
    }
    int steps = abs(d.x) + abs(d.y) + abs(d.z);
    float weight = steps == 1 ? radiationFaceWeight : (steps == 2 ? radiationEdgeWeight : radiationCornerWeight);
    float path = u.dx * sqrt(float(steps));
    bool first = direction.w != 0;
    // Forwards, from the start.
    float beam = 0.0f;
    int3 cell = start;
    int3 last = start;
    while (all(cell >= low) && all(cell <= high)) {
        uint index = uint(cell.x) + u.nx * (uint(cell.y) + u.ny * uint(cell.z));
        float taken = 0.0f;
        if (mask[index] != 0) {
            beam = 0.0f;
        } else {
            float2 m = medium[index];
            if (m.x > 0.0f) {
                taken = weight * radiationExchange(m, path, beam);
            }
        }
        loss[index] = first ? taken : loss[index] + taken;
        last = cell;
        cell += d;
    }
    // And back.
    beam = 0.0f;
    cell = last;
    while (all(cell >= low) && all(cell <= high)) {
        uint index = uint(cell.x) + u.nx * (uint(cell.y) + u.ny * uint(cell.z));
        if (mask[index] != 0) {
            beam = 0.0f;
        } else {
            float2 m = medium[index];
            if (m.x > 0.0f) {
                loss[index] += weight * radiationExchange(m, path, beam);
            }
        }
        cell -= d;
    }
}

// Step 2 along all 13 lines at once, one thread a line, the one starting at its cell: each
// direction's threadgroups follow the last's along z. Each cell's loss along each direction, both
// ways, goes to that direction's slice of `slices`, by its place in the box; the cooling adds them
// up in order.
kernel void radiationLinesTogether(const device float2 *medium [[buffer(0)]],
                                   const device uchar *mask [[buffer(1)]],
                                   device float *slices [[buffer(2)]],
                                   const device uint *box [[buffer(3)]],
                                   constant SolverUniforms &u [[buffer(4)]],
                                   constant RadiationUniforms &r [[buffer(5)]],
                                   uint3 group [[threadgroup_position_in_grid]],
                                   uint3 local [[thread_position_in_threadgroup]]) {
    uint3 extent = radiationExtent(box);
    uint depth = (extent.z + radiationGroup.z - 1u) / radiationGroup.z;
    uint n = group.z / depth;
    uint3 position = uint3(group.x, group.y, group.z - n * depth) * radiationGroup + local;
    int3 low = int3(box[0], box[1], box[2]);
    int3 high = int3(box[4], box[5], box[6]);
    int3 start = low + int3(position);
    int3 d = radiationDirections[n];
    if (any(start > high) || all(clamp(start - d, low, high) == start - d)) {
        return;
    }
    int steps = abs(d.x) + abs(d.y) + abs(d.z);
    float weight = steps == 1 ? radiationFaceWeight : (steps == 2 ? radiationEdgeWeight : radiationCornerWeight);
    float path = u.dx * sqrt(float(steps));
    device float *slice = slices + n * r.capacity;
    float beam = 0.0f;
    int3 cell = start;
    int3 last = start;
    while (all(cell >= low) && all(cell <= high)) {
        uint index = uint(cell.x) + u.nx * (uint(cell.y) + u.ny * uint(cell.z));
        uint3 at = uint3(cell - low);
        float taken = 0.0f;
        if (mask[index] != 0) {
            beam = 0.0f;
        } else {
            float2 m = medium[index];
            if (m.x > 0.0f) {
                taken = weight * radiationExchange(m, path, beam);
            }
        }
        slice[at.x + extent.x * (at.y + extent.y * at.z)] = taken;
        last = cell;
        cell += d;
    }
    beam = 0.0f;
    cell = last;
    while (all(cell >= low) && all(cell <= high)) {
        uint index = uint(cell.x) + u.nx * (uint(cell.y) + u.ny * uint(cell.z));
        if (mask[index] != 0) {
            beam = 0.0f;
        } else {
            float2 m = medium[index];
            if (m.x > 0.0f) {
                uint3 at = uint3(cell - low);
                slice[at.x + extent.x * (at.y + extent.y * at.z)] += weight * radiationExchange(m, path, beam);
            }
        }
        cell -= d;
    }
}

// Step 3: each luminous cell of the box gives up what it lost over the time since the cooling was
// last taken, `elapsed` (or takes what it gained, where hotter gas shines on it), at most `largestShare` of its internal energy; what the
// threadgroup's cells gave up, in joules, goes to `partials`, one a threadgroup.
kernel void radiationApply(device Cell *state [[buffer(0)]],
                           const device float2 *medium [[buffer(1)]],
                           const device float *loss [[buffer(2)]],
                           const device uint *box [[buffer(3)]],
                           const device float &elapsed [[buffer(4)]],
                           constant SolverUniforms &u [[buffer(5)]],
                           constant RadiationUniforms &r [[buffer(6)]],
                           device float *partials [[buffer(7)]],
                           const device float *slices [[buffer(8)]],
                           uint3 tid [[thread_position_in_grid]],
                           uint3 group [[threadgroup_position_in_grid]],
                           uint3 groups [[threadgroups_per_grid]],
                           uint flat [[thread_index_in_threadgroup]],
                           uint lane [[thread_index_in_simdgroup]],
                           uint simdGroup [[simdgroup_index_in_threadgroup]]) {
    int3 cell = int3(box[0], box[1], box[2]) + int3(tid);
    float given = 0.0f;
    if (all(cell <= int3(box[4], box[5], box[6]))) {
        uint index = uint(cell.x) + u.nx * (uint(cell.y) + u.ny * uint(cell.z));
        if (medium[index].x > 0.0f) {
            uint3 extent = radiationExtent(box);
            float lost = 0.0f;
            if (extent.x * extent.y * extent.z <= r.capacity) {
                uint at = tid.x + extent.x * (tid.y + extent.y * tid.z);
                for (uint n = 0; n < 13; ++n) {
                    lost += slices[n * r.capacity + at];
                }
            } else {
                lost = loss[index];
            }
            Cell c = state[index];
            float internal = c.energy - 0.5f * (c.mx * c.mx + c.my * c.my + c.mz * c.mz) / c.rho;
            float energy = min(lost * elapsed, r.largestShare * max(internal, 0.0f));
            c.energy -= energy;
            state[index] = c;
            given = energy * u.dx * u.dx * u.dx;
        }
    }
    threadgroup float sums[32];
    float sum = simd_sum(given);
    if (lane == 0) {
        sums[simdGroup] = sum;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (flat == 0) {
        uint count = (radiationGroup.x * radiationGroup.y * radiationGroup.z + 31u) / 32u;
        float total = 0.0f;
        for (uint n = 0; n < count; ++n) {
            total += sums[n];
        }
        partials[group.x + groups.x * (group.y + groups.y * group.z)] = total;
    }
}

// Adds up the threadgroups' partial sums, in order, as the energy radiated since the cooling was
// last taken: row `stepIndex - 1` of `radiated`, as the gauges' log is kept; and starts the time
// since afresh.
kernel void radiationTally(const device float *partials [[buffer(0)]],
                           const device uint *arguments [[buffer(1)]],
                           const device StepControl &control [[buffer(2)]],
                           device float *radiated [[buffer(3)]],
                           device float &elapsed [[buffer(4)]],
                           uint tid [[thread_position_in_grid]]) {
    if (tid != 0 || control.stepIndex == 0) {
        return;
    }
    elapsed = 0.0f;
    uint count = arguments[0] * arguments[1] * arguments[2];
    float total = 0.0f;
    for (uint n = 0; n < count; ++n) {
        total += partials[n];
    }
    radiated[control.stepIndex - 1] = total;
}
