import BlastModel
import Foundation
import Metal
import RadialBlast
import simd

// The air solver's refined levels: setting them up, their pools and how they grow, regridding, the
// second level's view of the grid, the charges' share laid in fine cells, and binding the levels
// for the readers of surfaces.
extension BlastSolver {
    /// The most patches the first level's pool may grow to.
    public var refinementPatchCapacity: Int { refinement?.capacity ?? 0 }
    /// Each refined level's pool since the run's start: the most patches it may hold, those it
    /// holds now, the most in use at once, and whether it ran out, so that some blocks the shock
    /// wanted refined were not (a larger `refinementMemory` gives the run its full refinement).
    public var refinementPools: [(capacity: Int, held: Int, most: Int, ranOut: Bool)] {
        precondition(!batchInFlight, "Cannot read the refinement's pool during a batch")
        return refinementLevels.map { ($0.capacity, $0.maxPatches, $0.poolUse.most, $0.poolUse.ranOut) }
    }

    /// Each refined level's patches placed since the last restart: what its fill did.
    public var refinedPatchesPlaced: [Int] {
        refinementLevels.map(\.patchesPlaced)
    }

    /// The patches the second level's pool may grow to (0 without one).
    public var finerRefinementPatchCapacity: Int { finerRefinement?.capacity ?? 0 }
    /// The patches each refined level holds after the last regrid, the first level first.
    public var refinementPatchesInUse: [Int] { refinementLevels.map(\.patchCount) }
    /// The refined levels, finest last.
    var refinementLevels: [AirRefinement] { [refinement, finerRefinement].compactMap { $0 } }

    /// Binds the refined levels for a surface reader (`RefinedAir` in Solver.metal) at `first`
    /// and the five indices after it: the first level's patches, fine state and outline, then the
    /// second level's; placeholders where there is no such level.
    func bindRefinedAir(_ encoder: MTLComputeCommandEncoder, from first: Int) {
        encoder.setBuffer(refinement?.patchOfTile ?? refinementPlaceholder, offset: 0, index: first)
        encoder.setBuffer(refinement?.fine[0] ?? refinementPlaceholder, offset: 0, index: first + 1)
        encoder.setBuffer(refinement?.fineMask ?? refinementPlaceholder, offset: 0, index: first + 2)
        if let deep = finerRefinement, let parent = deep.parent {
            encoder.setBuffer(parent.patchOfTile, offset: deep.patchOffset * 4, index: first + 3)
            encoder.setBuffer(
                parent.fine[0], offset: deep.cellOffset * MemoryLayout<CellState>.stride, index: first + 4)
            encoder.setBuffer(parent.fineMask, offset: deep.cellOffset, index: first + 5)
        } else {
            for index in first + 3...first + 5 {
                encoder.setBuffer(refinementPlaceholder, offset: 0, index: index)
            }
        }
    }

    /// Gives the cells of refinement level `level` (0 the first) their share of the charges laid
    /// down in the finest cells (`fineDeposit`): every cell of the coarse cells they touch, each
    /// the mean of the finest cells in it, whose mean the coarse cells already hold. With
    /// afterburning, the products are all unburnt fuel, and the air keeps its oxygen.
    func depositFine(level: Int) {
        guard level < refinementLevels.count, !fineDeposit.isEmpty else { return }
        let target = refinementLevels[level]
        let finest = refinementLevels.reduce(1) { $0 * $1.ratio }
        let r = target.parentScale * target.ratio
        let below = finest / r
        let stillOxygen = Self.oxygenInAir * stillCell.density
        var cells: [SIMD3<Int>: (state: CellState, species: SIMD2<Float>)] = [:]
        for coarse in Set(fineDeposit.keys.map { $0 / finest }) {
            for n in 0..<(r * r * r) {
                let fine = coarse &* r &+ SIMD3(n % r, (n / r) % r, n / (r * r))
                var cell = stillCell
                var species = SIMD2<Float>(0, stillOxygen)
                if let table = gravityTable(scale: r) {
                    // Under gravity, the air at rest at the fine cell's height.
                    let row = table.contents().bindMemory(
                        to: SIMD4<Float>.self, capacity: 2 * (grid.nz * r + 8))[2 * (fine.z + 4)]
                    cell.density = row.x
                    (cell.momentumX, cell.momentumY, cell.momentumZ) = (0, 0, 0)
                    cell.energy = row.y
                    species.y = stillOxygen / stillCell.density * row.x
                }
                // The mean of its finest cells, summed in double precision, so that it does not
                // depend on their order.
                var added = SIMD2<Double>.zero
                for m in 0..<(below * below * below) {
                    let finer = fine &* below &+ SIMD3(m % below, (m / below) % below, m / (below * below))
                    added += SIMD2<Double>(fineDeposit[finer] ?? .zero)
                }
                if added != .zero {
                    let mean = SIMD2<Float>(added / Double(below * below * below))
                    cell.density += mean.x
                    cell.energy += mean.y
                    species.x += mean.x
                }
                cells[fine] = (cell, species)
            }
        }
        target.setFine(cells)
    }

    /// Of the refinement's memory, the share each level takes when there are two: the second
    /// level's blocks are an eighth the volume of the first's, so the shell of them around a
    /// shock takes several times as many.
    static let levelMemoryShares: [Double] = [1.0 / 3, 2.0 / 3]

    /// Makes, keeps or drops the finer levels for the configuration, and releases their patches.
    func setUpRefinement() {
        let ratio = configuration.refinement
        guard ratio > 1 else {
            refinement = nil
            finerRefinement = nil
            updateGaugeChildren()
            return
        }
        let levels = configuration.refinementLevels > 1 && experimentalBoxes.isEmpty ? 2 : 1
        let total = configuration.refinementMemory
        let memory =
            levels == 1 ? [total] : Self.levelMemoryShares.map { Int(Double(total) * $0) }
        let startTotal = min(configuration.refinementStartMemory ?? total, total)
        let startMemory =
            levels == 1 ? [startTotal] : Self.levelMemoryShares.map { Int(Double(startTotal) * $0) }
        let composition = bodies.count > 1
        let cut = terrainCut != nil
        let first = AirRefinement.layout(
            grid: grid, ratio: ratio, parentScale: 1, memory: memory[0], species: hasSpecies,
            bodyComposition: composition, cut: cut)
        let second =
            levels > 1
            ? AirRefinement.layout(
                grid: grid, ratio: ratio, parentScale: ratio, memory: memory[1], species: hasSpecies,
                bodyComposition: composition, cut: cut) : nil
        // Each pool starts small and grows ahead of the patches in use (`makeRefinementRoom`);
        // one that has grown keeps its size.
        let start = (0..<levels).map { level in
            AirRefinement.layout(
                grid: grid, ratio: ratio, parentScale: level == 0 ? 1 : ratio, memory: startMemory[level],
                species: hasSpecies, bodyComposition: composition, cut: cut
            ).maxPatches
        }
        let side = AirRefinement.patchSize * ratio
        let reserve =
            second.map { ($0.tileDims.x * $0.tileDims.y * $0.tileDims.z, start[1] * side * side * side) }
            ?? (0, 0)
        let layoutChanged =
            refinement?.ratio != ratio || refinement?.species != hasSpecies
            || refinement?.bodyComposition != composition || refinement?.capacity != first.maxPatches
            || refinement?.cutTerrain != cut
            || finerRefinement?.capacity != second?.maxPatches
            || (refinement?.patchOfTile.length ?? 0)
                != max(16, (first.tileDims.x * first.tileDims.y * first.tileDims.z + reserve.0) * 4)
        if layoutChanged {
            refinement = nil
            finerRefinement = nil
            refinement = try? AirRefinement(
                device: device, library: library, grid: grid, ratio: ratio, memory: memory[0],
                species: hasSpecies, bodyComposition: composition, reserve: (reserve.0, reserve.1), cut: cut,
                start: start[0])
            if levels > 1, let refinement {
                finerRefinement = try? AirRefinement(
                    device: device, library: library, grid: grid, ratio: ratio, memory: memory[1],
                    species: hasSpecies, bodyComposition: composition, parent: refinement, cut: cut,
                    start: start[1])
            }
        }
        for level in refinementLevels {
            level.reset()
            let fine = grid.cellSize / Float(level.parentScale * level.ratio)
            level.setBoxes(rigidBoxes?.map { $0.holdingCells(of: fine) })
            level.setTerrain(rigidBoxes == nil ? nil : terrain)
            level.setPanes(ventedPanes)
        }
        for level in refinementLevels { level.coarseCut = cut ? terrainCut : nil }
        applyFacadeBand()
        updateGaugeChildren()
    }

    /// Grows each refined level's pool, while the GPU is idle, to keep room ahead of the patches
    /// in use: eight steps of the most a step has added, a quarter of those in use, and 64 at
    /// least, growing by a quarter at a time or more. As a patch keeps its slot and the pool
    /// hands out slots in the same order at any size (`AirRefinement.grow`), a pool that never
    /// fills steps exactly as one made at its full size, in a fraction of the memory: the 500 t
    /// burst refined twice to 2 m used 28% and 39% of the pools it would have held. Notes, too,
    /// whether a pool ran out since the last look while it could still have grown
    /// (`refinementPoolGrewLate`).
    func makeRefinementRoom() {
        let levels = refinementLevels
        guard !levels.isEmpty else { return }
        if poolLive.count != levels.count {
            poolLive = levels.map(\.livePatches)
            poolGrowth = poolLive.map { max(Double($0) / 2, 16) }
            poolCouldGrow = levels.map { $0.maxPatches < $0.capacity }
            stepsSincePoolLook = 0
        }
        var targets: [Int] = []
        for (n, level) in levels.enumerated() {
            let live = level.livePatches
            if stepsSincePoolLook > 0 {
                poolGrowth[n] = max(poolGrowth[n], Double(live - poolLive[n]) / Double(stepsSincePoolLook))
            }
            if poolCouldGrow[n] && level.poolUse.ranOut { refinementPoolGrewLate = true }
            poolLive[n] = live
            let room = max(Int((8 * poolGrowth[n]).rounded(.up)), live / 4, 64)
            targets.append(
                live + room > level.maxPatches
                    ? min(max(live + room, level.maxPatches + level.maxPatches / 4), level.capacity)
                    : level.maxPatches)
        }
        stepsSincePoolLook = 0
        growPools(to: targets)
        poolCouldGrow = levels.map { $0.maxPatches < $0.capacity }
    }

    /// Grows the refined levels' pools to `targets` patches, the first level first.
    func growPools(to targets: [Int]) {
        guard let refinement, zip(refinementLevels, targets).contains(where: { $1 > $0.maxPatches }) else {
            return
        }
        do {
            if let finer = finerRefinement, targets.count > 1 {
                let cells = finer.side * finer.side * finer.side
                let child = (finer.maxPatches * cells, min(targets[1], finer.capacity) * cells)
                try refinement.grow(to: targets[0], child: child)
                finer.adopt()
                try finer.grow(to: targets[1])
            } else {
                try refinement.grow(to: targets[0])
            }
        } catch {
            // Out of memory: the pools stay as they are, and refine no more than they hold.
        }
    }

    /// The most steps the next command buffer may take, so that no pool that could still grow
    /// fills before the next look: half its free slots at the most a step has added.
    var poolStepLimit: Int {
        var limit = Int.max
        for (n, level) in refinementLevels.enumerated()
        where n < poolLive.count && level.maxPatches < level.capacity {
            let free = Double(level.maxPatches - poolLive[n])
            limit = min(limit, max(1, Int(free / (2 * max(poolGrowth[n], 1)))))
        }
        return limit
    }

    /// The uniforms of the second level, from the coarse grid's.
    func finerUniforms(_ base: SolverUniforms) -> SolverUniforms? {
        finerRefinement?.levelUniforms(
            from: base,
            threshold: configuration.refinementFinerThreshold ?? configuration.refinementThreshold,
            grid: grid)
    }

    /// The coarse grid as the first level sees it.
    func coarseView(species: MTLBuffer) -> AirRefinement.ParentView {
        AirRefinement.ParentView(
            state: stateBuffers[current], species: species, mask: maskBuffer,
            rigid: (hasBody || !experimentalBoxes.isEmpty) ? rigidMaskBuffer : maskBuffer,
            wallVelocity: wallVelocityBuffer, impulse: impulseBuffer, placeholder: refinementPlaceholder)
    }

    /// Step 7 for every level: flags each level's blocks (the second level's from the first
    /// level's cells, before the first is placed afresh), keeps the first level around the
    /// second, and places each level's patches, coarsest first.
    func encodeRegrid(
        _ encoder: MTLComputeCommandEncoder, species: MTLBuffer, uniforms: SolverUniforms,
        tiles: (list: MTLBuffer, dispatch: MTLBuffer, threads: MTLSize)?
    ) {
        guard let refinement else { return }
        let deep = finerUniforms(uniforms)
        if let finerRefinement, let deep {
            finerRefinement.encodeFlagFromParent(encoder, control: controlBuffer, uniforms: deep)
        }
        refinement.encodeFlag(
            encoder, coarse: stateBuffers[current], mask: maskBuffer, control: controlBuffer, tiles: tiles,
            grid: grid, uniforms: uniforms, boxDefinition: experimentalBoxDefinition)
        if let finerRefinement, let deep {
            finerRefinement.encodeNest(encoder, control: controlBuffer, uniforms: deep)
        }
        refinement.encodePlace(
            encoder, parent: coarseView(species: species), control: controlBuffer, tileFlags: tileFlagBuffer,
            uniforms: uniforms, boxDefinition: experimentalBoxDefinition, maxSpeed: maxSpeedBuffer)
        // New patches over a structure standing on cut terrain: its slivers solid before their
        // first sweep, each level's before the next is placed over it.
        let caps = capsFineSlivers
        if caps {
            refinement.encodeCapSliversAfterPlacing(
                encoder, parent: coarseView(species: species), uniforms: uniforms)
        }
        if let finerRefinement, let deep {
            finerRefinement.encodePlace(
                encoder, parent: refinement.view(), control: controlBuffer, tileFlags: tileFlagBuffer,
                uniforms: deep, maxSpeed: maxSpeedBuffer)
            if caps {
                finerRefinement.encodeCapSliversAfterPlacing(
                    encoder, parent: refinement.view(), uniforms: deep)
            }
        }
    }

    /// Whether a structure stands on the terrain's cut cells, which then shuts in slivers on the
    /// grid (`remaskCapSlivers`) and on each level (`refineRemaskCapSlivers`).
    var capsFineSlivers: Bool {
        !(terrainCut?.geometry.cutColumns.isEmpty ?? true)
            && bodies.contains(where: { $0.model.ground != nil })
    }

    /// Whether each refined level takes only the substeps its own waves need
    /// (`SolverConfiguration.refinementOwnSteps`); not with the experimental box, which follows
    /// the first level's substeps itself, nor with the terrain's cut cells, whose differences are
    /// shared out after every substep's final sweep.
    var ownLevelSteps: Bool {
        configuration.refinementOwnSteps && experimentalBoxes.isEmpty && refinement?.cutTerrain != true
    }

    /// The gas the refined levels hold, each cell counted at the finest level that holds it: the
    /// coarse cells the first level covers, and the mass, energy, momentum and fuel and oxygen.
    func refinedGas() -> (
        covered: Set<Int>, mass: Double, energy: Double, momentum: SIMD3<Double>, species: SIMD2<Double>
    )? {
        guard let refinement else { return nil }
        guard let finerRefinement else { return refinement.gas(in: grid) }
        let deep = finerRefinement.gas(in: grid)
        let first = refinement.gas(in: grid, excluding: deep.covered)
        return (
            first.covered, first.mass + deep.mass, first.energy + deep.energy, first.momentum + deep.momentum,
            first.species + deep.species
        )
    }
}
