// A collapse's dust (`AirDust`, emmettl/bombcad-work#36; docs/whole-event.md, "Dust, stage 1"),
// appended last to the library: two classes of fines, fine and coarse, as densities (kg/m³) in each
// air cell, carried by the air's own mass fluxes and settling at their terminal speeds. Passive: the
// air and the structure never read it. Each air sweep, compiled with the dust (`airDust`), keeps the
// mass fluxes through each cell's low and high faces; `dustSweep` then moves the fines through the
// same faces, each at the mass fraction of the cell it leaves (first-order upwind), and in the
// vertical sweep lets each class fall through every face at its settling speed. A face the cell's
// air does not cross (a solid cell, the ground) takes no fines across it; what falls onto it is
// deposited and booked in the cell's ledger, as is what goes out through an open face. Fines are
// made by the structure's elements, from their fracture and crushing work, and by the rubble, from a
// share of each particle's impact losses (`dustFromElements`, `dustFromImpacts`), as whole quanta
// added to a counter for the air cell holding them; `dustInject` puts each cell's into its air. The
// ledger's counts are exact in quanta, so what was made equals what is airborne, deposited and gone
// but for the field's own rounding.

struct DustUniforms {
    float settlingFine;       // m/s
    float settlingCoarse;     // m/s
    float quantum;            // kg a quantum of the counters and the ledger
    float cellVolume;         // m³ of an air cell
    float energyPerKilogram;  // J per kilogram of fines made
    float impactShare;        // the share of the rubble's impact losses that makes fines
    uint fineShare;           // of 4096: the fine class's share of the fines made
    uint count;               // the emitting kernel's elements or particle slots
    float emitAt;             // kg: fines held back until an element or particle has this many
    uint cells;               // air cells; the totals' counters follow theirs
    uint spare0;
    uint spare1;
};

// The ledger's six counts a cell, in quanta: settled (fine, coarse), out through an open face
// (fine, coarse), made here (fine, coarse).
constant uint dustLedgerWords = 6;
// The totals counted after the cells' counters: made outside the domain, made by elements, made by
// the rubble's impacts.
constant uint dustOutside = 0;
constant uint dustByElements = 1;
constant uint dustByImpacts = 2;

static inline void dustSweepCell(int3 cell, device float2 *src, device float2 *dst, const device uchar *mask,
                                 const device float2 *massFlux, const device Cell *state,
                                 const device StepControl &control, constant SolverUniforms &u,
                                 constant DustUniforms &d, device long *ledger, device uchar *tileFlags) {
    int index = cell.x + int(u.nx) * (cell.y + int(u.ny) * cell.z);
    if (control.dt <= 0.0f) {
        // A step that does nothing swaps the two copies, as the air's sweep does its cells.
        float2 held = dst[index];
        dst[index] = src[index];
        src[index] = held;
        return;
    }
    float2 own = src[index];
    if (mask[index] != 0) {
        // Fines in a solid cell are held there until it opens.
        dst[index] = own;
        return;
    }
    uint axis = u.axis;
    int n = axis == 0 ? int(u.nx) : (axis == 1 ? int(u.ny) : int(u.nz));
    int i = cell[axis];
    int stride = axis == 0 ? 1 : (axis == 1 ? int(u.nx) : int(u.nx * u.ny));
    bool lowWall = ((u.boundaryFlags >> (2 * axis)) & 1u) != 0;
    bool highWall = ((u.boundaryFlags >> (2 * axis + 1)) & 1u) != 0;
    int kindP1 = classify(mask, index, 1, stride, i, n, lowWall, highWall);
    int kindM1 = classify(mask, index, -1, stride, i, n, lowWall, highWall);

    // The face fluxes the sweep used, kg/m²/s: through the low face as the cell below reckoned it
    // where there is one, so that the face's flux is one.
    float2 faces = massFlux[index];
    float lowMass = kindM1 == kindFluid ? massFlux[index - stride].y : faces.x;
    float highMass = faces.y;
    float2 fraction = own / max(state[index].rho, u.densityFloor);
    float2 low = float2(0.0f);
    float2 high = float2(0.0f);
    if (kindM1 == kindFluid) {
        float2 below = src[index - stride] / max(state[index - stride].rho, u.densityFloor);
        low = lowMass * (lowMass > 0.0f ? below : fraction);
    } else if (kindM1 == kindOpen) {
        low = lowMass < 0.0f ? lowMass * fraction : float2(0.0f);  // clean air beyond
    }
    if (kindP1 == kindFluid) {
        float2 above = src[index + stride] / max(state[index + stride].rho, u.densityFloor);
        high = highMass * (highMass > 0.0f ? fraction : above);
    } else if (kindP1 == kindOpen) {
        high = highMass > 0.0f ? highMass * fraction : float2(0.0f);
    }
    if (axis == 2u) {
        // Each class falls at its settling speed through the faces: into this cell from the air
        // above, and out of it through its floor, onto a solid, the ground or out of the domain.
        float2 settling = float2(d.settlingFine, d.settlingCoarse);
        if (kindP1 == kindFluid) {
            high -= settling * src[index + stride];
        }
        low -= settling * own;
    }
    // Through a face to a solid or out of the domain, whole quanta, booked in the ledger.
    float perQuantum = control.dt * u.dx * u.dx / d.quantum;
    if (kindM1 != kindFluid) {
        float2 out = rint(max(-low, 0.0f) * perQuantum);
        low = -out / perQuantum;
        uint slot = dustLedgerWords * uint(index) + (kindM1 == kindWall ? 0u : 2u);
        ledger[slot] += long(out.x);
        ledger[slot + 1] += long(out.y);
    }
    if (kindP1 != kindFluid) {
        float2 out = rint(max(high, 0.0f) * perQuantum);
        high = out / perQuantum;
        if (kindP1 == kindOpen) {
            uint slot = dustLedgerWords * uint(index) + 2u;
            ledger[slot] += long(out.x);
            ledger[slot + 1] += long(out.y);
        }
    }
    float2 result = own - control.dt / u.dx * (high - low);
    dst[index] = result;
    // A cell with fines near its tile's edge wakes the tiles they can reach next step.
    if (u.finalSweep != 0 && u.tileNx != 0 && any(result != 0.0f)) {
        int3 local = cell % tileSize;
        if (any(local < tileReach) || any(local >= tileSize - tileReach)) {
            wakeTilesAround(cell, tileFlags, tileWoken, u);
        }
    }
}

// After each air sweep: the fines through the same faces.
kernel void dustSweep(device float2 *src [[buffer(0)]],
                      device float2 *dst [[buffer(1)]],
                      const device uchar *mask [[buffer(2)]],
                      const device float2 *massFlux [[buffer(3)]],
                      const device Cell *state [[buffer(4)]],
                      const device StepControl &control [[buffer(5)]],
                      constant SolverUniforms &u [[buffer(6)]],
                      constant DustUniforms &d [[buffer(7)]],
                      device long *ledger [[buffer(8)]],
                      device uchar *tileFlags [[buffer(10)]],
                      uint3 tid [[thread_position_in_grid]]) {
    if (tid.x >= u.nx || tid.y >= u.ny || tid.z >= u.nz) {
        return;
    }
    dustSweepCell(int3(tid), src, dst, mask, massFlux, state, control, u, d, ledger, tileFlags);
}

// The same over the tiles the air's sweep takes (`sweepTiles`).
kernel void dustSweepTiles(device float2 *src [[buffer(0)]],
                           device float2 *dst [[buffer(1)]],
                           const device uchar *mask [[buffer(2)]],
                           const device float2 *massFlux [[buffer(3)]],
                           const device Cell *state [[buffer(4)]],
                           const device StepControl &control [[buffer(5)]],
                           constant SolverUniforms &u [[buffer(6)]],
                           constant DustUniforms &d [[buffer(7)]],
                           device long *ledger [[buffer(8)]],
                           const device uint *tiles [[buffer(9)]],
                           device uchar *tileFlags [[buffer(10)]],
                           uint3 group [[threadgroup_position_in_grid]],
                           uint3 local [[thread_position_in_threadgroup]],
                           uint3 groupSize [[threads_per_threadgroup]]) {
    uint tile = tiles[group.x];
    uint3 origin = uint3(tile % u.tileNx, (tile / u.tileNx) % u.tileNy, tile / (u.tileNx * u.tileNy))
        * uint(tileSize);
    for (uint z = local.z; z < uint(tileSize); z += groupSize.z) {
        uint3 cell = origin + uint3(local.x, local.y, z);
        if (cell.x < u.nx && cell.y < u.ny && cell.z < u.nz) {
            dustSweepCell(int3(cell), src, dst, mask, massFlux, state, control, u, d, ledger, tileFlags);
        }
    }
}

// After the structure's substeps: each air cell takes the fines made in it, split between the
// classes in whole quanta, and wakes the tiles round it.
kernel void dustInject(device float2 *field [[buffer(0)]],
                       device uint2 *made [[buffer(1)]],
                       device long *ledger [[buffer(2)]],
                       constant SolverUniforms &u [[buffer(3)]],
                       constant DustUniforms &d [[buffer(4)]],
                       device uchar *tileFlags [[buffer(5)]],
                       uint3 tid [[thread_position_in_grid]]) {
    if (tid.x >= u.nx || tid.y >= u.ny || tid.z >= u.nz) {
        return;
    }
    int index = int(tid.x) + int(u.nx) * (int(tid.y) + int(u.ny) * int(tid.z));
    long quanta = as_type<long>(made[index]);
    if (quanta == 0) {
        return;
    }
    made[index] = uint2(0u);
    long fine = quanta * long(d.fineShare) / 4096;
    long coarse = quanta - fine;
    field[index] += float2(float(fine), float(coarse)) * (d.quantum / d.cellVolume);
    uint slot = dustLedgerWords * uint(index) + 4u;
    ledger[slot] += fine;
    ledger[slot + 1] += coarse;
    if (u.tileNx != 0) {
        wakeTilesAround(int3(tid), tileFlags, tileWoken, u);
    }
}

// The air cell that takes fines made at `position`: the cell holding it if it is air, else the
// first cell of air round it, those above first; the solid cell itself if none is (they wait there
// until it opens); -1 outside the domain.
static inline int dustTarget(float3 position, const device uchar *mask, constant StructureUniforms &u) {
    int3 dims = int3(u.fluidNx, u.fluidNy, u.fluidNz);
    int3 cell = int3(floor(position / u.fluidCell));
    if (any(cell < 0) || any(cell >= dims)) {
        return -1;
    }
    int index = cell.x + dims.x * (cell.y + dims.y * cell.z);
    if (mask[index] == 0) {
        return index;
    }
    for (int dz = 1; dz >= -1; --dz) {
        for (int dy = -1; dy <= 1; ++dy) {
            for (int dx = -1; dx <= 1; ++dx) {
                int3 c = cell + int3(dx, dy, dz);
                if (any(c < 0) || any(c >= dims)) {
                    continue;
                }
                int near = c.x + dims.x * (c.y + dims.y * c.z);
                if (mask[near] == 0) {
                    return near;
                }
            }
        }
    }
    return index;
}

// Adds `quanta` to the counter of air cell `target` (outside the domain where it is -1), and to the
// total of their source.
static inline void dustEmit(device atomic_uint *made, int target, long quanta, uint source,
                            constant DustUniforms &d) {
    uint cell = target >= 0 ? uint(target) : d.cells + dustOutside;
    atomicAdd64(made + 2 * cell, quanta);
    atomicAdd64(made + 2 * (d.cells + source), quanta);
}

// Each air step, after the substeps: an element's fines from the fracture and crushing work its
// trace (`tracesWork`) has gained. Its state (`sources`, two float4s each): for its fracture and
// crushing work, and for its work in all, the trace's sum when last read (zeroed when the trace is
// folded, `StructureSolver.workTotals`), that work summed since the dust began, and the most it has
// reached; and the fines made and not yet given to the air, kg. Fines are made from the rise of the
// fracture and crushing work past the most it had reached, but only as far as the element's work in
// all rises past its own: work given back (a crack closing, unloading on a cracked plane) makes none,
// and nor does work the trace moves between its channels in an element at rest, which leaves its
// total as it was (the midpoint trace shares its correction among the channels in proportion).
kernel void dustFromElements(const device float *work [[buffer(0)]],
                             device float4 *sources [[buffer(1)]],
                             const device uint *elementList [[buffer(2)]],
                             const device uint *nodeMap [[buffer(3)]],
                             const device StructureNode *nodes [[buffer(4)]],
                             const device uint *nodeList [[buffer(5)]],
                             const device uchar *fluidMask [[buffer(6)]],
                             device atomic_uint *made [[buffer(7)]],
                             constant StructureUniforms &u [[buffer(8)]],
                             constant DustUniforms &d [[buffer(9)]],
                             uint compact [[thread_position_in_grid]]) {
    if (compact >= d.count) {
        return;
    }
    const device float *w = work + compact * workChannels;
    // Concrete's fracture and crushing, as the census counts them, less the bars' share of the
    // cracks' shear (dowel action and kinking): cracks opened and sheared, and crushing.
    float fracture = w[workTensionCracked] + w[workTensionHairline] + w[workCrackShear] + w[workCrackShearPressed]
        + w[workInterlock] + w[workInterlockPressed] + w[workCompressionCrushed];
    float total = 0.0f;
    for (uint c = 0; c < workChannels; ++c) {
        total += w[c];
    }
    float4 f = sources[2 * compact];
    float4 a = sources[2 * compact + 1];
    if (fracture == f.x && total == a.x) {
        return;
    }
    f.y += fracture - f.x;
    f.x = fracture;
    a.y += total - a.x;
    a.x = total;
    float rise = 0.0f;
    float riseAll = 0.0f;
    if (f.y > f.z) {
        rise = f.y - f.z;
        f.z = f.y;
    }
    if (a.y > a.z) {
        riseAll = a.y - a.z;
        a.z = a.y;
    }
    f.w += min(rise, riseAll) / d.energyPerKilogram;
    if (f.w >= d.emitAt) {
        long quanta = long(floor(f.w / d.quantum));
        f.w -= float(quanta) * d.quantum;
        uint element = elementList[compact];
        uint3 tid = uint3(element % u.ex, (element / u.ex) % u.ey, element / (u.ex * u.ey));
        float3 centre = float3(0.0f);
        for (uint c = 0; c < 8; ++c) {
            uint3 corner = tid + uint3(c & 1u, (c >> 1) & 1u, (c >> 2) & 1u);
            centre += nodePosition(nodeMap[corner.x + (u.ex + 1) * (corner.y + (u.ey + 1) * corner.z)], nodeList,
                                   nodes, u);
        }
        dustEmit(made, dustTarget(0.125f * centre, fluidMask, u), quanta, dustByElements, d);
    }
    sources[2 * compact] = f;
    sources[2 * compact + 1] = a;
}

// Each air step, after the substeps: a rubble particle's fines from a share of the impact losses
// `rubbleMove` has added up (`impacts`, a float4 each: contact's and the ground's work on it since
// it was made, the least that has reached, the losses past it not yet turned to fines, J, and the
// fines not yet given to the air, kg).
kernel void dustFromImpacts(const device RubbleParticle *particles [[buffer(0)]],
                            device float4 *impacts [[buffer(1)]],
                            const device uint *state [[buffer(2)]],
                            const device uchar *fluidMask [[buffer(3)]],
                            device atomic_uint *made [[buffer(4)]],
                            constant StructureUniforms &u [[buffer(5)]],
                            constant DustUniforms &d [[buffer(6)]],
                            uint index [[thread_position_in_grid]]) {
    if (index >= d.count || !rubbleInUse(state, index)) {
        return;
    }
    float4 s = impacts[index];
    if (s.z <= 0.0f) {
        return;
    }
    s.w += d.impactShare * s.z / d.energyPerKilogram;
    s.z = 0.0f;
    if (s.w >= d.emitAt) {
        long quanta = long(floor(s.w / d.quantum));
        s.w -= float(quanta) * d.quantum;
        dustEmit(made, dustTarget(float3(particles[index].position), fluidMask, u), quanta, dustByImpacts, d);
    }
    impacts[index] = s;
}
