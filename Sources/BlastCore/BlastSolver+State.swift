import BlastModel
import Foundation
import Metal
import RadialBlast
import simd

// The air solver's state: initial conditions, restarting and the clock, direct access to cells and
// fields, and the totals, peaks and impulses read from them.
extension BlastSolver {
    /// Sets every cell to the same state and restarts the clock.
    public func fill(uniform primitive: Primitive) {
        let cell = cellState(primitive)
        stillCell = cell
        largestCharge = 0
        fineDeposit = [:]
        for buffer in stateBuffers {
            buffer.contents().bindMemory(to: CellState.self, capacity: grid.cellCount)
                .update(repeating: cell, count: grid.cellCount)
        }
        let wantsSpecies = configuration.afterburning || hasFlame
        if wantsSpecies && !hasSpecies {
            let length = grid.cellCount * MemoryLayout<SIMD2<Float>>.stride
            if let first = device.makeBuffer(length: length, options: .storageModeShared),
                let second = device.makeBuffer(length: length, options: .storageModeShared)
            {
                speciesBuffers = [first, second]
            }
        } else if !wantsSpecies {
            speciesBuffers = []
        }
        // A deflagration's cloud is laid down afterwards (see `depositCloud`).
        let air = SIMD2<Float>(0, hasFlame ? 0 : Self.oxygenInAir * primitive.density)
        for buffer in speciesBuffers {
            buffer.contents().bindMemory(to: SIMD2<Float>.self, capacity: grid.cellCount)
                .update(repeating: air, count: grid.cellCount)
        }
        gravityGround = primitive
        if configuration.gravity != nil { fillHydrostatic() }
        restart()
    }

    /// Sets every cell from a closure and restarts the clock. Intended for small grids.
    public func fill(_ body: (_ i: Int, _ j: Int, _ k: Int) -> Primitive) {
        pendingFirings = []
        mutateState { cells in
            for k in 0..<grid.nz {
                for j in 0..<grid.ny {
                    for i in 0..<grid.nx {
                        cells[grid.index(i, j, k)] = cellState(body(i, j, k))
                    }
                }
            }
        }
        restart()
    }

    /// The conserved state of air in `primitive` state, by the configured equation of state.
    public func cellState(_ primitive: Primitive) -> CellState {
        var cell = CellState(primitive, gamma: configuration.gamma)
        let kinetic = 0.5 * primitive.density * simd_length_squared(primitive.velocity)
        cell.energy =
            configuration.airModel.internalEnergy(
                density: primitive.density, pressure: primitive.pressure, gamma: configuration.gamma)
            + kinetic
        return cell
    }

    /// The primitive state of a cell, by the configured equation of state.
    public func primitive(of cell: CellState) -> Primitive {
        Self.primitive(of: cell, gamma: configuration.gamma, airModel: configuration.airModel)
    }

    static func primitive(of cell: CellState, gamma: Float, airModel: AirModel) -> Primitive {
        var primitive = cell.primitive(gamma: gamma)
        let kinetic = 0.5 * primitive.density * simd_length_squared(primitive.velocity)
        primitive.pressure = airModel.pressure(
            density: primitive.density, internalEnergy: cell.energy - kinetic, gamma: gamma)
        return primitive
    }

    /// Direct access to the current conserved state. Call `restart()` after editing.
    public func mutateState(_ body: (UnsafeMutableBufferPointer<CellState>) throws -> Void) rethrows {
        fineDeposit = [:]
        try editState(body)
    }

    /// The same, keeping any charge laid down in fine cells.
    func editState(_ body: (UnsafeMutableBufferPointer<CellState>) throws -> Void) rethrows {
        precondition(!batchInFlight, "Cannot edit state while a batch is in flight")
        frameExtractor?.invalidate()
        let pointer = stateContents[current].bindMemory(
            to: CellState.self, capacity: grid.cellCount)
        try body(UnsafeMutableBufferPointer(start: pointer, count: grid.cellCount))
    }

    /// Sets the clock without touching the state, after `restart()`: for a blast laid down as it
    /// is some time after detonation.
    func startClock(at start: Double) {
        time = start
        // The GPU's clock too, in its ticks: the exposure plane's arrivals, panes' and breaches'
        // opening times and the envelope histories read it as time since detonation.
        clockTicks = UInt64((start / StepControl.tick).rounded())
        // And the clocks venting's panes and walls, and the envelope histories, keep for themselves.
        envelopeComponentRecorder?.startClock(at: start)
        envelopeVenting?.startClocks(at: start)
    }

    /// Direct access to the peak overpressure and impulse fields.
    func setFields(_ body: (UnsafeMutableBufferPointer<Float>, UnsafeMutableBufferPointer<Float>) -> Void) {
        let peak = peakContents.bindMemory(to: Float.self, capacity: grid.cellCount)
        let impulse = impulseContents.bindMemory(to: Float.self, capacity: grid.cellCount)
        body(
            UnsafeMutableBufferPointer(start: peak, count: grid.cellCount),
            UnsafeMutableBufferPointer(start: impulse, count: grid.cellCount))
    }

    /// Resets time, histories and the peak/impulse fields, treating the current state as initial.
    /// The structure, if any, returns to its undeformed state.
    public func restart() {
        precondition(!batchInFlight, "Cannot restart while a batch is in flight")
        frameExtractor?.invalidate()
        time = 0
        stepCount = 0
        clockTicks = 0
        rampStart = 0
        lastFiring = 0
        // The slivers a structure shut in are found again from where it stands (`remaskCapSlivers`).
        if let cappedSliverBuffer { memset(cappedSliverBuffer.contents(), 0, cappedSliverBuffer.length) }
        exposurePlane?.reset()
        exposureNeedsInitialSample = exposurePlane != nil
        sweepUpdateCapture = nil
        clockInputCapture = nil
        stepSelectorDiagnostic = nil
        compensatedSweep = nil
        firstPhaseColumns?.reset()
        firstPhaseNeedsInitialSample = firstPhaseColumns != nil
        envelopeExposure?.reset()
        envelopeNeedsInitialSample = envelopeExposure != nil
        envelopeComponentRecorder?.reset()
        componentsNeedInitialSample = envelopeComponentRecorder != nil
        envelopeVenting?.reset(mask: maskBuffer, rigidMask: rigidMaskBuffer)
        lastBatchGPUProfile = nil
        lastFluidStep = 0
        checkpointSubsteps = 0
        congestion?.reset()
        setUpRadiativeCooling()
        for body in bodies { body.reset() }
        settlements = []
        structuresSettled = false
        if let plan = tiledCoupling {
            let header = wallVelocityBuffer.contents().bindMemory(to: UInt32.self, capacity: 2)
            header[0] = min(header[0], UInt32(plan.capacity))
            header[1] = 0
            if let occupancyBuffer { memset(occupancyBuffer.contents(), 0, occupancyBuffer.length) }
            if let combinedOccupancyBuffer {
                memset(combinedOccupancyBuffer.contents(), 0, combinedOccupancyBuffer.length)
            }
        }
        if let interactionBuffer { memset(interactionBuffer.contents(), 0, interactionBuffer.length) }
        if bodiesInContact {
            for (body, steps) in zip(bodies, stepsBeforeContact) {
                body.solids?.stepOverride = steps.solids
                body.shells?.stepOverride = steps.shells
            }
            bodiesInContact = false
        }

        // Structures' cut cells, kept as air before the remask marks the structure.
        try? setUpStructureCut()
        if hasBody, let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeComputeCommandEncoder()
        {
            // Mark the undeformed structure in the solid mask.
            encodeBodyEnvelopes(encoder, clear: true)
            encodeRemask(encoder, fine: false)
            encoder.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
        }
        gaugeHistories = Array(repeating: [], count: gaugeCount)
        resetDebrisExchange()
        memset(peakContents, 0, peakBuffer.length)
        memset(impulseContents, 0, impulseBuffer.length)
        maxSpeedBuffer.contents().storeBytes(of: 0, as: UInt64.self)
        airIsAsleep = false
        // Both state buffers start alike, so that a tile never swept holds the same state in each.
        memcpy(
            stateContents[1 - current], stateContents[current],
            stateBuffers[current].length)
        if hasSpecies {
            memcpy(
                speciesBuffers[1 - current].contents(), speciesBuffers[current].contents(),
                speciesBuffers[current].length)
        }
        // A deflagration's flame is advanced everywhere, its burning starts slowly, and vent panels
        // open where the air may not yet be awake.
        tilesEnabled = configuration.skipStillAir && deflagrationStage == nil
        memset(tileFlagBuffer.contents(), 0, tileFlagBuffer.length)
        tileCountBuffer.contents().storeBytes(of: 0, as: UInt32.self)
        if tilesEnabled, tiledCoupling == nil, let region = couplingRegion {
            // Around the structure the mask moves and debris trades with the air, so those
            // tiles are always swept.
            let reach = 2
            let low = simd_max(region.origin &- reach, .zero) / Self.tileSize
            let high =
                simd_min(region.origin &+ region.dims &+ (reach - 1), SIMD3(grid.nx, grid.ny, grid.nz) &- 1)
                / Self.tileSize
            let flags = tileFlagBuffer.contents().bindMemory(to: UInt8.self, capacity: tileFlagBuffer.length)
            for z in low.z...high.z {
                for y in low.y...high.y {
                    for x in low.x...high.x { flags[x + tileDims.x * (y + tileDims.y * z)] = 1 }
                }
            }
        }

        setUpRefinement()
        assignGravityTables()

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return }
        var uniforms = makeUniforms()
        encodeWakeCoupling(encoder)
        encoder.setComputePipelineState(measurePipeline)
        encoder.setBuffer(stateBuffers[current], offset: 0, index: 0)
        encoder.setBuffer(maskBuffer, offset: 0, index: 1)
        encoder.setBuffer(maxSpeedBuffer, offset: 0, index: 2)
        encoder.setBytes(&uniforms, length: MemoryLayout<SolverUniforms>.stride, index: 3)
        dispatchGrid(encoder, pipeline: measurePipeline)
        if tilesEnabled {
            let wake = gravityVariant(wakeTilesPipeline, "wakeTiles")
            encoder.setComputePipelineState(wake)
            encoder.setBuffer(stateBuffers[current], offset: 0, index: 0)
            encoder.setBuffer(maskBuffer, offset: 0, index: 1)
            encoder.setBuffer(tileFlagBuffer, offset: 0, index: 2)
            encoder.setBytes(&uniforms, length: MemoryLayout<SolverUniforms>.stride, index: 3)
            encoder.setBuffer(hasSpecies ? speciesBuffers[current] : noSpecies, offset: 0, index: 4)
            // Not read without gravity.
            encoder.setBuffer(gravityTable(scale: 1) ?? noSpecies, offset: 0, index: 5)
            dispatchGrid(encoder, pipeline: wake)
        }
        var placed = 0
        if refinement != nil {
            // Refine around the charge from the start; the regrid acts only on a step that
            // advances, so the clock is given one.
            var control = StepControl()
            control.dt = 1
            controlBuffer.contents().storeBytes(of: control, as: StepControl.self)
            encodeRegrid(encoder, species: currentSpecies, uniforms: uniforms, tiles: nil)
            // The structure's own outline in the new patches.
            encodeRemask(encoder)
            placed = 1
        }
        encodeVisualization(encoder)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        depositFine(level: 0)
        // A level beneath another is placed from its parent's cells, once they hold the charge,
        // and the first level is kept around it.
        while placed < refinementLevels.count {
            guard let commandBuffer = commandQueue.makeCommandBuffer(),
                let encoder = commandBuffer.makeComputeCommandEncoder()
            else { return }
            encodeRegrid(encoder, species: currentSpecies, uniforms: uniforms, tiles: nil)
            encodeRemask(encoder)
            encoder.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            depositFine(level: placed)
            placed += 1
        }
        // A pool too small for the patches around the charge at the start grows fourfold, and
        // the run starts again, from the start, so that it is placed whole.
        let short = refinementLevels.map { $0.poolUse.ranOut && $0.maxPatches < $0.capacity }
        if short.contains(true) {
            growPools(to: zip(refinementLevels, short).map { $1 ? $0.maxPatches * 4 : $0.maxPatches })
            restart()
            return
        }
        poolLive = []
        refinementPoolGrewLate = false
    }

    /// Read-only view of the current conserved state. Solid cells hold stale values.
    public func withState<R>(_ body: (UnsafeBufferPointer<CellState>) throws -> R) rethrows -> R {
        precondition(!batchInFlight, "Cannot read state while a batch is in flight")
        let pointer = stateContents[current].bindMemory(
            to: CellState.self, capacity: grid.cellCount)
        return try body(UnsafeBufferPointer(start: pointer, count: grid.cellCount))
    }

    public func primitive(_ i: Int, _ j: Int, _ k: Int) -> Primitive {
        withState { primitive(of: $0[grid.index(i, j, k)]) }
    }

    public func isSolid(_ i: Int, _ j: Int, _ k: Int) -> Bool {
        maskContents.load(fromByteOffset: grid.index(i, j, k), as: UInt8.self) != 0
    }

    /// Largest overpressure (Pa) seen so far in a cell.
    public func peakOverpressure(_ i: Int, _ j: Int, _ k: Int) -> Float {
        peakContents.load(
            fromByteOffset: grid.index(i, j, k) * MemoryLayout<Float>.stride, as: Float.self)
    }

    /// Positive-phase impulse (Pa s) accumulated so far in a cell.
    public func impulse(_ i: Int, _ j: Int, _ k: Int) -> Float {
        impulseContents.load(
            fromByteOffset: grid.index(i, j, k) * MemoryLayout<Float>.stride, as: Float.self)
    }

    /// Total mass (kg) and energy (J) of the gas, summed over fluid cells; under the patches of
    /// refined air, over their fluid fine cells.
    public func totals() -> (mass: Double, energy: Double) {
        let mask = maskContents.bindMemory(to: UInt8.self, capacity: grid.cellCount)
        let volume = Double(grid.cellSize) * Double(grid.cellSize) * Double(grid.cellSize)
        let fine = refinedGas()
        return withState { cells in
            var mass = 0.0
            var energy = 0.0
            for index in 0..<grid.cellCount where mask[index] == 0 && fine?.covered.contains(index) != true {
                let share = openShare(index)
                mass += Double(cells[index].density) * share
                energy += Double(cells[index].energy) * share
            }
            return (mass * volume + (fine?.mass ?? 0), energy * volume + (fine?.energy ?? 0))
        }
    }

    /// The share of cell `index` that holds air: its cut cell's (the terrain's or a structure's), or
    /// one.
    func fluidShare(_ index: Int) -> Double {
        if let structure = structureCut?.geometry, structure.index[index] >= 0,
            terrainCut?.geometry.alpha(
                index % grid.nx, (index / grid.nx) % grid.ny, index / (grid.nx * grid.ny))
                ?? 1 >= 1
        {
            return Double(structure.records[Int(structure.index[index])].x)
        }
        guard let cut = terrainCut?.geometry else { return 1 }
        let i = index % grid.nx
        let j = (index / grid.nx) % grid.ny
        return Double(cut.alpha(i, j, index / (grid.nx * grid.ny)))
    }

    /// Total momentum of the gas in kg m/s, counted as `totals()` is.
    public func momentum() -> SIMD3<Double> {
        let mask = maskContents.bindMemory(to: UInt8.self, capacity: grid.cellCount)
        let volume = Double(grid.cellSize) * Double(grid.cellSize) * Double(grid.cellSize)
        let fine = refinedGas()
        return withState { cells in
            var total = SIMD3<Double>.zero
            for index in 0..<grid.cellCount where mask[index] == 0 && fine?.covered.contains(index) != true {
                total +=
                    SIMD3(
                        Double(cells[index].momentumX), Double(cells[index].momentumY),
                        Double(cells[index].momentumZ)) * openShare(index)
            }
            return total * volume + (fine?.momentum ?? .zero)
        }
    }

    public var fluidCellCount: Int {
        let mask = maskContents.bindMemory(to: UInt8.self, capacity: grid.cellCount)
        var count = 0
        for index in 0..<grid.cellCount where mask[index] == 0 { count += 1 }
        return count
    }

    /// Bytes of GPU memory held by the solver's fields.
    public var memoryFootprint: Int {
        let buffers = stateBuffers + speciesBuffers + [maskBuffer, peakBuffer, impulseBuffer]
        return buffers.reduce(0) { $0 + $1.length } + grid.cellCount * 8
            + (sweepUpdateCapture?.buffer.length ?? 0)
            + (clockInputCapture?.output.length ?? 0)
            + (compensatedSweep?.residuals.length ?? 0)
            + (exposurePlane?.buffer.length ?? 0) + (firstPhaseColumns?.memoryFootprint ?? 0)
            + (envelopeExposure?.memoryFootprint ?? 0)
            + (envelopeComponentRecorder?.memoryFootprint ?? 0) + (envelopeVenting?.memoryFootprint ?? 0)
            + bodies.reduce(0) { $0 + $1.memoryFootprint }
            + refinementLevels.reduce(0) { $0 + $1.memoryFootprint }
            + (experimentalBoxDefinition?.length ?? 0) + (experimentalBoxMask?.length ?? 0)
            + (experimentalBoxImpulse?.length ?? 0) + (congestion?.memoryFootprint ?? 0)
            + (hasBody
                ? wallVelocityBuffer.length + (occupancyBuffer?.length ?? 0)
                    + (debrisExchangeBuffer?.length ?? 0) + (debrisAreaBuffer?.length ?? 0) : 0)
            + (combinedOccupancyBuffer?.length ?? 0) + (couplingTiles?.length ?? 0)
            + (interactionBuffer?.length ?? 0)
            + (bodyEnvelopeBuffer?.length ?? 0)
            + (experimentalBoxes.isEmpty || hasBody ? 0 : wallVelocityBuffer.length)
    }
}
