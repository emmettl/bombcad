// Venting's kernels, appended to Solver.metal at compile time (ShaderLibrary): panes and walls
// stepped on their loads and opened when they fail, breaches, and the rooms behind them.

// Envelope venting (EnvelopeVenting.swift): each pane's glass the one-way model's single degree of
// freedom (`SDOFSystem.response` for `EnvelopePanel.largeDeflectionGlass`), K_LM m x'' + R(x) = p
// with p the step's net pressure on it (outer less inner): R its stiffening backbone, elastic both
// ways; by velocity Verlet at a 200th of the shortest period it reaches or less; breaking when
// Brown's integral of its largest principal stress, the integral of (sigma / S)^n dt, reaches the
// reference duration, or when it deflects past where its edges let go. Its cells open after the
// step. A thread a pane. A pane that broke in the step before is marked open first.
struct EnvelopeGlass {
    float mass;
    float substep;
    float strength;
    float reference;
    float exponent;
    float letsGo;
    uint first;
    uint count;
};

// The backbone's resistance (x) and the largest principal stress (y) at deflection `d` >= 0, as
// `SDOFSystem.envelope` and `Brittle.stress` interpolate them: from (0, 0) to the first point, then
// point to point, and the last point's beyond.
static inline float2 glassAt(float d, const device float4 *table, uint first, uint count) {
    float4 lead = table[first];
    if (d <= lead.x) return float2(lead.y, lead.z) * (d / lead.x);
    uint low = 0;
    uint high = count - 1;
    if (d >= table[first + high].x) return table[first + high].yz;
    // table[low].x < d <= table[high].x
    while (high - low > 1) {
        uint middle = (low + high) / 2;
        if (table[first + middle].x < d) low = middle; else high = middle;
    }
    float4 a = table[first + low];
    float4 b = table[first + high];
    float f = (d - a.x) / (b.x - a.x);
    return float2(a.y + (b.y - a.y) * f, a.z + (b.z - a.z) * f);
}

kernel void stepEnvelopePanes(const device float2 *current [[buffer(0)]],
                              const device uint2 *panes [[buffer(1)]],
                              const device EnvelopeGlass *glass [[buffer(2)]],
                              device float4 *state [[buffer(3)]],
                              device uint *status [[buffer(4)]],
                              device atomic_uint *opened [[buffer(5)]],
                              const device StepControl &control [[buffer(6)]],
                              constant uint &count [[buffer(7)]],
                              const device uint2 *ownerRooms [[buffer(8)]],
                              device atomic_uint *roomDispatch [[buffer(9)]],
                              device uint *roomList [[buffer(10)]],
                              const device float4 *table [[buffer(11)]],
                              const device uint2 *holes [[buffer(12)]],
                              uint pane [[thread_position_in_grid]]) {
    if (pane >= count || control.dt <= 0.0f) return;
    uint was = status[pane];
    if (was == 1u) status[pane] = 2u;
    float4 motion = state[2 * pane];
    float4 clock = state[2 * pane + 1];
    clock.x += control.dt;
    if (was != 0u) {
        state[2 * pane + 1] = clock;
        return;
    }
    // Holed by a fragment (its time in the run's ticks, all ones for none): broken on the step
    // the run's clock reaches it, however the run is batched, through the same path as the glass.
    ulong hole = ulong(holes[pane].x) | (ulong(holes[pane].y) << 32);
    bool holed = hole <= runClock(control);
    EnvelopeGlass g = glass[pane];
    float2 sides = current[panes[pane].x];
    float p = sides.x - sides.y;
    uint n = max(1u, uint(ceil(control.dt / g.substep)));
    float h = control.dt / float(n);
    float x = motion.x;
    float v = motion.y;
    float fatigue = motion.z;
    float r = sign(x) * glassAt(fabs(x), table, g.first, g.count).x;
    bool broken = false;
    if (holed) {
        broken = true;
        clock.y = float(hole) * 9.094947017729282e-13f;  // 2^-40
        status[pane] = 1u;
        uint owner = panes[pane].y;
        if (atomic_exchange_explicit(opened + owner, 1u, memory_order_relaxed) == 0u) {
            uint2 range = ownerRooms[owner];
            uint at = atomic_fetch_add_explicit(roomDispatch, range.y, memory_order_relaxed);
            for (uint k = 0; k < range.y; ++k) roomList[at + k] = range.x + k;
        }
    }
    for (uint i = 0; i < n && !broken; ++i) {
        v += 0.5f * h * (p - r) / g.mass;
        x += h * v;
        float2 at = glassAt(fabs(x), table, g.first, g.count);
        r = sign(x) * at.x;
        v += 0.5f * h * (p - r) / g.mass;
        if (g.exponent > 0.0f) {
            fatigue += h * pow(at.y / g.strength, g.exponent);
            broken = fatigue >= g.reference;
        } else {
            broken = at.y >= g.strength;
        }
        broken = broken || fabs(x) >= g.letsGo;
        if (broken) {
            clock.y = clock.x - control.dt + float(i + 1) * h;
            status[pane] = 1u;
            // The building's first broken pane lists its rooms for reading from now on, in the
            // order the buildings open.
            uint owner = panes[pane].y;
            if (atomic_exchange_explicit(opened + owner, 1u, memory_order_relaxed) == 0u) {
                uint2 range = ownerRooms[owner];
                uint at = atomic_fetch_add_explicit(roomDispatch, range.y, memory_order_relaxed);
                for (uint k = 0; k < range.y; ++k) roomList[at + k] = range.x + k;
            }
        }
    }
    state[2 * pane] = float4(x, v, fatigue, 0.0f);
    state[2 * pane + 1] = clock;
}

// The cells of the panes that broke in the step just taken leave the mask (and the rigid mask the
// structures' outline starts from) and hold the still air, as a cell under glass has from the
// start: the pane's volume of air at rest at ambient, the flow's own mass, momentum and energy
// untouched. The tiles round them wake. A thread a cell.
kernel void openEnvelopePanes(const device uint2 *cells [[buffer(0)]],
                              const device uint *status [[buffer(1)]],
                              device uchar *mask [[buffer(2)]],
                              device uchar *rigidMask [[buffer(3)]],
                              device Cell *stateA [[buffer(4)]],
                              device Cell *stateB [[buffer(5)]],
                              device float2 *speciesA [[buffer(6)]],
                              device float2 *speciesB [[buffer(7)]],
                              device uchar *tileFlags [[buffer(8)]],
                              constant SolverUniforms &u [[buffer(9)]],
                              const device StepControl &control [[buffer(10)]],
                              constant uint &count [[buffer(11)]],
                              const device float4 *gravityTable [[buffer(12)]],
                              uint tid [[thread_position_in_grid]]) {
    if (tid >= count || control.dt <= 0.0f) return;
    uint2 entry = cells[tid];
    if (status[entry.y] != 1u) return;
    uint index = entry.x;
    // Already opened (a pane in a wall that went first): its air is the flow's now.
    if (mask[index] == 0) return;
    mask[index] = 0;
    rigidMask[index] = 0;
    Cell still;
    still.rho = u.stillRho;
    still.mx = u.stillMx;
    still.my = u.stillMy;
    still.mz = u.stillMz;
    still.energy = u.stillEnergy;
    // Under gravity, the background at rest at the cell's height.
    if (u.gravity != 0.0f) {
        still = gravityRestOf(gravityTable, int(index / (u.nx * u.ny)));
    }
    stateA[index] = still;
    stateB[index] = still;
    if (carriesSpecies(u)) {
        float2 air = float2(0.0f, u.stillOxygen / u.stillRho * still.rho);
        speciesA[index] = air;
        speciesB[index] = air;
    }
    if (u.tileNx != 0) {
        int3 cell = int3(index % u.nx, (index / u.nx) % u.ny, index / (u.nx * u.ny));
        wakeTilesAround(cell, tileFlags, tileWoken, u);
    }
}

// Envelope venting's walls, roofs and slabs (`EnvelopeWallFailure`): each of a component's single
// degrees of freedom as `SDOFSystem.response` steps it, K_LM m x'' + c x' + R(x) = p, R its backbone
// with permanent set (inward the backbone at the furthest inward deflection yet, outward the
// rebound resistance), K_LM elastic until it yields, then the mean of elastic and plastic up to 2°
// of support rotation, then plastic; by velocity Verlet at a 200th of its elastic period. The
// component fails when a system's level does (concrete past 10° once yielded, masonry with no
// resistance left): a panel's either bound, a cantilever's the way its load has pushed harder so
// far. Its cells open after the step, as a pane's. A thread a component.
struct EnvelopeWallSystem {
    float mass;
    float loadMassElastic;
    float loadMassPlastic;
    float span;
    float reboundFactor;
    float damping;
    float substep;
    float stiffness;
    float yieldPast;
    float rotationPast;
    float lostPast;
    float sign;
    uint first;
    uint count;
    uint eitherWay;  // 1: yielded either way (concrete), not only inward
    uint pad1;
};

// The backbone's resistance at deflection `x` >= 0, as `SDOFSystem.envelope`.
static inline float wallEnvelope(float x, const device float4 *table, EnvelopeWallSystem s) {
    float4 lead = table[s.first];
    if (x <= lead.x) return s.stiffness * x;
    for (uint k = 1; k < s.count; ++k) {
        float4 b = table[s.first + k];
        if (x <= b.x) {
            float4 a = table[s.first + k - 1];
            return a.y + (b.y - a.y) * (x - a.x) / (b.x - a.x);
        }
    }
    return table[s.first + s.count - 1].y;
}

kernel void stepEnvelopeWalls(const device float2 *current [[buffer(0)]],
                              const device uint4 *walls [[buffer(1)]],
                              const device EnvelopeWallSystem *systems [[buffer(2)]],
                              const device float4 *table [[buffer(3)]],
                              device float4 *state [[buffer(4)]],
                              device float4 *clocks [[buffer(5)]],
                              device uint *status [[buffer(6)]],
                              device atomic_uint *opened [[buffer(7)]],
                              const device StepControl &control [[buffer(8)]],
                              constant uint2 &counts [[buffer(9)]],
                              const device uint2 *ownerRooms [[buffer(10)]],
                              device atomic_uint *roomDispatch [[buffer(11)]],
                              device uint *roomList [[buffer(12)]],
                              uint wall [[thread_position_in_grid]]) {
    // counts: the walls, and the panes before them in `status`.
    if (wall >= counts.x || control.dt <= 0.0f) return;
    uint opener = counts.y + wall;
    uint was = status[opener];
    if (was == 1u) status[opener] = 2u;
    float4 clock = clocks[wall];  // (time, broken at, largest net pressure, smallest)
    clock.x += control.dt;
    if (was != 0u) {
        clocks[wall] = clock;
        return;
    }
    uint4 w = walls[wall];  // (component, owner, first system, systems | cantilever << 16)
    float2 sides = current[w.x];
    float p = sides.x - sides.y;
    clock.z = max(clock.z, p);
    clock.w = min(clock.w, p);
    uint count = w.w & 0xffffu;
    bool cantilever = (w.w >> 16) != 0u;
    // A cantilever is judged the way its load has pushed it harder so far (`cantileverLoad`).
    uint judged = cantilever && -clock.w > clock.z ? 1u : 0u;
    bool broken = false;
    float brokeAt = 0.0f;
    for (uint k = 0; k < count; ++k) {
        EnvelopeWallSystem s = systems[w.z + k];
        float4 a = state[2 * (w.z + k)];      // x, v, permanent set, peak inward
        float4 b = state[2 * (w.z + k) + 1];  // rebound (<= 0), yielded, resistance, failed
        float x = a.x, v = a.y, permanent = a.z, peak = a.w;
        float rebound = b.x, r = b.z;
        bool yielded = b.y != 0.0f;
        bool failed = b.w != 0.0f;
        float load = s.sign * p;
        uint n = max(1u, uint(ceil(control.dt / s.substep)));
        float h = control.dt / float(n);
        float yieldX = table[s.first].x;
        for (uint i = 0; i < n; ++i) {
            float kick = s.loadMassElastic;
            if (yielded) {
                bool small = s.span > 0.0f && atan(max(fabs(x), peak) / (s.span / 2.0f)) <= 2.0f * M_PI_F / 180.0f;
                kick = small ? 0.5f * (s.loadMassElastic + s.loadMassPlastic) : s.loadMassPlastic;
            }
            v += 0.5f * h * (load - r - s.damping * v) / (kick * s.mass);
            x += h * v;
            // The resistance at x (yielding moves the permanent set).
            r = s.stiffness * (x - permanent);
            float reached = max(max(x, peak), yieldX);
            float upper = wallEnvelope(reached, table, s);
            float outward = max(max(-x, -rebound), yieldX);
            float lower = -s.reboundFactor * min(wallEnvelope(outward, table, s), upper);
            if (r > upper) {
                r = upper;
                permanent = x - r / s.stiffness;
                yielded = yielded || x > yieldX;
            } else if (r < lower) {
                r = lower;
                permanent = x - r / s.stiffness;
                yielded = yielded || -x > yieldX;
            }
            kick = s.loadMassElastic;
            if (yielded) {
                bool small = s.span > 0.0f && atan(max(fabs(x), peak) / (s.span / 2.0f)) <= 2.0f * M_PI_F / 180.0f;
                kick = small ? 0.5f * (s.loadMassElastic + s.loadMassPlastic) : s.loadMassPlastic;
            }
            v += 0.5f * h * (load - r - s.damping * v) / (kick * s.mass);
            peak = max(peak, x);
            rebound = min(rebound, x);
            float yieldedBy = s.eitherWay != 0 ? max(peak, -rebound) : peak;
            if (!failed && ((yieldedBy > s.yieldPast && max(peak, -rebound) > s.rotationPast) || fabs(x) >= s.lostPast)) {
                failed = true;
                if (!cantilever || k == judged) {
                    float t = clock.x - control.dt + float(i + 1) * h;
                    brokeAt = broken ? min(brokeAt, t) : t;
                    broken = true;
                }
            }
        }
        // A cantilever judged now by a system that failed earlier has failed too.
        if (cantilever && k == judged && failed && !broken) {
            broken = true;
            brokeAt = clock.x;
        }
        state[2 * (w.z + k)] = float4(x, v, permanent, peak);
        state[2 * (w.z + k) + 1] = float4(rebound, yielded ? 1.0f : 0.0f, r, failed ? 1.0f : 0.0f);
    }
    if (broken) {
        clock.y = brokeAt;
        status[opener] = 1u;
        uint owner = w.y;
        if (atomic_exchange_explicit(opened + owner, 1u, memory_order_relaxed) == 0u) {
            uint2 range = ownerRooms[owner];
            uint at = atomic_fetch_add_explicit(roomDispatch, range.y, memory_order_relaxed);
            for (uint k = 0; k < range.y; ++k) roomList[at + k] = range.x + k;
        }
    }
    clocks[wall] = clock;
}

// Holes through envelope walls, roofs and slabs (`EnvelopeVenting.setBreaches`): each a column of
// a component's cells that opens, as a pane's cells do, on the step the run's clock reaches it,
// however the run is batched. A thread a hole.
kernel void openEnvelopeBreaches(const device uint4 *breaches [[buffer(0)]],
                                 device uint *status [[buffer(1)]],
                                 device atomic_uint *opened [[buffer(2)]],
                                 const device StepControl &control [[buffer(3)]],
                                 constant uint &count [[buffer(4)]],
                                 const device uint2 *ownerRooms [[buffer(5)]],
                                 device atomic_uint *roomDispatch [[buffer(6)]],
                                 device uint *roomList [[buffer(7)]],
                                 uint hole [[thread_position_in_grid]]) {
    if (hole >= count || control.dt <= 0.0f) return;
    uint4 b = breaches[hole];  // (opener, owner, ticks low, ticks high)
    uint was = status[b.x];
    if (was == 1u) status[b.x] = 2u;
    if (was != 0u) return;
    ulong ticks = ulong(b.z) | (ulong(b.w) << 32);
    if (ticks > runClock(control)) return;
    status[b.x] = 1u;
    if (atomic_exchange_explicit(opened + b.y, 1u, memory_order_relaxed) == 0u) {
        uint2 range = ownerRooms[b.y];
        uint at = atomic_fetch_add_explicit(roomDispatch, range.y, memory_order_relaxed);
        for (uint k = 0; k < range.y; ++k) roomList[at + k] = range.x + k;
    }
}

// Each room of an opened building: its cells' mean overpressure this step, its peak and positive
// impulse. A threadgroup of 256 a room, its sum in a fixed order.
struct EnvelopeRoom {
    uint owner;
    uint first;
    uint count;
    uint pad;
};

kernel void sampleEnvelopeRooms(const device Cell *state [[buffer(0)]],
                                const device EnvelopeRoom *rooms [[buffer(1)]],
                                const device uint *cells [[buffer(2)]],
                                const device uint *roomList [[buffer(3)]],
                                device float4 *results [[buffer(4)]],
                                constant SolverUniforms &u [[buffer(5)]],
                                const device StepControl &control [[buffer(6)]],
                                const device float4 *gravityTable [[buffer(7)]],
                                uint group [[threadgroup_position_in_grid]],
                                uint local [[thread_index_in_threadgroup]]) {
    threadgroup float partial[256];
    // Only the rooms of buildings opened are dispatched (`roomList`, by `stepEnvelopePanes`).
    uint index = roomList[group];
    EnvelopeRoom room = rooms[index];
    if (control.dt <= 0.0f) return;
    float sum = 0.0f;
    for (uint n = local; n < room.count; n += 256u) {
        uint index = cells[room.first + n];
        Cell c = state[index];
        float rho = max(c.rho, u.densityFloor);
        float kinetic = 0.5f * (c.mx * c.mx + c.my * c.my + c.mz * c.mz) / rho;
        // Under gravity, against the ambient pressure at the cell's height.
        float ambient = u.gravity != 0.0f ? gravityAmbientOf(gravityTable, int(index / (u.nx * u.ny)), u)
                                          : u.ambientPressure;
        sum += gasPressure(rho, c.energy - kinetic, u.airModel, u.gamma) - ambient;
    }
    partial[local] = sum;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint stride = 128u; stride > 0u; stride /= 2u) {
        if (local < stride) partial[local] += partial[local + stride];
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (local != 0) return;
    float mean = partial[0] / float(max(room.count, 1u));
    float4 result = results[index];
    result.x = max(result.x, mean);
    result.y += max(mean, 0.0f) * control.dt;
    result.z = mean;
    results[index] = result;
}
