// Cut cells' redistribution, appended to Solver.metal at compile time (ShaderLibrary): what a cut
// cell could not hold over a step shared up the terrain's column or along a structure's wall.

// The share of its density and pressure a cell keeps, at least, when the cut cells' redistribution
// gives it a difference: a difference that would take more (a strong expansion over a small cut
// cell beside a charge can ask a cell for more than it holds; docs/terrain.md, "A cell above a hot
// sliver") is given only in part, and the rest goes on up the column.
constant float cutKeepShare = 0.1f;

// Cell `c`'s density and pressure (the pressure from its own state, as the redistribution works it
// out), for `cutChangeKeeps`.
static inline float2 cutCellDensityPressure(Cell c, constant SolverUniforms &u) {
    float rho = max(c.rho, u.densityFloor);
    float3 momentum = float3(c.mx, c.my, c.mz);
    float kinetic = 0.5f * dot(momentum, momentum) / rho;
    return float2(rho, gasPressure(rho, c.energy - kinetic, u.airModel, u.gamma));
}

// Whether cell `c`, of density and pressure `before`, given `change` (mass, momentum) and
// `changeEnergy` for its whole volume over its air share `alpha`, keeps `cutKeepShare` of its
// density and pressure and stays above the floors, worked out as the redistribution applies a
// change.
static inline bool cutChangeKeeps(Cell c, float2 before, float4 change, float changeEnergy, float alpha,
                                  constant SolverUniforms &u) {
    float rho = c.rho + change.x / alpha;
    if (!(rho > max(u.densityFloor, cutKeepShare * before.x))) {
        return false;
    }
    float3 momentum = float3(c.mx + change.y / alpha, c.my + change.z / alpha, c.mz + change.w / alpha);
    float energy = c.energy + changeEnergy / alpha;
    float kinetic = 0.5f * dot(momentum, momentum) / rho;
    return gasPressure(rho, energy - kinetic, u.airModel, u.gamma) >= max(u.pressureFloor, cutKeepShare * before.y);
}

// The share of `change` the cut cells' redistribution gives cell `c`: all of it (1) where the cell
// keeps `cutKeepShare` of its density and pressure, as always; otherwise the most that leaves it
// that, found by bisection, so that the rest goes on up its column to cells that can take it,
// rather than draining this one and the pressure floor adding energy.
static inline float positiveCutShare(Cell c, float4 change, float4 changeEnergy, float alpha,
                                     constant SolverUniforms &u) {
    float2 before = cutCellDensityPressure(c, u);
    if (cutChangeKeeps(c, before, change, changeEnergy.z, alpha, u)) {
        return 1.0f;
    }
    if (!(before.x > u.densityFloor && before.y >= u.pressureFloor)) {
        return 1.0f;
    }
    float low = 0.0f;
    float high = 1.0f;
    for (int n = 0; n < 20; ++n) {
        float middle = 0.5f * (low + high);
        if (cutChangeKeeps(c, before, middle * change, middle * changeEnergy.z, alpha, u)) {
            low = middle;
        } else {
            high = middle;
        }
    }
    return low;
}

// After a step's sweeps, with cut cells: each cut cell's difference between its conservative
// update and the whole cell's it was given (its fuel and oxygen's too) is shared out up its
// column: the cell keeps its share alpha of it, and the rest goes to the first cell above it at
// least half full (the next cell up, for a cell itself at least half full), in a fixed order. The
// differences are then cleared. One thread a column with cut cells, its index in `columnsCut`.
// Where the air is refined, this runs after refluxing: a cell under a patch drops its own
// difference (its fine cells hold its air, and have shared out theirs), and what reaches such a
// cell goes into its fine cells, as much a volume to each. A block standing in the column stops
// what is carried up; the last cell of air below it takes it.
kernel void redistributeCutDefects(device Cell *state [[buffer(0)]],
                                   device float2 *species [[buffer(1)]],
                                   const device uint4 *cutColumns [[buffer(2)]],
                                   const device float4 *cutRecords [[buffer(3)]],
                                   constant SolverUniforms &u [[buffer(4)]],
                                   const device StepControl &control [[buffer(5)]],
                                   device float *peak [[buffer(6)]],
                                   device atomic_uint *maxSpeed [[buffer(7)]],
                                   device float4 *cutDefects [[buffer(8)]],
                                   const device uint *columnsCut [[buffer(9)]],
                                   constant uint &columnCount [[buffer(10)]],
                                   const device float4 *gravityTable [[buffer(11)]],
                                   const device uchar *mask [[buffer(12)]],
                                   const device int *patchOfTile [[buffer(13)]],
                                   device Cell *fine [[buffer(14)]],
                                   const device float4 *fineCut [[buffer(15)]],
                                   device float2 *fineSpecies [[buffer(16)]],
                                   const device uchar *fineMask [[buffer(17)]],
                                   const device float4 *fineGravityTable [[buffer(18)]],
                                   device uchar *tileFlags [[buffer(19)]],
                                   uint gid [[thread_position_in_grid]]) {
    if (!cutCells || gid >= columnCount) {
        return;
    }
    uint columnIndex = columnsCut[gid];
    uint4 column = cutColumns[columnIndex];
    bool withSpecies = carriesSpecies(u);
    if (control.dt <= 0.0f) {
        return;
    }
    int2 xy = int2(int(columnIndex % (u.nx + 1u)), int(columnIndex / (u.nx + 1u)));
    int stride = int(u.nx * u.ny);
    int base = xy.x + int(u.nx) * xy.y;
    int top = int(u.nz) - 1;
    bool refined = u.refineRatio != 0u;
    int r = int(u.refineRatio);
    int side = patchSize * r;
    // Adds `change` (mass, momentum) and `changeEnergy` (fuel, oxygen, energy), for its whole volume,
    // to the air of cell k, holding `alpha` of it: to its own state, or under a patch to each of its
    // fine cells of air. Unless `whole`, a cell of its own takes no more than leaves it positive
    // (`positiveCutShare`), and what it could not take is returned, for the cells above.
    struct Left {
        float4 change;
        float4 changeEnergy;
    };
    auto apply = [&](int k, float4 change, float4 changeEnergy, float alpha, bool whole) -> Left {
        Left left = {float4(0.0f), float4(0.0f)};
        int3 cell = int3(xy, k);
        int index = base + stride * k;
        int holder = refined ? patchAt(cell, patchOfTile, u) : -1;
        if (holder >= 0) {
            int3 tile = cell / patchSize;
            for (int n = 0; n < r * r * r; ++n) {
                int3 f = cell * r + int3(n % r, (n / r) % r, n / (r * r));
                int3 local = f - tile * side;
                uint child = uint(holder) * uint(side * side * side) + uint(local.x + side * (local.y + side * local.z));
                if ((fineMask[child] & 1) != 0) {
                    continue;
                }
                Cell c = fine[child];
                c.rho = max(c.rho + change.x / alpha, u.densityFloor);
                c.mx += change.y / alpha;
                c.my += change.z / alpha;
                c.mz += change.w / alpha;
                c.energy += changeEnergy.z / alpha;
                float3 momentum = float3(c.mx, c.my, c.mz);
                float kinetic = 0.5f * dot(momentum, momentum) / c.rho;
                float pressure = gasPressure(c.rho, c.energy - kinetic, u.airModel, u.gamma);
                if (pressure < u.pressureFloor) {
                    pressure = u.pressureFloor;
                    c.energy = gasEnergy(c.rho, pressure, u.airModel, u.gamma) + kinetic;
                }
                fine[child] = c;
                if (withSpecies) {
                    fineSpecies[child] = max(fineSpecies[child] + changeEnergy.xy / alpha, 0.0f);
                }
                float ambient = airGravity ? gravityAmbientOf(fineGravityTable, f.z, u) : u.ambientPressure;
                recordCell(maxSpeed, momentum, c.rho, pressure, u, ambient);
            }
            return left;
        }
        Cell c = state[index];
        float share = whole ? 1.0f : positiveCutShare(c, change, changeEnergy, alpha, u);
        if (share < 1.0f) {
            left.change = change - share * change;
            left.changeEnergy = changeEnergy - share * changeEnergy;
            change *= share;
            changeEnergy *= share;
        }
        c.rho += change.x / alpha;
        c.mx += change.y / alpha;
        c.my += change.z / alpha;
        c.mz += change.w / alpha;
        c.energy += changeEnergy.z / alpha;
        c.rho = max(c.rho, u.densityFloor);
        float3 momentum = float3(c.mx, c.my, c.mz);
        float kinetic = 0.5f * dot(momentum, momentum) / c.rho;
        float pressure = gasPressure(c.rho, c.energy - kinetic, u.airModel, u.gamma);
        if (pressure < u.pressureFloor) {
            pressure = u.pressureFloor;
            c.energy = gasEnergy(c.rho, pressure, u.airModel, u.gamma) + kinetic;
        }
        state[index] = c;
        if (withSpecies) {
            // A deflagration's are not held at zero: a cell above the cloud's edge can be given a
            // difference that takes what a small cell beneath gave too much of (see `sweepCell`).
            float2 given = species[index] + changeEnergy.xy / alpha;
            species[index] = u.deflagration != 0u ? given : max(given, 0.0f);
        }
        float ambient = airGravity ? gravityAmbientOf(gravityTable, k, u) : u.ambientPressure;
        peak[index] = max(peak[index], pressure - ambient);
        recordCell(maxSpeed, momentum, c.rho, pressure, u, ambient);
        // A cell changed here, perhaps in a tile asleep (the cell above a sliver), is swept next step.
        if (u.tileNx != 0) {
            wakeTilesAround(cell, tileFlags, tileWoken, u);
        }
        return left;
    };
    // What each cell above the first gets from those below it, carried up the column.
    float4 passed = float4(0.0f);
    float4 passedEnergy = float4(0.0f);
    int lastK = -1;
    float lastAlpha = 1.0f;
    int last = min(max(int(column.z), int(column.w)), top);
    for (int k = int(column.y); k <= last; ++k) {
        float alpha = cutRecordOf(int3(xy, k), cutColumns, cutRecords, u).x;
        float4 change = float4(0.0f);
        float4 changeEnergy = float4(0.0f);
        // From the first cell at least half full up, each takes what those below passed on.
        if (k >= int(column.w)) {
            change += passed;
            changeEnergy += passedEnergy;
            passed = float4(0.0f);
            passedEnergy = float4(0.0f);
        }
        if (k < int(column.z)) {
            uint record = column.x + uint(k) - column.y;
            float4 d = cutDefects[2 * record];
            float4 e = cutDefects[2 * record + 1];
            cutDefects[2 * record] = float4(0.0f);
            cutDefects[2 * record + 1] = float4(0.0f);
            if (!refined || patchAt(int3(xy, k), patchOfTile, u) < 0) {
                // Its share, and the rest for the cell that takes it.
                change += alpha * d;
                changeEnergy += alpha * e;
                passed += (1.0f - alpha) * d;
                passedEnergy += (1.0f - alpha) * e;
            }
        }
        if (mask[base + stride * k] != 0) {
            // A block: what it would take goes to the last cell of air below it, and nothing
            // passes it.
            change += passed;
            changeEnergy += passedEnergy;
            passed = float4(0.0f);
            passedEnergy = float4(0.0f);
            if (lastK >= 0 && (any(change != 0.0f) || any(changeEnergy != 0.0f))) {
                apply(lastK, change, changeEnergy, lastAlpha, true);
            }
            continue;
        }
        lastK = k;
        lastAlpha = alpha;
        if (all(change == 0.0f) && all(changeEnergy == 0.0f)) {
            continue;
        }
        Left left = apply(k, change, changeEnergy, alpha, false);
        passed += left.change;
        passedEnergy += left.changeEnergy;
    }
    // What a cell could not take goes on up, through whole cells, to the first that can; the last
    // cell of air, under a block or at the top, takes whatever is left.
    for (int k = last + 1; k <= top && (any(passed != 0.0f) || any(passedEnergy != 0.0f)); ++k) {
        if (mask[base + stride * k] != 0) {
            break;
        }
        lastK = k;
        lastAlpha = 1.0f;
        Left left = apply(k, passed, passedEnergy, 1.0f, k == top);
        passed = left.change;
        passedEnergy = left.changeEnergy;
    }
    if (lastK >= 0 && (any(passed != 0.0f) || any(passedEnergy != 0.0f))) {
        apply(lastK, passed, passedEnergy, lastAlpha, true);
    }
}

// Adds `change` (mass, momentum) and `changeEnergy` (fuel, oxygen, energy), for its whole volume, to
// the air of coarse cell `index`, holding `alpha` of it, as `redistributeCutDefects` does.
static inline void applyCutChange(device Cell *state, device float2 *species, int index, int3 cell, float4 change,
                                  float4 changeEnergy, float alpha, device float *peak, device atomic_uint *maxSpeed,
                                  device uchar *tileFlags, constant SolverUniforms &u) {
    Cell c = state[index];
    c.rho += change.x / alpha;
    c.mx += change.y / alpha;
    c.my += change.z / alpha;
    c.mz += change.w / alpha;
    c.energy += changeEnergy.z / alpha;
    c.rho = max(c.rho, u.densityFloor);
    float3 momentum = float3(c.mx, c.my, c.mz);
    float kinetic = 0.5f * dot(momentum, momentum) / c.rho;
    float pressure = gasPressure(c.rho, c.energy - kinetic, u.airModel, u.gamma);
    if (pressure < u.pressureFloor) {
        pressure = u.pressureFloor;
        c.energy = gasEnergy(c.rho, pressure, u.airModel, u.gamma) + kinetic;
    }
    state[index] = c;
    if (carriesSpecies(u)) {
        species[index] = max(species[index] + changeEnergy.xy / alpha, 0.0f);
    }
    peak[index] = max(peak[index], pressure - u.ambientPressure);
    recordCell(maxSpeed, momentum, c.rho, pressure, u, u.ambientPressure);
    if (u.tileNx != 0) {
        wakeTilesAround(cell, tileFlags, tileWoken, u);
    }
}

// After a step's sweeps, with structures' cut cells (`StructureCutGeometry`), each record's
// difference: the cell keeps its share alpha of it, and sets the rest aside (`passed`) for the cell
// that takes it (`takeStructureCut`); a cell with none to give it to (at least half air) keeps it
// all. The differences are then cleared.
kernel void keepStructureCut(device Cell *state [[buffer(0)]],
                             device float2 *species [[buffer(1)]],
                             const device uint *cells [[buffer(2)]],
                             const device float4 *records [[buffer(3)]],
                             const device int *targets [[buffer(4)]],
                             device float4 *defects [[buffer(5)]],
                             device float4 *passed [[buffer(6)]],
                             constant SolverUniforms &u [[buffer(7)]],
                             const device StepControl &control [[buffer(8)]],
                             device float *peak [[buffer(9)]],
                             device atomic_uint *maxSpeed [[buffer(10)]],
                             device uchar *tileFlags [[buffer(11)]],
                             constant uint &count [[buffer(12)]],
                             uint gid [[thread_position_in_grid]]) {
    if (!structureCut || gid >= count || control.dt <= 0.0f) {
        return;
    }
    float4 d = defects[2 * gid];
    float4 e = defects[2 * gid + 1];
    defects[2 * gid] = float4(0.0f);
    defects[2 * gid + 1] = float4(0.0f);
    float alpha = records[gid].x;
    int index = int(cells[gid]);
    int3 cell = int3(index % int(u.nx), (index / int(u.nx)) % int(u.ny), index / int(u.nx * u.ny));
    bool gives = targets[gid] >= 0;
    passed[2 * gid] = gives ? (1.0f - alpha) * d : float4(0.0f);
    passed[2 * gid + 1] = gives ? (1.0f - alpha) * e : float4(0.0f);
    float4 change = gives ? alpha * d : d;
    float4 changeEnergy = gives ? alpha * e : e;
    if (all(change == 0.0f) && all(changeEnergy == 0.0f)) {
        return;
    }
    // A cell with none to give it to is at least half air (`StructureCutGeometry` makes the others
    // solid), so keeping it all grows it by at most twice.
    applyCutChange(state, species, index, cell, change, changeEnergy, alpha, peak, maxSpeed, tileFlags, u);
}

// The second pass: each cell that takes others' differences adds what they set aside, in a fixed
// order (`starts` into `contributors`), over the air it holds.
kernel void takeStructureCut(device Cell *state [[buffer(0)]],
                             device float2 *species [[buffer(1)]],
                             const device uint *receivers [[buffer(2)]],
                             const device float *shares [[buffer(3)]],
                             const device uint *starts [[buffer(4)]],
                             const device uint *contributors [[buffer(5)]],
                             const device float4 *passed [[buffer(6)]],
                             constant SolverUniforms &u [[buffer(7)]],
                             const device StepControl &control [[buffer(8)]],
                             device float *peak [[buffer(9)]],
                             device atomic_uint *maxSpeed [[buffer(10)]],
                             device uchar *tileFlags [[buffer(11)]],
                             constant uint &count [[buffer(12)]],
                             uint gid [[thread_position_in_grid]]) {
    if (!structureCut || gid >= count || control.dt <= 0.0f) {
        return;
    }
    float4 change = float4(0.0f);
    float4 changeEnergy = float4(0.0f);
    for (uint n = starts[gid]; n < starts[gid + 1]; ++n) {
        uint record = contributors[n];
        change += passed[2 * record];
        changeEnergy += passed[2 * record + 1];
    }
    if (all(change == 0.0f) && all(changeEnergy == 0.0f)) {
        return;
    }
    int index = int(receivers[gid]);
    int3 cell = int3(index % int(u.nx), (index / int(u.nx)) % int(u.ny), index / int(u.nx * u.ny));
    applyCutChange(state, species, index, cell, change, changeEnergy, shares[gid], peak, maxSpeed, tileFlags, u);
}
