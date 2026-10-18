// Adaptive refinement of the air, appended to Solver.metal at compile time.
//
// One finer level, by a ratio r of 2 or 4, made of patches: a patch refines a block of 4 x 4 x 4
// coarse cells into (4r)^3 fine cells. (Patches smaller than the tiles of still air fit a curved
// shock more closely: a sphere cuts through many cubes, and the cubes' size sets how thick a
// shell of them must be to hold it.) Patches come from a pool of fixed size and are placed,
// every coarse step, on the tiles where the pressure jumps sharply between neighbouring cells
// (the shock), and on those within a few cells of it, so that the shock cannot leave the fine
// cells before the next regrid. Each coarse step:
//
//   1. the coarse cells around every patch are saved (the halo), as they are at the step's start;
//   2. the coarse grid is swept as usual, every cell of it, and a coarse cell beside a patch
//      records the flux it used through the face it shares with the patch;
//   3. the patches take r substeps of a coarse step / r, each three sweeps. A fine stencil
//      reaching past its patch reads the neighbouring patch, or, in unrefined air, the coarse
//      state there: limited linear in space, linear in time between the halo and the step's end;
//      a fine cell on a patch's face adds up the flux through it;
//   4. each coarse cell beside a patch has the difference between the fine fluxes through their
//      shared face and its own put right (refluxing), so that mass, momentum and energy are
//      conserved across the level's edge;
//   5. each coarse cell under a patch takes the mean of its fine cells;
//   6. the structure, if any, takes its substeps, loaded by the fine cells beside its faces, and
//      what it then changes in the coarse cells under the patches (debris trading with the air,
//      cells it uncovers) is carried into their fine cells;
//   7. the patches are placed afresh: kept where still wanted, released where not, and new ones
//      filled from the coarse state.
//
// With afterburning, the fine cells carry their own fuel and oxygen through every step as the
// coarse cells do: carried by the fine mass fluxes, burnt in each substep, refluxed across the
// level's edge and averaged back, and filled at the coarse cell's mass fractions.
//
// Fine cells inherit the solid mask of the coarse cell they lie in, and its speed where it is a
// moving solid. Peak overpressure is the
// largest a coarse cell's fine cells reach, and so is its impulse: what it had when the patch was
// placed, plus the largest impulse any of its fine cells has gathered since, each adding up its
// own over its substeps. In open air its fine cells agree; against a wall, where impulse falls
// off steeply, the cell reads the wall's value, as a coarse cell beside a wall does. Everything is
// done on the GPU, so stepping still needs no round trip to the CPU, and every sum runs in a
// fixed order, so runs repeat exactly.
//
// A second level refines the first in the same way: its patches refine blocks of 4 x 4 x 4 cells
// of the first level, and it sees the first level as the first level sees the coarse grid, its
// "parent", whose cells are then found through the first level's patches (`parentIndex`). Its
// uniforms give its parent's grid as theirs (`nx`, `dx`), so that the kernels below serve both
// levels. It takes r substeps within each substep of the first level, between that substep's
// sweeps and the next (steps 1 to 5 above, with the first level's substep as the coarse step),
// and its patches are placed only where the first level's patches cover the cells within two of
// its own (see `refineNest`), so that it never meets the coarse grid: it is properly nested.

constant int haloDepth = 2;
constant int haloSide = 8;  // patchSize + 2 haloDepth
constant uint haloCells = 512;
constant uint freePatch = 0xFFFFFFFFu;

struct TerrainUniforms {
    float2 origin;
    float spacing;
    uint columns;
    uint rows;
    uint enabled;
    uint cutSamples;
};

// The terrain's elevation at `p`: bilinear between the nodes round it, the edge carried outward,
// as `Terrain.height(at:)` computes it.
static inline float terrainHeight(float2 p, constant TerrainUniforms &t, const device float *heights) {
    float2 last = float2(float(t.columns - 1), float(t.rows - 1));
    float2 position = clamp((p - t.origin) / t.spacing, float2(0.0f), last);
    int2 low = min(int2(floor(position)), int2(int(t.columns) - 2, int(t.rows) - 2));
    float2 f = position - float2(low);
    uint base = uint(low.x) + t.columns * uint(low.y);
    float h00 = heights[base];
    float h10 = heights[base + 1];
    float h01 = heights[base + t.columns];
    float h11 = heights[base + t.columns + 1];
    float bottom = h00 + f.x * (h10 - h00);
    float top = h01 + f.x * (h11 - h01);
    return bottom + f.y * (top - bottom);
}

// The terrain's cut cells on a level of refinement (see `TerrainCutGeometry` for the coarse
// grid's): each fine cell's share of air and the apertures of its faces, by the coarse grid's
// quadrature at the fine cell's own size: `8 / r` points to an edge, the very points the coarse
// grid's 8 fall on, so that a coarse cell's share is the mean of its fine cells' (the lengths of
// air above each point add up). A share under 1e-6 counts as none, and a face beside a cell
// with none is closed, as on the coarse grid. `low` holds the share and the low faces' apertures
// (x, y, z), `high` the high faces'.
struct CutGeometry {
    float4 low;
    float4 high;
};

// The share of air above the surface at height `h` along a column from `z0`, `dx` high.
static inline float cutOpen(float h, float z0, float dx) {
    return clamp((z0 + dx - max(h, z0)) / dx, 0.0f, 1.0f);
}

// The share of air of fine cell `c` (cells of `dx`, `samples` points to an edge).
static inline float cutShareAt(int3 c, float dx, int samples, constant TerrainUniforms &t,
                               const device float *heights) {
    float2 origin = float2(c.xy) * dx;
    float z0 = float(c.z) * dx;
    float sum = 0.0f;
    for (int b = 0; b < samples; ++b) {
        for (int a = 0; a < samples; ++a) {
            float2 p = origin + (float2(float(a), float(b)) + 0.5f) / float(samples) * dx;
            sum += cutOpen(terrainHeight(p, t, heights), z0, dx);
        }
    }
    float share = sum / float(samples * samples);
    return share < 1e-6f ? 0.0f : share;
}

// The open share of the face of `c` low along `axis` (0 or 1): points along the face's line.
static inline float cutSideAperture(int3 c, uint axis, float dx, int samples, constant TerrainUniforms &t,
                                    const device float *heights) {
    float2 origin = float2(c.xy) * dx;
    float z0 = float(c.z) * dx;
    float sum = 0.0f;
    for (int a = 0; a < samples; ++a) {
        float along = (float(a) + 0.5f) / float(samples) * dx;
        float2 p = axis == 0u ? origin + float2(0.0f, along) : origin + float2(along, 0.0f);
        sum += cutOpen(terrainHeight(p, t, heights), z0, dx);
    }
    return sum / float(samples);
}

// The surface's lowest and highest over the footprint of fine cell `c`: at its corners and where its
// edges cross the terrain's node lines (a bilinear patch has its extremes there), as the coarse
// grid's `TerrainCutGeometry` finds them.
static inline float2 cutExtremes(int3 c, float dx, constant TerrainUniforms &t, const device float *heights) {
    float2 low = float2(c.xy) * dx;
    float2 high = low + dx;
    float xs[6];
    float ys[6];
    int nx = 0;
    int ny = 0;
    xs[nx++] = low.x;
    xs[nx++] = high.x;
    ys[ny++] = low.y;
    ys[ny++] = high.y;
    for (float line = ceil((low.x - t.origin.x) / t.spacing); nx < 6 && t.origin.x + line * t.spacing < high.x; line += 1.0f) {
        xs[nx++] = t.origin.x + line * t.spacing;
    }
    for (float line = ceil((low.y - t.origin.y) / t.spacing); ny < 6 && t.origin.y + line * t.spacing < high.y; line += 1.0f) {
        ys[ny++] = t.origin.y + line * t.spacing;
    }
    float2 extremes = float2(INFINITY, -INFINITY);
    for (int i = 0; i < nx; ++i) {
        for (int j = 0; j < ny; ++j) {
            float h = terrainHeight(float2(xs[i], ys[j]), t, heights);
            extremes = float2(min(extremes.x, h), max(extremes.y, h));
        }
    }
    return extremes;
}

static inline float cutHighest(int3 c, float dx, constant TerrainUniforms &t, const device float *heights) {
    return cutExtremes(c, dx, t, heights).y;
}

// Fine cell `c`'s share of air and apertures. A cell the surface does not rise into is whole, its
// faces all open (the solid cell beneath it is a wall to it as to any whole cell), as on the coarse
// grid, where such cells lie above a column's cut cells.
static inline CutGeometry cutGeometryAt(int3 c, float dx, int samples, constant TerrainUniforms &t,
                                        const device float *heights) {
    float2 extremes = cutExtremes(c, dx, t, heights);
    float highest = extremes.y;
    if (highest <= float(c.z) * dx) {
        CutGeometry whole = {float4(1.0f), float4(1.0f)};
        return whole;
    }
    if (extremes.x >= float(c.z + 1) * dx) {
        // Below the surface throughout: solid.
        CutGeometry solid = {float4(0.0f), float4(0.0f)};
        return solid;
    }
    // The footprint's heights give the share, the low and high faces along z, and the share of the
    // cells below and above.
    float2 origin = float2(c.xy) * dx;
    float z0 = float(c.z) * dx;
    float share = 0.0f;
    float below = 0.0f;
    float above = 0.0f;
    float lowZ = 0.0f;
    float highZ = 0.0f;
    for (int b = 0; b < samples; ++b) {
        for (int a = 0; a < samples; ++a) {
            float h = terrainHeight(origin + (float2(float(a), float(b)) + 0.5f) / float(samples) * dx, t, heights);
            share += cutOpen(h, z0, dx);
            below += cutOpen(h, z0 - dx, dx);
            above += cutOpen(h, z0 + dx, dx);
            lowZ += h < z0 ? 1.0f : 0.0f;
            highZ += h < z0 + dx ? 1.0f : 0.0f;
        }
    }
    float count = float(samples * samples);
    share /= count;
    below /= count;
    above /= count;
    share = share < 1e-6f ? 0.0f : share;
    below = below < 1e-6f ? 0.0f : below;
    above = above < 1e-6f ? 0.0f : above;
    CutGeometry g;
    g.low = float4(share, 0.0f, 0.0f, 0.0f);
    g.high = float4(0.0f);
    if (share == 0.0f) {
        return g;
    }
    int3 ex = int3(1, 0, 0);
    int3 ey = int3(0, 1, 0);
    bool westOpen = cutShareAt(c - ex, dx, samples, t, heights) > 0.0f;
    bool southOpen = cutShareAt(c - ey, dx, samples, t, heights) > 0.0f;
    bool eastOpen = cutShareAt(c + ex, dx, samples, t, heights) > 0.0f;
    bool northOpen = cutShareAt(c + ey, dx, samples, t, heights) > 0.0f;
    g.low.y = westOpen ? cutSideAperture(c, 0u, dx, samples, t, heights) : 0.0f;
    g.low.z = southOpen ? cutSideAperture(c, 1u, dx, samples, t, heights) : 0.0f;
    g.low.w = c.z > 0 && below > 0.0f ? lowZ / count : 0.0f;
    // A high face is its neighbour's low face: open in full beside a whole cell.
    float z0f = float(c.z) * dx;
    g.high.x = !eastOpen ? 0.0f
        : cutHighest(c + ex, dx, t, heights) <= z0f ? 1.0f
                                                    : cutSideAperture(c + ex, 0u, dx, samples, t, heights);
    g.high.y = !northOpen ? 0.0f
        : cutHighest(c + ey, dx, t, heights) <= z0f ? 1.0f
                                                    : cutSideAperture(c + ey, 1u, dx, samples, t, heights);
    g.high.z = highest <= z0f + dx ? 1.0f : (above > 0.0f ? highZ / count : 0.0f);
    return g;
}

// Whether a cell with this geometry is cut (or touches a cut face), and so takes a cut cell's update.
static inline bool cutGeometryCut(CutGeometry g) {
    return any(g.low != float4(1.0f)) || any(g.high.xyz != float3(1.0f));
}

// The wall's unit normal, out of the air into the ground, from the apertures' differences; down
// where they cancel.
static inline float3 cutGeometryNormal(CutGeometry g) {
    float3 wall = g.low.yzw - g.high.xyz;
    float size = length(wall);
    return size > 1e-6f ? wall / size : float3(0.0f, 0.0f, -1.0f);
}

// Points to an edge of a level's fine cell's quadrature: the coarse grid's (`TerrainCutGeometry
// .samples`) shared out among its cells along a coarse cell's edge (one at least).
static inline int cutSamples(constant SolverUniforms &u, constant TerrainUniforms &t) {
    return max(int(t.cutSamples) / (int(u.refineRatio) * int(max(u.parentScale, 1u))), 1);
}


// Index of the parent's cell `cell` in its state, its mask and the rest of its fields: on the
// coarse grid, the cell's own; under a level that refines another, the cell of that level's patch
// holding it, or -1 where none does.
static inline int parentIndex(int3 cell, const device int *parentPatches, constant SolverUniforms &u) {
    if (u.parentSide == 0u) {
        return cell.x + int(u.nx) * (cell.y + int(u.ny) * cell.z);
    }
    int side = int(u.parentSide);
    int3 block = cell / side;
    int patch = parentPatches[block.x + int(u.parentTileNx) * (block.y + int(u.parentTileNy) * block.z)];
    if (patch < 0) {
        return -1;
    }
    int3 local = cell - block * side;
    return patch * side * side * side + local.x + side * (local.y + side * local.z);
}

// Whether the parent's cell at `index` is solid: on the coarse grid any mark, in a level's
// patches bit 0 of its own outline; a cell no patch holds counts as solid.
static inline bool parentSolid(const device uchar *mask, int index, constant SolverUniforms &u) {
    return index < 0 || (u.parentSide == 0u ? mask[index] != 0 : (mask[index] & 1) != 0);
}

// The parent's cell `cell` (at `index` in its fields) as the terrain's cut cells see it: on the
// coarse grid by its column (`cutColumns`, `cutRecords`), under a level that refines another by
// that level's own fine geometry (`cutRecords` its `fineCut`, two float4 a cell). Its share of air
// and low faces' apertures:
static inline float4 parentCutLow(int3 cell, int index, const device uint4 *cutColumns,
                                  const device float4 *cutRecords, constant SolverUniforms &u) {
    if (u.parentSide == 0u) {
        return cutRecordOf(cell, cutColumns, cutRecords, u);
    }
    return index < 0 ? float4(0.0f) : cutRecords[2 * index];
}

// and, if it is a cut cell, where its differences are kept (two float4 from twice this in the
// parent's differences), else -1.
static inline int parentCutRecord(int3 cell, int index, const device uint4 *cutColumns,
                                  const device float4 *cutRecords, constant SolverUniforms &u) {
    if (u.parentSide == 0u) {
        uint4 column = cutColumnOf(cell, cutColumns, u);
        return cell.z >= int(column.y) && cell.z < int(column.z) ? int(column.x + uint(cell.z) - column.y) : -1;
    }
    if (index < 0) {
        return -1;
    }
    float4 low = cutRecords[2 * index];
    float4 high = cutRecords[2 * index + 1];
    return low.x > 0.0f && (any(low != float4(1.0f)) || any(high.xyz != float3(1.0f))) ? index : -1;
}

// Whether it is a rigid block (bit 1 of a level's outline).
static inline bool parentRigid(const device uchar *rigidMask, int index, constant SolverUniforms &u) {
    return index >= 0 && (u.parentSide == 0u ? rigidMask[index] != 0 : (rigidMask[index] & 2) != 0);
}

// The parent's cell at `index`, or still air where no patch holds it.
static inline Cell parentCell(const device Cell *parent, int index, constant SolverUniforms &u) {
    if (index >= 0) {
        return parent[index];
    }
    Cell still;
    still.rho = u.stillRho;
    still.mx = u.stillMx;
    still.my = u.stillMy;
    still.mz = u.stillMz;
    still.energy = u.stillEnergy;
    return still;
}

// The velocity of a solid parent cell: on the coarse grid the moving solids' (zero outside the
// region where they move), in a level's patches the speed its outline holds (`fineWall`).
static inline float3 parentWallVelocity(const device float *wallVelocity, int3 cell, int index,
                                        constant SolverUniforms &u) {
    if (u.parentSide == 0u) {
        return movingWallVelocity(wallVelocity, cell, u);
    }
    return index < 0 ? float3(0.0f)
                     : float3(wallVelocity[3 * index], wallVelocity[3 * index + 1], wallVelocity[3 * index + 2]);
}

// The time step of a level: the coarse step over its ratio and its parent's.
static inline float levelStep(const device StepControl &control, constant SolverUniforms &u) {
    if (u.ownSteps != 0u) {
        return u.refineLevel == 2u ? control.levelStep1 : control.levelStep0;
    }
    return control.dt / float(int(u.refineRatio) * int(max(u.parentScale, 1u)));
}

// The fastest wave in a cell along any axis, as `recordCell` reckons it.
static inline float levelWaveSpeed(float3 momentum, float rho, float pressure, constant SolverUniforms &u) {
    float3 speed = fabs(momentum) / rho;
    return max(speed.x, max(speed.y, speed.z)) + sqrt(gasGamma(rho, pressure, u.airModel, u.gamma) * pressure / rho);
}

static inline uint tileIndex(int3 tile, constant SolverUniforms &u) {
    return uint(tile.x) + u.refineTileNx * (uint(tile.y) + u.refineTileNy * uint(tile.z));
}

static inline int3 tileCoordinates(uint tile, constant SolverUniforms &u) {
    return int3(tile % u.refineTileNx, (tile / u.refineTileNx) % u.refineTileNy,
                tile / (u.refineTileNx * u.refineTileNy));
}

// Index of fine cell `fine` within the storage of the patch that refines `tile`.
static inline uint fineIndex(uint patch, int3 fine, int3 tile, constant SolverUniforms &u) {
    int side = patchSize * int(u.refineRatio);
    int3 local = fine - tile * side;
    return patch * uint(side * side * side) + uint(local.x + side * (local.y + side * local.z));
}

static inline Cell blend(Cell a, Cell b, float alpha) {
    Cell c;
    c.rho = a.rho + alpha * (b.rho - a.rho);
    c.mx = a.mx + alpha * (b.mx - a.mx);
    c.my = a.my + alpha * (b.my - a.my);
    c.mz = a.mz + alpha * (b.mz - a.mz);
    c.energy = a.energy + alpha * (b.energy - a.energy);
    return c;
}

// Coarse cell `cell` at `alpha` of the way through the coarse step: between its state in the
// halo of `patch`, saved at the step's start, and its state now, at the step's end. With alpha
// one, or outside the halo, just now.
static inline Cell coarseAt(int3 cell, int3 tile, uint patch, const device Cell *coarse, const device Cell *halo,
                            float alpha, constant SolverUniforms &u, const device int *parentPatches) {
    Cell now = parentCell(coarse, parentIndex(cell, parentPatches, u), u);
    int3 h = cell - (tile * patchSize - haloDepth);
    if (alpha >= 1.0f || any(h < 0) || any(h >= haloSide)) {
        return now;
    }
    Cell old = halo[patch * haloCells + uint(h.x + haloSide * (h.y + haloSide * h.z))];
    return blend(old, now, alpha);
}

static inline float cellPressureOf(Cell c, constant SolverUniforms &u) {
    float rho = max(c.rho, u.densityFloor);
    float kinetic = 0.5f * (c.mx * c.mx + c.my * c.my + c.mz * c.mz) / rho;
    return gasPressure(rho, c.energy - kinetic, u.airModel, u.gamma);
}

// A cell less gravity's background at its height (or with `add`, plus it), from a level's table.
static inline Cell gravityDeviation(Cell c, const device float4 *table, int k, float sign) {
    float4 b = gravityCellOf(table, k);
    c.rho += sign * b.x;
    c.energy += sign * b.y;
    return c;
}

// Fine cell `fine` filled from the coarse air around it: the coarse cell it lies in, plus
// minmod-limited slopes towards its fluid neighbours. The slopes' offsets sum to zero over a
// coarse cell's fine cells, so their mean is the coarse cell. Where that would leave density or
// pressure below the floors, the coarse cell alone. With gravity, the coarse cells' deviations
// from the background are filled so, and the fine cell's own background added, so that air at
// rest in it fills fine cells at rest in it.
static inline Cell prolong(int3 fine, int3 tile, uint patch, const device Cell *coarse, const device Cell *halo,
                           const device uchar *mask, float alpha, constant SolverUniforms &u,
                           const device int *parentPatches, const device float4 *parentTable,
                           const device float4 *levelTable) {
    int r = int(u.refineRatio);
    int3 cell = fine / r;
    int3 dims = int3(u.nx, u.ny, u.nz);
    bool gravity = airGravity;
    Cell c = coarseAt(cell, tile, patch, coarse, halo, alpha, u, parentPatches);
    if (gravity) {
        c = gravityDeviation(c, parentTable, cell.z, -1.0f);
    }
    float3 offset = (float3(fine - cell * r) + 0.5f) / float(r) - 0.5f;
    Cell result = c;
    for (int axis = 0; axis < 3; ++axis) {
        if (dims[axis] == 1) {
            continue;
        }
        int3 below = cell;
        int3 above = cell;
        below[axis] -= 1;
        above[axis] += 1;
        Cell lo = c;
        Cell hi = c;
        if (below[axis] >= 0 && !parentSolid(mask, parentIndex(below, parentPatches, u), u)) {
            lo = coarseAt(below, tile, patch, coarse, halo, alpha, u, parentPatches);
            if (gravity) {
                lo = gravityDeviation(lo, parentTable, below.z, -1.0f);
            }
        }
        if (above[axis] < dims[axis] && !parentSolid(mask, parentIndex(above, parentPatches, u), u)) {
            hi = coarseAt(above, tile, patch, coarse, halo, alpha, u, parentPatches);
            if (gravity) {
                hi = gravityDeviation(hi, parentTable, above.z, -1.0f);
            }
        }
        float o = offset[axis];
        result.rho += o * limitedSlope(c.rho - lo.rho, hi.rho - c.rho, 1.0f);
        result.mx += o * limitedSlope(c.mx - lo.mx, hi.mx - c.mx, 1.0f);
        result.my += o * limitedSlope(c.my - lo.my, hi.my - c.my, 1.0f);
        result.mz += o * limitedSlope(c.mz - lo.mz, hi.mz - c.mz, 1.0f);
        result.energy += o * limitedSlope(c.energy - lo.energy, hi.energy - c.energy, 1.0f);
    }
    if (gravity) {
        c = gravityDeviation(c, levelTable, fine.z, 1.0f);
        result = gravityDeviation(result, levelTable, fine.z, 1.0f);
    }
    if (result.rho <= u.densityFloor || cellPressureOf(result, u) <= u.pressureFloor) {
        return c;
    }
    return result;
}

static inline Prim primOf(Cell c, constant SolverUniforms &u) {
    Prim w;
    w.rho = max(c.rho, u.densityFloor);
    float3 velocity = float3(c.mx, c.my, c.mz) / w.rho;
    w.v = toSweep(velocity, u.axis);
    float2 gas = gasState(w.rho, c.energy - 0.5f * w.rho * dot(velocity, velocity), u.airModel, u.gamma);
    w.p = max(gas.x, u.pressureFloor);
    w.g = gas.y;
    return w;
}

// Fluid, wall or open, for fine cell `fine` reached along the sweep.
static inline int fineKind(int3 fine, int n, const device uchar *mask, constant SolverUniforms &u,
                           const device int *parentPatches) {
    uint axis = u.axis;
    if (fine[axis] < 0) {
        return ((u.boundaryFlags >> (2 * axis)) & 1u) != 0 ? kindWall : kindOpen;
    }
    if (fine[axis] >= n) {
        return ((u.boundaryFlags >> (2 * axis + 1)) & 1u) != 0 ? kindWall : kindOpen;
    }
    int3 cell = fine / int(u.refineRatio);
    return parentSolid(mask, parentIndex(cell, parentPatches, u), u) ? kindWall : kindFluid;
}

static inline void addFlux(device float *registers, uint slot, Flux f, uint axis, float dt) {
    float3 momentum = fromSweep(f.momentum, axis);
    registers[slot] += f.mass * dt;
    registers[slot + 1] += momentum.x * dt;
    registers[slot + 2] += momentum.y * dt;
    registers[slot + 3] += momentum.z * dt;
    registers[slot + 4] += f.energy * dt;
}

// Velocity of the solid in coarse cell `cell`: zero outside the region where solids move.
static inline float3 wallVelocityOf(const device float *wallVelocity, int3 cell, constant SolverUniforms &u) {
    return movingWallVelocity(wallVelocity, cell, u);
}

// Its speed along the sweep.
static inline float wallSpeedOf(const device float *wallVelocity, int3 cell, constant SolverUniforms &u) {
    return wallVelocityOf(wallVelocity, cell, u)[u.axis];
}

// What lies two fine cells either side of a patch along the sweep, for its fine sweep: filled
// before each sweep, so that the sweep itself reads only its own patch and these. A ghost is
// fluid held by a neighbouring patch, fluid in unrefined air (whose coarse cell is refluxed),
// a wall (whose speed along the sweep the ghost's x momentum then holds), or an open face of the
// domain.
enum GhostKind { ghostFine = 0, ghostCoarse = 1, ghostWall = 2, ghostOpen = 3, ghostTerrain = 4 };

// Index of a ghost: layer 0 and 1 are two and one cells below the patch along the sweep, 2 and 3
// one and two above; (a, b) are the cell's place across the sweep, along the next two axes.
static inline uint ghostIndex(uint patch, uint layer, uint a, uint b, uint side) {
    return (patch * 4u + layer) * side * side + a + side * b;
}

// Before each fine sweep: the ghosts of every patch along `u.axis`, one thread each.
kernel void refineGhosts(const device Cell *fineSrc [[buffer(0)]],
                         device Cell *ghosts [[buffer(1)]],
                         device uchar *ghostKinds [[buffer(2)]],
                         const device uchar *mask [[buffer(3)]],
                         constant SolverUniforms &u [[buffer(4)]],
                         const device int *patchOfTile [[buffer(5)]],
                         const device uint *tileOfPatch [[buffer(6)]],
                         const device uint *patchList [[buffer(7)]],
                         const device Cell *coarse [[buffer(8)]],
                         const device Cell *halo [[buffer(9)]],
                         const device float *wallVelocity [[buffer(10)]],
                         const device uchar *fineMask [[buffer(11)]],
                         const device packed_float3 *fineWall [[buffer(12)]],
                         device float *fineFlux [[buffer(13)]],
                         const device StepControl &control [[buffer(14)]],
                         const device float2 *fineSpecies [[buffer(15)]],
                         device float2 *ghostSpecies [[buffer(16)]],
                         const device float2 *coarseSpecies [[buffer(17)]],
                         const device int *parentPatches [[buffer(18)]],
                         const device float4 *parentTable [[buffer(19)]],
                         const device float4 *levelTable [[buffer(20)]],
                         const device float *terrainHeights [[buffer(21)]],
                         constant TerrainUniforms &terrain [[buffer(22)]],
                         uint gid [[thread_position_in_grid]]) {
    // A step of zero length reads no ghosts (see `fineSweepCell`), and adds nothing to the
    // registers.
    if (control.dt <= 0.0f) {
        return;
    }
    uint side = uint(patchSize) * u.refineRatio;
    uint perPatch = 4u * side * side;
    uint patch = patchList[gid / perPatch];
    uint position = gid % perPatch;
    uint layer = position / (side * side);
    uint a = position % side;
    uint b = (position / side) % side;
    uint axis = u.axis;
    int3 tile = tileCoordinates(tileOfPatch[patch], u);
    int3 local;
    local[axis] = layer < 2u ? int(layer) - 2 : int(side) + int(layer) - 2;
    local[(axis + 1) % 3] = int(a);
    local[(axis + 2) % 3] = int(b);
    int3 fine = tile * int(side) + local;
    uint index = ghostIndex(patch, layer, a, b, side);
    int3 dims = int3(u.nx, u.ny, u.nz);
    // Across the sweep, beyond the domain: no fine cell reads it.
    if (fine[(axis + 1) % 3] >= dims[(axis + 1) % 3] * int(u.refineRatio)
        || fine[(axis + 2) % 3] >= dims[(axis + 2) % 3] * int(u.refineRatio)) {
        return;
    }
    int n = dims[axis] * int(u.refineRatio);
    int kind = fineKind(fine, n, mask, u, parentPatches);
    bool inDomain = fine[axis] >= 0 && fine[axis] < n;
    // Inside the domain, a cell a neighbouring patch holds is solid or fluid by that patch's own
    // outline, whatever its coarse cell is; asking the coarse cell would make the two patches
    // disagree about the face between them, and gain or lose energy through it.
    int3 cell = fine / int(u.refineRatio);
    int3 home = cell / patchSize;
    int holder = inDomain ? patchOfTile[tileIndex(home, u)] : -1;
    if (cutCells && terrain.enabled != 0 && holder < 0 && inDomain
        && cutShareAt(fine, u.dx / float(u.refineRatio), cutSamples(u, terrain), terrain, terrainHeights) == 0.0f) {
        // Unrefined, and its fine cell here would hold no air: the terrain's, as a patch's own are.
        ghostKinds[index] = ghostTerrain;
        ghosts[index].mx = 0.0f;
        return;
    }
    if (kind != kindFluid && holder < 0) {
        ghostKinds[index] = kind == kindWall ? ghostWall : ghostOpen;
        if (kind == kindWall) {
            // A solid cell inside the domain may be moving; a reflecting face of the domain is not.
            ghosts[index].mx =
                inDomain ? parentWallVelocity(wallVelocity, cell, parentIndex(cell, parentPatches, u), u)[axis] : 0.0f;
        }
        return;
    }
    if (holder >= 0) {
        // Held by a neighbouring patch, whose own outline decides whether it is solid.
        uint there = fineIndex(uint(holder), fine, home, u);
        if ((fineMask[there] & 1) != 0) {
            // With cut cells, the terrain's solid cells are marked so, for their neighbours' mirrors.
            ghostKinds[index] = cutCells && (fineMask[there] & 16) != 0 ? ghostTerrain : ghostWall;
            ghosts[index].mx = float3(fineWall[there])[axis];
            return;
        }
        ghosts[index] = fineSrc[there];
        ghostKinds[index] = ghostFine;
        if (u.afterburnEnergy > 0.0f) {
            ghostSpecies[index] = fineSpecies[there];
        }
        return;
    }
    // How far through the step of the grid above this substep starts: s / r, or with the levels'
    // own steps s over the substeps this level takes in it.
    float alpha = u.ownSteps != 0u
        ? float(u.refineSubstep) / float(u.refineLevel == 2u ? control.levelSubsteps1 : control.levelSubsteps0)
        : u.refineAlpha;
    Cell outside = prolong(fine, tile, patch, coarse, halo, mask, alpha, u, parentPatches, parentTable,
                           levelTable);
    ghosts[index] = outside;
    ghostKinds[index] = ghostCoarse;
    if (u.afterburnEnergy > 0.0f) {
        // At the coarse cell's mass fractions, as they are at the step's end.
        int at = parentIndex(cell, parentPatches, u);
        ghostSpecies[index] = at < 0 ? float2(0.0f, u.stillOxygen) / u.stillRho * outside.rho
                                     : coarseSpecies[at] / max(coarse[at].rho, u.densityFloor) * outside.rho;
    }
    // Unrefined fluid beside a patch's face, where the fine cell inside is solid: the coarse cell
    // used a flux through that face, which refluxing must replace with what the fine level has
    // there, the wall's (the fine sweep adds the fluxes of fine cells that are fluid).
    if (layer == 1u || layer == 2u) {
        int3 inside = local;
        inside[axis] = layer == 1u ? 0 : int(side) - 1;
        uint own = patch * side * side * side + uint(inside.x + int(side) * (inside.y + int(side) * inside.z));
        // (A cut cell's face beside the terrain's solid fine cell is closed: nothing passes.)
        if ((fineMask[own] & 1) != 0 && !(cutCells && (fineMask[own] & 16) != 0)) {
            Prim w = primOf(outside, u);
            Prim wall = mirrored(w, float3(fineWall[own])[axis]);
            Flux f = layer == 1u ? riemannFlux(w, wall, u) : riemannFlux(wall, w, u);
            uint face = 2u * axis + (layer == 1u ? 0u : 1u);
            addFlux(fineFlux, registerSlot(patch, face, a, b, side), f, axis, levelStep(control, u));
        }
    }
}

// One fine cell's one-dimensional update along `u.axis`, over a coarse step / r: as `sweepCell`,
// with the patch's own outline (`fineMask`) and the speeds of its solid cells (`fineWall`).
static inline void fineSweepCell(int3 local, int3 tile, uint patch, const device Cell *fineSrc, device Cell *fineDst,
                                 const device Cell *ghosts, const device uchar *ghostKinds, const device uchar *mask,
                                 device atomic_uint *peakBits, const device StepControl &control,
                                 device atomic_uint *maxSpeed, constant SolverUniforms &u, device float *fineFlux,
                                 device float *fineImpulse, const device uchar *fineMask,
                                 const device packed_float3 *fineWall, const device float2 *speciesSrc,
                                 device float2 *speciesDst, const device float2 *ghostSpecies,
                                 device float *speciesFluxSums, const device int *boxPatches, device float *boxImpulse, const device uint *tileOfPatch,
                                 const device int *childPatches, device float *childFlux, device float *childSpeciesFlux,
                                 const device float4 *gravityTable, const device float *viscosity,
                                 const device float4 *fineCut, device float4 *fineDefects,
                                 const device float *terrainHeights, constant TerrainUniforms &terrain) {
    int r = int(u.refineRatio);
    int shift = r == 2 ? 1 : 2;
    int side = patchSize * r;
    int3 fine = tile * side + local;
    int3 dims = int3(u.nx, u.ny, u.nz);
    int3 cell = fine >> shift;
    if (any(cell >= dims)) {
        return;
    }
    // The coarse cell, whose peak overpressure this fine cell's counts towards.
    int scale = int(max(u.parentScale, 1u));
    int3 coarseDims = dims / scale;
    int3 coarseCell = cell / scale;
    int coarseIndex = coarseCell.x + coarseDims.x * (coarseCell.y + coarseDims.y * coarseCell.z);
    uint axis = u.axis;
    int n = dims[axis] << shift;
    uint a = uint(local[(axis + 1) % 3]);
    uint b = uint(local[(axis + 2) % 3]);
    int stride = axis == 0 ? 1 : (axis == 1 ? side : side * side);
    uint base = patch * uint(side * side * side);
    uint index = base + uint(local.x + side * (local.y + side * local.z));
    if ((fineMask[index] & 1) != 0) {
        return;
    }
    // A step of zero length (a batch stopped short) leaves the cell as it was, as on the coarse
    // grid: its fluxes are not worked out at all, since a ghost may then read a halo saved before
    // the structure's outline last moved (only a real step saves it), and zero times a flux that
    // is not finite would not be zero.
    if (control.dt <= 0.0f) {
        fineDst[index] = fineSrc[index];
        if (u.afterburnEnergy > 0.0f) {
            speciesDst[index] = speciesSrc[index];
        }
        return;
    }

    // The kind of the cell `offset` along the sweep, its state if fluid, and its speed along the
    // sweep if a wall; `ground` says whether a wall is the terrain's (cut cells only).
    bool ground = false;
    auto look = [&](int offset, thread Prim &w, thread float &speed) {
        speed = 0.0f;
        ground = false;
        int along = local[axis] + offset;
        if (along >= 0 && along < side) {
            int3 g = fine;
            g[axis] += offset;
            if (g[axis] >= n) {
                return ((u.boundaryFlags >> (2 * axis + 1)) & 1u) != 0 ? int(kindWall) : int(kindOpen);
            }
            if ((fineMask[index + offset * stride] & 1) != 0) {
                speed = float3(fineWall[index + offset * stride])[axis];
                ground = (fineMask[index + offset * stride] & 16) != 0;
                return int(kindWall);
            }
            w = primOf(fineSrc[index + offset * stride], u);
            return int(kindFluid);
        }
        uint layer = along < 0 ? uint(along + 2) : uint(along - side + 2);
        uint g = ghostIndex(patch, layer, a, b, uint(side));
        uchar kind = ghostKinds[g];
        if (kind == ghostTerrain) {
            ground = true;
            return int(kindWall);
        }
        if (kind == ghostWall) {
            speed = ghosts[g].mx;
            return int(kindWall);
        }
        if (kind == ghostOpen) {
            return int(kindOpen);
        }
        w = primOf(ghosts[g], u);
        return int(kindFluid);
    };

    Cell c = fineSrc[index];
    Prim w0 = primOf(c, u);
    // With gravity, the cell each state came from and -1 for a mirror, as in `sweepCell`.
    int4 from = int4(-2, -1, 1, 2);
    float4 mirror = float4(1.0f);
    Prim wP1 = w0;
    float speedP1;
    int kindP1 = look(1, wP1, speedP1);
    bool groundP1 = ground;
    if (kindP1 == kindWall) {
        wP1 = mirrored(w0, speedP1);
        from.z = 0;
        mirror.z = -1.0f;
    } else if (kindP1 == kindOpen) {
        wP1 = farFieldFaces(u) ? farFieldGhost(w0, 1.0f, u) : w0;
        from.z = 0;
    }
    Prim wM1 = w0;
    float speedM1;
    int kindM1 = look(-1, wM1, speedM1);
    bool groundM1 = ground;
    bool groundP2 = false;
    bool groundM2 = false;
    if (kindM1 == kindWall) {
        wM1 = mirrored(w0, speedM1);
        from.y = 0;
        mirror.y = -1.0f;
    } else if (kindM1 == kindOpen) {
        wM1 = farFieldFaces(u) ? farFieldGhost(w0, -1.0f, u) : w0;
        from.y = 0;
    }
    Prim wP2 = wP1;
    if (kindP1 == kindWall) {
        wP2 = mirrored(wM1, speedP1);
        from.w = from.y;
        mirror.w = -mirror.y;
    } else if (kindP1 == kindFluid) {
        Prim w = wP1;
        float speed;
        int kind = look(2, w, speed);
        groundP2 = kind == kindWall && ground;
        if (kind == kindFluid) {
            wP2 = w;
        } else if (kind == kindWall) {
            wP2 = mirrored(wP1, speed);
            from.w = 1;
            mirror.w = -1.0f;
        } else {
            from.w = 1;
        }
    } else {
        from.w = from.z;
    }
    Prim wM2 = wM1;
    if (kindM1 == kindWall) {
        wM2 = mirrored(wP1, speedM1);
        from.x = from.z;
        mirror.x = -mirror.z;
    } else if (kindM1 == kindFluid) {
        Prim w = wM1;
        float speed;
        int kind = look(-2, w, speed);
        groundM2 = kind == kindWall && ground;
        if (kind == kindFluid) {
            wM2 = w;
        } else if (kind == kindWall) {
            wM2 = mirrored(wM1, speed);
            from.x = -1;
            mirror.x = -1.0f;
        } else {
            from.x = -1;
        }
    } else {
        from.x = from.y;
    }

    // The terrain's cut cells, as on the coarse grid (see `sweepCell`): a ghost beside a cut cell
    // mirrors it about its wall's normal; one two away, the cell beside it about that cell's.
    CutGeometry here = {float4(1.0f), float4(1.0f)};
    bool cut = false;
    float dxFineCut = u.dx / float(r);
    if (cutCells) {
        here.low = fineCut[2 * index];
        here.high = fineCut[2 * index + 1];
        cut = cutGeometryCut(here);
        // The geometry of the cell `offset` along the sweep: this patch's, or worked out afresh.
        auto geometryAt = [&](int offset) {
            int along = local[axis] + offset;
            if (along >= 0 && along < side) {
                CutGeometry g;
                g.low = fineCut[2 * (index + offset * stride)];
                g.high = fineCut[2 * (index + offset * stride) + 1];
                return g;
            }
            int3 at = fine;
            at[axis] += offset;
            return cutGeometryAt(at, dxFineCut, cutSamples(u, terrain), terrain, terrainHeights);
        };
        if (kindP1 == kindWall && groundP1 && cut) {
            float3 normal = toSweep(cutGeometryNormal(here), axis);
            wP1 = mirroredAbout(w0, normal);
            wP2 = mirroredAbout(wM1, normal);
        }
        if (kindM1 == kindWall && groundM1 && cut) {
            float3 normal = toSweep(cutGeometryNormal(here), axis);
            wM1 = mirroredAbout(w0, normal);
            wM2 = mirroredAbout(wP1, normal);
        }
        if (kindP1 == kindFluid && groundP2) {
            CutGeometry next = geometryAt(1);
            if (cutGeometryCut(next)) {
                wP2 = mirroredAbout(wP1, toSweep(cutGeometryNormal(next), axis));
            }
        }
        if (kindM1 == kindFluid && groundM2) {
            CutGeometry previous = geometryAt(-1);
            if (cutGeometryCut(previous)) {
                wM2 = mirroredAbout(wM1, toSweep(cutGeometryNormal(previous), axis));
            }
        }
    }

    float dt = levelStep(control, u);
    float lambda = dt / (u.dx / float(r));
    Flux fluxLow;
    Flux fluxHigh;
    bool gravityHere = airGravity && axis == 2u;
    if (gravityHere) {
        stencilFluxesGravity(wM2, wM1, w0, wP1, wP2, from, mirror, fine.z, gravityTable, lambda, dt, u, fluxLow,
                             fluxHigh);
    } else {
        stencilFluxes(wM2, wM1, w0, wP1, wP2, lambda, u, fluxLow, fluxHigh);
    }
    // Sub-grid mixing's fluxes, each fine cell taking its coarse cell's eddy viscosity scaled to
    // its own size as an inertial range's is, (dx_fine / dx_coarse)^(4/3).
    float carrierLow = 0.0f;
    float carrierHigh = 0.0f;
    if (airMixing) {
        int levels = r * scale;
        float shrink = pow(1.0f / float(levels), 4.0f / 3.0f);
        auto nuAt = [&](int offset) {
            int3 g = fine;
            g[axis] += offset;
            int3 at = clamp(g / levels, int3(0), coarseDims - 1);
            return shrink * viscosity[at.x + coarseDims.x * (at.y + coarseDims.y * at.z)];
        };
        float dxFine = u.dx / float(r);
        float nu0 = nuAt(0);
        if (kindM1 == kindFluid) {
            MixingFace face = mixingFace(wM1, w0, nuAt(-1), nu0, dxFine, dt, u);
            fluxLow = sumOf(fluxLow, face.flux);
            carrierLow = face.carrier;
        }
        if (kindP1 == kindFluid) {
            MixingFace face = mixingFace(w0, wP1, nu0, nuAt(1), dxFine, dt, u);
            fluxHigh = sumOf(fluxHigh, face.flux);
            carrierHigh = face.carrier;
        }
    }

    // Experimental moving boxes: finest-level tractions and impermeable moving-wall work, one
    // scalar for each face as on the coarse grid.
    if (u.experimentalBox != 0) {
        int3 global = tile * side + local;
        float dx = u.dx / float(r);
        for (int direction = -1; direction <= 1; direction += 2) {
            int3 across = global; across[u.axis] += direction;
            if (any(across < 0) || any(across >= int3(u.nx,u.ny,u.nz) * r)) continue;
            int holder = patchAt(across/r,boxPatches,u);
            if (holder < 0) continue;
            uint there = fineIndex(uint(holder),across,tileCoordinates(tileOfPatch[holder],u),u);
            if ((fineMask[there] & 8u) == 0) continue;
            Flux f = direction < 0 ? fluxLow : fluxHigh;
            float speed = float3(fineWall[there])[u.axis];
            float traction = f.momentum.x-f.mass*speed;
            f.mass = 0.0f; f.momentum = float3(traction,0.0f,0.0f); f.energy = traction*speed;
            if (direction < 0) fluxLow = f; else fluxHigh = f;
            boxImpulse[6*index+2*u.axis+(direction < 0 ? 0 : 1)] +=
                float(direction) * (traction-u.ambientPressure) * dt * dx * dx;
        }
    }

    // Where a finer level lies beneath this one: a cell of this level beside a patch of that
    // level records the flux it used through the face they share, as an unrefined coarse cell
    // does (see `sweepCell`), for that level's fluxes to replace.
    int childSpecies = -1;
    int childRegister = -1;
    bool childLow = false;
    if (u.childTileNx != 0u) {
        int i = fine[axis];
        int edge = i % patchSize;
        bool lowEdge = edge == 0 && i > 0;
        bool highEdge = edge == patchSize - 1 && i < n - 1;
        auto childAt = [&](int3 at) {
            int3 block = at / patchSize;
            return childPatches[block.x + int(u.childTileNx) * (block.y + int(u.childTileNy) * block.z)];
        };
        if ((lowEdge || highEdge) && childAt(fine) < 0) {
            int3 across = fine;
            across[axis] += lowEdge ? -1 : 1;
            int child = childAt(across);
            if (child >= 0) {
                int3 inPatch = fine % patchSize;
                uint face = 2u * axis + (lowEdge ? 1u : 0u);
                uint ca = uint(inPatch[(axis + 1) % 3]);
                uint cb = uint(inPatch[(axis + 2) % 3]);
                childRegister = int(registerSlot(uint(child), face, ca, cb, uint(patchSize)));
                childSpecies = int(speciesSlot(uint(child), face, ca, cb, uint(patchSize)));
                childLow = lowEdge;
            }
        }
    }

    // A cut cell's update (see `cutCellUpdate`), and its faces' apertures for what it records.
    Flux defect = {0.0f, float3(0.0f), 0.0f};
    Flux cutLow = fluxLow;
    Flux cutHigh = fluxHigh;
    float apertureLow = 1.0f;
    float apertureHigh = 1.0f;
    if (cutCells && cut) {
        apertureLow = here.low[1 + axis];
        apertureHigh = here.high[axis];
        CutUpdate update = cutCellUpdate(w0, fluxLow, fluxHigh, apertureLow, apertureHigh, here.low.x,
                                         toSweep(cutGeometryNormal(here), axis), gravityHere, gravityTable, fine.z,
                                         lambda, dt, u);
        cutLow = update.low;
        cutHigh = update.high;
        defect = update.defect;
    }
    if (childRegister >= 0) {
        // Through a cut cell's face, the face's own flux times its aperture, as the level beneath
        // records its own.
        Flux through = childLow ? fluxLow : fluxHigh;
        float aperture = childLow ? apertureLow : apertureHigh;
        if (aperture != 1.0f) {
            through.mass *= aperture;
            through.momentum *= aperture;
            through.energy *= aperture;
        }
        storeFlux(childFlux, uint(childRegister), through, axis, dt);
    }

    // A fine cell on the patch's face, beside unrefined fluid, adds up the flux through it (times
    // the face's aperture, on cut cells).
    if (local[axis] == 0 && ghostKinds[ghostIndex(patch, 1u, a, b, uint(side))] == ghostCoarse) {
        Flux through = fluxLow;
        if (apertureLow != 1.0f) {
            through.mass *= apertureLow;
            through.momentum *= apertureLow;
            through.energy *= apertureLow;
        }
        addFlux(fineFlux, registerSlot(patch, 2u * axis, a, b, uint(side)), through, axis, dt);
    }
    if (local[axis] == side - 1 && ghostKinds[ghostIndex(patch, 2u, a, b, uint(side))] == ghostCoarse) {
        Flux through = fluxHigh;
        if (apertureHigh != 1.0f) {
            through.mass *= apertureHigh;
            through.momentum *= apertureHigh;
            through.energy *= apertureHigh;
        }
        addFlux(fineFlux, registerSlot(patch, 2u * axis + 1u, a, b, uint(side)), through, axis, dt);
    }

    float3 momentum = toSweep(float3(c.mx, c.my, c.mz), axis);
    float rho = c.rho - lambda * (fluxHigh.mass - fluxLow.mass);
    momentum -= lambda * (fluxHigh.momentum - fluxLow.momentum);
    float energy = c.energy - lambda * (fluxHigh.energy - fluxLow.energy);
    if (gravityHere) {
        gravitySources(momentum, energy, w0.rho, fluxLow, fluxHigh, fine.z, gravityTable, dt, u);
    }

    // Fuel and oxygen, as in `sweepCell`: at the mass fraction of the cell they leave, burnt
    // after the substep's final sweep.
    if (u.afterburnEnergy > 0.0f) {
        float2 own = speciesSrc[index];
        float2 fraction = own / max(c.rho, u.densityFloor);
        auto speciesAt = [&](int offset, int kind, Prim w) {
            if (kind == kindOpen && farFieldFaces(u)) {
                // Beyond a far-field face, still air: its oxygen and no products.
                return float2(0.0f, u.stillOxygen / u.stillRho);
            }
            if (kind != kindFluid) {
                return fraction;
            }
            int along = local[axis] + offset;
            if (along >= 0 && along < side) {
                return speciesSrc[index + offset * stride] / w.rho;
            }
            uint layer = along < 0 ? uint(along + 2) : uint(along - side + 2);
            return ghostSpecies[ghostIndex(patch, layer, a, b, uint(side))] / w.rho;
        };
        float2 inflow = speciesFlux(fluxLow.mass, speciesAt(-1, kindM1, wM1), fraction);
        float2 outflow = speciesFlux(fluxHigh.mass, fraction, speciesAt(1, kindP1, wP1));
        if (airMixing) {
            // Sub-grid mixing carries the species down their gradients in mass fraction.
            inflow -= carrierLow * (fraction - speciesAt(-1, kindM1, wM1));
            outflow -= carrierHigh * (speciesAt(1, kindP1, wP1) - fraction);
        }
        if (local[axis] == 0 && ghostKinds[ghostIndex(patch, 1u, a, b, uint(side))] == ghostCoarse) {
            uint slot = speciesSlot(patch, 2u * axis, a, b, uint(side));
            speciesFluxSums[slot] += apertureLow * inflow.x * dt;
            speciesFluxSums[slot + 1] += apertureLow * inflow.y * dt;
        }
        if (local[axis] == side - 1 && ghostKinds[ghostIndex(patch, 2u, a, b, uint(side))] == ghostCoarse) {
            uint slot = speciesSlot(patch, 2u * axis + 1u, a, b, uint(side));
            speciesFluxSums[slot] += apertureHigh * outflow.x * dt;
            speciesFluxSums[slot + 1] += apertureHigh * outflow.y * dt;
        }
        if (cutCells && cut) {
            // The species' difference too, at the conservative mass fluxes, with the mixing's carrying
            // through each face's open part, as the cell beyond it takes them.
            float2 cutIn = speciesFlux(cutLow.mass, speciesAt(-1, kindM1, wM1), fraction);
            float2 cutOut = speciesFlux(cutHigh.mass, fraction, speciesAt(1, kindP1, wP1));
            if (airMixing) {
                cutIn -= apertureLow * carrierLow * (fraction - speciesAt(-1, kindM1, wM1));
                cutOut -= apertureHigh * carrierHigh * (speciesAt(1, kindP1, wP1) - fraction);
            }
            float2 kept = -lambda * ((cutOut - cutIn) - here.low.x * (outflow - inflow));
            float4 held = fineDefects[2 * index + 1];
            fineDefects[2 * index + 1] = float4(held.xy + kept, held.zw);
        }
        if (childSpecies >= 0) {
            float2 through = (childLow ? inflow : outflow) * ((childLow ? apertureLow : apertureHigh) * dt);
            childSpeciesFlux[childSpecies] = through.x;
            childSpeciesFlux[childSpecies + 1] = through.y;
        }
        float2 species = max(own - lambda * (outflow - inflow), 0.0f);
        if (u.finalSweep != 0) {
            float fuel = afterburntHere(species, rho, momentum, energy, dt, u);
            species.x -= fuel;
            species.y -= fuel * u.oxygenPerFuel;
            energy += fuel * u.afterburnEnergy;
        }
        speciesDst[index] = species;
    }

    if (cutCells && cut) {
        float4 held = fineDefects[2 * index];
        float4 heldEnergy = fineDefects[2 * index + 1];
        fineDefects[2 * index] = float4(held.x + defect.mass, held.yzw + fromSweep(defect.momentum, axis));
        fineDefects[2 * index + 1] = float4(heldEnergy.xy, heldEnergy.z + defect.energy, heldEnergy.w);
    }
    rho = max(rho, u.densityFloor);
    float kinetic = 0.5f * dot(momentum, momentum) / rho;
    float pressure = gasPressure(rho, energy - kinetic, u.airModel, u.gamma);
    if (pressure < u.pressureFloor) {
        pressure = u.pressureFloor;
        energy = gasEnergy(rho, pressure, u.airModel, u.gamma) + kinetic;
    }
    float3 worldMomentum = fromSweep(momentum, axis);
    Cell result;
    result.rho = rho;
    result.mx = worldMomentum.x;
    result.my = worldMomentum.y;
    result.mz = worldMomentum.z;
    result.energy = energy;
    fineDst[index] = result;

    if (u.finalSweep != 0) {
        // Under gravity, against the ambient pressure at the fine cell's height.
        float ambient = airGravity ? gravityAmbientOf(gravityTable, fine.z, u) : u.ambientPressure;
        recordCell(maxSpeed, momentum, rho, pressure, u, ambient);
        if (u.ownSteps != 0u) {
            // This level's own fastest wave, which sets its substeps in the next step.
            recordWaveSpeed(maxSpeed + 1u + u.refineLevel, levelWaveSpeed(momentum, rho, pressure, u));
        }
        float overpressure = pressure - ambient;
        // On cut cells, only a cell at least half air counts for the peaks and the impulse, as on
        // the coarse grid where they are read at the first such cell: a sliver's state is its share
        // of what it is given.
        if (overpressure > 0.0f && (!cutCells || here.low.x >= 0.5f)) {
            // Positive floats order like their bit patterns.
            atomic_fetch_max_explicit(&peakBits[coarseIndex], as_type<uint>(overpressure), memory_order_relaxed);
            fineImpulse[index] += overpressure * dt;
        }
    }
}

kernel void refineSweep(const device Cell *fineSrc [[buffer(0)]],
                        device Cell *fineDst [[buffer(1)]],
                        const device uchar *mask [[buffer(2)]],
                        device atomic_uint *peakBits [[buffer(3)]],
                        const device StepControl &control [[buffer(4)]],
                        device atomic_uint *maxSpeed [[buffer(5)]],
                        constant SolverUniforms &u [[buffer(6)]],
                        const device Cell *ghosts [[buffer(7)]],
                        const device uchar *ghostKinds [[buffer(8)]],
                        const device uint *tileOfPatch [[buffer(9)]],
                        const device uint *patchList [[buffer(10)]],
                        device float *fineFlux [[buffer(12)]],
                        device float *fineImpulse [[buffer(13)]],
                        const device uchar *fineMask [[buffer(14)]],
                        const device packed_float3 *fineWall [[buffer(15)]],
                        const device float2 *speciesSrc [[buffer(16)]],
                        device float2 *speciesDst [[buffer(17)]],
                        const device float2 *ghostSpecies [[buffer(18)]],
                        device float *speciesFluxSums [[buffer(19)]],
                        const device int *boxPatches [[buffer(20)]],
                        device float *boxImpulse [[buffer(21)]],
                        const device int *childPatches [[buffer(22)]],
                        device float *childFlux [[buffer(23)]],
                        device float *childSpeciesFlux [[buffer(24)]],
                        const device float4 *gravityTable [[buffer(25)]],
                        const device float *viscosity [[buffer(26)]],
                        const device float4 *fineCut [[buffer(27)]],
                        device float4 *fineDefects [[buffer(28)]],
                        const device float *terrainHeights [[buffer(29)]],
                        constant TerrainUniforms &terrain [[buffer(30)]],
                        uint3 group [[threadgroup_position_in_grid]],
                        uint3 local [[thread_position_in_threadgroup]],
                        uint3 groupSize [[threads_per_threadgroup]]) {
    // Blocks of 8 x 8 x 8 fine cells, (r / 2)^3 per patch, one per threadgroup.
    uint across = u.refineRatio / 2u;
    uint blocks = across * across * across;
    uint patch = patchList[group.x / blocks];
    uint block = group.x % blocks;
    int3 tile = tileCoordinates(tileOfPatch[patch], u);
    int3 origin = int3(block % across, (block / across) % across, block / (across * across)) * 8;
    for (uint z = local.z; z < 8u; z += groupSize.z) {
        fineSweepCell(origin + int3(local.x, local.y, z), tile, patch, fineSrc, fineDst, ghosts, ghostKinds, mask,
                      peakBits, control, maxSpeed, u, fineFlux, fineImpulse, fineMask, fineWall, speciesSrc,
                      speciesDst, ghostSpecies, speciesFluxSums, boxPatches, boxImpulse, tileOfPatch, childPatches,
                      childFlux, childSpeciesFlux, gravityTable, viscosity, fineCut, fineDefects, terrainHeights,
                      terrain);
    }
}

// With the terrain's cut cells, after each substep's final sweep: every fine cut cell's
// difference (see `redistributeCutDefects` for the coarse grid's) is shared out up its fine column,
// the cell keeping its share alpha and the rest going to the first cell above at least half air,
// through the patches stacked above it. What reaches the top of a stack still unplaced goes to the
// coarse cell above it (`refineCutPassUp`). One thread a fine column of each patch with cut cells
// that has none beneath it, dispatched as the ghosts are (four of their layers to a patch's one).
// With a level beneath this one, this runs after that level's refluxing and restriction: a cell it
// covers drops its own difference (its fine cells hold its air), and what reaches such a cell is
// added to it, for that level's sync to carry down.
kernel void refineRedistributeCut(device Cell *fine [[buffer(0)]],
                                  device float2 *fineSpecies [[buffer(1)]],
                                  const device float4 *fineCut [[buffer(2)]],
                                  device float4 *fineDefects [[buffer(3)]],
                                  constant SolverUniforms &u [[buffer(4)]],
                                  const device int *patchOfTile [[buffer(5)]],
                                  const device uint *tileOfPatch [[buffer(6)]],
                                  const device uint *patchList [[buffer(7)]],
                                  const device uint *patchCut [[buffer(8)]],
                                  device float4 *passedUp [[buffer(9)]],
                                  const device StepControl &control [[buffer(10)]],
                                  const device uchar *mask [[buffer(11)]],
                                  const device uchar *fineMask [[buffer(12)]],
                                  device atomic_uint *maxSpeed [[buffer(13)]],
                                  const device float4 *gravityTable [[buffer(14)]],
                                  const device int *parentPatches [[buffer(15)]],
                                  const device int *childPatches [[buffer(16)]],
                                  uint gid [[thread_position_in_grid]]) {
    if (!cutCells || control.dt <= 0.0f) {
        return;
    }
    int r = int(u.refineRatio);
    // Whether a patch of the level beneath holds fine cell `f`.
    auto covered = [&](int3 f) {
        if (u.childTileNx == 0u) {
            return false;
        }
        int3 block = f / patchSize;
        return childPatches[block.x + int(u.childTileNx) * (block.y + int(u.childTileNy) * block.z)] >= 0;
    };
    int side = patchSize * r;
    uint perPatch = 4u * uint(side * side);
    uint position = gid % perPatch;
    if (position >= uint(side * side)) {
        return;
    }
    uint patch = patchList[gid / perPatch];
    if (patchCut[patch] == 0u) {
        return;
    }
    int3 tile = tileCoordinates(tileOfPatch[patch], u);
    if (tile.z > 0) {
        int below = patchOfTile[tileIndex(tile - int3(0, 0, 1), u)];
        if (below >= 0 && patchCut[below] != 0u) {
            return;
        }
    }
    int a = int(position) % side;
    int b = int(position) / side;
    int3 dims = int3(u.nx, u.ny, u.nz);
    bool withSpecies = u.afterburnEnergy > 0.0f;
    float4 passed = float4(0.0f);
    float4 passedEnergy = float4(0.0f);
    bool reached = false;
    int last = -1;
    float lastShare = 1.0f;
    int lastZ = 0;
    // Adds `change` (mass, momentum) and `changeEnergy` (fuel, oxygen, energy) for its whole
    // volume to fine cell `index`, holding `share` of air.
    auto apply = [&](int index, float4 change, float4 changeEnergy, float share, int z) {
        Cell c = fine[index];
        c.rho += change.x / share;
        c.mx += change.y / share;
        c.my += change.z / share;
        c.mz += change.w / share;
        c.energy += changeEnergy.z / share;
        c.rho = max(c.rho, u.densityFloor);
        float3 momentum = float3(c.mx, c.my, c.mz);
        float kinetic = 0.5f * dot(momentum, momentum) / c.rho;
        float pressure = gasPressure(c.rho, c.energy - kinetic, u.airModel, u.gamma);
        if (pressure < u.pressureFloor) {
            pressure = u.pressureFloor;
            c.energy = gasEnergy(c.rho, pressure, u.airModel, u.gamma) + kinetic;
        }
        fine[index] = c;
        if (withSpecies) {
            fineSpecies[index] = max(fineSpecies[index] + changeEnergy.xy / share, 0.0f);
        }
        float ambient = airGravity ? gravityAmbientOf(gravityTable, z, u) : u.ambientPressure;
        recordCell(maxSpeed, momentum, c.rho, pressure, u, ambient);
    };
    // What a column carries up and cannot pass on, stopped by a block above the terrain, goes to
    // its last cell of air, taken as at least half air. That cell may be a sliver between the
    // terrain and a building's base, a twentieth air, where the column's whole carry would change
    // its density twentyfold and could take it below nothing. Through a district on 8 m cells
    // refined twice, with the second level's pool full, an isolated patch's sliver did, and the
    // run broke. What it is not given (at most half of what is carried, and only there) is lost.
    auto blockedShare = [](float share) { return max(share, 0.5f); };
    uint current = patch;
    int3 at = tile;
    bool more = true;
    while (more) {
        for (int k = 0; k < side; ++k) {
            int3 f = at * side + int3(a, b, k);
            if (any(f / r >= dims)) {
                break;
            }
            int index = int(fineIndex(current, f, at, u));
            if ((fineMask[index] & 1) != 0) {
                // Solid: the terrain's beneath the air, or a block above it, which what is still
                // carried up cannot pass; the last cell of air takes it (`blockedShare`).
                if (last >= 0 && (any(passed != 0.0f) || any(passedEnergy != 0.0f))) {
                    apply(last, passed, passedEnergy, blockedShare(lastShare), lastZ);
                    passed = float4(0.0f);
                    passedEnergy = float4(0.0f);
                }
                continue;
            }
            CutGeometry g = {fineCut[2 * index], fineCut[2 * index + 1]};
            float share = g.low.x;
            reached = reached || share >= 0.5f;
            float4 change = float4(0.0f);
            float4 changeEnergy = float4(0.0f);
            if (reached) {
                change += passed;
                changeEnergy += passedEnergy;
                passed = float4(0.0f);
                passedEnergy = float4(0.0f);
            }
            if (cutGeometryCut(g)) {
                float4 d = fineDefects[2 * index];
                float4 e = fineDefects[2 * index + 1];
                fineDefects[2 * index] = float4(0.0f);
                fineDefects[2 * index + 1] = float4(0.0f);
                if (!covered(f)) {
                    change += share * d;
                    changeEnergy += share * e;
                    passed += (1.0f - share) * d;
                    passedEnergy += (1.0f - share) * e;
                }
            }
            if (any(change != 0.0f) || any(changeEnergy != 0.0f)) {
                apply(index, change, changeEnergy, share, f.z);
            }
            last = index;
            lastShare = share;
            lastZ = f.z;
        }
        bool carrying = any(passed != 0.0f) || any(passedEnergy != 0.0f);
        int3 up = at + int3(0, 0, 1);
        int holder = up.z < int(u.refineTileNz) ? patchOfTile[tileIndex(up, u)] : -1;
        if (holder >= 0 && (patchCut[holder] != 0u || carrying)) {
            current = uint(holder);
            at = up;
        } else {
            more = false;
        }
    }
    if (any(passed != 0.0f) || any(passedEnergy != 0.0f)) {
        // To the coarse cell above the stack, if air; else the last fine cell of air keeps it.
        int3 above = int3((at.xy * side + int2(a, b)) / r, (at.z + 1) * patchSize);
        if (above.z < dims.z && !parentSolid(mask, parentIndex(above, parentPatches, u), u)) {
            uint slot = 2u * (current * uint(side * side) + position);
            passedUp[slot] += passed;
            passedUp[slot + 1] += passedEnergy;
        } else if (last >= 0) {
            apply(last, passed, passedEnergy, blockedShare(lastShare), lastZ);
        }
    }
}

// After the substeps, with the terrain's cut cells: what each stack of patches passed up out of
// its top goes to the coarse cell above, a cut cell's difference or straight into a whole one, its
// r^2 fine columns added in a fixed order. One thread a coarse column of each patch, dispatched as
// the restriction is (the first 16 of a patch's 64).
kernel void refineCutPassUp(device Cell *coarse [[buffer(0)]],
                            device float2 *coarseSpecies [[buffer(1)]],
                            const device uint4 *cutColumns [[buffer(2)]],
                            device float4 *cutDefects [[buffer(3)]],
                            constant SolverUniforms &u [[buffer(4)]],
                            const device uint *tileOfPatch [[buffer(5)]],
                            const device uint *patchList [[buffer(6)]],
                            device float4 *passedUp [[buffer(7)]],
                            const device StepControl &control [[buffer(8)]],
                            const device int *parentPatches [[buffer(9)]],
                            const device float4 *cutRecords [[buffer(10)]],
                            uint gid [[thread_position_in_grid]]) {
    if (!cutCells || control.dt <= 0.0f) {
        return;
    }
    uint perPatch = uint(patchSize * patchSize * patchSize);
    uint position = gid % perPatch;
    if (position >= uint(patchSize * patchSize)) {
        return;
    }
    uint patch = patchList[gid / perPatch];
    int3 tile = tileCoordinates(tileOfPatch[patch], u);
    int r = int(u.refineRatio);
    int side = patchSize * r;
    int2 column = int2(int(position) % patchSize, int(position) / patchSize);
    float4 sum = float4(0.0f);
    float4 sumEnergy = float4(0.0f);
    for (int fb = 0; fb < r; ++fb) {
        for (int fa = 0; fa < r; ++fa) {
            uint slot = 2u * (patch * uint(side * side) + uint(column.x * r + fa + side * (column.y * r + fb)));
            sum += passedUp[slot];
            sumEnergy += passedUp[slot + 1];
            passedUp[slot] = float4(0.0f);
            passedUp[slot + 1] = float4(0.0f);
        }
    }
    if (all(sum == 0.0f) && all(sumEnergy == 0.0f)) {
        return;
    }
    int3 cell = int3(tile.xy * patchSize + column, (tile.z + 1) * patchSize);
    if (any(cell >= int3(u.nx, u.ny, u.nz))) {
        return;
    }
    // A fine cell's volume over the coarse cell's.
    float scale = 1.0f / float(r * r * r);
    sum *= scale;
    sumEnergy *= scale;
    int index = parentIndex(cell, parentPatches, u);
    if (index < 0) {
        return;
    }
    int record = parentCutRecord(cell, index, cutColumns, cutRecords, u);
    if (record >= 0) {
        cutDefects[2 * record] += sum;
        cutDefects[2 * record + 1] += float4(sumEnergy.xyz, 0.0f);
        return;
    }
    Cell c = coarse[index];
    c.rho = max(c.rho + sum.x, u.densityFloor);
    c.mx += sum.y;
    c.my += sum.z;
    c.mz += sum.w;
    c.energy += sumEnergy.z;
    float kinetic = 0.5f * (c.mx * c.mx + c.my * c.my + c.mz * c.mz) / c.rho;
    if (gasPressure(c.rho, c.energy - kinetic, u.airModel, u.gamma) < u.pressureFloor) {
        c.energy = gasEnergy(c.rho, u.pressureFloor, u.airModel, u.gamma) + kinetic;
    }
    coarse[index] = c;
    if (u.afterburnEnergy > 0.0f) {
        coarseSpecies[index] = max(coarseSpecies[index] + sumEnergy.xy, 0.0f);
    }
}

// Step 1: the coarse cells around each patch, as they are at the start of the step.
kernel void refineSaveHalo(const device Cell *coarse [[buffer(0)]],
                           device Cell *halo [[buffer(1)]],
                           constant SolverUniforms &u [[buffer(2)]],
                           const device uint *tileOfPatch [[buffer(3)]],
                           const device uint *patchList [[buffer(4)]],
                           const device StepControl &control [[buffer(5)]],
                           const device int *parentPatches [[buffer(6)]],
                           uint gid [[thread_position_in_grid]]) {
    if (control.dt <= 0.0f) {
        return;
    }
    uint h = gid % haloCells;
    uint patch = patchList[gid / haloCells];
    int3 tile = tileCoordinates(tileOfPatch[patch], u);
    int3 cell = tile * patchSize - haloDepth + int3(h % haloSide, (h / haloSide) % haloSide, h / (haloSide * haloSide));
    if (any(cell < 0) || any(cell >= int3(u.nx, u.ny, u.nz))) {
        return;
    }
    halo[patch * haloCells + h] = parentCell(coarse, parentIndex(cell, parentPatches, u), u);
}

// Step 4, along `u.axis`: puts right each unrefined coarse cell beside a patch for the difference
// between the fine fluxes through their shared face (added up over the substeps) and the flux it
// used itself, and clears the fine sums. One thread per coarse face, of two faces of each patch.
kernel void refineReflux(device Cell *coarse [[buffer(0)]],
                         const device uchar *mask [[buffer(1)]],
                         constant SolverUniforms &u [[buffer(2)]],
                         const device int *patchOfTile [[buffer(3)]],
                         const device uint *tileOfPatch [[buffer(4)]],
                         const device uint *patchList [[buffer(5)]],
                         device float *fineFlux [[buffer(6)]],
                         const device float *coarseFlux [[buffer(7)]],
                         const device StepControl &control [[buffer(8)]],
                         device float *fineSpeciesFlux [[buffer(9)]],
                         const device float *coarseSpeciesFlux [[buffer(10)]],
                         device float2 *coarseSpecies [[buffer(11)]],
                         const device int *parentPatches [[buffer(12)]],
                         const device uint4 *cutColumns [[buffer(13)]],
                         device float4 *cutDefects [[buffer(14)]],
                         const device float4 *cutRecords [[buffer(15)]],
                         uint gid [[thread_position_in_grid]]) {
    if (control.dt <= 0.0f) {
        return;
    }
    uint perFace = uint(patchSize * patchSize);
    uint patch = patchList[gid / (2u * perFace)];
    uint high = (gid % (2u * perFace)) / perFace;
    uint position = gid % perFace;
    uint axis = u.axis;
    int3 tile = tileCoordinates(tileOfPatch[patch], u);
    int r = int(u.refineRatio);
    int side = patchSize * r;
    uint face = 2u * axis + high;
    int a = int(position % uint(patchSize));
    int b = int(position / uint(patchSize));

    // The fine sums through this coarse face, in a fixed order, cleared for the next step.
    float sums[5] = {0.0f, 0.0f, 0.0f, 0.0f, 0.0f};
    for (int fb = 0; fb < r; ++fb) {
        for (int fa = 0; fa < r; ++fa) {
            uint slot = registerSlot(patch, face, uint(a * r + fa), uint(b * r + fb), uint(side));
            for (int k = 0; k < 5; ++k) {
                sums[k] += fineFlux[slot + k];
                fineFlux[slot + k] = 0.0f;
            }
        }
    }
    float2 speciesSums = float2(0.0f);
    if (u.afterburnEnergy > 0.0f) {
        for (int fb = 0; fb < r; ++fb) {
            for (int fa = 0; fa < r; ++fa) {
                uint slot = speciesSlot(patch, face, uint(a * r + fa), uint(b * r + fb), uint(side));
                speciesSums += float2(fineSpeciesFlux[slot], fineSpeciesFlux[slot + 1]);
                fineSpeciesFlux[slot] = 0.0f;
                fineSpeciesFlux[slot + 1] = 0.0f;
            }
        }
    }

    int3 inside = tile * patchSize;
    inside[axis] += high != 0 ? patchSize - 1 : 0;
    inside[(axis + 1) % 3] += a;
    inside[(axis + 2) % 3] += b;
    int3 outside = inside;
    outside[axis] += high != 0 ? 1 : -1;
    int3 dims = int3(u.nx, u.ny, u.nz);
    if (any(inside >= dims) || outside[axis] < 0 || outside[axis] >= dims[axis]) {
        return;
    }
    int outsideIndex = parentIndex(outside, parentPatches, u);
    // Whatever the coarse cell inside is, the outside cell recorded the flux it used, fluid or
    // wall, and the fine level has a flux for every fine face (the wall's where the fine cell is
    // solid), so the two always correspond.
    if (parentSolid(mask, outsideIndex, u) || patchAt(outside, patchOfTile, u) >= 0) {
        return;
    }
    uint slot = registerSlot(patch, face, uint(a), uint(b), uint(patchSize));
    // The fine faces each have 1 / r^2 of the coarse face's area.
    float area = 1.0f / float(r * r);
    float sign = high != 0 ? 1.0f : -1.0f;  // the outside cell lies above the face, or below
    float scale = sign / u.dx;
    if (cutCells) {
        int record = parentCutRecord(outside, outsideIndex, cutColumns, cutRecords, u);
        if (record >= 0) {
            // A cut cell takes the correction into its difference, which is shared out after
            // (`redistributeCutDefects`), as its own sweeps' are: divided by its share of air it
            // could be too much for it.
            float4 change = scale * float4(area * sums[0] - coarseFlux[slot], area * sums[1] - coarseFlux[slot + 1],
                                           area * sums[2] - coarseFlux[slot + 2], area * sums[3] - coarseFlux[slot + 3]);
            float energy = scale * (area * sums[4] - coarseFlux[slot + 4]);
            if (airGravity && axis == 2u) {
                energy -= 0.5f * u.gravity * (area * sums[0] - coarseFlux[slot]);
            }
            float2 species = float2(0.0f);
            if (u.afterburnEnergy > 0.0f) {
                uint at = speciesSlot(patch, face, uint(a), uint(b), uint(patchSize));
                float2 used = float2(coarseSpeciesFlux[at], coarseSpeciesFlux[at + 1]);
                species = scale * (area * speciesSums - used);
            }
            cutDefects[2 * record] += change;
            cutDefects[2 * record + 1] += float4(species, energy, 0.0f);
            return;
        }
    }
    Cell c = coarse[outsideIndex];
    c.rho += scale * (area * sums[0] - coarseFlux[slot]);
    c.mx += scale * (area * sums[1] - coarseFlux[slot + 1]);
    c.my += scale * (area * sums[2] - coarseFlux[slot + 2]);
    c.mz += scale * (area * sums[3] - coarseFlux[slot + 3]);
    c.energy += scale * (area * sums[4] - coarseFlux[slot + 4]);
    if (airGravity && axis == 2u) {
        // The coarse cell's energy took -g times its faces' mean mass flux (see `gravitySources`);
        // this face's has changed.
        c.energy -= 0.5f * u.gravity * (area * sums[0] - coarseFlux[slot]);
    }
    c.rho = max(c.rho, u.densityFloor);
    float kinetic = 0.5f * (c.mx * c.mx + c.my * c.my + c.mz * c.mz) / c.rho;
    if (gasPressure(c.rho, c.energy - kinetic, u.airModel, u.gamma) < u.pressureFloor) {
        c.energy = gasEnergy(c.rho, u.pressureFloor, u.airModel, u.gamma) + kinetic;
    }
    coarse[outsideIndex] = c;
    if (u.afterburnEnergy > 0.0f) {
        uint at = speciesSlot(patch, face, uint(a), uint(b), uint(patchSize));
        float2 used = float2(coarseSpeciesFlux[at], coarseSpeciesFlux[at + 1]);
        coarseSpecies[outsideIndex] = max(coarseSpecies[outsideIndex] + scale * (area * speciesSums - used), 0.0f);
    }
}

static inline Cell addCells(Cell a, Cell b) {
    Cell c;
    c.rho = a.rho + b.rho;
    c.mx = a.mx + b.mx;
    c.my = a.my + b.my;
    c.mz = a.mz + b.mz;
    c.energy = a.energy + b.energy;
    return c;
}

// The sum of the 2 x 2 x 2 fine cells from `low` with spacing `spacing`, added pairwise, so that
// eight equal cells sum exactly to eight times one.
static inline Cell octetSum(int3 low, int spacing, uint patch, int3 tile, const device Cell *fine,
                            constant SolverUniforms &u) {
    Cell s[8];
    for (int n = 0; n < 8; ++n) {
        s[n] = fine[fineIndex(patch, low + spacing * int3(n & 1, (n >> 1) & 1, n >> 2), tile, u)];
    }
    return addCells(addCells(addCells(s[0], s[1]), addCells(s[2], s[3])),
                    addCells(addCells(s[4], s[5]), addCells(s[6], s[7])));
}

// The mean of the fluid fine cells of coarse cell `cell`, summed in a fixed order (pairwise when
// all are fluid, so that equal cells give exactly their own value); `count` is how many are fluid.
static inline Cell fineMean(int3 cell, uint patch, int3 tile, const device Cell *fine, const device uchar *fineMask,
                            constant SolverUniforms &u, thread int &count) {
    int r = int(u.refineRatio);
    int all = r * r * r;
    count = 0;
    for (int n = 0; n < all; ++n) {
        count += (fineMask[fineIndex(patch, cell * r + int3(n % r, (n / r) % r, n / (r * r)), tile, u)] & 1) == 0;
    }
    Cell sum = {0.0f, 0.0f, 0.0f, 0.0f, 0.0f};
    if (count == 0) {
        return sum;
    }
    if (count < all) {
        for (int n = 0; n < all; ++n) {
            uint child = fineIndex(patch, cell * r + int3(n % r, (n / r) % r, n / (r * r)), tile, u);
            if ((fineMask[child] & 1) == 0) {
                sum = addCells(sum, fine[child]);
            }
        }
        float inverse = 1.0f / float(count);
        sum.rho *= inverse;
        sum.mx *= inverse;
        sum.my *= inverse;
        sum.mz *= inverse;
        sum.energy *= inverse;
        return sum;
    }
    if (r == 2) {
        sum = octetSum(cell * 2, 1, patch, tile, fine, u);
    } else {
        // Ratio 4: eight octets of spacing 2, then the octets pairwise.
        Cell o[8];
        for (int n = 0; n < 8; ++n) {
            o[n] = octetSum(cell * 4 + int3(n & 1, (n >> 1) & 1, n >> 2), 2, patch, tile, fine, u);
        }
        sum = addCells(addCells(addCells(o[0], o[1]), addCells(o[2], o[3])),
                       addCells(addCells(o[4], o[5]), addCells(o[6], o[7])));
    }
    float inverse = 1.0f / float(r * r * r);
    Cell mean;
    mean.rho = sum.rho * inverse;
    mean.mx = sum.mx * inverse;
    mean.my = sum.my * inverse;
    mean.mz = sum.mz * inverse;
    mean.energy = sum.energy * inverse;
    return mean;
}

// The fuel and oxygen of 2 x 2 x 2 fine cells, as `octetSum`.
static inline float2 speciesOctet(int3 low, int spacing, uint patch, int3 tile, const device float2 *species,
                                  constant SolverUniforms &u) {
    float2 s[8];
    for (int n = 0; n < 8; ++n) {
        s[n] = species[fineIndex(patch, low + spacing * int3(n & 1, (n >> 1) & 1, n >> 2), tile, u)];
    }
    return ((s[0] + s[1]) + (s[2] + s[3])) + ((s[4] + s[5]) + (s[6] + s[7]));
}

// The mean fuel and oxygen of the fluid fine cells of coarse cell `cell`, as `fineMean`.
static inline float2 speciesMean(int3 cell, uint patch, int3 tile, const device float2 *species,
                                 const device uchar *fineMask, int count, constant SolverUniforms &u) {
    int r = int(u.refineRatio);
    int all = r * r * r;
    if (count < all) {
        float2 sum = float2(0.0f);
        for (int n = 0; n < all; ++n) {
            uint child = fineIndex(patch, cell * r + int3(n % r, (n / r) % r, n / (r * r)), tile, u);
            if ((fineMask[child] & 1) == 0) {
                sum += species[child];
            }
        }
        return sum / float(max(count, 1));
    }
    if (r == 2) {
        return speciesOctet(cell * 2, 1, patch, tile, species, u) * 0.125f;
    }
    float2 o[8];
    for (int n = 0; n < 8; ++n) {
        o[n] = speciesOctet(cell * 4 + int3(n & 1, (n >> 1) & 1, n >> 2), 2, patch, tile, species, u);
    }
    return (((o[0] + o[1]) + (o[2] + o[3])) + ((o[4] + o[5]) + (o[6] + o[7]))) * (1.0f / 64.0f);
}

// With the terrain's cut cells, a coarse cut cell's state from its fine cells: their air weighted by
// their shares, over the coarse cell's own share (`coarseShare`), so that it holds what they hold.
// Its fuel and oxygen likewise into `species`.
static inline Cell cutMean(int3 cell, uint patch, int3 tile, const device Cell *fine, const device uchar *fineMask,
                           const device float4 *fineCut, float coarseShare, const device float2 *fineSpecies,
                           bool takeSpecies, thread float2 &species, constant SolverUniforms &u) {
    int r = int(u.refineRatio);
    Cell sum = {0.0f, 0.0f, 0.0f, 0.0f, 0.0f};
    species = float2(0.0f);
    bool withSpecies = takeSpecies && u.afterburnEnergy > 0.0f;
    for (int n = 0; n < r * r * r; ++n) {
        uint child = fineIndex(patch, cell * r + int3(n % r, (n / r) % r, n / (r * r)), tile, u);
        if ((fineMask[child] & 1) != 0) {
            continue;
        }
        float share = fineCut[2 * child].x;
        Cell f = fine[child];
        sum.rho += share * f.rho;
        sum.mx += share * f.mx;
        sum.my += share * f.my;
        sum.mz += share * f.mz;
        sum.energy += share * f.energy;
        if (withSpecies) {
            species += share * fineSpecies[child];
        }
    }
    float inverse = 1.0f / (float(r * r * r) * coarseShare);
    sum.rho *= inverse;
    sum.mx *= inverse;
    sum.my *= inverse;
    sum.mz *= inverse;
    sum.energy *= inverse;
    species *= inverse;
    return sum;
}

// Step 5: each coarse cell under a patch becomes the mean of its fine cells, and takes their
// largest impulse.
kernel void refineRestrict(device Cell *coarse [[buffer(0)]],
                           const device uchar *mask [[buffer(1)]],
                           constant SolverUniforms &u [[buffer(2)]],
                           const device uint *tileOfPatch [[buffer(3)]],
                           const device uint *patchList [[buffer(4)]],
                           const device Cell *fine [[buffer(5)]],
                           const device StepControl &control [[buffer(6)]],
                           device float *impulse [[buffer(7)]],
                           const device float *fineImpulse [[buffer(8)]],
                           const device float *impulseBase [[buffer(9)]],
                           const device uchar *fineMask [[buffer(10)]],
                           const device float2 *fineSpecies [[buffer(11)]],
                           device float2 *coarseSpecies [[buffer(12)]],
                           const device int *parentPatches [[buffer(13)]],
                           const device uint4 *cutColumns [[buffer(14)]],
                           const device float4 *cutRecords [[buffer(15)]],
                           const device float4 *fineCut [[buffer(16)]],
                           uint gid [[thread_position_in_grid]]) {
    if (control.dt <= 0.0f) {
        return;
    }
    uint perPatch = uint(patchSize * patchSize * patchSize);
    uint patch = patchList[gid / perPatch];
    uint position = gid % perPatch;
    int3 tile = tileCoordinates(tileOfPatch[patch], u);
    int3 cell = tile * patchSize
        + int3(position % uint(patchSize), (position / uint(patchSize)) % uint(patchSize), position / uint(patchSize * patchSize));
    int3 dims = int3(u.nx, u.ny, u.nz);
    if (any(cell >= dims)) {
        return;
    }
    int index = parentIndex(cell, parentPatches, u);
    if (index < 0) {
        return;
    }
    int r = int(u.refineRatio);
    float largest = 0.0f;
    for (int n = 0; n < r * r * r; ++n) {
        uint child = fineIndex(patch, cell * r + int3(n % r, (n / r) % r, n / (r * r)), tile, u);
        largest = max(largest, (fineMask[child] & 1) == 0 ? fineImpulse[child] : 0.0f);
    }
    impulse[index] = impulseBase[patch * perPatch + position] + largest;
    if (cutCells && parentCutRecord(cell, index, cutColumns, cutRecords, u) >= 0) {
        bool open = false;
        for (int n = 0; n < r * r * r && !open; ++n) {
            open = (fineMask[fineIndex(patch, cell * r + int3(n % r, (n / r) % r, n / (r * r)), tile, u)] & 1) == 0;
        }
        // As below, a cell whose fine cells are all solid (the terrain's and a block's on it) keeps
        // what it had.
        if (open) {
            float2 species;
            Cell mean = cutMean(cell, patch, tile, fine, fineMask, fineCut,
                                parentCutLow(cell, index, cutColumns, cutRecords, u).x, fineSpecies, true, species, u);
            coarse[index] = mean;
            if (u.afterburnEnergy > 0.0f) {
                coarseSpecies[index] = species;
            }
            return;
        }
    }
    // A cell whose fine cells are all solid keeps what it had.
    int count;
    Cell mean = fineMean(cell, patch, tile, fine, fineMask, u, count);
    if (count > 0) {
        coarse[index] = mean;
        if (u.afterburnEnergy > 0.0f) {
            coarseSpecies[index] = speciesMean(cell, patch, tile, fineSpecies, fineMask, count, u);
        }
    }
}

// After the structure's substeps: carries into the fine cells what has changed in the coarse
// cells under the patches since they were averaged, the momentum and energy that debris trades
// with the air, by adding the difference between the coarse cell and its fluid fine cells' mean
// to each of them. That leaves a cell nothing touched exactly as it was (the mean is the one it
// was given). The fine cells keep their own outline (see `refineRemaskPrepare`), so a coarse
// cell the coarse mask has just opened, and refilled, passes nothing on.
kernel void refineSync(device Cell *fine [[buffer(0)]],
                       const device Cell *coarse [[buffer(1)]],
                       const device uchar *mask [[buffer(2)]],
                       constant SolverUniforms &u [[buffer(3)]],
                       const device uint *tileOfPatch [[buffer(4)]],
                       const device uint *patchList [[buffer(5)]],
                       device uchar *seenMask [[buffer(6)]],
                       const device StepControl &control [[buffer(7)]],
                       const device uchar *fineMask [[buffer(8)]],
                       const device int *parentPatches [[buffer(9)]],
                       const device uint4 *cutColumns [[buffer(10)]],
                       const device float4 *cutRecords [[buffer(11)]],
                       const device float4 *fineCut [[buffer(12)]],
                       uint gid [[thread_position_in_grid]]) {
    if (control.dt <= 0.0f) {
        return;
    }
    uint perPatch = uint(patchSize * patchSize * patchSize);
    uint patch = patchList[gid / perPatch];
    uint position = gid % perPatch;
    int3 tile = tileCoordinates(tileOfPatch[patch], u);
    int3 cell = tile * patchSize
        + int3(position % uint(patchSize), (position / uint(patchSize)) % uint(patchSize), position / uint(patchSize * patchSize));
    int3 dims = int3(u.nx, u.ny, u.nz);
    if (any(cell >= dims)) {
        return;
    }
    int index = parentIndex(cell, parentPatches, u);
    if (index < 0) {
        return;
    }
    uchar solid = parentSolid(mask, index, u) ? 1 : 0;
    uchar was = seenMask[patch * perPatch + position];
    seenMask[patch * perPatch + position] = solid;
    if (solid != 0 || was != 0) {
        return;
    }
    int r = int(u.refineRatio);
    Cell c = coarse[index];
    int count;
    Cell mean = fineMean(cell, patch, tile, fine, fineMask, u, count);
    if (count == 0) {
        return;
    }
    if (cutCells && parentCutRecord(cell, index, cutColumns, cutRecords, u) >= 0) {
        // A cut cell's fine cells hold its air share for share (its species are not read here).
        float2 species;
        mean = cutMean(cell, patch, tile, fine, fineMask, fineCut, parentCutLow(cell, index, cutColumns, cutRecords, u).x,
                       (const device float2 *)fineCut, false, species, u);
    }
    Cell d = c;
    d.rho -= mean.rho;
    d.mx -= mean.mx;
    d.my -= mean.my;
    d.mz -= mean.mz;
    d.energy -= mean.energy;
    if (d.rho == 0.0f && d.mx == 0.0f && d.my == 0.0f && d.mz == 0.0f && d.energy == 0.0f) {
        return;
    }
    for (int n = 0; n < r * r * r; ++n) {
        uint child = fineIndex(patch, cell * r + int3(n % r, (n / r) % r, n / (r * r)), tile, u);
        if ((fineMask[child] & 1) != 0) {
            continue;
        }
        Cell f = addCells(fine[child], d);
        bool valid = f.rho > u.densityFloor && cellPressureOf(f, u) > u.pressureFloor;
        fine[child] = valid ? f : c;
    }
}

// Marks the block holding `cell`, and every block within `u.refineMargin` cells of it: how close a
// sharp jump must come to a block of cells for that block to be refined too
// (`SolverConfiguration.refinementMargin`, 1 by default). A shock moves under half a cell a step,
// and the patches are placed afresh every step, so it cannot leave the refined blocks before they
// follow it.
static inline void flagAround(int3 cell, device uchar *wanted, constant SolverUniforms &u) {
    int3 dims = int3(u.nx, u.ny, u.nz);
    int reach = int(u.refineMargin);
    int3 low = max(cell - reach, 0) / patchSize;
    int3 high = min(cell + reach, dims - 1) / patchSize;
    for (int z = low.z; z <= high.z; ++z) {
        for (int y = low.y; y <= high.y; ++y) {
            for (int x = low.x; x <= high.x; ++x) {
                wanted[tileIndex(int3(x, y, z), u)] = 1;
            }
        }
    }
}

// Step 7a: a tile is wanted where the pressure of a cell in it and of a neighbour differ by more
// than `refineThreshold` of the lower, or where such a pair lies within `refineMargin` cells.
// A band of air beside envelope buildings' faces in which refinement is held while the air is
// loaded (|p − ambient| over `threshold`), so that their façades' reflected loads are resolved
// through their positive phase and not only as the shock passes. `band` is a byte a coarse cell;
// a level's cells map to coarse ones by `ratio`.
struct FacadeBand {
    uint nx;
    uint ny;
    uint nz;
    uint ratio;
    float threshold;
    float ambient;
    uint on;
    uint pad;
};

static inline bool heldByBand(int3 cell, float p, const device uchar *band, constant FacadeBand &b) {
    if (b.on == 0) return false;
    int3 c = cell / int(b.ratio);
    if (any(c < 0) || c.x >= int(b.nx) || c.y >= int(b.ny) || c.z >= int(b.nz)) return false;
    return band[uint(c.x) + b.nx * (uint(c.y) + b.ny * uint(c.z))] != 0 && fabs(p - b.ambient) > b.threshold;
}

static inline void flagCell(int3 cell, const device Cell *coarse, const device uchar *mask, device uchar *wanted,
                            constant SolverUniforms &u, const device float4 *boxDefinition,
                            const device uchar *band, constant FacadeBand &held) {
    int3 dims = int3(u.nx, u.ny, u.nz);
    int index = cell.x + dims.x * (cell.y + dims.y * cell.z);
    // Around each experimental box, whatever the air does there.
    for (uint b = 0; b < u.experimentalBox; ++b) {
        float3 point = (float3(cell)+0.5f)*u.dx;
        float3 low = boxDefinition[boxVectors*b+6].xyz-2.0f*u.dx;
        float3 high = boxDefinition[boxVectors*b+7].xyz+2.0f*u.dx;
        if (all(point >= low) && all(point <= high)) { flagAround(cell,wanted,u); return; }
    }
    if (mask[index] != 0) {
        return;
    }
    float p = cellPressureOf(coarse[index], u);
    if (heldByBand(cell, p, band, held)) {
        flagAround(cell, wanted, u);
    }
    // Each pair of neighbours is looked at once, from its lower cell, and marks around both cells,
    // so that a jump refines the same on either side of it.
    bool sharp = false;
    for (int axis = 0; axis < 3; ++axis) {
        int3 next = cell;
        next[axis] += 1;
        if (next[axis] >= dims[axis]) {
            continue;
        }
        int nextIndex = next.x + dims.x * (next.y + dims.y * next.z);
        if (mask[nextIndex] != 0) {
            continue;
        }
        float q = cellPressureOf(coarse[nextIndex], u);
        if (fabs(q - p) > u.refineThreshold * min(p, q)) {
            sharp = true;
            flagAround(next, wanted, u);
        }
    }
    if (sharp) {
        flagAround(cell, wanted, u);
    }
}

kernel void refineFlag(const device Cell *coarse [[buffer(0)]],
                       const device uchar *mask [[buffer(1)]],
                       device uchar *wanted [[buffer(2)]],
                       constant SolverUniforms &u [[buffer(3)]],
                       const device StepControl &control [[buffer(4)]],
                       const device float4 *boxDefinition [[buffer(6)]],
                       const device uchar *band [[buffer(7)]],
                       constant FacadeBand &held [[buffer(8)]],
                       uint3 tid [[thread_position_in_grid]]) {
    if (control.dt <= 0.0f || tid.x >= u.nx || tid.y >= u.ny || tid.z >= u.nz) {
        return;
    }
    flagCell(int3(tid), coarse, mask, wanted, u, boxDefinition, band, held);
}

// The same over the awake tiles alone, as `sweepTiles` (still air has nothing to flag).
kernel void refineFlagTiles(const device Cell *coarse [[buffer(0)]],
                            const device uchar *mask [[buffer(1)]],
                            device uchar *wanted [[buffer(2)]],
                            constant SolverUniforms &u [[buffer(3)]],
                            const device StepControl &control [[buffer(4)]],
                            const device uint *tiles [[buffer(5)]],
                            const device float4 *boxDefinition [[buffer(6)]],
                            const device uchar *band [[buffer(7)]],
                            constant FacadeBand &held [[buffer(8)]],
                            uint3 group [[threadgroup_position_in_grid]],
                            uint3 local [[thread_position_in_threadgroup]],
                            uint3 groupSize [[threads_per_threadgroup]]) {
    if (control.dt <= 0.0f) {
        return;
    }
    uint tile = tiles[group.x];
    uint3 origin = uint3(tile % u.tileNx, (tile / u.tileNx) % u.tileNy, tile / (u.tileNx * u.tileNy))
        * uint(tileSize);
    for (uint z = local.z; z < uint(tileSize); z += groupSize.z) {
        uint3 cell = origin + uint3(local.x, local.y, z);
        if (cell.x < u.nx && cell.y < u.ny && cell.z < u.nz) {
            flagCell(int3(cell), coarse, mask, wanted, u, boxDefinition, band, held);
        }
    }
}

// Step 7a for a level beneath another, per cell of its parent's patches: as `flagCell`, from the
// parent level's cells. A jump between a parent cell and one no patch of the parent holds is not
// looked at; the coarse grid's flags cover it.
kernel void refineFlagFine(const device Cell *parent [[buffer(0)]],
                           const device uchar *parentMask [[buffer(1)]],
                           device uchar *wanted [[buffer(2)]],
                           constant SolverUniforms &u [[buffer(3)]],
                           const device StepControl &control [[buffer(4)]],
                           const device int *parentPatches [[buffer(5)]],
                           const device uint *parentTileOfPatch [[buffer(6)]],
                           const device uint *parentList [[buffer(7)]],
                           const device uchar *band [[buffer(8)]],
                           constant FacadeBand &held [[buffer(9)]],
                           uint gid [[thread_position_in_grid]]) {
    if (control.dt <= 0.0f) {
        return;
    }
    int side = int(u.parentSide);
    uint cells = uint(side * side * side);
    uint patch = parentList[gid / cells];
    uint position = gid % cells;
    uint block = parentTileOfPatch[patch];
    int3 origin = int3(block % u.parentTileNx, (block / u.parentTileNx) % u.parentTileNy,
                       block / (u.parentTileNx * u.parentTileNy)) * side;
    int3 cell = origin + int3(position % uint(side), (position / uint(side)) % uint(side), position / uint(side * side));
    int3 dims = int3(u.nx, u.ny, u.nz);
    uint index = patch * cells + position;
    if (any(cell >= dims) || (parentMask[index] & 1) != 0) {
        return;
    }
    float p = cellPressureOf(parent[index], u);
    if (heldByBand(cell, p, band, held)) {
        flagAround(cell, wanted, u);
    }
    bool sharp = false;
    for (int axis = 0; axis < 3; ++axis) {
        int3 next = cell;
        next[axis] += 1;
        if (next[axis] >= dims[axis]) {
            continue;
        }
        int nextIndex = parentIndex(next, parentPatches, u);
        if (parentSolid(parentMask, nextIndex, u)) {
            continue;
        }
        float q = cellPressureOf(parent[nextIndex], u);
        if (fabs(q - p) > u.refineThreshold * min(p, q)) {
            sharp = true;
            flagAround(next, wanted, u);
        }
    }
    if (sharp) {
        flagAround(cell, wanted, u);
    }
}

// How far beyond a patch of a level beneath another, in its parent's cells, the parent's patches
// must reach: its ghost cells reach one parent cell out (half of one at ratio 4), and filling them
// takes the parent's slopes from the cell beyond.
constant int nestReach = 2;

// Whether the parent's patches cover every cell within `nestReach` of block `tile` of this level.
static inline bool nested(int3 tile, const device int *parentPatches, constant SolverUniforms &u) {
    int3 dims = int3(u.nx, u.ny, u.nz);
    int side = int(u.parentSide);
    int3 low = max(tile * patchSize - nestReach, 0) / side;
    int3 high = min(tile * patchSize + patchSize - 1 + nestReach, dims - 1) / side;
    for (int z = low.z; z <= high.z; ++z) {
        for (int y = low.y; y <= high.y; ++y) {
            for (int x = low.x; x <= high.x; ++x) {
                if (parentPatches[x + int(u.parentTileNx) * (y + int(u.parentTileNy) * z)] < 0) {
                    return false;
                }
            }
        }
    }
    return true;
}

// Step 7a', per block of a level beneath another, after both levels are flagged: the parent's
// blocks around each block this level wants, or keeps as pinned, are wanted too, so that the
// level stays nested in its parent (and the parent is not released from under it).
kernel void refineNest(const device uchar *wanted [[buffer(0)]],
                       const device int *patchOfTile [[buffer(1)]],
                       const device uint *pinned [[buffer(2)]],
                       device uchar *parentWanted [[buffer(3)]],
                       constant SolverUniforms &u [[buffer(4)]],
                       const device StepControl &control [[buffer(5)]],
                       uint tid [[thread_position_in_grid]]) {
    uint tiles = u.refineTileNx * u.refineTileNy * u.refineTileNz;
    if (control.dt <= 0.0f || tid >= tiles) {
        return;
    }
    int patch = patchOfTile[tid];
    if (wanted[tid] == 0 && (patch < 0 || pinned[patch] == 0)) {
        return;
    }
    int3 tile = tileCoordinates(tid, u);
    int3 dims = int3(u.nx, u.ny, u.nz);
    int side = int(u.parentSide);
    int3 low = max(tile * patchSize - nestReach, 0) / side;
    int3 high = min(tile * patchSize + patchSize - 1 + nestReach, dims - 1) / side;
    for (int z = low.z; z <= high.z; ++z) {
        for (int y = low.y; y <= high.y; ++y) {
            for (int x = low.x; x <= high.x; ++x) {
                parentWanted[x + int(u.parentTileNx) * (y + int(u.parentTileNy) * z)] = 1;
            }
        }
    }
}

// Step 7b, per block: releases the patches no longer wanted to the pool.
kernel void refineRelease(device int *patchOfTile [[buffer(0)]],
                          device uint *tileOfPatch [[buffer(1)]],
                          device uint *freeStack [[buffer(2)]],
                          device atomic_int *counters [[buffer(3)]],
                          const device uchar *wanted [[buffer(4)]],
                          const device uint *pinned [[buffer(5)]],
                          constant SolverUniforms &u [[buffer(6)]],
                          const device StepControl &control [[buffer(7)]],
                          uint tid [[thread_position_in_grid]]) {
    uint tiles = u.refineTileNx * u.refineTileNy * u.refineTileNz;
    if (control.dt <= 0.0f || tid >= tiles) {
        return;
    }
    int patch = patchOfTile[tid];
    // A patch over an outline that differs from the coarse cells' is never released: the two
    // grids disagree about how much gas is there, and the gas would be lost or gained.
    if (patch >= 0 && wanted[tid] == 0 && pinned[patch] == 0) {
        patchOfTile[tid] = -1;
        tileOfPatch[patch] = freePatch;
        int top = atomic_fetch_add_explicit(&counters[0], 1, memory_order_relaxed);
        freeStack[top] = uint(patch);
    }
}

// Blocks handled by each threadgroup of the allocation's kernels.
constant uint allocationGroup = 256;

// Whether block `tid` asks for a new patch: it is wanted and has none, and, for a level beneath
// another, its parent's patches are around it.
static inline bool requestsPatch(uint tid, const device int *patchOfTile, const device uchar *wanted,
                                 const device int *parentPatches, constant SolverUniforms &u) {
    uint tiles = u.refineTileNx * u.refineTileNy * u.refineTileNz;
    if (tid >= tiles || wanted[tid] == 0 || patchOfTile[tid] >= 0) {
        return false;
    }
    return u.parentSide == 0u || nested(tileCoordinates(tid, u), parentPatches, u);
}

// The sum of `value` over the threadgroup's threads before this one, and (in `total`) over all.
static inline uint groupPrefix(uint value, uint lane, uint simd, uint simds, threadgroup uint *partial,
                               thread uint &total) {
    uint before = simd_prefix_exclusive_sum(value);
    uint sum = simd_sum(value);
    if (lane == 0) {
        partial[simd] = sum;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    total = 0;
    for (uint s = 0; s < simds; ++s) {
        before += s < simd ? partial[s] : 0u;
        total += partial[s];
    }
    return before;
}

// Step 7c, per group of `allocationGroup` blocks: how many of them ask for a new patch.
kernel void refineRequest(const device int *patchOfTile [[buffer(0)]],
                          const device uchar *wanted [[buffer(1)]],
                          device uint *groupCounts [[buffer(2)]],
                          constant SolverUniforms &u [[buffer(3)]],
                          const device int *parentPatches [[buffer(4)]],
                          uint tid [[thread_position_in_grid]],
                          uint group [[threadgroup_position_in_grid]],
                          uint lane [[thread_index_in_simdgroup]],
                          uint simd [[simdgroup_index_in_threadgroup]],
                          uint simds [[simdgroups_per_threadgroup]]) {
    threadgroup uint partial[32];
    uint total;
    groupPrefix(requestsPatch(tid, patchOfTile, wanted, parentPatches, u) ? 1u : 0u, lane, simd, simds, partial,
                total);
    if (lane == 0 && simd == 0) {
        groupCounts[group] = total;
    }
}

// Step 7d, one thread: where each group's requests start among all of them, in block order, and
// how many the pool can grant: the first that many requests, in block order, are granted, so that
// which blocks are refined when the pool is used up does not depend on the order threads run in.
// Counters: 0 the free stack's height, which falls by the patches granted; 1 the patches granted;
// 3 the height before; 4 the most patches in use yet; 5 set once more were wanted than were free
// (the pool ran out, and some blocks the shock wanted refined were not).
kernel void refineGrant(device uint *groupCounts [[buffer(0)]],
                        device int *counters [[buffer(1)]],
                        constant SolverUniforms &u [[buffer(2)]],
                        const device StepControl &control [[buffer(3)]],
                        uint tid [[thread_position_in_grid]]) {
    if (tid != 0 || control.dt <= 0.0f) {
        return;
    }
    uint tiles = u.refineTileNx * u.refineTileNy * u.refineTileNz;
    uint groups = (tiles + allocationGroup - 1) / allocationGroup;
    uint running = 0;
    for (uint g = 0; g < groups; ++g) {
        uint count = groupCounts[g];
        groupCounts[g] = running;
        running += count;
    }
    int free = counters[0];
    int granted = min(int(running), max(free, 0));
    counters[3] = free;
    counters[0] = free - granted;
    counters[1] = granted;
    counters[4] = max(counters[4], int(u.refineMaxPatches) - (free - granted));
    if (int(running) > max(free, 0)) {
        counters[5] = 1;
    }
}

// Step 7e, per block: gives each block granted a new patch one from the pool, and wakes the tiles
// of still air holding each wanted block and the coarse cells around it, which must record their
// fluxes through its faces. The flags are cleared for the next step.
kernel void refineAllocate(device int *patchOfTile [[buffer(0)]],
                           device uint *tileOfPatch [[buffer(1)]],
                           const device uint *freeStack [[buffer(2)]],
                           const device int *counters [[buffer(3)]],
                           device uchar *wanted [[buffer(4)]],
                           device uint *newPatches [[buffer(5)]],
                           device uchar *tileFlags [[buffer(6)]],
                           constant SolverUniforms &u [[buffer(7)]],
                           const device StepControl &control [[buffer(8)]],
                           device uint *pinned [[buffer(9)]],
                           const device int *parentPatches [[buffer(10)]],
                           const device uint *groupStarts [[buffer(11)]],
                           uint tid [[thread_position_in_grid]],
                           uint group [[threadgroup_position_in_grid]],
                           uint lane [[thread_index_in_simdgroup]],
                           uint simd [[simdgroup_index_in_threadgroup]],
                           uint simds [[simdgroups_per_threadgroup]]) {
    if (control.dt <= 0.0f) {
        return;
    }
    // Every thread of the group takes part in the sum before any leaves.
    bool request = requestsPatch(tid, patchOfTile, wanted, parentPatches, u);
    threadgroup uint partial[32];
    uint total;
    uint rank = groupStarts[group] + groupPrefix(request ? 1u : 0u, lane, simd, simds, partial, total);
    uint tiles = u.refineTileNx * u.refineTileNy * u.refineTileNz;
    if (tid >= tiles || wanted[tid] == 0) {
        return;
    }
    wanted[tid] = 0;
    int3 tile = tileCoordinates(tid, u);
    if (patchOfTile[tid] < 0) {
        // A level beneath another takes a new patch only where its parent's patches are around
        // it; and none is left once the pool is used up.
        if (!request || rank >= uint(counters[1])) {
            return;
        }
        uint patch = freeStack[uint(counters[3]) - 1u - rank];
        patchOfTile[tid] = int(patch);
        tileOfPatch[patch] = tid;
        pinned[patch] = 0;
        newPatches[rank] = patch;
    }
    if (u.tileNx == 0) {
        return;
    }
    int3 cells = int3(u.nx, u.ny, u.nz);
    int3 low = max(tile * patchSize - 1, 0) / tileSize;
    int3 high = min(tile * patchSize + patchSize, cells - 1) / tileSize;
    for (int z = low.z; z <= high.z; ++z) {
        for (int y = low.y; y <= high.y; ++y) {
            for (int x = low.x; x <= high.x; ++x) {
                uint index = uint(x) + u.tileNx * (uint(y) + u.tileNy * uint(z));
                if (tileFlags[index] == tileStill) {
                    tileFlags[index] = tileWoken;
                }
            }
        }
    }
}

// Step 7d, per pool slot: lists the patches in use, for the next step's dispatches.
kernel void refineList(const device uint *tileOfPatch [[buffer(0)]],
                       device uint *patchList [[buffer(1)]],
                       device atomic_int *counters [[buffer(2)]],
                       constant SolverUniforms &u [[buffer(3)]],
                       uint tid [[thread_position_in_grid]]) {
    if (tid >= u.refineMaxPatches || tileOfPatch[tid] == freePatch) {
        return;
    }
    patchList[atomic_fetch_add_explicit(&counters[2], 1, memory_order_relaxed)] = tid;
}

// Step 7e, one thread: the threadgroup counts of the refinement's dispatches, from the number of
// patches in use and of new ones, whose counters are then reset. Layout: sweep, halo, reflux,
// restrict, fill (new patches), ghosts, every fine cell, the coarse cells of new patches, each
// (groups, 1, 1); then the number of patches.
kernel void refineArguments(device atomic_int *counters [[buffer(0)]],
                            device uint *arguments [[buffer(1)]],
                            constant SolverUniforms &u [[buffer(2)]],
                            device StepControl &control [[buffer(3)]],
                            uint tid [[thread_position_in_grid]]) {
    if (tid != 0) {
        return;
    }
    uint patches = uint(atomic_exchange_explicit(&counters[2], 0, memory_order_relaxed));
    uint fresh = uint(atomic_exchange_explicit(&counters[1], 0, memory_order_relaxed));
    uint r = u.refineRatio;
    uint side = uint(patchSize) * r;
    uint across = r / 2u;
    uint groups[8] = {patches * across * across * across, patches * (haloCells / 256u), patches, patches,
                      fresh * (side * side * side / 256u), patches * (4u * side * side / 256u),
                      patches * (side * side * side / 256u), fresh};
    for (uint n = 0; n < 8; ++n) {
        arguments[3 * n] = groups[n];
        arguments[3 * n + 1] = 1;
        arguments[3 * n + 2] = 1;
    }
    arguments[24] = patches;
}

// Matches `TerrainUniforms` in Refinement.swift.
// Step 7f: fills each new patch from the coarse air (at the step's end).
// Envelope venting's panes as the fine levels see them (`EnvelopeVenting.sortedPaneCellBuffer`): this
// header, then the coarse cells standing for panes, (cell, pane) sorted by cell; and each pane's
// status (0 whole).
struct PaneLookup {
    uint count;
    uint nx;
    uint ny;
    uint nz;
    float coarseDx;
    float pad0;
    float pad1;
    float pad2;
};

// Whether the point lies in a coarse cell of a pane, or of a wall, roof or slab, that has broken:
// its finer cells are air whatever block holds them, as the coarse cell is.
static inline bool inOpenedPane(float3 point, const device PaneLookup *lookup, const device uint *status) {
    PaneLookup v = lookup[0];
    const device uint2 *cells = (const device uint2 *)(lookup + 1);
    if (v.count == 0u) {
        return false;
    }
    int3 c = int3(floor(point / v.coarseDx));
    if (any(c < 0) || any(c >= int3(v.nx, v.ny, v.nz))) {
        return false;
    }
    uint index = uint(c.x) + v.nx * (uint(c.y) + v.ny * uint(c.z));
    uint low = 0;
    uint high = v.count;
    while (low < high) {
        uint middle = (low + high) / 2;
        if (cells[middle].x < index) low = middle + 1; else high = middle;
    }
    // A cell may stand for a pane and the wall holding it: open once either is.
    for (uint k = low; k < v.count && cells[k].x == index; ++k) {
        if (status[cells[k].y] != 0u) return true;
    }
    return false;
}

kernel void refineFill(device Cell *fine [[buffer(0)]],
                       const device Cell *coarse [[buffer(1)]],
                       const device uchar *mask [[buffer(2)]],
                       constant SolverUniforms &u [[buffer(3)]],
                       const device uint *tileOfPatch [[buffer(4)]],
                       const device uint *newPatches [[buffer(5)]],
                       device float *fineImpulse [[buffer(6)]],
                       const device float *impulse [[buffer(7)]],
                       device float *impulseBase [[buffer(8)]],
                       device uchar *seenMask [[buffer(9)]],
                       const device uchar *rigidMask [[buffer(10)]],
                       const device float4 *boxes [[buffer(11)]],
                       constant uint &boxCount [[buffer(12)]],
                       device uchar *fineMask [[buffer(13)]],
                       device packed_float3 *fineWall [[buffer(14)]],
                       const device float *wallVelocity [[buffer(15)]],
                       const device float2 *coarseSpecies [[buffer(16)]],
                       device float2 *fineSpecies [[buffer(17)]],
                       const device float4 *boxDefinition [[buffer(18)]],
                       const device int *parentPatches [[buffer(19)]],
                       const device float *terrainHeights [[buffer(20)]],
                       constant TerrainUniforms &terrain [[buffer(21)]],
                       const device float4 *gravityTable [[buffer(22)]],
                       const device float4 *parentGravityTable [[buffer(23)]],
                       device float4 *fineCut [[buffer(24)]],
                       const device uint4 *cutColumns [[buffer(25)]],
                       device uint *patchCut [[buffer(26)]],
                       const device float4 *cutRecords [[buffer(27)]],
                       device atomic_uint *maxSpeed [[buffer(28)]],
                       const device PaneLookup *panes [[buffer(29)]],
                       const device uint *paneStatus [[buffer(30)]],
                       uint gid [[thread_position_in_grid]]) {
    uint r = u.refineRatio;
    uint side = uint(patchSize) * r;
    uint cells = side * side * side;
    uint patch = newPatches[gid / cells];
    uint position = gid % cells;
    int3 tile = tileCoordinates(tileOfPatch[patch], u);
    int3 fineCoordinates = tile * int(side) + int3(position % side, (position / side) % side, position / (side * side));
    int3 cell = fineCoordinates / int(r);
    if (any(cell >= int3(u.nx, u.ny, u.nz))) {
        return;
    }
    int index = parentIndex(cell, parentPatches, u);
    if (index < 0) {
        return;
    }
    bool parentIsSolid = parentSolid(mask, index, u);
    // With the terrain's cut cells, each fine cell's share of air and apertures; a fine cell without
    // air is the terrain's (`refineFillConserve` notes whether the patch has cut cells).
    uint at = patch * cells + position;
    CutGeometry geometry = {float4(1.0f), float4(1.0f)};
    if (cutCells) {
        if (position == 0u) {
            patchCut[patch] = 0u;
        }
        if (terrain.enabled != 0) {
            geometry = cutGeometryAt(fineCoordinates, u.dx / float(r), cutSamples(u, terrain), terrain, terrainHeights);
        }
        fineCut[2 * at] = geometry.low;
        fineCut[2 * at + 1] = geometry.high;
    }
    // The fine outline: rigid blocks by whether the fine cell's centre lies in one (or, without
    // a list of them, as the coarse cell is), and the structure as the coarse cell has it until
    // the structure's own fine pass (`refineRemaskPrepare`) refines it.
    // The terrain likewise: by whether the fine cell's centre lies below its surface. (Marked 16
    // for `refineFillConserve`, which runs next; the structure's remask clears the mark.)
    bool rigid = false;
    bool byTerrain = false;
    if (boxCount > 0 || terrain.enabled != 0) {
        float3 centre = (float3(fineCoordinates) + 0.5f) * (u.dx / float(r));
        for (uint n = 0; n < boxCount && !rigid; ++n) {
            rigid = all(centre >= boxes[2 * n].xyz) && all(centre <= boxes[2 * n + 1].xyz);
        }
        // A vented pane's cells are air once it has broken, whatever block holds them.
        if (rigid && inOpenedPane(centre, panes, paneStatus)) {
            rigid = false;
        }
        if (!rigid && terrain.enabled != 0) {
            byTerrain = cutCells ? geometry.low.x == 0.0f : centre.z < terrainHeight(centre.xy, terrain, terrainHeights);
            rigid = byTerrain;
        }
        // A cut cell less than half air with a block on the fine cell above it is solid, as such a
        // coarse cell is when the scene loads: its air would be shut in, and what its column could
        // pass up no further would come back to it magnified as many times as it is small, every
        // step. A block too thin for the coarse cells to hold can stand on one here.
        if (!rigid && cutCells && geometry.low.x < 0.5f) {
            float3 above = centre + float3(0.0f, 0.0f, u.dx / float(r));
            bool capped = false;
            for (uint n = 0; n < boxCount && !capped; ++n) {
                capped = all(above >= boxes[2 * n].xyz) && all(above <= boxes[2 * n + 1].xyz);
            }
            rigid = capped && !inOpenedPane(above, panes, paneStatus);
        }
    } else {
        rigid = parentRigid(rigidMask, index, u);
    }
    bool structure = u.experimentalBox == 0 && parentIsSolid && !parentRigid(rigidMask, index, u);
    float3 point = (float3(fineCoordinates)+0.5f)*(u.dx/float(r));
    int owner = u.experimentalBox != 0 ? experimentalBoxOwner(point,u.dx/float(r),u,boxDefinition) : -1;
    bool own = owner >= 0;
    fineMask[at] = (rigid || structure || own ? 1 : 0) | (rigid ? 2 : 0) | (own ? 8 : 0) | (byTerrain ? 16 : 0);
    fineWall[at] = own ? experimentalBoxVelocity(point,boxDefinition+boxVectors*uint(owner))
                      : structure ? parentWallVelocity(wallVelocity, cell, index, u) : float3(0.0f);
    bool coarseCut = cutCells && !parentIsSolid && parentCutRecord(cell, index, cutColumns, cutRecords, u) >= 0;
    if (coarseCut) {
        // In a coarse cut cell, its state throughout (under gravity, its deviation from the background
        // on the fine cell's): `refineFillConserve` then makes the fine cells hold what it holds.
        Cell c = parentCell(coarse, index, u);
        if (airGravity) {
            c = gravityDeviation(gravityDeviation(c, parentGravityTable, cell.z, -1.0f), gravityTable,
                                 fineCoordinates.z, 1.0f);
        }
        fine[at] = c;
    } else if (!parentIsSolid) {
        fine[at] = prolong(fineCoordinates, tile, patch, coarse, coarse, mask, 1.0f, u, parentPatches,
                           parentGravityTable, gravityTable);
    } else {
        // A fine cell of air in a coarse cell that is solid: air the coarse cells could not see,
        // which has held the still air the domain was filled with. (The mean of the air beside it
        // would copy the hottest gas into it, beside a charge, and add energy.) With gravity, the
        // air at rest at its height.
        Cell still;
        still.rho = u.stillRho;
        still.mx = u.stillMx;
        still.my = u.stillMy;
        still.mz = u.stillMz;
        still.energy = u.stillEnergy;
        if (airGravity) {
            float4 b = gravityCellOf(gravityTable, fineCoordinates.z);
            still.rho = b.x;
            still.mx = 0.0f;
            still.my = 0.0f;
            still.mz = 0.0f;
            still.energy = b.y;
        }
        fine[at] = still;
    }
    if (u.afterburnEnergy > 0.0f) {
        // At the coarse cell's mass fractions, so that the fine cells' mean is the coarse cell's.
        fineSpecies[at] = !parentIsSolid
            ? coarseSpecies[index] / max(coarse[index].rho, u.densityFloor) * fine[at].rho
            : float2(0.0f, airGravity ? u.stillOxygen / u.stillRho * fine[at].rho : u.stillOxygen);
    }
    fineImpulse[at] = 0.0f;
    if (u.ownSteps != 0u && (fineMask[at] & 1) == 0) {
        // A new patch's waves count towards its level's substeps from its first step, which no
        // sweep of this level has seen yet.
        Cell c = fine[at];
        float rho = max(c.rho, u.densityFloor);
        float3 momentum = float3(c.mx, c.my, c.mz);
        float pressure = max(cellPressureOf(c, u), u.pressureFloor);
        recordWaveSpeed(maxSpeed + 1u + u.refineLevel, levelWaveSpeed(momentum, rho, pressure, u));
    }
    // The first fine cell of each coarse cell keeps the impulse the coarse cell had so far.
    if (all(fineCoordinates == cell * int(r))) {
        int3 inPatch = cell - tile * patchSize;
        uint coarseCell = uint(inPatch.x + patchSize * (inPatch.y + patchSize * inPatch.z));
        impulseBase[patch * uint(patchSize * patchSize * patchSize) + coarseCell] = impulse[index];
        seenMask[patch * uint(patchSize * patchSize * patchSize) + coarseCell] = parentIsSolid ? 1 : 0;
    }
}

// After `refineFill`, per coarse cell of each new patch: where its fine outline differs from its
// own, the gas the coarse cell held over the fine cells that are solid is shared among those that
// are fluid, so that placing the patch neither loses nor gains gas, and the patch is pinned.
// Not under the terrain: there it is given up, since shared it would raise the fluid cells'
// pressure by the solid share (an eighth of a cell solid, 14%), which would flag the blocks beside
// and refine its way along a sloping surface ahead of the blast. What is given up there balances,
// on average over the surface, the still air gained where a fine cell is fluid in a solid coarse
// cell. Nor under a rigid block where the air is still (since 18 October 2026): a block whose
// edges fall between the coarse cells' takes part of the cells beside it at a finer level, and the
// gas shared into what is left raised the pressure there by up to several times; at threshold
// 0.005 that flagged the blocks beside, whose patches did the same, and in Beirut's district
// refined twice the refinement ran ahead of the shock from building to building, a precursor of
// 20-200 kPa 50-200 m ahead that the gauges took for the blast's arrival. Where the air moves, the
// block's share is shared, so that the gas in a closed room stays conserved.
kernel void refineFillConserve(device Cell *fine [[buffer(0)]],
                               const device uchar *mask [[buffer(1)]],
                               constant SolverUniforms &u [[buffer(2)]],
                               const device uint *tileOfPatch [[buffer(3)]],
                               const device uint *newPatches [[buffer(4)]],
                               const device uchar *fineMask [[buffer(5)]],
                               device uint *pinned [[buffer(6)]],
                               device float2 *fineSpecies [[buffer(7)]],
                               const device int *parentPatches [[buffer(8)]],
                               const device Cell *coarse [[buffer(9)]],
                               const device float2 *coarseSpecies [[buffer(10)]],
                               const device uint4 *cutColumns [[buffer(11)]],
                               const device float4 *cutRecords [[buffer(12)]],
                               const device float4 *fineCut [[buffer(13)]],
                               device uint *patchCut [[buffer(14)]],
                               uint gid [[thread_position_in_grid]]) {
    uint perPatch = uint(patchSize * patchSize * patchSize);
    uint patch = newPatches[gid / perPatch];
    uint position = gid % perPatch;
    int3 tile = tileCoordinates(tileOfPatch[patch], u);
    int3 cell = tile * patchSize
        + int3(position % uint(patchSize), (position / uint(patchSize)) % uint(patchSize), position / uint(patchSize * patchSize));
    int3 dims = int3(u.nx, u.ny, u.nz);
    if (any(cell >= dims)) {
        return;
    }
    int r = int(u.refineRatio);
    int all = r * r * r;
    bool coarseSolid = parentSolid(mask, parentIndex(cell, parentPatches, u), u);
    if (cutCells) {
        bool anyCut = false;
        for (int n = 0; n < all; ++n) {
            uint child = fineIndex(patch, cell * r + int3(n % r, (n / r) % r, n / (r * r)), tile, u);
            CutGeometry g = {fineCut[2 * child], fineCut[2 * child + 1]};
            anyCut = anyCut || cutGeometryCut(g);
        }
        if (anyCut) {
            patchCut[patch] = 1u;
        }
        int index = parentIndex(cell, parentPatches, u);
        // Not where a block's fine outline takes part of the cell: its fine shares then fall short
        // of the coarse cell's, and making them hold what it held would raise or lower their
        // pressure, as below.
        bool blocked = false;
        for (int n = 0; n < all && !blocked; ++n) {
            blocked = (fineMask[fineIndex(patch, cell * r + int3(n % r, (n / r) % r, n / (r * r)), tile, u)] & 2) != 0;
        }
        if (!coarseSolid && !blocked && parentCutRecord(cell, index, cutColumns, cutRecords, u) >= 0) {
            // A cut cell: its fine cells, each filled with its state, are made to hold what it
            // holds, share for share, by adding the same to each (the shares agree to rounding).
            // Nothing is given up or shared, and the patch need not be kept.
            float target = float(all) * parentCutLow(cell, index, cutColumns, cutRecords, u).x;
            float2 species;
            Cell held =
                cutMean(cell, patch, tile, fine, fineMask, fineCut, 1.0f / float(all), fineSpecies, true, species, u);
            float shares = 0.0f;
            for (int n = 0; n < all; ++n) {
                uint child = fineIndex(patch, cell * r + int3(n % r, (n / r) % r, n / (r * r)), tile, u);
                shares += (fineMask[child] & 1) == 0 ? fineCut[2 * child].x : 0.0f;
            }
            if (shares <= 0.0f) {
                return;
            }
            Cell c = coarse[index];
            Cell d;
            d.rho = (target * c.rho - held.rho) / shares;
            d.mx = (target * c.mx - held.mx) / shares;
            d.my = (target * c.my - held.my) / shares;
            d.mz = (target * c.mz - held.mz) / shares;
            d.energy = (target * c.energy - held.energy) / shares;
            float2 dSpecies = u.afterburnEnergy > 0.0f ? (target * coarseSpecies[index] - species) / shares : float2(0.0f);
            for (int n = 0; n < all; ++n) {
                uint child = fineIndex(patch, cell * r + int3(n % r, (n / r) % r, n / (r * r)), tile, u);
                if ((fineMask[child] & 1) == 0) {
                    fine[child] = addCells(fine[child], d);
                    if (u.afterburnEnergy > 0.0f) {
                        fineSpecies[child] = max(fineSpecies[child] + dSpecies, 0.0f);
                    }
                }
            }
            return;
        }
    }
    int fluid = 0;
    Cell lost = {0.0f, 0.0f, 0.0f, 0.0f, 0.0f};
    float2 lostSpecies = float2(0.0f);
    bool species = u.afterburnEnergy > 0.0f;
    // A block's share is given up only where the air is still (within half the threshold's jump of
    // ambient), where sharing it would make a pressure out of nothing ahead of the blast; where the
    // air moves it is shared, and the gas conserved.
    int parent = parentIndex(cell, parentPatches, u);
    bool still = !coarseSolid
        && fabs(cellPressureOf(coarse[parent], u) - u.ambientPressure) < 0.5f * u.refineThreshold * u.ambientPressure;
    uchar givenUp = still ? 18 : 16;
    for (int n = 0; n < all; ++n) {
        uint child = fineIndex(patch, cell * r + int3(n % r, (n / r) % r, n / (r * r)), tile, u);
        if ((fineMask[child] & 1) == 0) {
            fluid += 1;
        } else if (!coarseSolid && (fineMask[child] & givenUp) == 0) {
            lost = addCells(lost, fine[child]);
            if (species) {
                lostSpecies += fineSpecies[child];
            }
        }
    }
    if (fluid == (coarseSolid ? 0 : all)) {
        return;
    }
    pinned[patch] = 1;
    if (coarseSolid || fluid == 0) {
        return;
    }
    float share = 1.0f / float(fluid);
    for (int n = 0; n < all; ++n) {
        uint child = fineIndex(patch, cell * r + int3(n % r, (n / r) % r, n / (r * r)), tile, u);
        if ((fineMask[child] & 1) == 0) {
            Cell c = fine[child];
            c.rho += lost.rho * share;
            c.mx += lost.mx * share;
            c.my += lost.my * share;
            c.mz += lost.mz * share;
            c.energy += lost.energy * share;
            fine[child] = c;
            if (species) {
                fineSpecies[child] += lostSpecies * share;
            }
        }
    }
}

// For a deformable structure: the overpressure of the first fluid air met going out along
// `normal` from `point`, starting `offset` beyond it and looking through at most `reach` cells of
// `cellSize`. Where the air is refined (`ratio` > 0, the patches of the blocks `blocksX` by
// `blocksY` across in `patchOfTile`, their cells in `fine`), it walks the fine cells instead, so
// a face is loaded by the fine cell beside it: against a wall the air's pressure changes too
// steeply for the mean over a coarse cell to stand for it. With a second level (`deepRatio`, its
// cells per coarse cell's edge, > 0), it walks that level's cells, and reads each where the
// finest level holding it does.
static inline float overpressureAlong(float3 point, float3 normal, float offset, int reach, const device Cell *fluid,
                                      const device uchar *fluidMask, const device int *patchOfTile,
                                      const device Cell *fine, const device uchar *fineMask, uint ratio, uint blocksX,
                                      uint blocksY, float cellSize, int3 dims, uint airModel, float gamma,
                                      float ambient, const device int *deepPatches, const device Cell *deepFine,
                                      const device uchar *deepMask, uint deepRatio, uint deepBlocksX,
                                      uint deepBlocksY) {
    uint finest = deepRatio != 0 ? deepRatio : ratio;
    float step = finest != 0 ? cellSize / float(finest) : cellSize;
    int steps = finest != 0 ? reach * int(finest) : reach;
    float3 sample = point + normal * (offset + 0.5f * step);
    for (int attempt = 0; attempt < steps; ++attempt) {
        int3 cell = int3(floor(sample / cellSize));
        if (any(cell < 0) || any(cell >= dims)) {
            return 0.0f;
        }
        int index = cell.x + dims.x * (cell.y + dims.y * cell.z);
        // Under a patch the fine cells' own outline says what is fluid.
        int patch = -1;
        uint at = 0;
        bool deep = false;
        if (deepRatio != 0) {
            // Blocks of the second level are 4 cells of the first across.
            float deepCell = cellSize / float(deepRatio);
            int side = patchSize * int(ratio);
            int3 global = int3(floor(sample / deepCell));
            int3 block = global / side;
            int found = deepPatches[block.x + int(deepBlocksX) * (block.y + int(deepBlocksY) * block.z)];
            if (found >= 0) {
                int3 local = clamp(global - block * side, 0, side - 1);
                patch = found;
                at = uint(found) * uint(side * side * side) + uint(local.x + side * (local.y + side * local.z));
                deep = true;
            }
        }
        if (ratio != 0 && !deep) {
            int3 block = cell / patchSize;
            patch = patchOfTile[block.x + int(blocksX) * (block.y + int(blocksY) * block.z)];
            int side = patchSize * int(ratio);
            int3 local = clamp(int3(floor(sample / (cellSize / float(ratio)))) - block * side, 0, side - 1);
            at = uint(max(patch, 0)) * uint(side * side * side) + uint(local.x + side * (local.y + side * local.z));
        }
        bool open = deep ? (deepMask[at] & 1) == 0 : (patch >= 0 ? (fineMask[at] & 1) == 0 : fluidMask[index] == 0);
        if (open) {
            Cell c = deep ? deepFine[at] : (patch >= 0 ? fine[at] : fluid[index]);
            float kinetic = 0.5f * (c.mx * c.mx + c.my * c.my + c.mz * c.mz) / max(c.rho, 1e-6f);
            return gasPressure(max(c.rho, 1e-6f), c.energy - kinetic, airModel, gamma) - ambient;
        }
        sample += normal * step;
    }
    return 0.0f;
}

// With refined levels' own steps, once per step after `prepareStep`, one thread: how many substeps
// each level takes in a step of the grid above, as few of the r there are as its own fastest wave
// allows (the speeds its sweeps and new patches recorded in the last step, slots 2 and 3 of
// `maxSpeed`; the first level counting the second's, as the second takes at most r in each of
// its). A level's step is then the step above over its substeps. The substeps not taken get
// dispatches of no threadgroups (`steps`, one copy of the level's dispatches per substep, the
// second level's per substep of the first), and where a level takes an odd number of sweeps its
// current state is copied back into its first buffer (`keep`), as between steps the encoder
// expects it there. With the step at zero (a batch stopped short) every substep runs, doing
// nothing, as without.
kernel void refineLevelSteps(device StepControl &control [[buffer(0)]],
                             device atomic_uint *maxSpeed [[buffer(1)]],
                             constant SolverUniforms &u [[buffer(2)]],
                             const device uint *arguments1 [[buffer(3)]],
                             device uint *steps1 [[buffer(4)]],
                             device uint *keep1 [[buffer(5)]],
                             const device uint *arguments2 [[buffer(6)]],
                             device uint *steps2 [[buffer(7)]],
                             device uint *keep2 [[buffer(8)]],
                             constant uint &levels [[buffer(9)]],
                             uint tid [[thread_position_in_grid]]) {
    if (tid != 0) {
        return;
    }
    uint r = u.refineRatio;
    float dt = control.dt;
    uint n1 = r;
    uint n2 = r;
    if (dt > 0.0f) {
        float v1 = as_type<float>(atomic_load_explicit(maxSpeed + 2, memory_order_relaxed));
        float v2 = levels > 1u ? as_type<float>(atomic_load_explicit(maxSpeed + 3, memory_order_relaxed)) : 0.0f;
        // Substeps of length dt / n at a level of cells h / r^l keep its Courant number within the
        // limit when n >= r^l dt v / (cfl h).
        float limit = u.cfl * u.dx;
        n1 = uint(clamp(ceil(float(r) * dt * max(v1, v2) / limit), 1.0f, float(r)));
        n2 = uint(clamp(ceil(float(r * r) * dt * v2 / (float(n1) * limit)), 1.0f, float(r)));
        atomic_store_explicit(maxSpeed + 2, 0u, memory_order_relaxed);
        atomic_store_explicit(maxSpeed + 3, 0u, memory_order_relaxed);
        control.levelSubstepSum0 += n1;
        control.levelSubstepSum1 += n1 * n2;
    }
    control.levelSubsteps0 = n1;
    control.levelSubsteps1 = n2;
    control.levelStep0 = dt / float(n1);
    control.levelStep1 = dt / float(n1 * n2);
    for (uint s = 0; s < r; ++s) {
        for (uint k = 0; k < 32u; ++k) {
            steps1[32u * s + k] = s < n1 ? arguments1[k] : (k % 3u == 0u ? 0u : 1u);
        }
    }
    // Every fine cell's dispatch (offset 72, the seventh) copies the state back.
    bool odd1 = (n1 * u.sweepAxes) % 2u == 1u;
    keep1[0] = odd1 ? arguments1[18] : 0u;
    keep1[1] = 1u;
    keep1[2] = 1u;
    if (levels < 2u) {
        return;
    }
    bool odd2 = (n2 * u.sweepAxes) % 2u == 1u;
    for (uint s1 = 0; s1 < r; ++s1) {
        for (uint s2 = 0; s2 < r; ++s2) {
            uint slot = s1 * r + s2;
            bool on = s1 < n1 && s2 < n2;
            for (uint k = 0; k < 32u; ++k) {
                steps2[32u * slot + k] = on ? arguments2[k] : (k % 3u == 0u ? 0u : 1u);
            }
        }
        keep2[3u * s1] = s1 < n1 && odd2 ? arguments2[18] : 0u;
        keep2[3u * s1 + 1u] = 1u;
        keep2[3u * s1 + 2u] = 1u;
    }
}

// With refined levels' own steps, after a level's substeps when it took an odd number of sweeps
// (see `refineLevelSteps`): its fluid cells' state, and their fuel and oxygen, back into the first
// of its two buffers.
kernel void refineKeepCurrent(device Cell *first [[buffer(0)]],
                              const device Cell *second [[buffer(1)]],
                              device float2 *firstSpecies [[buffer(2)]],
                              const device float2 *secondSpecies [[buffer(3)]],
                              const device uchar *fineMask [[buffer(4)]],
                              const device uint *patchList [[buffer(5)]],
                              constant SolverUniforms &u [[buffer(6)]],
                              uint gid [[thread_position_in_grid]]) {
    uint side = uint(patchSize) * u.refineRatio;
    uint cells = side * side * side;
    uint at = patchList[gid / cells] * cells + gid % cells;
    if ((fineMask[at] & 1) != 0) {
        return;
    }
    first[at] = second[at];
    if (carriesSpecies(u)) {
        firstSpecies[at] = secondSpecies[at];
    }
}


// Envelope venting in refined air: after the step a pane breaks in, the finer cells of this level
// under its coarse cells (`scale` along an edge) in patches already placed become air holding the
// still air, as `openEnvelopePanes` makes the coarse cells; patches placed later take them as air
// (`inOpenedPane` in `refineFill`). A thread a fine cell.
kernel void refineOpenPanes(device Cell *fineA [[buffer(0)]],
                            device Cell *fineB [[buffer(1)]],
                            device float2 *speciesA [[buffer(2)]],
                            device float2 *speciesB [[buffer(3)]],
                            device uchar *fineMask [[buffer(4)]],
                            device packed_float3 *fineWall [[buffer(5)]],
                            const device int *patchOfTile [[buffer(6)]],
                            const device PaneLookup *lookup [[buffer(7)]],
                            const device uint *paneStatus [[buffer(8)]],
                            constant SolverUniforms &u [[buffer(10)]],
                            const device StepControl &control [[buffer(11)]],
                            constant uint &scale [[buffer(12)]],
                            const device float4 *gravityTable [[buffer(13)]],
                            uint gid [[thread_position_in_grid]]) {
    PaneLookup panes = lookup[0];
    const device uint2 *paneCells = (const device uint2 *)(lookup + 1);
    uint per = scale * scale * scale;
    if (gid >= panes.count * per || control.dt <= 0.0f) {
        return;
    }
    uint2 entry = paneCells[gid / per];
    if (paneStatus[entry.y] != 1u) {
        return;
    }
    uint local = gid % per;
    int3 coarse = int3(entry.x % panes.nx, (entry.x / panes.nx) % panes.ny, entry.x / (panes.nx * panes.ny));
    int3 fine = coarse * int(scale) + int3(local % scale, (local / scale) % scale, local / (scale * scale));
    int3 parent = fine / int(u.refineRatio);
    int3 tile = parent / patchSize;
    if (any(tile >= int3(u.refineTileNx, u.refineTileNy, u.refineTileNz))) {
        return;
    }
    int patch = patchOfTile[tileIndex(tile, u)];
    if (patch < 0) {
        return;
    }
    uint at = fineIndex(uint(patch), fine, tile, u);
    // Already air (a pane in a wall that went first, or a fine cell the block never held).
    if ((fineMask[at] & 1u) == 0u) {
        return;
    }
    fineMask[at] = 0;
    fineWall[at] = packed_float3(0.0f);
    Cell still;
    still.rho = u.stillRho;
    still.mx = u.stillMx;
    still.my = u.stillMy;
    still.mz = u.stillMz;
    still.energy = u.stillEnergy;
    // Under gravity, the background at rest at the fine cell's height (this level's table).
    if (u.gravity != 0.0f) {
        still = gravityRestOf(gravityTable, fine.z);
    }
    fineA[at] = still;
    fineB[at] = still;
    if (carriesSpecies(u)) {
        float2 air = float2(0.0f, u.stillOxygen / u.stillRho * still.rho);
        speciesA[at] = air;
        speciesB[at] = air;
    }
}
