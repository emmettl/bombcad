import BlastModel
import Foundation
import Metal
import RadialBlast
import simd

// The air solver's stepping: batches of steps encoded into command buffers, the sweeps and their
// uniforms, the per-cell kernels for the gas model, tiles of still air, and the GPU time each
// buffer aims at.
extension BlastSolver {
    /// Splits compute encoders at stage boundaries for diagnostic GPU timestamps.
    /// Run throughput benchmarks separately with this disabled.
    /// With `detailed`, the air's stages each get an encoder of their own too (see
    /// `BatchGPUProfile.stages`); keep batches to a few steps, as a batch times at most 2,048
    /// encoders.
    public func enableGPUProfiling(_ enabled: Bool, detailed: Bool = false) throws {
        precondition(!batchInFlight)
        gpuProfiler = enabled ? try BatchGPUProfiler(device: device, detailed: detailed) : nil
        lastBatchGPUProfile = nil
    }

    /// Marks the tiles of still air within `radius` of `centre` to be swept, for a charge laid down
    /// there during the run.
    func wakeTiles(around centre: SIMD3<Float>, radius: Float) {
        guard tilesEnabled else { return }
        let dims = SIMD3(grid.nx, grid.ny, grid.nz)
        let low =
            simd_max(SIMD3<Int>(((centre - radius) / grid.cellSize).rounded(.down)), .zero) / Self.tileSize
        let high =
            simd_min(SIMD3<Int>(((centre + radius) / grid.cellSize).rounded(.down)), dims &- 1)
            / Self.tileSize
        guard all(low .<= high) else { return }
        let flags = tileFlagBuffer.contents().bindMemory(to: UInt8.self, capacity: tileFlagBuffer.length)
        for z in low.z...high.z {
            for y in low.y...high.y {
                for x in low.x...high.x where flags[x + tileDims.x * (y + tileDims.y * z)] == 0 {
                    flags[x + tileDims.x * (y + tileDims.y * z)] = 1
                }
            }
        }
    }

    /// The fastest wave in the air measured again, as at the start, for the next step's length:
    /// after a charge laid down during the run, which the last step's did not see.
    func measureWaveSpeedAgain() {
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return }
        // Taken as the larger of the last step's and the air's now, by the kernel's atomic maximum.
        var uniforms = makeUniforms()
        encoder.setComputePipelineState(measurePipeline)
        encoder.setBuffer(stateBuffers[current], offset: 0, index: 0)
        encoder.setBuffer(maskBuffer, offset: 0, index: 1)
        encoder.setBuffer(maxSpeedBuffer, offset: 0, index: 2)
        encoder.setBytes(&uniforms, length: MemoryLayout<SolverUniforms>.stride, index: 3)
        dispatchGrid(encoder, pipeline: measurePipeline)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    /// The most steps the next batch may take: `steps`, limited to `maxStepsPerBatch` and, with
    /// a body, to the next checkpoint.
    public func batchSteps(_ steps: Int) -> Int {
        var steps = min(max(steps, 1), Self.maxStepsPerBatch)
        if hasBody {
            steps = min(steps, Self.checkpointInterval - stepCount % Self.checkpointInterval)
        }
        return steps
    }

    /// Encodes up to `steps` time steps into a new, uncommitted command buffer.
    ///
    /// Commit the buffer, wait for it to complete, then call `completeBatch()` before encoding
    /// another. Steps that would pass `timeLimit` (absolute simulation time) become no-ops, and
    /// with a body the batch ends at the next checkpoint (see `batchSteps`).
    public func encodeBatch(
        steps: Int, timeLimit: Double? = nil, updateVisualization: Bool = false
    ) -> MTLCommandBuffer? {
        makeRefinementRoom()
        let steps = min(batchSteps(steps), poolStepLimit)
        return encodeBatchPart(
            steps: steps, range: 0..<steps, timeLimit: timeLimit, updateVisualization: updateVisualization)
    }

    /// Encodes steps `range` of a batch of `steps` into a new, uncommitted command buffer: the
    /// batch's setup with its first part, its sampling and drawing with its last, as `encodeBatch`
    /// does all at once. The parts share the batch's state on the GPU (its clock and its time
    /// limit among it), so the steps are the same however the batch is cut; commit each and wait
    /// for it before encoding the next, and call `completeBatch()` after the last.
    func encodeBatchPart(
        steps: Int, range: Range<Int>, timeLimit: Double?, updateVisualization: Bool
    ) -> MTLCommandBuffer? {
        let first = range.lowerBound == 0
        let last = range.upperBound == steps
        // A charge due now is laid down before the batch, which then stops at the next one's time.
        var timeLimit = timeLimit
        if first, !pendingFirings.isEmpty {
            precondition(!batchInFlight, "completeBatch() must be called before encoding another batch")
            fireDueCharges()
            if let next = pendingFirings.first?.time { timeLimit = min(timeLimit ?? .infinity, next) }
        }
        if first {
            precondition(!batchInFlight, "completeBatch() must be called before encoding another batch")
            guard !interObjectContactDetected && !couplingCapacityExceeded else { return nil }
            settleStructures()
            assignGravityTables()
            gpuProfiler?.beginBatch()
        }
        guard let kernels = try? cellKernels(),
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let initialEncoder = gpuProfiler?.encoder(command: commandBuffer, phase: "observation")
                ?? commandBuffer.makeComputeCommandEncoder()
        else { return nil }
        var encoder = initialEncoder
        var currentPhase = "observation"
        func phase(_ name: String) {
            guard let gpuProfiler, name != currentPhase || !gpuProfiler.detailed else { return }
            encoder.endEncoding()
            encoder = gpuProfiler.encoder(command: commandBuffer, phase: name)!
            currentPhase = name
        }
        // With detailed profiling, a stage of the air of its own encoder.
        func airStage(_ name: String) {
            if gpuProfiler?.detailed == true { phase("air/" + name) }
        }
        if gpuProfiler?.detailed == true {
            for level in refinementLevels {
                level.stage = { name in
                    airStage(name)
                    return encoder
                }
            }
            liveEncoder = { encoder }
        }
        defer {
            for level in refinementLevels { level.stage = nil }
            liveEncoder = nil
        }
        // In flight from the first part's encoding until `completeBatch()`.
        defer { if first { batchInFlight = true } }
        stepsSincePoolLook += range.count

        if first {
            var control = StepControl()
            if let timeLimit {
                control.timeLimit = Float(max(timeLimit - time, 0))
            }
            control.clockLow = UInt32(truncatingIfNeeded: clockTicks)
            control.clockHigh = UInt32(truncatingIfNeeded: clockTicks >> 32)
            controlBuffer.contents().storeBytes(of: control, as: StepControl.self)
            if exposureNeedsInitialSample {
                encodeExposure(encoder, initial: true)
                exposureNeedsInitialSample = false
            }
            if envelopeNeedsInitialSample {
                encodeEnvelopeExposure(encoder, initial: true)
                envelopeNeedsInitialSample = false
            }
            if componentsNeedInitialSample {
                encodeEnvelopeComponents(encoder, initial: true)
                componentsNeedInitialSample = false
            }
        }

        let extents = [grid.nx, grid.ny, grid.nz]
        let tileThreads = Self.tileThreads(for: kernels.sweepTiles)
        if first {
            if stepCount % Self.checkpointInterval == 0 || checkpointSubsteps == 0 {
                checkpointSubsteps = structureSubsteps
                if let bodyStep, lastFluidStep > 0 {
                    let likely = Int((1.25 * lastFluidStep / bodyStep).rounded(.up)) + 1
                    checkpointSubsteps = max(likely, 1)
                }
                for body in bodies { body.checkpoint() }
            }
            batchSubsteps = min(checkpointSubsteps, structureSubsteps)
        }
        let substeps = batchSubsteps
        for step in range {
            phase("coupling")
            encodeBodyEnvelopes(encoder, clear: true)
            if !airIsAsleep { encodeAllocateCoupling(encoder) }
            if tiledCoupling != nil { encodeInteractionCheck(encoder) }
            phase("air")
            airStage("prepare")
            let globalStep = stepCount + step
            let ramp = min(1, Float(globalStep - rampStart + 1) / Float(max(configuration.startupSteps, 1)))
            var uniforms = makeUniforms(cfl: configuration.cfl * ramp)
            // With the air asleep, each step is exactly as long as the structure's substeps cover.
            let asleep = airIsAsleep && hasBody
            if asleep, let bodyStep {
                uniforms.forcedStep = 0.999 * Float(structureSubsteps) * bodyStep
            } else if let bodyStep {
                // Only the substeps this step is likely to need are encoded, a quarter more than
                // the step before the last checkpoint took; the air may step no further than
                // they cover.
                // Freestanding objects in the air keep their own limit too, whichever is shorter.
                let covered = 0.999 * Float(substeps) * bodyStep
                uniforms.maxStep = uniforms.maxStep > 0 ? min(uniforms.maxStep, covered) : covered
            }

            if asleep {
                uniforms.tileNx = 0
            } else if tilesEnabled {
                let tiles = tileDims.x * tileDims.y * tileDims.z
                encoder.setComputePipelineState(kernels.collectTiles)
                encoder.setBuffer(tileFlagBuffer, offset: 0, index: 0)
                encoder.setBuffer(tileListBuffer, offset: 0, index: 1)
                encoder.setBuffer(tileCountBuffer, offset: 0, index: 2)
                encoder.setBuffer(maxSpeedBuffer, offset: 0, index: 3)
                encoder.setBytes(&uniforms, length: MemoryLayout<SolverUniforms>.stride, index: 4)
                // Not read without gravity.
                encoder.setBuffer(gravityTable(scale: 1) ?? noSpecies, offset: 0, index: 5)
                encoder.dispatchThreads(
                    MTLSize(width: tiles, height: 1, depth: 1),
                    threadsPerThreadgroup: MTLSize(
                        width: min(tiles, kernels.collectTiles.maxTotalThreadsPerThreadgroup), height: 1,
                        depth: 1))
            }

            encoder.setComputePipelineState(gravityVariant(preparePipeline, "prepareStep"))
            // Not read without gravity.
            encoder.setBuffer(gravityTable(scale: 1) ?? noSpecies, offset: 0, index: 15)
            encoder.setBuffer(controlBuffer, offset: 0, index: 0)
            encoder.setBuffer(maxSpeedBuffer, offset: 0, index: 1)
            encoder.setBuffer(stateBuffers[current], offset: 0, index: 2)
            encoder.setBuffer(gaugeLogBuffer, offset: 0, index: 3)
            encoder.setBuffer(gaugeCellBuffer, offset: 0, index: 4)
            encoder.setBytes(&uniforms, length: MemoryLayout<SolverUniforms>.stride, index: 5)
            encoder.setBuffer(tileCountBuffer, offset: 0, index: 6)
            encoder.setBuffer(tileDispatchBuffer, offset: 0, index: 7)
            encoder.setBuffer(refinement?.patchOfTile ?? refinementPlaceholder, offset: 0, index: 8)
            encoder.setBuffer(refinement?.fine[0] ?? refinementPlaceholder, offset: 0, index: 9)
            encoder.setBuffer(gaugeChildBuffer, offset: 0, index: 10)
            encoder.setBuffer(refinement?.fineMask ?? refinementPlaceholder, offset: 0, index: 11)
            encodeFinerGaugeBuffers(encoder)
            encoder.setBuffer(maskBuffer, offset: 0, index: 16)
            encoder.setBuffer(gaugePointBuffer, offset: 0, index: 17)
            encoder.dispatchThreads(
                MTLSize(width: 1, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))

            if !asleep { encodeEddyViscosity(encoder, uniforms: uniforms) }
            let refining = refinement != nil && !asleep
            if let refinement, refining, ownLevelSteps {
                refinement.encodeLevelSteps(
                    encoder, control: controlBuffer, maxSpeed: maxSpeedBuffer, uniforms: uniforms,
                    child: finerRefinement)
            }
            if let refinement, refining {
                refinement.encodeSaveHalo(
                    encoder, parent: coarseView(species: currentSpecies), uniforms: uniforms,
                    control: controlBuffer)
            }

            // Alternate the sweep order each step so the splitting error stays second order.
            let order = globalStep.isMultiple(of: 2) ? [0, 1, 2] : [2, 1, 0]
            // An axis with a single cell has identical fluxes on both faces and can be skipped,
            // but at least one sweep must run to keep the bookkeeping kernels going.
            var axes = order.filter { extents[$0] > 1 }
            if axes.isEmpty { axes = [0] }

            airStage("coarse sweeps")
            encoder.setComputePipelineState(tilesEnabled ? kernels.sweepTiles : kernels.sweep)
            encoder.setBuffer(maskBuffer, offset: 0, index: 2)
            encoder.setBuffer(peakBuffer, offset: 0, index: 3)
            encoder.setBuffer(impulseBuffer, offset: 0, index: 4)
            encoder.setBuffer(controlBuffer, offset: 0, index: 5)
            encoder.setBuffer(maxSpeedBuffer, offset: 0, index: 6)
            encoder.setBuffer(wallVelocityBuffer, offset: 0, index: 8)
            encoder.setBuffer(tileListBuffer, offset: 0, index: 9)
            encoder.setBuffer(tileFlagBuffer, offset: 0, index: 10)
            encoder.setBuffer(refinement?.patchOfTile ?? refinementPlaceholder, offset: 0, index: 13)
            encoder.setBuffer(refinement?.coarseFlux ?? refinementPlaceholder, offset: 0, index: 14)
            encoder.setBuffer(refinement?.coarseSpeciesFlux ?? refinementPlaceholder, offset: 0, index: 15)
            encoder.setBuffer(experimentalBoxMask ?? noSpecies, offset: 0, index: 16)
            encoder.setBuffer(experimentalBoxImpulse ?? noSpecies, offset: 0, index: 17)
            // Not read without gravity, or without mixing.
            encoder.setBuffer(gravityTable(scale: 1) ?? noSpecies, offset: 0, index: 18)
            encoder.setBuffer(mixingViscosity() ?? noSpecies, offset: 0, index: 19)
            encoder.setBuffer(terrainCut?.columns ?? noSpecies, offset: 0, index: 20)
            encoder.setBuffer(terrainCut?.records ?? noSpecies, offset: 0, index: 21)
            encoder.setBuffer(terrainCut?.walls ?? noSpecies, offset: 0, index: 22)
            encoder.setBuffer(terrainCut?.defects ?? noSpecies, offset: 0, index: 23)
            encoder.setBuffer(terrainCut?.ceilings ?? noSpecies, offset: 0, index: 24)
            // Not read without congestion.
            encoder.setBuffer(congestionBuffer ?? noSpecies, offset: 0, index: 25)
            // Not read without structures' cut cells.
            encoder.setBuffer(structureCut?.index ?? noSpecies, offset: 0, index: 26)
            encoder.setBuffer(structureCut?.records ?? noSpecies, offset: 0, index: 27)
            encoder.setBuffer(structureCut?.walls ?? noSpecies, offset: 0, index: 28)
            encoder.setBuffer(structureCut?.defects ?? noSpecies, offset: 0, index: 29)
            for (n, axis) in axes.enumerated() where !asleep {
                if configuration.periodicSides { encodePeriodicHalo(encoder, uniforms: uniforms) }
                uniforms.axis = UInt32(axis)
                uniforms.finalSweep = n == axes.count - 1 ? 1 : 0
                encoder.setBuffer(stateBuffers[current], offset: 0, index: 0)
                encoder.setBuffer(stateBuffers[1 - current], offset: 0, index: 1)
                encoder.setBuffer(hasSpecies ? speciesBuffers[current] : noSpecies, offset: 0, index: 11)
                encoder.setBuffer(hasSpecies ? speciesBuffers[1 - current] : noSpecies, offset: 0, index: 12)
                encoder.setBytes(&uniforms, length: MemoryLayout<SolverUniforms>.stride, index: 7)
                if tilesEnabled {
                    encoder.dispatchThreadgroups(
                        indirectBuffer: tileDispatchBuffer, indirectBufferOffset: 0,
                        threadsPerThreadgroup: tileThreads)
                } else {
                    dispatchGrid(encoder, pipeline: kernels.sweep)
                }
                // Where the air is refined, after refluxing instead (below).
                if let terrainCut, n == axes.count - 1, !terrainCut.geometry.cutColumns.isEmpty,
                    !(refinement != nil && refining)
                {
                    encodeCutRedistribution(
                        encoder, cut: terrainCut, pipeline: kernels.redistributeCutDefects,
                        uniforms: uniforms,
                        state: stateBuffers[1 - current],
                        species: hasSpecies ? speciesBuffers[1 - current] : noSpecies)
                    // The merge took over the encoder's pipeline and some of its buffers.
                    encoder.setComputePipelineState(tilesEnabled ? kernels.sweepTiles : kernels.sweep)
                    encoder.setBuffer(maskBuffer, offset: 0, index: 2)
                    encoder.setBuffer(peakBuffer, offset: 0, index: 3)
                    encoder.setBuffer(impulseBuffer, offset: 0, index: 4)
                    encoder.setBuffer(controlBuffer, offset: 0, index: 5)
                    encoder.setBuffer(maxSpeedBuffer, offset: 0, index: 6)
                    encoder.setBuffer(wallVelocityBuffer, offset: 0, index: 8)
                    encoder.setBuffer(tileListBuffer, offset: 0, index: 9)
                    encoder.setBuffer(tileFlagBuffer, offset: 0, index: 10)
                }
                if let structureCut, n == axes.count - 1, refinement == nil {
                    encodeStructureCutRedistribution(
                        encoder, cut: structureCut, kernels: kernels, uniforms: uniforms,
                        state: stateBuffers[1 - current],
                        species: hasSpecies ? speciesBuffers[1 - current] : noSpecies)
                    encoder.setComputePipelineState(tilesEnabled ? kernels.sweepTiles : kernels.sweep)
                    encoder.setBuffer(maskBuffer, offset: 0, index: 2)
                    encoder.setBuffer(peakBuffer, offset: 0, index: 3)
                    encoder.setBuffer(impulseBuffer, offset: 0, index: 4)
                    encoder.setBuffer(controlBuffer, offset: 0, index: 5)
                    encoder.setBuffer(maxSpeedBuffer, offset: 0, index: 6)
                    encoder.setBuffer(wallVelocityBuffer, offset: 0, index: 8)
                    encoder.setBuffer(tileListBuffer, offset: 0, index: 9)
                    encoder.setBuffer(tileFlagBuffer, offset: 0, index: 10)
                }
                current = 1 - current
            }
            if let congestion, !asleep {
                // The congestion's drag after the step's sweeps, then the turbulence its obstacles
                // make (see `congestionDrag` and `obstacleTurbulence`).
                var fields = uniforms
                encoder.setComputePipelineState(congestion.drag)
                encoder.setBuffer(stateBuffers[current], offset: 0, index: 0)
                encoder.setBuffer(congestion.porosityDrag, offset: 0, index: 1)
                encoder.setBuffer(maskBuffer, offset: 0, index: 2)
                encoder.setBuffer(controlBuffer, offset: 0, index: 3)
                encoder.setBytes(&fields, length: MemoryLayout<SolverUniforms>.stride, index: 4)
                encoder.setBuffer(congestion.parallel, offset: 0, index: 5)
                encoder.setBuffer(congestion.turbulence[congestion.current], offset: 0, index: 6)
                dispatchGrid(encoder, pipeline: congestion.drag)
                encoder.setComputePipelineState(congestion.turbulenceUpdate)
                encoder.setBuffer(congestion.generation, offset: 0, index: 2)
                encoder.setBuffer(congestion.parallel, offset: 0, index: 3)
                encoder.setBuffer(maskBuffer, offset: 0, index: 4)
                encoder.setBuffer(controlBuffer, offset: 0, index: 5)
                encoder.setBytes(&fields, length: MemoryLayout<SolverUniforms>.stride, index: 6)
                encoder.setBuffer(congestion.turbulence[congestion.current], offset: 0, index: 7)
                encoder.setBuffer(congestion.turbulence[1 - congestion.current], offset: 0, index: 8)
                dispatchGrid(encoder, pipeline: congestion.turbulenceUpdate)
                congestion.current = 1 - congestion.current
            }
            if let refinement, refining {
                let coarse = coarseView(species: currentSpecies)
                refinement.encodeSubsteps(
                    encoder, axes: axes, parent: coarse, peak: peakBuffer, control: controlBuffer,
                    maxSpeed: maxSpeedBuffer, uniforms: uniforms,
                    child: finerRefinement.flatMap { level in finerUniforms(uniforms).map { (level, $0) } })
                refinement.encodeRefluxAndRestrict(
                    encoder, axes: axes, parent: coarse, control: controlBuffer, uniforms: uniforms
                ) { encoder in
                    guard let terrainCut = self.terrainCut, !terrainCut.geometry.cutColumns.isEmpty else {
                        return
                    }
                    self.encodeCutRedistribution(
                        encoder, cut: terrainCut, pipeline: kernels.redistributeCutDefects,
                        uniforms: uniforms,
                        state: self.stateBuffers[self.current],
                        species: self.currentSpecies)
                    // What reached first-level cells the second level covers is carried down to it.
                    if let finer = self.finerRefinement, let deep = self.finerUniforms(uniforms) {
                        finer.encodeSync(
                            encoder, parent: refinement.view(), control: self.controlBuffer, uniforms: deep)
                    }
                }
            }
            airStage("other")
            if let radiativeCoolingStage, !asleep {
                // Every few steps of the run's count, the luminous gas loses what it has radiated
                // since, in the coarse cells; the fine cells under them each lose as much a volume, as
                // they gain what debris trades with the air. Not at a batch's end: the time since
                // carries over, so a run comes out the same however it is batched.
                let take = (globalStep + 1).isMultiple(of: max(radiativeCoolingStage.settings.interval, 1))
                radiativeCoolingStage.encode(
                    encoder, take: take, state: stateBuffers[current], mask: maskBuffer,
                    species: hasSpecies && configuration.afterburning ? speciesBuffers[current] : nil,
                    placeholder: noSpecies,
                    control: controlBuffer, uniforms: uniforms,
                    tiles: tilesEnabled ? (tileListBuffer, tileDispatchBuffer, tileThreads) : nil)
                if take, let refinement, refining {
                    refinement.encodeSync(
                        encoder, parent: coarseView(species: currentSpecies), control: controlBuffer,
                        uniforms: uniforms)
                    if let finerRefinement, let deep = finerUniforms(uniforms) {
                        finerRefinement.encodeSync(
                            encoder, parent: refinement.view(), control: controlBuffer, uniforms: deep)
                    }
                }
            }
            if let deflagrationStage, !asleep {
                deflagrationStage.encodeStep(
                    encoder, state: stateBuffers[current],
                    species: hasSpecies ? speciesBuffers[current] : nil,
                    mask: maskBuffer,
                    rigidMask: rigidMaskBuffer, viscosity: mixingViscosity(), control: controlBuffer,
                    congestion: congestion)
            }

            phase("mechanics")
            if hasBody {
                // The structure covers the same interval in several smaller steps, loaded by the
                // pressure the air has just reached (the fine cells', where it is refined). While
                // the air is frozen it cannot take back what debris would take from it, so debris
                // then moves on without it.
                var binding = StructureSolver.FluidBinding(
                    state: stateBuffers[current], mask: maskBuffer, control: controlBuffer, grid: grid,
                    gamma: configuration.gamma, ambientPressure: configuration.ambientPressure,
                    airModel: configuration.airModel,
                    exchange: asleep ? nil : debrisExchangeBuffer, debrisArea: debrisAreaBuffer,
                    exchangeRegion: couplingRegion)
                binding.couplingMap = tiledCoupling == nil ? nil : wallVelocityBuffer
                binding.couplingMapCount = UInt32(tiledCoupling?.mapCount ?? 0)
                binding.readsCutCells = structureCut != nil
                if let refinement {
                    binding.refinement = (
                        refinement.patchOfTile, refinement.fine[0], refinement.fineMask, refinement.ratio,
                        refinement.tileDims
                    )
                }
                if let deep = finerRefinement {
                    binding.deepRefinement = (
                        deep.parentScale * deep.ratio, deep.tileDims, deep.patchOffset, deep.cellOffset
                    )
                }
                let count = asleep ? structureSubsteps : substeps
                if bodies.count > 1 {
                    for body in bodies { body.prepareDebrisAreas(encoder, fluid: binding) }
                    binding.debrisAreasPrepared = true
                }
                if bodiesInContact {
                    encodeBodiesInContact(encoder, count: count, fluid: binding)
                }
                for (index, body) in bodies.enumerated() where !bodiesInContact {
                    if bodies.count > 1 {
                        body.encodeSubsteps(
                            encoder, count: count, fluid: binding,
                            afterSubstep: { [self] substep in
                                encodeBodyEnvelope(encoder, index: index, substep: substep)
                            })
                    } else {
                        body.encodeSubsteps(encoder, count: count, fluid: binding)
                    }
                }
                phase("coupling")
                encodeBodyEnvelopes(encoder, clear: false)
                encodeInteractionCheck(encoder)
                if !asleep {
                    encodeDebrisExchange(encoder)
                }
                // The solid outline follows the structure even while the air sleeps: the air is frozen,
                // but a body still moving reads the frozen air beside where it now is. Frozen where
                // it was when the air went to sleep, a face that had moved back through that outline
                // read solid cells, and no air, on one side and frozen air on the other (Mendonça's
                // slabs, thrown up and landing, were pushed down at about 11 g). Where nothing
                // crosses a cell's centre the outline and the air are left exactly as they were.
                // Asleep, it takes no new coupling pages, and the interaction check above stands.
                if configuration.twoWayCoupling {
                    encodeRemask(encoder, allocate: !asleep)
                    if !asleep { encodeInteractionCheck(encoder) }
                }
                if let refinement, refining {
                    refinement.encodeSync(
                        encoder, parent: coarseView(species: currentSpecies), control: controlBuffer,
                        uniforms: uniforms)
                    if let finerRefinement, let deep = finerUniforms(uniforms) {
                        finerRefinement.encodeSync(
                            encoder, parent: refinement.view(), control: controlBuffer, uniforms: deep)
                    }
                }
            }
            phase("air")
            if refining {
                encodeRegrid(
                    encoder, species: currentSpecies, uniforms: uniforms,
                    tiles: tilesEnabled ? (tileListBuffer, tileDispatchBuffer, tileThreads) : nil)
            }
            phase("observation")
            encodeExposure(encoder, initial: false)
            encodeEnvelopeExposure(encoder, initial: false)
            encodeEnvelopeComponents(encoder, initial: false)
            encodeEnvelopeVenting(encoder)
        }
        guard last else {
            encoder.endEncoding()
            return commandBuffer
        }
        if gaugeCount > 0 {
            var uniforms = makeUniforms()
            encoder.setComputePipelineState(gravityVariant(sampleGaugesPipeline, "sampleGauges"))
            // Not read without gravity.
            encoder.setBuffer(gravityTable(scale: 1) ?? noSpecies, offset: 0, index: 15)
            encoder.setBuffer(controlBuffer, offset: 0, index: 0)
            encoder.setBuffer(stateBuffers[current], offset: 0, index: 2)
            encoder.setBuffer(gaugeLogBuffer, offset: 0, index: 3)
            encoder.setBuffer(gaugeCellBuffer, offset: 0, index: 4)
            encoder.setBytes(&uniforms, length: MemoryLayout<SolverUniforms>.stride, index: 5)
            encoder.setBuffer(refinement?.patchOfTile ?? refinementPlaceholder, offset: 0, index: 8)
            encoder.setBuffer(refinement?.fine[0] ?? refinementPlaceholder, offset: 0, index: 9)
            encoder.setBuffer(gaugeChildBuffer, offset: 0, index: 10)
            encoder.setBuffer(refinement?.fineMask ?? refinementPlaceholder, offset: 0, index: 11)
            encodeFinerGaugeBuffers(encoder)
            encoder.setBuffer(maskBuffer, offset: 0, index: 16)
            encoder.setBuffer(gaugePointBuffer, offset: 0, index: 17)
            encoder.dispatchThreads(
                MTLSize(width: 1, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        }
        if !frameRequest.isEmpty, frameExtractor == nil {
            frameExtractor = try? FrameExtractor(library: library)
        }
        frameExtractor?.encode(
            encoder, request: frameRequest, grid: grid, state: stateBuffers[current], mask: maskBuffer,
            species: currentSpecies, hasSpecies: speciesHoldDetonationProducts, control: controlBuffer,
            uniforms: makeUniforms())
        if updateVisualization || frameRequest.viewField != nil {
            encodeVisualization(encoder)
        }
        // After the visualisation, which it is cut down from, in the same encoder.
        if let stride = frameRequest.viewField {
            frameExtractor?.encodeViewField(
                encoder, stride: stride, grid: grid, field: visualizationTexture, control: controlBuffer,
                always: false)
        }
        encoder.endEncoding()
        return commandBuffer
    }

    /// Folds the results of the last completed batch into `time`, `stepCount` and the gauges.
    @discardableResult
    public func completeBatch() -> BatchResult {
        precondition(batchInFlight, "No batch to complete")
        batchInFlight = false
        lastBatchGPUProfile = gpuProfiler?.resolve()
        let control = controlBuffer.contents().load(as: StepControl.self)
        clockTicks = control.clock
        // A row per step, and one for the state the batch ended in.
        let rows = Int(control.stepIndex) + (gaugeCount > 0 ? 1 : 0)
        let rowStride = gaugeCount + 1
        let log = gaugeLogBuffer.contents().bindMemory(to: Float.self, capacity: rows * rowStride)
        // The clock adds up the steps one by one, so that it reads the same however they were
        // batched.
        let start = time
        var lastStep: Float = 0
        for row in 0..<rows {
            let step = log[row * rowStride]
            for gauge in 0..<gaugeCount {
                // A step that did nothing, and the batch's last row, repeat a sample at a time
                // already recorded; skip them.
                if let last = gaugeHistories[gauge].last, last.time >= time { continue }
                gaugeHistories[gauge].append(
                    GaugeSample(time: time, pressure: log[row * rowStride + 1 + gauge]))
            }
            time += Double(step)
            if step > 0 { lastStep = step }
        }
        let elapsed = time - start
        deflagrationStage?.complete()
        for body in bodies {
            body.time = time
            if bodies.count > 1 {
                body.solids?.time = time
                body.shells?.time = time
            }
        }
        stepCount += Int(control.activeSteps)
        if let radiativeCoolingStage {
            radiatedEnergy += radiativeCoolingStage.collect(rows: Int(control.stepIndex))
            radiationHistory.append((time, radiatedEnergy))
        }
        // Once the blast has left and the air is close to ambient everywhere, stop advancing it.
        // This is decided only at a checkpoint, from the step before it.
        if hasBody, !airIsAsleep, control.activeSteps > 0, stepCount % Self.checkpointInterval == 0 {
            let quiet =
                configuration.airSleepThreshold > 0
                && control.maxOverpressure < configuration.airSleepThreshold * configuration.ambientPressure
            let crossing = Double(simd_length(grid.size) / ambientSoundSpeed)
            let late =
                configuration.airSleepCrossings > 0
                && time - lastFiring > Double(configuration.airSleepCrossings) * crossing
            // A deflagration's pressure rises slowly from nothing, and lasts many crossings; a
            // charge still to fire will wake it.
            airIsAsleep = (quiet || late) && !hasFlame && pendingFirings.isEmpty
        }
        if control.activeSteps > 0 { lastFluidStep = control.lastStep }
        var swept = 1.0
        if tilesEnabled {
            let tiles = Double(tileDims.x * tileDims.y * tileDims.z)
            swept =
                control.activeSteps > 0
                ? Double(control.tileSweeps) / (Double(control.activeSteps) * tiles) : 0
        }
        frameExtractor?.complete(reachedLimit: control.stopped == 2, time: time, steps: stepCount)
        // Bodies that came close stopped the batch; from the next, they meet in contact.
        var contactStarted = false
        if bodyEnvelopesOverlap, configuration.interBodyContact, !bodiesInContact, !couplingCapacityExceeded {
            bodiesInContact = true
            contactStarted = true
            // In contact, every body takes the shortest of their steps, so that the two sides of
            // each pair push for the same time and their impulses are equal and opposite.
            let common = bodies.map(\.criticalTimeStep).min()!
            stepsBeforeContact = bodies.map { ($0.solids?.stepOverride, $0.shells?.stepOverride) }
            for body in bodies {
                body.solids?.stepOverride = common
                body.shells?.stepOverride = common
            }
        }
        return BatchResult(
            steps: Int(control.activeSteps), elapsed: elapsed, lastTimeStep: Double(lastStep),
            // A NaN anywhere in the air makes the wave speed NaN, which the step's maximum
            // passes over, so the step itself stays finite: the overpressure says it.
            isStable: control.batchTime.isFinite && control.dt.isFinite && !control.maxOverpressure.isNaN,
            maxOverpressure: control.maxOverpressure, sweptFraction: swept,
            refinedTiles: refinement?.patchCount ?? 0, finerRefinedTiles: finerRefinement?.patchCount ?? 0,
            firstLevelSubsteps: levelSubsteps(control, level: 0),
            secondLevelSubsteps: levelSubsteps(control, level: 1),
            stoppedShort: control.stopped == 1,
            reachedLimit: control.stopped == 2, unsupportedInteraction: interObjectContactDetected,
            contactStarted: contactStarted, couplingCapacityExceeded: couplingCapacityExceeded)
    }

    /// Advances by `steps` time steps, blocking until the GPU has finished.
    @discardableResult
    public func advance(steps: Int, timeLimit: Double? = nil) -> BatchResult {
        var total = BatchResult(steps: 0, elapsed: 0, lastTimeStep: 0, isStable: true)
        var remaining = steps
        var stoppedShort = false
        while remaining > 0 {
            // A batch that stopped just short of the limit is nearly always one step from it.
            let count = batchSteps(stoppedShort ? 1 : remaining)
            // The batch in command buffers of about `commandBufferTarget` of the GPU's time each,
            // so that none holds the GPU long enough to starve the window server; the steps are
            // the same however it is cut (`encodeBatchPart`).
            var encoded = 0
            var failed = false
            while encoded < count {
                makeRefinementRoom()
                let part = min(
                    gpuProfiler == nil ? gpuSteps.part(count - encoded) : count - encoded, poolStepLimit)
                guard
                    let commandBuffer = encodeBatchPart(
                        steps: count, range: encoded..<(encoded + part), timeLimit: timeLimit,
                        updateVisualization: false)
                else {
                    failed = true
                    break
                }
                commandBuffer.commit()
                commandBuffer.waitUntilCompleted()
                failed = failed || commandBuffer.error != nil
                gpuSteps.measure(commandBuffer, steps: part)
                stepGPUSeconds += max(commandBuffer.gpuEndTime - commandBuffer.gpuStartTime, 0)
                encoded += part
            }
            // Nothing encoded: no batch to complete.
            if encoded == 0 { break }
            let result = completeBatch()
            total.sweptFraction = Self.mergeSwept(total, result)
            (total.firstLevelSubsteps, total.secondLevelSubsteps) = Self.mergeSubsteps(total, result)
            total.steps += result.steps
            total.elapsed += result.elapsed
            total.lastTimeStep = result.lastTimeStep
            total.maxOverpressure = result.maxOverpressure
            total.isStable = total.isStable && result.isStable && !failed
            total.refinedTiles = result.refinedTiles
            total.finerRefinedTiles = result.finerRefinedTiles
            remaining -= result.steps
            stoppedShort = result.stoppedShort
            if result.contactStarted { continue }
            if result.steps == 0 || result.reachedLimit || (result.steps < count && !result.stoppedShort)
                || !result.isStable
            {
                break
            }
        }
        total.unsupportedInteraction = interObjectContactDetected
        total.couplingCapacityExceeded = couplingCapacityExceeded
        return total
    }

    /// The GPU time a command buffer of `advance` aims at, in seconds: well under the second or
    /// so after which the window server, starved of the GPU, is killed by the system's watchdog,
    /// and long enough that committing and waiting cost a fraction of a percent.
    /// `BOMBCAD_COMMAND_BUFFER_SECONDS` in the environment sets another, to check that the steps
    /// are the same however they are cut.
    public static let commandBufferTarget =
        ProcessInfo.processInfo.environment["BOMBCAD_COMMAND_BUFFER_SECONDS"].flatMap(Double.init) ?? 0.075

    /// The GPU time each of `advance`'s command buffers aims at, `commandBufferTarget` unless
    /// set; the steps are the same whatever it is.
    public var commandBufferSeconds: Double {
        get { gpuSteps.target }
        set { gpuSteps.target = newValue }
    }

    /// Advances until simulation time reaches `endTime`, blocking until the GPU has finished.
    @discardableResult
    public func advance(until endTime: Double) -> BatchResult {
        var total = BatchResult(steps: 0, elapsed: 0, lastTimeStep: 0, isStable: true)
        while endTime - time > 1e-7 * max(endTime, 1e-3) {
            let result = advance(steps: 64, timeLimit: endTime)
            total.sweptFraction = Self.mergeSwept(total, result)
            (total.firstLevelSubsteps, total.secondLevelSubsteps) = Self.mergeSubsteps(total, result)
            total.steps += result.steps
            total.elapsed += result.elapsed
            total.lastTimeStep = result.lastTimeStep
            total.maxOverpressure = result.maxOverpressure
            total.isStable = total.isStable && result.isStable
            total.refinedTiles = result.refinedTiles
            total.finerRefinedTiles = result.finerRefinedTiles
            if result.steps == 0 || !result.isStable { break }
        }
        total.unsupportedInteraction = interObjectContactDetected
        total.couplingCapacityExceeded = couplingCapacityExceeded
        return total
    }

    /// The substeps each refined level took per step in the last batch (see `BatchResult`).
    private func levelSubsteps(_ control: StepControl, level: Int) -> Double {
        let levels = refinementLevels
        guard level < levels.count, let ratio = refinement?.ratio else { return 0 }
        guard ownLevelSteps, control.activeSteps > 0 else {
            return Double(level == 0 ? ratio : ratio * ratio)
        }
        let sum = level == 0 ? control.levelSubstepSum0 : control.levelSubstepSum1
        return Double(sum) / Double(control.activeSteps)
    }

    /// The levels' substeps per step of two runs of steps together, weighted by their steps.
    private static func mergeSubsteps(_ total: BatchResult, _ result: BatchResult) -> (Double, Double) {
        let steps = Double(total.steps + result.steps)
        guard steps > 0 else { return (result.firstLevelSubsteps, result.secondLevelSubsteps) }
        let (a, b) = (Double(total.steps), Double(result.steps))
        return (
            (total.firstLevelSubsteps * a + result.firstLevelSubsteps * b) / steps,
            (total.secondLevelSubsteps * a + result.secondLevelSubsteps * b) / steps
        )
    }

    /// The swept fraction of two runs of steps together, weighted by their steps.
    private static func mergeSwept(_ total: BatchResult, _ result: BatchResult) -> Double {
        let steps = total.steps + result.steps
        guard steps > 0 else { return result.sweptFraction }
        return (total.sweptFraction * Double(total.steps) + result.sweptFraction * Double(result.steps))
            / Double(steps)
    }

    func makeUniforms(cfl: Float? = nil) -> SolverUniforms {
        var uniforms = SolverUniforms(
            nx: UInt32(grid.nx), ny: UInt32(grid.ny), nz: UInt32(grid.nz),
            dx: grid.cellSize,
            gamma: configuration.gamma,
            cfl: cfl ?? configuration.cfl,
            ambientPressure: configuration.ambientPressure,
            densityFloor: configuration.densityFloor,
            pressureFloor: configuration.pressureFloor,
            limiterTheta: configuration.limiterTheta,
            riemannSolver: configuration.riemannSolver.rawValue,
            boundaryFlags: configuration.reflectiveFaces.rawValue
                | (configuration.openFaces == .farField && configuration.gravity == nil ? farFieldFlag : 0),
            gaugeCount: UInt32(gaugeCount))
        if tilesEnabled {
            uniforms.tileNx = UInt32(tileDims.x)
            uniforms.tileNy = UInt32(tileDims.y)
            uniforms.tileNz = UInt32(tileDims.z)
        }
        uniforms.stillRho = stillCell.density
        uniforms.stillMx = stillCell.momentumX
        uniforms.stillMy = stillCell.momentumY
        uniforms.stillMz = stillCell.momentumZ
        uniforms.stillEnergy = stillCell.energy
        uniforms.airModel = configuration.airModel.rawValue
        refinement?.configure(&uniforms, threshold: configuration.refinementThreshold)
        uniforms.refineMargin = UInt32(max(configuration.refinementMargin, 0))
        uniforms.gaugeWalls = configuration.gaugesReadWallPressure ? 1 : 0
        if let finerRefinement {
            uniforms.childTileNx = UInt32(finerRefinement.tileDims.x)
            uniforms.childTileNy = UInt32(finerRefinement.tileDims.y)
            uniforms.childTileNz = UInt32(finerRefinement.tileDims.z)
        }
        if refinement != nil, ownLevelSteps {
            uniforms.ownSteps = 1
            uniforms.refineLevel = 1
            uniforms.sweepAxes = UInt32(max(1, [grid.nx, grid.ny, grid.nz].filter { $0 > 1 }.count))
        }
        if hasFlame {
            uniforms.deflagration = 1
        } else if hasSpecies {
            uniforms.afterburnEnergy = configuration.afterburnEnergy
            uniforms.oxygenPerFuel = Self.oxygenPerFuel
            uniforms.stillOxygen = Self.oxygenInAir * stillCell.density
            uniforms.afterburnRate =
                1 / max(configuration.afterburnTime * cbrt(max(largestCharge, 1e-3)), 1e-9)
        }
        if let region = couplingRegion, configuration.movingWalls {
            uniforms.couplingMapCount = UInt32(tiledCoupling?.mapCount ?? 0)
            uniforms.regionX = UInt32(region.origin.x)
            uniforms.regionY = UInt32(region.origin.y)
            uniforms.regionZ = UInt32(region.origin.z)
            uniforms.regionNx = UInt32(region.dims.x)
            uniforms.regionNy = UInt32(region.dims.y)
            uniforms.regionNz = UInt32(region.dims.z)
        }
        if !experimentalBoxes.isEmpty {
            uniforms.experimentalBox = UInt32(experimentalBoxes.count)
            uniforms.regionX = 0
            uniforms.regionY = 0
            uniforms.regionZ = 0
            uniforms.regionNx = UInt32(grid.nx)
            uniforms.regionNy = UInt32(grid.ny)
            uniforms.regionNz = UInt32(grid.nz)
            uniforms.maxStep = min(experimentalBoxMaxStep, experimentalStepCeiling ?? .infinity)
        }
        if let limit = configuration.afterburnLimit {
            uniforms.ignitionTemperature = limit.ignitionTemperature
            uniforms.limitFlameTemperature = limit.limitFlameTemperature
        }
        if let mixing = configuration.mixing {
            uniforms.mixingCoefficient = mixing.coefficient
            uniforms.mixingPrandtl = mixing.prandtl
            uniforms.mixingModel = mixing.model == .sigma ? 1 : 0
        }
        if let gravity = configuration.gravity {
            uniforms.gravity = gravity.acceleration
            uniforms.gravityLapse = gravity.lapseRate
            uniforms.gravityT0 = gravityGround.pressure / (gravityGround.density * AirGravity.gasConstant)
            uniforms.gravityP0 = gravityGround.pressure
        }
        return uniforms
    }

    /// The per-cell kernels for the configured gas model, compiled the first time it is used.
    func cellKernels() throws -> CellKernels {
        let model = configuration.airModel
        let gravity = configuration.gravity != nil
        let mixing = configuration.mixing != nil
        let limit = configuration.afterburnLimit != nil
        let cut = terrainCut != nil
        let porous = congestionBuffer != nil
        let structureCutOn = structureCut != nil
        let key =
            16 * Int(model.rawValue) + (gravity ? 1 : 0) + (mixing ? 2 : 0) + (limit ? 4 : 0) + (cut ? 8 : 0)
            + (porous ? 1024 : 0) + (structureCutOn ? 2048 : 0)
        if let kernels = cellKernelsByModel[key] { return kernels }
        var constants = MTLFunctionConstantValues()
        var value = model.rawValue
        constants.setConstantValue(&value, type: .uint, index: ShaderLibrary.airModelConstant)
        if gravity { constants = ShaderLibrary.withGravity(constants) }
        if mixing { constants = ShaderLibrary.withMixing(constants) }
        if limit { constants = ShaderLibrary.withBurnLimit(constants) }
        if cut { constants = ShaderLibrary.withCutCells(constants) }
        if porous { constants = ShaderLibrary.withPorousAir(constants) }
        if structureCutOn { constants = ShaderLibrary.withStructureCut(constants) }
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            try ShaderLibrary.pipeline(name, in: library, constants: constants)
        }
        let kernels = CellKernels(
            sweep: try pipeline("sweep"), sweepTiles: try pipeline("sweepTiles"),
            collectTiles: try pipeline("collectTiles"),
            redistributeCutDefects: try pipeline("redistributeCutDefects"),
            keepStructureCut: try pipeline("keepStructureCut"),
            takeStructureCut: try pipeline("takeStructureCut"))
        cellKernelsByModel[key] = kernels
        return kernels
    }

    /// Threads per tile in the tiled sweep: a column through the tile for each, or several if the
    /// pipeline cannot hold a whole tile's worth.
    private static func tileThreads(for sweepTiles: MTLComputePipelineState) -> MTLSize {
        var depth = Self.tileSize
        while depth > 1
            && Self.tileSize * Self.tileSize * depth > sweepTiles.maxTotalThreadsPerThreadgroup
        {
            depth /= 2
        }
        return MTLSize(width: Self.tileSize, height: Self.tileSize, depth: depth)
    }

    func dispatchGrid(_ encoder: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState) {
        let width = pipeline.threadExecutionWidth
        let height = max(1, pipeline.maxTotalThreadsPerThreadgroup / width)
        encoder.dispatchThreads(
            MTLSize(width: grid.nx, height: grid.ny, depth: grid.nz),
            threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1))
    }
}

/// How long the GPU has lately taken for a step, from the command buffers waited for, to size
/// the next so that it takes about `target` of the GPU's time.
struct GPUStepRate {
    /// The GPU time a buffer aims at, in seconds.
    var target = BlastSolver.commandBufferTarget
    /// Seconds a step, smoothed over the buffers; nil until the first.
    private(set) var seconds: Double?

    /// How many of `remaining` steps the next buffer takes: at least one, and four to begin
    /// with, to measure the rate.
    func part(_ remaining: Int) -> Int {
        guard let seconds, seconds > 0 else { return min(remaining, 4) }
        return min(max(Int(min(target / seconds, Double(Int.max / 2))), 1), remaining)
    }

    mutating func measure(_ commandBuffer: MTLCommandBuffer, steps: Int) {
        measure(gpuSeconds: commandBuffer.gpuEndTime - commandBuffer.gpuStartTime, steps: steps)
    }

    mutating func measure(gpuSeconds: Double, steps: Int) {
        guard gpuSeconds > 0, steps > 0 else { return }
        let rate = gpuSeconds / Double(steps)
        seconds = seconds.map { 0.7 * $0 + 0.3 * rate } ?? rate
    }
}
