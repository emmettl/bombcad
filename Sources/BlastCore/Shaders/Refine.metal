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

constant int haloDepth = 2;
constant int haloSide = 8;  // patchSize + 2 haloDepth
constant uint haloCells = 512;
constant uint freePatch = 0xFFFFFFFFu;

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
                            float alpha, constant SolverUniforms &u) {
    Cell now = coarse[cell.x + int(u.nx) * (cell.y + int(u.ny) * cell.z)];
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

// Fine cell `fine` filled from the coarse air around it: the coarse cell it lies in, plus
// minmod-limited slopes towards its fluid neighbours. The slopes' offsets sum to zero over a
// coarse cell's fine cells, so their mean is the coarse cell. Where that would leave density or
// pressure below the floors, the coarse cell alone.
static inline Cell prolong(int3 fine, int3 tile, uint patch, const device Cell *coarse, const device Cell *halo,
                           const device uchar *mask, float alpha, constant SolverUniforms &u) {
    int r = int(u.refineRatio);
    int3 cell = fine / r;
    int3 dims = int3(u.nx, u.ny, u.nz);
    Cell c = coarseAt(cell, tile, patch, coarse, halo, alpha, u);
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
        if (below[axis] >= 0 && mask[below.x + dims.x * (below.y + dims.y * below.z)] == 0) {
            lo = coarseAt(below, tile, patch, coarse, halo, alpha, u);
        }
        if (above[axis] < dims[axis] && mask[above.x + dims.x * (above.y + dims.y * above.z)] == 0) {
            hi = coarseAt(above, tile, patch, coarse, halo, alpha, u);
        }
        float o = offset[axis];
        result.rho += o * limitedSlope(c.rho - lo.rho, hi.rho - c.rho, 1.0f);
        result.mx += o * limitedSlope(c.mx - lo.mx, hi.mx - c.mx, 1.0f);
        result.my += o * limitedSlope(c.my - lo.my, hi.my - c.my, 1.0f);
        result.mz += o * limitedSlope(c.mz - lo.mz, hi.mz - c.mz, 1.0f);
        result.energy += o * limitedSlope(c.energy - lo.energy, hi.energy - c.energy, 1.0f);
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
static inline int fineKind(int3 fine, int n, const device uchar *mask, constant SolverUniforms &u) {
    uint axis = u.axis;
    if (fine[axis] < 0) {
        return ((u.boundaryFlags >> (2 * axis)) & 1u) != 0 ? kindWall : kindOpen;
    }
    if (fine[axis] >= n) {
        return ((u.boundaryFlags >> (2 * axis + 1)) & 1u) != 0 ? kindWall : kindOpen;
    }
    int3 cell = fine / int(u.refineRatio);
    return mask[cell.x + int(u.nx) * (cell.y + int(u.ny) * cell.z)] != 0 ? kindWall : kindFluid;
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
    int3 local = cell - int3(u.regionX, u.regionY, u.regionZ);
    int3 dims = int3(u.regionNx, u.regionNy, u.regionNz);
    if (any(local < 0) || any(local >= dims)) {
        return float3(0.0f);
    }
    uint at = 3u * uint(local.x + dims.x * (local.y + dims.y * local.z));
    return float3(wallVelocity[at], wallVelocity[at + 1], wallVelocity[at + 2]);
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
enum GhostKind { ghostFine = 0, ghostCoarse = 1, ghostWall = 2, ghostOpen = 3 };

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
                         uint gid [[thread_position_in_grid]]) {
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
    int kind = fineKind(fine, n, mask, u);
    bool inDomain = fine[axis] >= 0 && fine[axis] < n;
    // Inside the domain, a cell a neighbouring patch holds is solid or fluid by that patch's own
    // outline, whatever its coarse cell is; asking the coarse cell would make the two patches
    // disagree about the face between them, and gain or lose energy through it.
    int3 cell = fine / int(u.refineRatio);
    int3 home = cell / patchSize;
    int holder = inDomain ? patchOfTile[tileIndex(home, u)] : -1;
    if (kind != kindFluid && holder < 0) {
        ghostKinds[index] = kind == kindWall ? ghostWall : ghostOpen;
        if (kind == kindWall) {
            // A solid cell inside the domain may be moving; a reflecting face of the domain is not.
            ghosts[index].mx = inDomain ? wallSpeedOf(wallVelocity, cell, u) : 0.0f;
        }
        return;
    }
    if (holder >= 0) {
        // Held by a neighbouring patch, whose own outline decides whether it is solid.
        uint there = fineIndex(uint(holder), fine, home, u);
        if ((fineMask[there] & 1) != 0) {
            ghostKinds[index] = ghostWall;
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
    Cell outside = prolong(fine, tile, patch, coarse, halo, mask, u.refineAlpha, u);
    ghosts[index] = outside;
    ghostKinds[index] = ghostCoarse;
    if (u.afterburnEnergy > 0.0f) {
        // At the coarse cell's mass fractions, as they are at the step's end.
        int at = cell.x + dims.x * (cell.y + dims.y * cell.z);
        ghostSpecies[index] = coarseSpecies[at] / max(coarse[at].rho, u.densityFloor) * outside.rho;
    }
    // Unrefined fluid beside a patch's face, where the fine cell inside is solid: the coarse cell
    // used a flux through that face, which refluxing must replace with what the fine level has
    // there, the wall's (the fine sweep adds the fluxes of fine cells that are fluid).
    if (layer == 1u || layer == 2u) {
        int3 inside = local;
        inside[axis] = layer == 1u ? 0 : int(side) - 1;
        uint own = patch * side * side * side + uint(inside.x + int(side) * (inside.y + int(side) * inside.z));
        if ((fineMask[own] & 1) != 0) {
            Prim w = primOf(outside, u);
            Prim wall = mirrored(w, float3(fineWall[own])[axis]);
            Flux f = layer == 1u ? riemannFlux(w, wall, u) : riemannFlux(wall, w, u);
            uint face = 2u * axis + (layer == 1u ? 0u : 1u);
            addFlux(fineFlux, registerSlot(patch, face, a, b, side), f, axis, control.dt / float(u.refineRatio));
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
                                 device float *speciesFluxSums) {
    int r = int(u.refineRatio);
    int shift = r == 2 ? 1 : 2;
    int side = patchSize * r;
    int3 fine = tile * side + local;
    int3 dims = int3(u.nx, u.ny, u.nz);
    int3 cell = fine >> shift;
    if (any(cell >= dims)) {
        return;
    }
    int coarseIndex = cell.x + dims.x * (cell.y + dims.y * cell.z);
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

    // The kind of the cell `offset` along the sweep, its state if fluid, and its speed along the
    // sweep if a wall.
    auto look = [&](int offset, thread Prim &w, thread float &speed) {
        speed = 0.0f;
        int along = local[axis] + offset;
        if (along >= 0 && along < side) {
            int3 g = fine;
            g[axis] += offset;
            if (g[axis] >= n) {
                return ((u.boundaryFlags >> (2 * axis + 1)) & 1u) != 0 ? int(kindWall) : int(kindOpen);
            }
            if ((fineMask[index + offset * stride] & 1) != 0) {
                speed = float3(fineWall[index + offset * stride])[axis];
                return int(kindWall);
            }
            w = primOf(fineSrc[index + offset * stride], u);
            return int(kindFluid);
        }
        uint layer = along < 0 ? uint(along + 2) : uint(along - side + 2);
        uint g = ghostIndex(patch, layer, a, b, uint(side));
        uchar kind = ghostKinds[g];
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
    Prim wP1 = w0;
    float speedP1;
    int kindP1 = look(1, wP1, speedP1);
    if (kindP1 == kindWall) {
        wP1 = mirrored(w0, speedP1);
    } else if (kindP1 == kindOpen) {
        wP1 = w0;
    }
    Prim wM1 = w0;
    float speedM1;
    int kindM1 = look(-1, wM1, speedM1);
    if (kindM1 == kindWall) {
        wM1 = mirrored(w0, speedM1);
    } else if (kindM1 == kindOpen) {
        wM1 = w0;
    }
    Prim wP2 = wP1;
    if (kindP1 == kindWall) {
        wP2 = mirrored(wM1, speedP1);
    } else if (kindP1 == kindFluid) {
        Prim w = wP1;
        float speed;
        int kind = look(2, w, speed);
        if (kind == kindFluid) {
            wP2 = w;
        } else if (kind == kindWall) {
            wP2 = mirrored(wP1, speed);
        }
    }
    Prim wM2 = wM1;
    if (kindM1 == kindWall) {
        wM2 = mirrored(wP1, speedM1);
    } else if (kindM1 == kindFluid) {
        Prim w = wM1;
        float speed;
        int kind = look(-2, w, speed);
        if (kind == kindFluid) {
            wM2 = w;
        } else if (kind == kindWall) {
            wM2 = mirrored(wM1, speed);
        }
    }

    float dt = control.dt / float(r);
    float lambda = dt / (u.dx / float(r));
    Flux fluxLow;
    Flux fluxHigh;
    stencilFluxes(wM2, wM1, w0, wP1, wP2, lambda, u, fluxLow, fluxHigh);

    // A fine cell on the patch's face, beside unrefined fluid, adds up the flux through it.
    if (local[axis] == 0 && ghostKinds[ghostIndex(patch, 1u, a, b, uint(side))] == ghostCoarse) {
        addFlux(fineFlux, registerSlot(patch, 2u * axis, a, b, uint(side)), fluxLow, axis, dt);
    }
    if (local[axis] == side - 1 && ghostKinds[ghostIndex(patch, 2u, a, b, uint(side))] == ghostCoarse) {
        addFlux(fineFlux, registerSlot(patch, 2u * axis + 1u, a, b, uint(side)), fluxHigh, axis, dt);
    }

    float3 momentum = toSweep(float3(c.mx, c.my, c.mz), axis);
    float rho = c.rho - lambda * (fluxHigh.mass - fluxLow.mass);
    momentum -= lambda * (fluxHigh.momentum - fluxLow.momentum);
    float energy = c.energy - lambda * (fluxHigh.energy - fluxLow.energy);

    // Fuel and oxygen, as in `sweepCell`: at the mass fraction of the cell they leave, burnt
    // after the substep's final sweep.
    if (u.afterburnEnergy > 0.0f) {
        float2 own = speciesSrc[index];
        float2 fraction = own / max(c.rho, u.densityFloor);
        auto speciesAt = [&](int offset, int kind, Prim w) {
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
        if (local[axis] == 0 && ghostKinds[ghostIndex(patch, 1u, a, b, uint(side))] == ghostCoarse) {
            uint slot = speciesSlot(patch, 2u * axis, a, b, uint(side));
            speciesFluxSums[slot] += inflow.x * dt;
            speciesFluxSums[slot + 1] += inflow.y * dt;
        }
        if (local[axis] == side - 1 && ghostKinds[ghostIndex(patch, 2u, a, b, uint(side))] == ghostCoarse) {
            uint slot = speciesSlot(patch, 2u * axis + 1u, a, b, uint(side));
            speciesFluxSums[slot] += outflow.x * dt;
            speciesFluxSums[slot + 1] += outflow.y * dt;
        }
        float2 species = max(own - lambda * (outflow - inflow), 0.0f);
        if (u.finalSweep != 0) {
            float fuel = burnt(species, dt, u);
            species.x -= fuel;
            species.y -= fuel * u.oxygenPerFuel;
            energy += fuel * u.afterburnEnergy;
        }
        speciesDst[index] = species;
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
        recordCell(maxSpeed, momentum, rho, pressure, u);
        float overpressure = pressure - u.ambientPressure;
        if (overpressure > 0.0f) {
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
                      speciesDst, ghostSpecies, speciesFluxSums);
    }
}

// Step 1: the coarse cells around each patch, as they are at the start of the step.
kernel void refineSaveHalo(const device Cell *coarse [[buffer(0)]],
                           device Cell *halo [[buffer(1)]],
                           constant SolverUniforms &u [[buffer(2)]],
                           const device uint *tileOfPatch [[buffer(3)]],
                           const device uint *patchList [[buffer(4)]],
                           const device StepControl &control [[buffer(5)]],
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
    halo[patch * haloCells + h] = coarse[cell.x + int(u.nx) * (cell.y + int(u.ny) * cell.z)];
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
    int outsideIndex = outside.x + dims.x * (outside.y + dims.y * outside.z);
    // Whatever the coarse cell inside is, the outside cell recorded the flux it used, fluid or
    // wall, and the fine level has a flux for every fine face (the wall's where the fine cell is
    // solid), so the two always correspond.
    if (mask[outsideIndex] != 0 || patchAt(outside, patchOfTile, u) >= 0) {
        return;
    }
    uint slot = registerSlot(patch, face, uint(a), uint(b), uint(patchSize));
    // The fine faces each have 1 / r^2 of the coarse face's area.
    float area = 1.0f / float(r * r);
    float sign = high != 0 ? 1.0f : -1.0f;  // the outside cell lies above the face, or below
    float scale = sign / u.dx;
    Cell c = coarse[outsideIndex];
    c.rho += scale * (area * sums[0] - coarseFlux[slot]);
    c.mx += scale * (area * sums[1] - coarseFlux[slot + 1]);
    c.my += scale * (area * sums[2] - coarseFlux[slot + 2]);
    c.mz += scale * (area * sums[3] - coarseFlux[slot + 3]);
    c.energy += scale * (area * sums[4] - coarseFlux[slot + 4]);
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
    int index = cell.x + dims.x * (cell.y + dims.y * cell.z);
    int r = int(u.refineRatio);
    float largest = 0.0f;
    for (int n = 0; n < r * r * r; ++n) {
        uint child = fineIndex(patch, cell * r + int3(n % r, (n / r) % r, n / (r * r)), tile, u);
        largest = max(largest, (fineMask[child] & 1) == 0 ? fineImpulse[child] : 0.0f);
    }
    impulse[index] = impulseBase[patch * perPatch + position] + largest;
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
    int index = cell.x + dims.x * (cell.y + dims.y * cell.z);
    uchar solid = mask[index] != 0 ? 1 : 0;
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

// How close, in coarse cells, a sharp jump must come to a block of cells for that block to be
// refined too. A shock moves under half a cell a step, and the patches are placed afresh every
// step, so it cannot leave the refined blocks before they follow it.
constant int refineReach = 2;

// Marks the block holding `cell`, and every block within `refineReach` cells of it.
static inline void flagAround(int3 cell, device uchar *wanted, constant SolverUniforms &u) {
    int3 dims = int3(u.nx, u.ny, u.nz);
    int3 low = max(cell - refineReach, 0) / patchSize;
    int3 high = min(cell + refineReach, dims - 1) / patchSize;
    for (int z = low.z; z <= high.z; ++z) {
        for (int y = low.y; y <= high.y; ++y) {
            for (int x = low.x; x <= high.x; ++x) {
                wanted[tileIndex(int3(x, y, z), u)] = 1;
            }
        }
    }
}

// Step 7a: a tile is wanted where the pressure of a cell in it and of a neighbour differ by more
// than `refineThreshold` of the lower, or where such a pair lies within `refineReach` cells.
static inline void flagCell(int3 cell, const device Cell *coarse, const device uchar *mask, device uchar *wanted,
                            constant SolverUniforms &u) {
    int3 dims = int3(u.nx, u.ny, u.nz);
    int index = cell.x + dims.x * (cell.y + dims.y * cell.z);
    if (mask[index] != 0) {
        return;
    }
    float p = cellPressureOf(coarse[index], u);
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
                       uint3 tid [[thread_position_in_grid]]) {
    if (control.dt <= 0.0f || tid.x >= u.nx || tid.y >= u.ny || tid.z >= u.nz) {
        return;
    }
    flagCell(int3(tid), coarse, mask, wanted, u);
}

// The same over the awake tiles alone, as `sweepTiles` (still air has nothing to flag).
kernel void refineFlagTiles(const device Cell *coarse [[buffer(0)]],
                            const device uchar *mask [[buffer(1)]],
                            device uchar *wanted [[buffer(2)]],
                            constant SolverUniforms &u [[buffer(3)]],
                            const device StepControl &control [[buffer(4)]],
                            const device uint *tiles [[buffer(5)]],
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
            flagCell(int3(cell), coarse, mask, wanted, u);
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

// Step 7c, per block: gives each newly wanted block a patch from the pool while any are left, and
// wakes the tiles of still air holding it and the coarse cells around it, which must record their
// fluxes through its faces. The flags are cleared for the next step.
kernel void refineAllocate(device int *patchOfTile [[buffer(0)]],
                           device uint *tileOfPatch [[buffer(1)]],
                           const device uint *freeStack [[buffer(2)]],
                           device atomic_int *counters [[buffer(3)]],
                           device uchar *wanted [[buffer(4)]],
                           device uint *newPatches [[buffer(5)]],
                           device uchar *tileFlags [[buffer(6)]],
                           constant SolverUniforms &u [[buffer(7)]],
                           const device StepControl &control [[buffer(8)]],
                           device uint *pinned [[buffer(9)]],
                           uint tid [[thread_position_in_grid]]) {
    uint tiles = u.refineTileNx * u.refineTileNy * u.refineTileNz;
    if (control.dt <= 0.0f || tid >= tiles || wanted[tid] == 0) {
        return;
    }
    wanted[tid] = 0;
    int3 tile = tileCoordinates(tid, u);
    if (patchOfTile[tid] < 0) {
        int top = atomic_fetch_sub_explicit(&counters[0], 1, memory_order_relaxed);
        if (top <= 0) {
            atomic_fetch_add_explicit(&counters[0], 1, memory_order_relaxed);  // the pool is used up
            return;
        }
        uint patch = freeStack[top - 1];
        patchOfTile[tid] = int(patch);
        tileOfPatch[patch] = tid;
        pinned[patch] = 0;
        newPatches[atomic_fetch_add_explicit(&counters[1], 1, memory_order_relaxed)] = patch;
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

// Step 7f: fills each new patch from the coarse air (at the step's end).
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
    int3 dims = int3(u.nx, u.ny, u.nz);
    int index = cell.x + dims.x * (cell.y + dims.y * cell.z);
    // The fine outline: rigid blocks by whether the fine cell's centre lies in one (or, without
    // a list of them, as the coarse cell is), and the structure as the coarse cell has it until
    // the structure's own fine pass (`refineRemaskPrepare`) refines it.
    bool rigid = false;
    if (boxCount > 0) {
        float3 centre = (float3(fineCoordinates) + 0.5f) * (u.dx / float(r));
        for (uint n = 0; n < boxCount && !rigid; ++n) {
            rigid = all(centre >= boxes[2 * n].xyz) && all(centre <= boxes[2 * n + 1].xyz);
        }
    } else {
        rigid = rigidMask[index] != 0;
    }
    bool structure = mask[index] != 0 && rigidMask[index] == 0;
    uint at = patch * cells + position;
    fineMask[at] = (rigid || structure ? 1 : 0) | (rigid ? 2 : 0);
    fineWall[at] = structure ? wallVelocityOf(wallVelocity, cell, u) : float3(0.0f);
    if (mask[index] == 0) {
        fine[at] = prolong(fineCoordinates, tile, patch, coarse, coarse, mask, 1.0f, u);
    } else {
        // A fine cell of air in a coarse cell that is solid: air the coarse cells could not see,
        // which has held the still air the domain was filled with. (The mean of the air beside it
        // would copy the hottest gas into it, beside a charge, and add energy.)
        Cell still;
        still.rho = u.stillRho;
        still.mx = u.stillMx;
        still.my = u.stillMy;
        still.mz = u.stillMz;
        still.energy = u.stillEnergy;
        fine[at] = still;
    }
    if (u.afterburnEnergy > 0.0f) {
        // At the coarse cell's mass fractions, so that the fine cells' mean is the coarse cell's.
        fineSpecies[at] = mask[index] == 0
            ? coarseSpecies[index] / max(coarse[index].rho, u.densityFloor) * fine[at].rho
            : float2(0.0f, u.stillOxygen);
    }
    fineImpulse[at] = 0.0f;
    // The first fine cell of each coarse cell keeps the impulse the coarse cell had so far.
    if (all(fineCoordinates == cell * int(r))) {
        int3 inPatch = cell - tile * patchSize;
        uint coarseCell = uint(inPatch.x + patchSize * (inPatch.y + patchSize * inPatch.z));
        impulseBase[patch * uint(patchSize * patchSize * patchSize) + coarseCell] = impulse[index];
        seenMask[patch * uint(patchSize * patchSize * patchSize) + coarseCell] = mask[index] != 0 ? 1 : 0;
    }
}

// After `refineFill`, per coarse cell of each new patch: where its fine outline differs from its
// own, the gas the coarse cell held over the fine cells that are solid is shared among those that
// are fluid, so that placing the patch neither loses nor gains gas, and the patch is pinned.
kernel void refineFillConserve(device Cell *fine [[buffer(0)]],
                               const device uchar *mask [[buffer(1)]],
                               constant SolverUniforms &u [[buffer(2)]],
                               const device uint *tileOfPatch [[buffer(3)]],
                               const device uint *newPatches [[buffer(4)]],
                               const device uchar *fineMask [[buffer(5)]],
                               device uint *pinned [[buffer(6)]],
                               device float2 *fineSpecies [[buffer(7)]],
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
    bool coarseSolid = mask[cell.x + dims.x * (cell.y + dims.y * cell.z)] != 0;
    int fluid = 0;
    Cell lost = {0.0f, 0.0f, 0.0f, 0.0f, 0.0f};
    float2 lostSpecies = float2(0.0f);
    bool species = u.afterburnEnergy > 0.0f;
    for (int n = 0; n < all; ++n) {
        uint child = fineIndex(patch, cell * r + int3(n % r, (n / r) % r, n / (r * r)), tile, u);
        if ((fineMask[child] & 1) == 0) {
            fluid += 1;
        } else if (!coarseSolid) {
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
// steeply for the mean over a coarse cell to stand for it.
static inline float overpressureAlong(float3 point, float3 normal, float offset, int reach, const device Cell *fluid,
                                      const device uchar *fluidMask, const device int *patchOfTile,
                                      const device Cell *fine, const device uchar *fineMask, uint ratio, uint blocksX,
                                      uint blocksY, float cellSize, int3 dims, uint airModel, float gamma,
                                      float ambient) {
    float step = ratio != 0 ? cellSize / float(ratio) : cellSize;
    int steps = ratio != 0 ? reach * int(ratio) : reach;
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
        if (ratio != 0) {
            int3 block = cell / patchSize;
            patch = patchOfTile[block.x + int(blocksX) * (block.y + int(blocksY) * block.z)];
            int side = patchSize * int(ratio);
            int3 local = clamp(int3(floor(sample / step)) - block * side, 0, side - 1);
            at = uint(max(patch, 0)) * uint(side * side * side) + uint(local.x + side * (local.y + side * local.z));
        }
        if (patch >= 0 ? (fineMask[at] & 1) == 0 : fluidMask[index] == 0) {
            Cell c = patch >= 0 ? fine[at] : fluid[index];
            float kinetic = 0.5f * (c.mx * c.mx + c.my * c.my + c.mz * c.mz) / max(c.rho, 1e-6f);
            return gasPressure(max(c.rho, 1e-6f), c.energy - kinetic, airModel, gamma) - ambient;
        }
        sample += normal * step;
    }
    return 0.0f;
}
