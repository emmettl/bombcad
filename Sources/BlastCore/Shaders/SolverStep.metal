// Each step's bookkeeping, appended to Solver.metal at compile time (ShaderLibrary): tiles woken
// and collected, the step's length and clock, and the gauges.

// After a restart: wakes the tiles within reach of every fluid cell that is not still.
kernel void wakeTiles(const device Cell *state [[buffer(0)]],
                      const device uchar *mask [[buffer(1)]],
                      device uchar *tileFlags [[buffer(2)]],
                      constant SolverUniforms &u [[buffer(3)]],
                      const device float2 *species [[buffer(4)]],
                      const device float4 *gravityTable [[buffer(5)]],
                      uint3 tid [[thread_position_in_grid]]) {
    if (tid.x >= u.nx || tid.y >= u.ny || tid.z >= u.nz) {
        return;
    }
    int index = int(tid.x + u.nx * (tid.y + u.ny * tid.z));
    if (mask[index] == 0 && !isStillAt(state[index], species[index], int(tid.z), gravityTable, u)) {
        wakeTilesAround(int3(tid), tileFlags, tileActive, u);
    }
}

// Before each step: lists the awake tiles for the sweeps. Still air, and air woken during the
// last step, was not swept then, so its contribution to the time step is added here, exactly
// as the final sweep would have computed it for a still cell.
kernel void collectTiles(device uchar *tileFlags [[buffer(0)]],
                         device uint *tiles [[buffer(1)]],
                         device atomic_uint *tileCount [[buffer(2)]],
                         device atomic_uint *maxSpeed [[buffer(3)]],
                         constant SolverUniforms &u [[buffer(4)]],
                         const device float4 *gravityTable [[buffer(5)]],
                         uint tid [[thread_position_in_grid]]) {
    if (tid >= u.tileNx * u.tileNy * u.tileNz) {
        return;
    }
    uchar flag = tileFlags[tid];
    if (flag != tileActive && airGravity) {
        // Under gravity, the air at rest at the ground, the warmest and so the fastest; it sets
        // the step only while nothing moves, which a charge does from its first step.
        Prim w = primOfCell(gravityRestOf(gravityTable, 0), u);
        recordCell(maxSpeed, float3(0.0f), w.rho, w.p, u, w.p);
    } else if (flag != tileActive) {
        float rho = max(u.stillRho, u.densityFloor);
        float3 momentum = float3(u.stillMx, u.stillMy, u.stillMz);
        float kinetic = 0.5f * dot(momentum, momentum) / rho;
        float pressure = gasPressure(rho, u.stillEnergy - kinetic, u.airModel, u.gamma);
        if (pressure < u.pressureFloor) {
            pressure = u.pressureFloor;
        }
        recordCell(maxSpeed, momentum, rho, pressure, u);
    }
    if (flag != tileStill) {
        tiles[atomic_fetch_add_explicit(tileCount, 1u, memory_order_relaxed)] = tid;
        if (flag == tileWoken) {
            tileFlags[tid] = tileActive;
        }
    }
}

// Writes row `row` of the gauge log: the step's length, then each gauge's pressure.
// The pressure at a rigid wall that gas of density `rho` and pressure `p` meets moving towards it at
// `towards` (negative: away): two shocks between it and its mirror, or two rarefactions, for a gas
// of ratio `gamma`. For a shocked state arriving at a wall, the normal reflection's pressure.
static inline float twoShockWallPressure(float rho, float p, float towards, float gamma) {
    float c = sqrt(gamma * p / rho);
    if (towards <= 0.0f) {
        float base = max(1.0f + 0.5f * (gamma - 1.0f) * towards / c, 0.0f);
        return p * pow(base, 2.0f * gamma / (gamma - 1.0f));
    }
    float a = 2.0f / ((gamma + 1.0f) * rho);
    float b = (gamma - 1.0f) / (gamma + 1.0f) * p;
    float q = p + rho * c * towards;
    for (int n = 0; n < 6; ++n) {
        float root = sqrt(a / (q + b));
        float f = (q - p) * root - towards;
        float slope = root * (1.0f - 0.5f * (q - p) / (q + b));
        q = max(q - f / slope, p);
    }
    return q;
}

static inline void logGauges(device float *gaugeLog, uint row, float dt, const device Cell *state,
                             const device uint *gaugeCells, constant SolverUniforms &u,
                             const device int *patchOfTile, const device Cell *fine,
                             const device uint *gaugeChildren, const device uchar *fineMask,
                             const device int *childPatches, const device Cell *childFine,
                             const device uchar *childMask, const device float4 *gravityTable,
                             const device uchar *mask, const device float4 *gaugePoints) {
    row *= u.gaugeCount + 1;
    gaugeLog[row] = dt;
    for (uint g = 0; g < u.gaugeCount; ++g) {
        Cell c = state[gaugeCells[g]];
        // A gauge whose cell a structure has moved into reads the fluid cell beside it nearest its
        // point, at the finest level it can, rather than the solid cell's stale state.
        bool read = mask[gaugeCells[g]] == 0;
        float3 point = gaugePoints[g].xyz;
        bool placed = gaugePoints[g].w != 0.0f;
        // Where the gauge's cell is refined, the finest cell holding the gauge's point: `child`
        // numbers the finest cells of its coarse cell.
        uint child = gaugeChildren[g];
        if (u.refineRatio != 0 && child != 0xFFFFFFFFu) {
            uint index = gaugeCells[g];
            int3 cell = int3(index % u.nx, (index / u.nx) % u.ny, index / (u.nx * u.ny));
            int r = int(u.refineRatio);
            int side = patchSize * r;
            int3 within = int3(child % uint(r), (child / uint(r)) % uint(r), child / uint(r * r));
            bool found = false;
            if (u.childTileNx != 0) {
                // Two levels: the cell of the second level, where it is refined.
                int deep = r * r;
                int3 finest = int3(child % uint(deep), (child / uint(deep)) % uint(deep), child / uint(deep * deep));
                int3 global = cell * deep + finest;
                int3 block = global / side;
                int patch = childPatches[block.x + int(u.childTileNx) * (block.y + int(u.childTileNy) * block.z)];
                if (patch >= 0) {
                    int3 local = global - block * side;
                    uint at = uint(patch) * uint(side * side * side) + uint(local.x + side * (local.y + side * local.z));
                    if ((childMask[at] & 1) == 0) {
                        c = childFine[at];
                        found = true;
                    }
                }
                within = finest / r;
            }
            int patch = found ? -1 : patchAt(cell, patchOfTile, u);
            if (patch >= 0) {
                int3 local = (cell % patchSize) * r + within;
                uint at = uint(patch) * uint(side * side * side) + uint(local.x + side * (local.y + side * local.z));
                if ((fineMask[at] & 1) == 0) {
                    c = fine[at];
                    found = true;
                } else {
                    // The fine cell is solid: the fluid one beside it in the patch nearest the point.
                    float fineCell = u.dx / float(r);
                    float3 origin = float3(cell / patchSize * patchSize) * u.dx;
                    float best = INFINITY;
                    for (int n = 0; n < 6; ++n) {
                        int3 q = local;
                        q[n / 2] += (n % 2) * 2 - 1;
                        if (any(q < 0) || any(q >= side)) { continue; }
                        uint there = uint(patch) * uint(side * side * side) + uint(q.x + side * (q.y + side * q.z));
                        if ((fineMask[there] & 1) != 0) { continue; }
                        float3 centre = origin + (float3(q) + 0.5f) * fineCell;
                        float distance = placed ? distance_squared(centre, point) : float(n);
                        if (distance < best) {
                            best = distance;
                            c = fine[there];
                            found = true;
                        }
                    }
                }
            }
            read = read || found;
        }
        if (!read) {
            // The coarse cell is solid and no fine cell stood in: its fluid neighbour nearest the point.
            uint index = gaugeCells[g];
            int3 cell = int3(index % u.nx, (index / u.nx) % u.ny, index / (u.nx * u.ny));
            float best = INFINITY;
            for (int n = 0; n < 6; ++n) {
                int3 q = cell;
                q[n / 2] += (n % 2) * 2 - 1;
                if (any(q < 0) || any(q >= int3(u.nx, u.ny, u.nz))) { continue; }
                uint there = uint(q.x) + u.nx * (uint(q.y) + u.ny * uint(q.z));
                if (mask[there] != 0) { continue; }
                float3 centre = (float3(q) + 0.5f) * u.dx;
                float distance = placed ? distance_squared(centre, point) : float(n);
                if (distance < best) {
                    best = distance;
                    c = state[there];
                }
            }
        }
        float kinetic = 0.5f * (c.mx * c.mx + c.my * c.my + c.mz * c.mz) / max(c.rho, u.densityFloor);
        float pressure = gasPressure(max(c.rho, u.densityFloor), c.energy - kinetic, u.airModel, u.gamma);
        if (u.gaugeWalls != 0 && placed) {
            // The wall nearest the gauge's point among its coarse cell's faces, within a cell: a solid
            // neighbour, or a reflective face of the domain.
            uint index = gaugeCells[g];
            int3 cell = int3(index % u.nx, (index / u.nx) % u.ny, index / (u.nx * u.ny));
            int3 dims = int3(u.nx, u.ny, u.nz);
            float nearest = u.dx;
            int face = -1;
            for (int n = 0; n < 6; ++n) {
                int axis = n / 2;
                int side = n % 2;
                int3 q = cell;
                q[axis] += side * 2 - 1;
                bool solid = any(q < 0) || any(q >= dims)
                                 ? ((u.boundaryFlags >> uint(2 * axis + side)) & 1u) != 0
                                 : mask[uint(q.x) + u.nx * (uint(q.y) + u.ny * uint(q.z))] != 0;
                if (!solid) { continue; }
                float plane = float(cell[axis] + side) * u.dx;
                float distance = fabs(point[axis] - plane);
                if (distance < nearest) {
                    nearest = distance;
                    face = n;
                }
            }
            if (face >= 0) {
                float rho = max(c.rho, u.densityFloor);
                float towards = float3(c.mx, c.my, c.mz)[face / 2] / rho * float((face % 2) * 2 - 1);
                pressure = twoShockWallPressure(rho, max(pressure, u.pressureFloor), towards, u.gamma);
            }
        }
        if (airGravity) {
            // Under gravity, as if at the ground: its overpressure against the ambient pressure
            // at the gauge's height, as the coarse cell holds it.
            int k = int(gaugeCells[g] / (u.nx * u.ny));
            pressure += u.ambientPressure - gravityAmbientOf(gravityTable, k, u);
        }
        gaugeLog[row + 1 + g] = pressure;
    }
}

// Runs once per step on a single thread: turns the fastest wave speed of the previous
// step into the next dt, advances the batch clock and samples the gauges.
kernel void prepareStep(device StepControl &control [[buffer(0)]],
                        device atomic_uint *maxSpeed [[buffer(1)]],
                        const device Cell *state [[buffer(2)]],
                        device float *gaugeLog [[buffer(3)]],
                        const device uint *gaugeCells [[buffer(4)]],
                        constant SolverUniforms &u [[buffer(5)]],
                        device atomic_uint *tileCount [[buffer(6)]],
                        device uint *tileDispatch [[buffer(7)]],
                        const device int *patchOfTile [[buffer(8)]],
                        const device Cell *fine [[buffer(9)]],
                        const device uint *gaugeChildren [[buffer(10)]],
                        const device uchar *fineMask [[buffer(11)]],
                        const device int *childPatches [[buffer(12)]],
                        const device Cell *childFine [[buffer(13)]],
                        const device uchar *childMask [[buffer(14)]],
                        const device float4 *gravityTable [[buffer(15)]],
                        const device uchar *mask [[buffer(16)]],
                        const device float4 *gaugePoints [[buffer(17)]],
                        uint tid [[thread_position_in_grid]]) {
    if (tid != 0) {
        return;
    }
    uint tiles = 0;
    if (u.tileNx != 0) {
        // One threadgroup per awake tile in the sweeps that follow.
        tiles = atomic_exchange_explicit(tileCount, 0u, memory_order_relaxed);
        tileDispatch[0] = tiles;
        tileDispatch[1] = 1;
        tileDispatch[2] = 1;
        control.activeTiles = tiles;
    }
    float fastest = as_type<float>(atomic_load_explicit(maxSpeed, memory_order_relaxed));
    // A cell whose density has fallen to nothing reads a wave speed that is NaN, or negative from
    // a negative density, and either outranks every real speed in the bitwise maximum; the step
    // would then be far longer than the air allows (a refined district once took steps of 0.6 s
    // where 3 ms were right). The batch stops there instead, unstable. Tested on the bits, as fast
    // math may fold a test for NaN or infinity away: NaN, infinity and every negative lie at or
    // above infinity's.
    if (as_type<uint>(fastest) >= 0x7F800000u) {
        control.stopped = 3;
        control.maxOverpressure = NAN;
    }
    float dt = u.cfl * u.dx / max(fastest, 1e-6f);
    if (u.maxStep > 0.0f) {
        dt = min(dt, u.maxStep);
    }
    if (u.forcedStep > 0.0f) {
        dt = u.forcedStep;
    }
    // Only a batch's first step is clipped to the time limit, where the time left is exactly
    // what the host worked out. A later step that would come within a ten-thousandth of the
    // batch's time to it stops the batch instead (rounding in the batch's own clock is at most
    // a sixtieth of that), so that the rounding never decides how long a step is, and the steps
    // come out the same however they are batched.
    float unclipped = dt;
    if (control.stopped != 0) {
        dt = 0.0f;
    } else if (control.stepIndex == 0) {
        if (dt >= control.timeLimit) {
            dt = max(control.timeLimit, 0.0f);
            control.stopped = 2;
        }
    } else if (control.batchTime + dt >= 0.9999f * control.timeLimit) {
        dt = 0.0f;
        control.stopped = 1;
    }
    // A step that does nothing leaves the limits for the next step as they are.
    if (dt > 0.0f) {
        control.tileSweeps += tiles;
        control.lastStep = unclipped;
        atomic_store_explicit(maxSpeed, 0u, memory_order_relaxed);
        if (u.forcedStep == 0.0f) {
            control.maxOverpressure = as_type<float>(atomic_exchange_explicit(maxSpeed + 1, 0u, memory_order_relaxed));
        }
    }

    logGauges(gaugeLog, control.stepIndex, dt, state, gaugeCells, u, patchOfTile, fine, gaugeChildren, fineMask,
              childPatches, childFine, childMask, gravityTable, mask, gaugePoints);

    control.dt = dt;
    control.batchTime += dt;
    ulong clock = (ulong(control.clockLow) | (ulong(control.clockHigh) << 32))
        + ulong(max(dt, 0.0f) * 1099511627776.0f);
    control.clockLow = uint(clock);
    control.clockHigh = uint(clock >> 32);
    control.stepIndex += 1;
    control.activeSteps += dt > 0.0f ? 1 : 0;
}

// After a batch's last step: samples the gauges once more, so that the state a batch ends in is
// recorded however the steps were batched (the next batch's first sample repeats it).
kernel void sampleGauges(const device StepControl &control [[buffer(0)]],
                         const device Cell *state [[buffer(2)]],
                         device float *gaugeLog [[buffer(3)]],
                         const device uint *gaugeCells [[buffer(4)]],
                         constant SolverUniforms &u [[buffer(5)]],
                         const device int *patchOfTile [[buffer(8)]],
                         const device Cell *fine [[buffer(9)]],
                         const device uint *gaugeChildren [[buffer(10)]],
                         const device uchar *fineMask [[buffer(11)]],
                         const device int *childPatches [[buffer(12)]],
                         const device Cell *childFine [[buffer(13)]],
                         const device uchar *childMask [[buffer(14)]],
                         const device float4 *gravityTable [[buffer(15)]],
                         const device uchar *mask [[buffer(16)]],
                         const device float4 *gaugePoints [[buffer(17)]],
                         uint tid [[thread_position_in_grid]]) {
    if (tid == 0) {
        logGauges(gaugeLog, control.stepIndex, 0.0f, state, gaugeCells, u, patchOfTile, fine, gaugeChildren, fineMask,
                  childPatches, childFine, childMask, gravityTable, mask, gaugePoints);
    }
}

// Seeds the wave-speed maximum from the initial condition.
kernel void measureWaveSpeed(const device Cell *state [[buffer(0)]],
                             const device uchar *mask [[buffer(1)]],
                             device atomic_uint *maxSpeed [[buffer(2)]],
                             constant SolverUniforms &u [[buffer(3)]],
                             uint3 tid [[thread_position_in_grid]]) {
    if (tid.x >= u.nx || tid.y >= u.ny || tid.z >= u.nz) {
        return;
    }
    int index = int(tid.x + u.nx * (tid.y + u.ny * tid.z));
    if (mask[index] != 0) {
        return;
    }
    Cell c = state[index];
    float rho = max(c.rho, u.densityFloor);
    float3 velocity = float3(c.mx, c.my, c.mz) / rho;
    float pressure = max(gasPressure(rho, c.energy - 0.5f * rho * dot(velocity, velocity), u.airModel, u.gamma),
                         u.pressureFloor);
    float3 speed = fabs(velocity);
    recordWaveSpeed(maxSpeed, max(speed.x, max(speed.y, speed.z))
                                  + sqrt(gasGamma(rho, pressure, u.airModel, u.gamma) * pressure / rho));
    recordWaveSpeed(maxSpeed + 1, fabs(pressure - u.ambientPressure));
}
