// The air's sweeps, appended to Solver.metal at compile time (ShaderLibrary): one cell's update
// along an axis, and the kernels that sweep the grid or its tiles of moving air.

// One-dimensional MUSCL-Hancock update of one cell along `u.axis`.
static inline void sweepCell(int3 cell, device Cell *src, device Cell *dst, const device uchar *mask,
                             device float *peak, device float *impulse, const device StepControl &control,
                             device atomic_uint *maxSpeed, constant SolverUniforms &u,
                             const device float *wallVelocity, device uchar *tileFlags,
                             device float2 *speciesSrc, device float2 *speciesDst,
                             const device int *patchOfTile, device float *coarseFlux,
                             device float *coarseSpeciesFlux, const device uchar *boxMask, device float *boxImpulse,
                             const device float4 *gravityTable, const device float *viscosity,
                             const device uint4 *cutColumns, const device float4 *cutRecords,
                             const device float4 *cutWalls, device float4 *cutDefects, const device uint *cutCeilings,
                             const device float4 *congestion, const device int *structureCutIndex,
                             const device float4 *structureCutRecords, const device float4 *structureCutWalls,
                             device float4 *structureCutDefects) {
    int index = cell.x + int(u.nx) * (cell.y + int(u.ny) * cell.z);
    // With cut cells, whether this cell lies below the highest the cut cells' work reaches over its
    // tile's columns (`TerrainCutGeometry.tileCeilings`): above it there is none to do.
    bool nearCut = cutCells
        && cell.z < int(cutCeilings[uint(cell.x / tileSize) + (u.nx + uint(tileSize) - 1u) / uint(tileSize) * uint(cell.y / tileSize)]);
    if (control.dt <= 0.0f) {
        // A step that does nothing (past the time limit) swaps the two buffers' cells, solid
        // ones included, as the host swaps the buffers: the air is then exactly as if the step
        // had never been encoded.
        Cell held = dst[index];
        dst[index] = src[index];
        src[index] = held;
        if (carriesSpecies(u)) {
            float2 species = speciesDst[index];
            speciesDst[index] = speciesSrc[index];
            speciesSrc[index] = species;
        }
        return;
    }
    if (mask[index] != 0) {
        return;
    }

    uint axis = u.axis;
    int n = axis == 0 ? int(u.nx) : (axis == 1 ? int(u.ny) : int(u.nz));
    int i = cell[axis];
    int stride = axis == 0 ? 1 : (axis == 1 ? int(u.nx) : int(u.nx * u.ny));
    bool lowWall = ((u.boundaryFlags >> (2 * axis)) & 1u) != 0;
    bool highWall = ((u.boundaryFlags >> (2 * axis + 1)) & 1u) != 0;

    // Five-cell stencil with walls replaced by mirrored ghosts and open faces by copies.
    Prim w0 = loadPrim(src, index, u);
    int kindP1 = classify(mask, index, 1, stride, i, n, lowWall, highWall);
    int kindM1 = classify(mask, index, -1, stride, i, n, lowWall, highWall);
    // A structure's face closed between two cells of air (a wall thinner than two cells leaves
    // air either side of it) is a wall to the stencil, as a solid cell is, so that neither side
    // reads the other's air through it.
    if (structureCut) {
        if (kindP1 == kindFluid && structureClosedBelow(structureCutIndex, structureCutRecords, index + stride, axis)) {
            kindP1 = kindWall;
        }
        if (kindM1 == kindFluid && structureClosedBelow(structureCutIndex, structureCutRecords, index, axis)) {
            kindM1 = kindWall;
        }
    }

    float speedP1 = kindP1 == kindWall ? wallSpeed(wallVelocity, cell, 1, u) : 0.0f;
    float speedM1 = kindM1 == kindWall ? wallSpeed(wallVelocity, cell, -1, u) : 0.0f;

    // With gravity, the cell each state came from (offsets M2, M1, P1, P2) and -1 for a mirror.
    int4 from = int4(-2, -1, 1, 2);
    float4 mirror = float4(1.0f);
    Prim wP1 = w0;
    if (kindP1 == kindFluid) {
        wP1 = loadPrim(src, index + stride, u);
    } else if (kindP1 == kindWall) {
        wP1 = mirrored(w0, speedP1);
        from.z = 0;
        mirror.z = -1.0f;
    } else {
        if (farFieldFaces(u)) { wP1 = farFieldGhost(w0, 1.0f, u); }
        from.z = 0;
    }
    Prim wM1 = w0;
    if (kindM1 == kindFluid) {
        wM1 = loadPrim(src, index - stride, u);
    } else if (kindM1 == kindWall) {
        wM1 = mirrored(w0, speedM1);
        from.y = 0;
        mirror.y = -1.0f;
    } else {
        if (farFieldFaces(u)) { wM1 = farFieldGhost(w0, -1.0f, u); }
        from.y = 0;
    }

    Prim wP2 = wP1;
    if (kindP1 == kindWall) {
        wP2 = mirrored(wM1, speedP1);
        from.w = from.y;
        mirror.w = -mirror.y;
    } else if (kindP1 == kindFluid) {
        int kind = classify(mask, index, 2, stride, i, n, lowWall, highWall);
        if (structureCut && kind == kindFluid
            && structureClosedBelow(structureCutIndex, structureCutRecords, index + 2 * stride, axis)) {
            kind = kindWall;
        }
        if (kind == kindFluid) {
            wP2 = loadPrim(src, index + 2 * stride, u);
        } else if (kind == kindWall) {
            wP2 = mirrored(wP1, wallSpeed(wallVelocity, cell, 2, u));
            from.w = 1;
            mirror.w = -1.0f;
        } else {
            // An open face beyond the next cell: its ghost as that cell builds it (`farFieldGhost`
            // of its state), so that both cells reconstruct the face between them alike and the
            // flux through it is one. A copy here left the two fluxes apart wherever the ghost
            // differed: a tube's far-field ends took in mass without the oxygen it carried.
            if (farFieldFaces(u)) { wP2 = farFieldGhost(wP1, 1.0f, u); }
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
        int kind = classify(mask, index, -2, stride, i, n, lowWall, highWall);
        if (structureCut && kind == kindFluid
            && structureClosedBelow(structureCutIndex, structureCutRecords, index - stride, axis)) {
            kind = kindWall;
        }
        if (kind == kindFluid) {
            wM2 = loadPrim(src, index - 2 * stride, u);
        } else if (kind == kindWall) {
            wM2 = mirrored(wM1, wallSpeed(wallVelocity, cell, -2, u));
            from.x = -1;
            mirror.x = -1.0f;
        } else {
            // As above, the open face beyond the previous cell.
            if (farFieldFaces(u)) { wM2 = farFieldGhost(wM1, -1.0f, u); }
            from.x = -1;
        }
    } else {
        from.x = from.y;
    }

    // A cut cell's solid neighbours stand for its wall, which faces along the cell's normal, not along
    // the sweep: a ghost beside a cut cell mirrors that cell's state (or, two away, the state as far
    // the other side of it) about the cut cell's normal. Every thread that needs a ghost builds it
    // by the same rule from the same cell, so both cells beside a face work out the same flux.
    if (nearCut) {
        int3 above = cell;
        int3 below = cell;
        int3 above2 = cell;
        int3 below2 = cell;
        above[axis] += 1;
        below[axis] -= 1;
        above2[axis] += 2;
        below2[axis] -= 2;
        bool cutHere = cutCellHere(cell, cutColumns, u);
        bool groundP1 = kindP1 == kindWall && cutHere && terrainSolid(above, cutColumns, u);
        bool groundM1 = kindM1 == kindWall && cutHere && terrainSolid(below, cutColumns, u);
        if (groundP1 || groundM1) {
            float3 normal = cutNormalOf(cell, cutColumns, cutWalls, axis, u);
            if (groundP1) {
                wP1 = mirroredAbout(w0, normal);
            }
            if (groundM1) {
                wM1 = mirroredAbout(w0, normal);
            }
            // The ghost beyond each wall mirrors the near ghost across the cell from it, as it
            // now stands, by that wall's own rule: a block's plainly, the terrain's about the
            // normal. (Built from the near ghost as it stood before, beside a block on one side
            // and the ground on the other, the face's two states were no longer each other's
            // mirror, and gas passed through the block's face.)
            if (kindP1 == kindWall) {
                wP2 = groundP1 ? mirroredAbout(wM1, normal) : mirrored(wM1, speedP1);
            }
            if (kindM1 == kindWall) {
                wM2 = groundM1 ? mirroredAbout(wP1, normal) : mirrored(wP1, speedM1);
            }
        }
        if (kindP1 == kindFluid && classify(mask, index, 2, stride, i, n, lowWall, highWall) == kindWall
            && terrainSolid(above2, cutColumns, u) && cutCellHere(above, cutColumns, u)) {
            wP2 = mirroredAbout(wP1, cutNormalOf(above, cutColumns, cutWalls, axis, u));
        }
        if (kindM1 == kindFluid && classify(mask, index, -2, stride, i, n, lowWall, highWall) == kindWall
            && terrainSolid(below2, cutColumns, u) && cutCellHere(below, cutColumns, u)) {
            wM2 = mirroredAbout(wM1, cutNormalOf(below, cutColumns, cutWalls, axis, u));
        }
    }

    float dt = control.dt;
    float lambda = dt / u.dx;
    Flux fluxLow;
    Flux fluxHigh;
    bool gravityHere = airGravity && axis == 2u;
    if (gravityHere) {
        stencilFluxesGravity(wM2, wM1, w0, wP1, wP2, from, mirror, cell.z, gravityTable, lambda, dt, u, fluxLow,
                             fluxHigh);
    } else {
        stencilFluxes(wM2, wM1, w0, wP1, wP2, lambda, u, fluxLow, fluxHigh);
    }
    // Sub-grid mixing's fluxes through the faces with fluid beyond them.
    float carrierLow = 0.0f;
    float carrierHigh = 0.0f;
    if (airMixing) {
        float nu0 = viscosity[index];
        if (kindM1 == kindFluid) {
            MixingFace face = mixingFace(wM1, w0, viscosity[index - stride], nu0, u.dx, dt, u);
            fluxLow = sumOf(fluxLow, face.flux);
            carrierLow = face.carrier;
        }
        if (kindP1 == kindFluid) {
            MixingFace face = mixingFace(w0, wP1, nu0, viscosity[index + stride], u.dx, dt, u);
            fluxHigh = sumOf(fluxHigh, face.flux);
            carrierHigh = face.carrier;
        }
    }

    // Experimental rigid-box path: impermeable moving-wall traction, recorded from the
    // same numerical face flux used by the gas. Each fluid thread owns six output scalars, one
    // for each of its faces (low and high along each axis); the host gives each face's impulse
    // to the box beyond it. Use gauge pressure for body loading; uniform atmospheric preload is
    // balanced externally.
    if (u.experimentalBox != 0 && (u.refineRatio == 0 || patchAt(cell, patchOfTile, u) < 0)) {
        for (int side = 0; side < 2; ++side) {
            int direction = side == 0 ? -1 : 1;
            bool inside = side == 0 ? i > 0 : i < n - 1;
            if (!inside || boxMask[index + direction * stride] == 0) continue;
            Flux f = side == 0 ? fluxLow : fluxHigh;
            float speed = side == 0 ? speedM1 : speedP1;
            float traction = f.momentum.x - f.mass * speed;
            f.mass = 0.0f;
            f.momentum = float3(traction, 0.0f, 0.0f);
            f.energy = traction * speed;
            if (side == 0) fluxLow = f; else fluxHigh = f;
            boxImpulse[6 * index + 2 * axis + side] +=
                float(direction) * (traction - u.ambientPressure) * dt * u.dx * u.dx;
        }
    }

    // A cell of unrefined air beside a patch records the flux it used through the face they
    // share, so that the patch's own fluxes can replace it (see Refine.metal).
    int speciesRegister = -1;  // where its fuel and oxygen flux goes, if it records one
    int fluxRegister = -1;  // and its flux
    bool registerLow = false;
    if (u.refineRatio != 0) {
        // The cell across may be fluid or solid here; either way this cell's flux through the
        // face is what the patch's fine fluxes replace.
        int local = i % patchSize;
        bool lowEdge = local == 0 && i > 0;
        bool highEdge = local == patchSize - 1 && i < n - 1;
        if ((lowEdge || highEdge) && patchAt(cell, patchOfTile, u) < 0) {
            int3 across = cell;
            across[axis] += lowEdge ? -1 : 1;
            int patch = patchAt(across, patchOfTile, u);
            if (patch >= 0) {
                int3 inPatch = cell % patchSize;
                uint face = 2u * axis + (lowEdge ? 1u : 0u);
                uint slot = registerSlot(uint(patch), face, uint(inPatch[(axis + 1) % 3]),
                                         uint(inPatch[(axis + 2) % 3]), uint(patchSize));
                fluxRegister = int(slot);
                speciesRegister = int(speciesSlot(uint(patch), face, uint(inPatch[(axis + 1) % 3]),
                                                  uint(inPatch[(axis + 2) % 3]), uint(patchSize)));
                registerLow = lowEdge;
            }
        }
    }

    // A cut cell: the conservative update (each face's flux times its aperture, the wall's pressure
    // on the wall's area along the sweep), against the whole cell's update that the sweep gives it;
    // the difference, for the volume it holds, is kept for `redistributeCutDefects`.
    int cutRecord = -1;
    Flux defect = {0.0f, float3(0.0f), 0.0f};
    Flux cutLow = fluxLow;
    Flux cutHigh = fluxHigh;
    float cutShare = 1.0f;
    float registerAperture = 1.0f;
    float cutApertureLow = 1.0f;
    float cutApertureHigh = 1.0f;
    if (nearCut) {
        uint4 column = cutColumnOf(cell, cutColumns, u);
        if (cell.z < int(column.z)) {
            cutRecord = int(column.x + uint(cell.z) - column.y);
            float4 own = cutRecords[cutRecord];
            int3 next = cell;
            next[axis] += 1;
            float apertureLow = own[1 + axis];
            float apertureHigh = cutRecordOf(next, cutColumns, cutRecords, u)[1 + axis];
            float4 wall = cutWalls[cutRecord];
            cutShare = own.x;
            CutUpdate update = cutCellUpdate(w0, fluxLow, fluxHigh, apertureLow, apertureHigh, cutShare,
                                             toSweep(wall.xyz, axis), gravityHere, gravityTable, cell.z, lambda, dt, u);
            cutLow = update.low;
            cutHigh = update.high;
            defect = update.defect;
            registerAperture = registerLow ? apertureLow : apertureHigh;
            cutApertureLow = apertureLow;
            cutApertureHigh = apertureHigh;
        }
    }
    // A cell a structure's outline cuts, as the terrain's (its high face's aperture is the next
    // cell's low face's: closed against a solid cell, open against one without a record).
    int structureRecord = -1;
    if (structureCut && cutRecord < 0) {
        structureRecord = structureCutIndex[index];
        if (structureRecord >= 0) {
            float4 own = structureCutRecords[structureRecord];
            float apertureLow = own[1 + axis];
            float apertureHigh = 1.0f;
            if (kindP1 == kindWall) {
                apertureHigh = 0.0f;
            } else if (i + 1 < n) {
                int next = structureCutIndex[index + stride];
                apertureHigh = next >= 0 ? structureCutRecords[next][1 + axis] : 1.0f;
            }
            float4 wall = structureCutWalls[structureRecord];
            cutShare = own.x;
            int wallFace = apertureHigh == 0.0f && kindP1 == kindWall && apertureLow > 0.0f
                               ? 1
                               : (apertureLow == 0.0f && kindM1 == kindWall && apertureHigh > 0.0f ? -1 : 0);
            CutUpdate update = structureCutUpdate(w0, fluxLow, fluxHigh, apertureLow, apertureHigh, cutShare,
                                                  toSweep(wall.xyz, axis), gravityHere, gravityTable, cell.z, lambda,
                                                  dt, wallFace, u);
            cutLow = update.low;
            cutHigh = update.high;
            defect = update.defect;
            cutApertureLow = apertureLow;
            cutApertureHigh = apertureHigh;
        }
    }
    if (fluxRegister >= 0) {
        // Through a cut cell's face, the face's own flux times its aperture (the wall's push is the
        // cell's own, not the face's), as the fine cells record theirs.
        Flux through = registerLow ? fluxLow : fluxHigh;
        if (registerAperture != 1.0f) {
            through.mass *= registerAperture;
            through.momentum *= registerAperture;
            through.energy *= registerAperture;
        }
        storeFlux(coarseFlux, uint(fluxRegister), through, axis, dt);
    }

    Cell c = src[index];
    float3 momentum = toSweep(float3(c.mx, c.my, c.mz), axis);
    // Porous cells: each face's flux through its open share, over the cell's open volume.
    float porosity = 1.0f;
    float porosityLow = 1.0f;
    float porosityHigh = 1.0f;
    if (porousAir) {
        porosity = congestion[index].x;
        porosityLow = kindM1 == kindFluid ? min(porosity, congestion[index - stride].x) : porosity;
        porosityHigh = kindP1 == kindFluid ? min(porosity, congestion[index + stride].x) : porosity;
        float open = 1.0f / porosity;
        fluxLow.mass *= porosityLow * open;
        fluxLow.momentum *= porosityLow * open;
        fluxLow.energy *= porosityLow * open;
        fluxHigh.mass *= porosityHigh * open;
        fluxHigh.momentum *= porosityHigh * open;
        fluxHigh.energy *= porosityHigh * open;
        // The obstacles' push back: what the pressure on the open faces leaves unbalanced.
        momentum.x += lambda * w0.p * (porosityHigh - porosityLow) * open;
    }
    float rho = c.rho - lambda * (fluxHigh.mass - fluxLow.mass);
    momentum -= lambda * (fluxHigh.momentum - fluxLow.momentum);
    float energy = c.energy - lambda * (fluxHigh.energy - fluxLow.energy);
    if (gravityHere) {
        gravitySources(momentum, energy, w0.rho, fluxLow, fluxHigh, cell.z, gravityTable, dt, u);
    }

    // Detonation products that have not yet burnt ("fuel") and oxygen, as densities, carried
    // by the same mass fluxes, each at the mass fraction of the cell it leaves (first-order
    // upwind, so they stay positive). Where they meet in a cell, the fuel burns at once, as far
    // as the oxygen allows, after the final sweep of the step: afterburning limited by mixing,
    // which here is the grid's own.
    float2 species = float2(0.0f);
    if (carriesSpecies(u)) {
        float2 own = speciesSrc[index];
        // A deflagration's cloud has a sharp edge, and on cut cells a small cell's whole-cell update
        // can take more of it than the cell holds, until its difference is shared out (see
        // `redistributeCutDefects`). Holding that at zero would make gas, so it is not; instead the
        // faces' mass fractions are of what is there, none for a cell left short, which both cells
        // beside a face take alike, and nothing short is carried on.
        bool leftShort = u.deflagration != 0u;
        float2 fraction = (leftShort ? max(own, 0.0f) : own) / max(c.rho, u.densityFloor);
        // Beyond a far-field face, still air: its oxygen and no products.
        float2 ambient = farFieldFaces(u) ? float2(0.0f, u.stillOxygen / u.stillRho) : fraction;
        float2 belowSpecies = kindM1 == kindFluid ? speciesSrc[index - stride] : float2(0.0f);
        float2 aboveSpecies = kindP1 == kindFluid ? speciesSrc[index + stride] : float2(0.0f);
        if (leftShort) {
            belowSpecies = max(belowSpecies, 0.0f);
            aboveSpecies = max(aboveSpecies, 0.0f);
        }
        float2 below = kindM1 == kindFluid ? belowSpecies / wM1.rho : (kindM1 == kindOpen ? ambient : fraction);
        float2 above = kindP1 == kindFluid ? aboveSpecies / wP1.rho : (kindP1 == kindOpen ? ambient : fraction);
        float2 inflow = speciesFlux(fluxLow.mass, below, fraction);
        float2 outflow = speciesFlux(fluxHigh.mass, fraction, above);
        float2 lowFace = float2(0.0f);
        float2 highFace = float2(0.0f);
        if (u.deflagration != 0u) {
            // A deflagration's mixture is carried at limited linear (MUSCL) mass fractions at the
            // faces instead: at the upwind cell's, the grid's diffusion would spread its flame
            // over many cells (see Deflagration.metal). Both cells beside a face work out the
            // same value, so the species stay conserved.
            float2 below2 = below;
            if (kindM1 == kindFluid && classify(mask, index, -2, stride, i, n, lowWall, highWall) == kindFluid) {
                below2 = max(speciesSrc[index - 2 * stride], 0.0f) / wM2.rho;
            }
            float2 above2 = above;
            if (kindP1 == kindFluid && classify(mask, index, 2, stride, i, n, lowWall, highWall) == kindFluid) {
                above2 = max(speciesSrc[index + 2 * stride], 0.0f) / wP2.rho;
            }
            lowFace = fluxLow.mass > 0.0f ? below + 0.5f * minmodPair(below - below2, fraction - below)
                                          : fraction - 0.5f * minmodPair(fraction - below, above - fraction);
            highFace = fluxHigh.mass > 0.0f ? fraction + 0.5f * minmodPair(fraction - below, above - fraction)
                                            : above - 0.5f * minmodPair(above - fraction, above2 - above);
            inflow = fluxLow.mass * lowFace;
            outflow = fluxHigh.mass * highFace;
        }
        if (airMixing) {
            // Sub-grid mixing carries the species down their gradients in mass fraction.
            inflow -= carrierLow * (fraction - below);
            outflow -= carrierHigh * (above - fraction);
        }
        if (cutRecord >= 0 || structureRecord >= 0) {
            // The species' difference too, at the conservative mass fluxes and the faces' own mass
            // fractions (a deflagration's limited linear ones), and the mixing's carrying through
            // each face's open part: through each face as the cell beyond it takes them.
            float2 cutIn = u.deflagration != 0u ? cutLow.mass * lowFace : speciesFlux(cutLow.mass, below, fraction);
            float2 cutOut = u.deflagration != 0u ? cutHigh.mass * highFace : speciesFlux(cutHigh.mass, fraction, above);
            if (airMixing) {
                cutIn -= cutApertureLow * carrierLow * (fraction - below);
                cutOut -= cutApertureHigh * carrierHigh * (above - fraction);
            }
            float2 kept = -lambda * ((cutOut - cutIn) - cutShare * (outflow - inflow));
            device float4 *defects = cutRecord >= 0 ? cutDefects : structureCutDefects;
            int slot = cutRecord >= 0 ? cutRecord : structureRecord;
            float4 held = defects[2 * slot + 1];
            defects[2 * slot + 1] = float4(held.xy + kept, held.zw);
        }
        // Near a deflagration's cut cells nothing is held at zero (see `leftShort`).
        species = own - lambda * (outflow - inflow);
        if (!(leftShort && nearCut)) {
            species = max(species, 0.0f);
        }
        if (speciesRegister >= 0) {
            float2 through = (registerLow ? inflow : outflow) * (registerAperture * dt);
            coarseSpeciesFlux[speciesRegister] = through.x;
            coarseSpeciesFlux[speciesRegister + 1] = through.y;
        }
        if (u.finalSweep != 0 && u.afterburnEnergy > 0.0f) {
            float nu = burnMixing ? viscosity[index] : 0.0f;
            float fuel = afterburntHere(species, rho, momentum, energy, control.dt, nu, u.dx, u);
            species.x -= fuel;
            species.y -= fuel * u.oxygenPerFuel;
            energy += fuel * u.afterburnEnergy;
        }
        speciesDst[index] = species;
    }

    if (cutRecord >= 0 || structureRecord >= 0) {
        device float4 *defects = cutRecord >= 0 ? cutDefects : structureCutDefects;
        int slot = cutRecord >= 0 ? cutRecord : structureRecord;
        float4 held = defects[2 * slot];
        float4 heldEnergy = defects[2 * slot + 1];
        defects[2 * slot] = float4(held.x + defect.mass, held.yzw + fromSweep(defect.momentum, axis));
        defects[2 * slot + 1] = float4(heldEnergy.xy, heldEnergy.z + defect.energy, heldEnergy.w);
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
    dst[index] = result;

    if (u.finalSweep != 0) {
        // Under gravity, against the ambient pressure at the cell's height.
        float ambient = airGravity ? gravityAmbientOf(gravityTable, cell.z, u) : u.ambientPressure;
        float overpressure = pressure - ambient;
        peak[index] = max(peak[index], overpressure);
        // Under a patch, impulse is taken from the fine cells instead (see Refine.metal).
        if (u.refineRatio == 0 || patchAt(cell, patchOfTile, u) < 0) {
            impulse[index] += max(overpressure, 0.0f) * dt;
        }
        recordCell(maxSpeed, momentum, rho, pressure, u, ambient);
        // A changed cell near the edge of its tile wakes the tiles it can reach next step.
        if (u.tileNx != 0 && !isStillAt(result, species, cell.z, gravityTable, u)) {
            int3 local = cell % tileSize;
            if (any(local < tileReach) || any(local >= tileSize - tileReach)) {
                wakeTilesAround(cell, tileFlags, tileWoken, u);
            }
        }
    }
}

// Sweeps every cell.
kernel void sweep(device Cell *src [[buffer(0)]],
                  device Cell *dst [[buffer(1)]],
                  const device uchar *mask [[buffer(2)]],
                  device float *peak [[buffer(3)]],
                  device float *impulse [[buffer(4)]],
                  const device StepControl &control [[buffer(5)]],
                  device atomic_uint *maxSpeed [[buffer(6)]],
                  constant SolverUniforms &u [[buffer(7)]],
                  const device float *wallVelocity [[buffer(8)]],
                  device uchar *tileFlags [[buffer(10)]],
                  device float2 *speciesSrc [[buffer(11)]],
                  device float2 *speciesDst [[buffer(12)]],
                  const device int *patchOfTile [[buffer(13)]],
                  device float *coarseFlux [[buffer(14)]],
                  device float *coarseSpeciesFlux [[buffer(15)]],
                  const device uchar *boxMask [[buffer(16)]],
                  device float *boxImpulse [[buffer(17)]],
                  const device float4 *gravityTable [[buffer(18)]],
                  const device float *viscosity [[buffer(19)]],
                  const device uint4 *cutColumns [[buffer(20)]],
                  const device float4 *cutRecords [[buffer(21)]],
                  const device float4 *cutWalls [[buffer(22)]],
                  device float4 *cutDefects [[buffer(23)]],
                  const device uint *cutCeilings [[buffer(24)]],
                  const device float4 *congestion [[buffer(25)]],
                  const device int *structureCutIndex [[buffer(26)]],
                  const device float4 *structureCutRecords [[buffer(27)]],
                  const device float4 *structureCutWalls [[buffer(28)]],
                  device float4 *structureCutDefects [[buffer(29)]],
                  uint3 tid [[thread_position_in_grid]]) {
    if (tid.x >= u.nx || tid.y >= u.ny || tid.z >= u.nz) {
        return;
    }
    sweepCell(int3(tid), src, dst, mask, peak, impulse, control, maxSpeed, u, wallVelocity, tileFlags,
              speciesSrc, speciesDst, patchOfTile, coarseFlux, coarseSpeciesFlux, boxMask, boxImpulse,
              gravityTable, viscosity, cutColumns, cutRecords, cutWalls, cutDefects, cutCeilings, congestion,
              structureCutIndex, structureCutRecords, structureCutWalls, structureCutDefects);
}

// Sweeps the cells of the tiles listed in `tiles`, one threadgroup per tile; each thread takes
// a column of the tile through z.
kernel void sweepTiles(device Cell *src [[buffer(0)]],
                       device Cell *dst [[buffer(1)]],
                       const device uchar *mask [[buffer(2)]],
                       device float *peak [[buffer(3)]],
                       device float *impulse [[buffer(4)]],
                       const device StepControl &control [[buffer(5)]],
                       device atomic_uint *maxSpeed [[buffer(6)]],
                       constant SolverUniforms &u [[buffer(7)]],
                       const device float *wallVelocity [[buffer(8)]],
                       const device uint *tiles [[buffer(9)]],
                       device uchar *tileFlags [[buffer(10)]],
                       device float2 *speciesSrc [[buffer(11)]],
                       device float2 *speciesDst [[buffer(12)]],
                       const device int *patchOfTile [[buffer(13)]],
                       device float *coarseFlux [[buffer(14)]],
                       device float *coarseSpeciesFlux [[buffer(15)]],
                  const device uchar *boxMask [[buffer(16)]],
                  device float *boxImpulse [[buffer(17)]],
                       const device float4 *gravityTable [[buffer(18)]],
                  const device float *viscosity [[buffer(19)]],
                       const device uint4 *cutColumns [[buffer(20)]],
                       const device float4 *cutRecords [[buffer(21)]],
                       const device float4 *cutWalls [[buffer(22)]],
                       device float4 *cutDefects [[buffer(23)]],
                       const device uint *cutCeilings [[buffer(24)]],
                       const device float4 *congestion [[buffer(25)]],
                       const device int *structureCutIndex [[buffer(26)]],
                       const device float4 *structureCutRecords [[buffer(27)]],
                       const device float4 *structureCutWalls [[buffer(28)]],
                       device float4 *structureCutDefects [[buffer(29)]],
                       uint3 group [[threadgroup_position_in_grid]],
                       uint3 local [[thread_position_in_threadgroup]],
                       uint3 groupSize [[threads_per_threadgroup]]) {
    uint tile = tiles[group.x];
    uint3 origin = uint3(tile % u.tileNx, (tile / u.tileNx) % u.tileNy, tile / (u.tileNx * u.tileNy))
        * uint(tileSize);
    for (uint z = local.z; z < uint(tileSize); z += groupSize.z) {
        uint3 cell = origin + uint3(local.x, local.y, z);
        if (cell.x < u.nx && cell.y < u.ny && cell.z < u.nz) {
            sweepCell(int3(cell), src, dst, mask, peak, impulse, control, maxSpeed, u, wallVelocity, tileFlags,
                      speciesSrc, speciesDst, patchOfTile, coarseFlux, coarseSpeciesFlux, boxMask, boxImpulse,
                      gravityTable, viscosity, cutColumns, cutRecords, cutWalls, cutDefects, cutCeilings, congestion,
              structureCutIndex, structureCutRecords, structureCutWalls, structureCutDefects);
        }
    }
}
