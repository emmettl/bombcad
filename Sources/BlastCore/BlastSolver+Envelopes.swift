import BlastModel
import Foundation
import Metal
import RadialBlast
import simd

// The air solver's envelope recorders: the faces' exposure and each component's load through the
// run, the band of refined air in front of the façades, and the mask they observe.
extension BlastSolver {
    /// Records stationary voxel-face exposure. Deformable reference bodies observed must be fully
    /// pinned; other bodies may move, and never take the air beside the faces recorded (see
    /// `keepAir`). Must be configured before the first step after loading. Ordinary runs allocate no
    /// recorder.
    public func configureEnvelopeExposure(objects: [SceneObject]) throws {
        let mask = try stationaryMask(observing: objects)
        let exposure = try EnvelopeExposure(
            device: device, library: library, grid: grid,
            mask: mask, objects: objects)
        envelopeExposure = exposure
        try keepAir(exposure.faces.map(\.fluid))
        envelopeNeedsInitialSample = true
    }

    /// Records each envelope component's load through the run (`EnvelopeComponent`,
    /// `EnvelopeComponentHistory`), on the same terms as `configureEnvelopeExposure`; it can run
    /// beside it or alone. Ordinary runs allocate no recorder.
    public func configureEnvelopeComponents(objects: [SceneObject], options: EnvelopeHistoryOptions) throws {
        let mask = try stationaryMask(observing: objects)
        let recorder = try EnvelopeComponentRecorder(
            device: device, library: library, grid: grid, mask: mask, objects: objects, options: options)
        envelopeComponentRecorder = recorder
        // Its clock from the run's (on the mapped start, the time since detonation it begins at).
        if time > 0 { recorder.startClock(at: time) }
        try keepAir(recorder.faces.map(\.fluid))
        componentsNeedInitialSample = true
        facadeBand = nil
        applyFacadeBand()
    }

    /// Sets the band on each refined level, or takes it off. The structures' part follows their
    /// solids as built, not as they move: it is made afresh whenever the levels are.
    func applyFacadeBand() {
        let envelopes = configuration.refinementHoldsEnvelopes.flatMap { threshold in
            envelopeComponentRecorder.map { ($0, threshold) }
        }
        let structures = configuration.refinementHoldsStructures.flatMap { threshold in
            bodies.isEmpty ? nil : (bodies.map(\.model), threshold)
        }
        let ceiling = refinementLevels.isEmpty ? nil : configuration.refinementCeiling
        let regions = refinementLevels.isEmpty ? nil : configuration.refinementConfinedTo
        let bounded = ceiling != nil || regions != nil
        guard envelopes != nil || structures != nil || bounded, !refinementLevels.isEmpty else {
            facadeBand = nil
            for level in refinementLevels {
                level.facadeBand = nil
                // All of it: a ceiling left set would have the kernels read `wanted` as the band.
                level.facadeBandParameters = FacadeBandParameters()
            }
            return
        }
        let held = envelopes != nil || structures != nil
        let threshold = min(envelopes?.1 ?? .infinity, structures?.1 ?? .infinity)
        if facadeBand == nil {
            facadeBand = device.makeBuffer(length: max(1, grid.cellCount), options: .storageModeShared)
        }
        if let buffer = facadeBand {
            let band = buffer.contents().bindMemory(to: UInt8.self, capacity: grid.cellCount)
            memset(band, 0, grid.cellCount)
            // Bit 2: above the ceiling, the cell's centre more than it above the ground beneath; but
            // never within 3 m/kg^(1/3) of a charge, whose near field stays refined however high.
            let charges = ceilingExemptions
            if let ceiling {
                for j in 0..<grid.ny {
                    for i in 0..<grid.nx {
                        let ground =
                            terrain?.height(
                                at: SIMD2((Float(i) + 0.5) * grid.cellSize, (Float(j) + 0.5) * grid.cellSize))
                            ?? 0
                        let first = max(Int(((ground + ceiling) / grid.cellSize - 0.5).rounded(.up)), 0)
                        guard first < grid.nz else { continue }
                        for k in first..<grid.nz {
                            let centre = (SIMD3(Float(i), Float(j), Float(k)) + 0.5) * grid.cellSize
                            if charges.contains(where: { simd_distance(centre, $0.position) < $0.radius }) {
                                continue
                            }
                            band[grid.index(i, j, k)] |= 2
                        }
                    }
                }
            }
            // Bit 2 too: outside every region refinement is confined to.
            if let regions {
                var inside = [Bool](repeating: false, count: grid.cellCount)
                for region in regions {
                    // The cells whose centres lie in the box.
                    let low = simd_max(SIMD3<Int>((region.low / grid.cellSize - 0.5).rounded(.up)), .zero)
                    let high = simd_min(
                        SIMD3<Int>((region.high / grid.cellSize - 0.5).rounded(.down)),
                        SIMD3(grid.nx, grid.ny, grid.nz) &- 1)
                    guard all(low .<= high) else { continue }
                    for k in low.z...high.z {
                        for j in low.y...high.y {
                            for i in low.x...high.x { inside[grid.index(i, j, k)] = true }
                        }
                    }
                }
                for index in 0..<grid.cellCount where !inside[index] { band[index] |= 2 }
            }
            for model in structures?.0 ?? [] {
                for solid in model.solids {
                    // The cells whose centres lie within a cell of the solid.
                    let low = simd_max(SIMD3<Int>(((solid.min / grid.cellSize) - 1.5).rounded(.up)), .zero)
                    let high = simd_min(
                        SIMD3<Int>(((solid.max / grid.cellSize) + 0.5).rounded(.down)),
                        SIMD3(grid.nx, grid.ny, grid.nz) &- 1)
                    guard all(low .<= high) else { continue }
                    for k in low.z...high.z {
                        for j in low.y...high.y {
                            for i in low.x...high.x { band[grid.index(i, j, k)] |= 1 }
                        }
                    }
                }
            }
            for face in envelopes?.0.faces ?? [] {
                let index = Int(face.fluid)
                let cell = SIMD3(index % grid.nx, (index / grid.nx) % grid.ny, index / (grid.nx * grid.ny))
                for dz in -1...1 {
                    for dy in -1...1 {
                        for dx in -1...1 where grid.contains(cell.x + dx, cell.y + dy, cell.z + dz) {
                            band[grid.index(cell.x + dx, cell.y + dy, cell.z + dz)] |= 1
                        }
                    }
                }
            }
            facadeBand = buffer
        }
        for level in refinementLevels {
            level.facadeBand = facadeBand
            level.facadeBandParameters = FacadeBandParameters(
                nx: UInt32(grid.nx), ny: UInt32(grid.ny), nz: UInt32(grid.nz),
                ratio: UInt32(level.parentScale),
                threshold: held ? threshold : 0, ambient: configuration.ambientPressure,
                on: held && facadeBand != nil ? 1 : 0, ceiling: bounded && facadeBand != nil ? 1 : 0)
        }
    }

    /// The components recorded, in the order of their histories.
    public func envelopeComponents() -> [EnvelopeComponent]? { envelopeComponentRecorder?.components }

    /// Each component's history up to now.
    public func envelopeComponentHistories() -> [EnvelopeComponentHistory]? {
        precondition(!batchInFlight, "Cannot read observers during a batch")
        return envelopeComponentRecorder?.histories(elapsed: time)
    }

    /// The air's mask before the first step, for the envelope recorders observing `objects`.
    /// Envelopes are stationary; a detailed structure observed as one (a damage reference's) must be pinned, with
    /// every other body, while beside envelopes alone other bodies may move.
    func stationaryMask(observing objects: [SceneObject]) throws -> UnsafeBufferPointer<UInt8> {
        precondition(!batchInFlight, "Cannot configure observers during a batch")
        let observesStructures = objects.contains { $0.structure != nil }
        // Before the first step: a mapped start's clock starts at its solution's time.
        guard stepCount == 0, experimentalBoxes.isEmpty,
            !observesStructures
                || bodies.allSatisfy({ body in
                    var fixed = true
                    if let solid = body.solids {
                        let nodes = UnsafeBufferPointer(
                            start: solid.nodeBuffer.contents().bindMemory(
                                to: StructureNode.self, capacity: solid.nodeCount), count: solid.nodeCount)
                        fixed = fixed && nodes.allSatisfy { $0.mass == 0 || $0.isFixed }
                    }
                    if let shell = body.shells {
                        let nodes = UnsafeBufferPointer(
                            start: shell.nodeBuffer.contents().bindMemory(
                                to: ShellNode.self, capacity: shell.nodeCount), count: shell.nodeCount)
                        fixed = fixed && nodes.allSatisfy { $0.mass == 0 || $0.isClamped }
                    }
                    return fixed
                })
        else { throw BlastError.allocationFailed("stationary envelope observation before the first step") }
        return UnsafeBufferPointer(
            start: maskContents.bindMemory(to: UInt8.self, capacity: grid.cellCount),
            count: grid.cellCount)
    }

    public func envelopeExposureSnapshot() -> [EnvelopeExposureSnapshot]? {
        precondition(!batchInFlight, "Cannot read observers during a batch")
        return envelopeExposure?.snapshot(grid: grid, elapsed: time)
    }

    /// Whether the envelope recorders read a face whose air is in a still tile as the still air
    /// (the default; the same bits) or from its cell, for measuring what that saves.
    public var envelopeStillTileSkipping: Bool {
        get { envelopeExposure?.skipStillTiles ?? envelopeComponentRecorder?.skipStillTiles ?? true }
        set {
            envelopeExposure?.skipStillTiles = newValue
            envelopeComponentRecorder?.skipStillTiles = newValue
        }
    }

    public func envelopeExposureSummaries() -> [EnvelopeExposureSummary]? {
        precondition(!batchInFlight, "Cannot read observers during a batch")
        return envelopeExposure?.summaries(grid: grid, elapsed: time)
    }

    func clearEnvelopeExposure() {
        envelopeExposure = nil
        envelopeNeedsInitialSample = false
        envelopeComponentRecorder = nil
        componentsNeedInitialSample = false
        envelopeVenting = nil
        for level in refinementLevels { level.setPanes(nil) }
        keptAirBuffer = nil
    }

    func encodeEnvelopeExposure(_ encoder: MTLComputeCommandEncoder, initial: Bool) {
        guard let observer = envelopeExposure else { return }
        var uniforms = makeUniforms()
        // Faces in still tiles read the still air; under gravity it is not uniform.
        var parameters = SIMD4<UInt32>(
            UInt32(observer.faces.count), initial ? 1 : 0,
            observer.skipStillTiles && configuration.gravity == nil ? 1 : 0, 0)
        encoder.setComputePipelineState(observer.pipeline)
        encoder.setBuffer(stateBuffers[current], offset: 0, index: 0)
        encoder.setBuffer(maskBuffer, offset: 0, index: 1)
        encoder.setBuffer(controlBuffer, offset: 0, index: 2)
        encoder.setBuffer(observer.faceBuffer, offset: 0, index: 3)
        encoder.setBuffer(observer.values, offset: 0, index: 4)
        encoder.setBuffer(observer.signed, offset: 0, index: 5)
        encoder.setBytes(&uniforms, length: MemoryLayout<SolverUniforms>.stride, index: 6)
        encoder.setBytes(&parameters, length: 16, index: 7)
        encoder.setBuffer(tileFlagBuffer, offset: 0, index: 8)
        // Where the air is refined, its finest cells against each face.
        bindRefinedAir(encoder, from: 9)
        encoder.dispatchThreads(
            MTLSize(width: observer.faces.count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: observer.pipeline.threadExecutionWidth, height: 1, depth: 1)
        )
    }

    func encodeEnvelopeComponents(_ encoder: MTLComputeCommandEncoder, initial: Bool) {
        guard let recorder = envelopeComponentRecorder, !recorder.faces.isEmpty else { return }
        var uniforms = makeUniforms()
        var parameters = recorder.parameters(initial: initial)
        // Faces in still tiles read the still air; under gravity it is not uniform.
        parameters.skipStill = recorder.skipStillTiles && configuration.gravity == nil ? 1 : 0
        parameters.readsRefined = recorder.readsRefinedAir && refinement != nil ? 1 : 0
        let perGroup = EnvelopeComponentRecorder.componentsPerGroup
        let length = MemoryLayout<EnvelopeComponentRecorder.Parameters>.stride
        // Which components' air has woken; those still asleep finished there, the rest listed
        // (SolverEnvelopes.metal). With nothing awake this is the step's only work.
        encoder.setComputePipelineState(recorder.markPipeline)
        encoder.setBuffer(controlBuffer, offset: 0, index: 2)
        encoder.setBuffer(recorder.tileRanges, offset: 0, index: 3)
        encoder.setBuffer(recorder.tiles, offset: 0, index: 4)
        encoder.setBuffer(recorder.sideBuffer, offset: 0, index: 5)
        encoder.setBuffer(tileFlagBuffer, offset: 0, index: 7)
        encoder.setBuffer(recorder.awake, offset: 0, index: 8)
        encoder.setBytes(&uniforms, length: MemoryLayout<SolverUniforms>.stride, index: 9)
        encoder.setBytes(&parameters, length: length, index: 10)
        encoder.setBuffer(recorder.faceDispatch, offset: 0, index: 11)
        encoder.setBuffer(recorder.faceList, offset: 0, index: 12)
        encoder.setBuffer(recorder.sumDispatch, offset: 0, index: 13)
        encoder.setBuffer(recorder.sumList, offset: 0, index: 14)
        encoder.setBuffer(recorder.stillPressure, offset: 0, index: 15)
        encoder.setBuffer(recorder.peaks, offset: 0, index: 16)
        encoder.setBuffer(recorder.bins, offset: 0, index: 17)
        // Not written without maxima.
        encoder.setBuffer(recorder.maxima ?? recorder.bins, offset: 0, index: 18)
        encoder.setBuffer(recorder.flags, offset: 0, index: 19)
        encoder.setBuffer(recorder.clock, offset: 0, index: 20)
        encoder.setBuffer(recorder.starts, offset: 0, index: 21)
        encoder.setBuffer(recorder.current, offset: 0, index: 22)
        encoder.dispatchThreadgroups(
            MTLSize(width: (recorder.entryCount + perGroup - 1) / perGroup, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 32 * perGroup, height: 1, depth: 1))
        // The listed components' faces: a threadgroup each (and at the first sample one for the
        // still air's row).
        encoder.setComputePipelineState(recorder.facePipeline)
        encoder.setBuffer(stateBuffers[current], offset: 0, index: 0)
        encoder.setBuffer(maskBuffer, offset: 0, index: 1)
        encoder.setBuffer(recorder.faceBuffer, offset: 0, index: 3)
        encoder.setBuffer(recorder.pressures, offset: 0, index: 4)
        encoder.setBytes(&uniforms, length: MemoryLayout<SolverUniforms>.stride, index: 5)
        encoder.setBytes(&parameters, length: length, index: 6)
        encoder.setBuffer(recorder.sideBuffer, offset: 0, index: 8)
        encoder.setBuffer(recorder.faceList, offset: 0, index: 9)
        encoder.setBuffer(recorder.stillPressure, offset: 0, index: 10)
        // The refined air, for faces in it (`readsRefinedAir`); the second level's as the gauges'.
        bindRefinedAir(encoder, from: 11)
        encoder.setBuffer(recorder.weightBuffer, offset: 0, index: 17)
        encoder.dispatchThreadgroups(
            indirectBuffer: recorder.faceDispatch, indirectBufferOffset: 0,
            threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        // And their sums, a SIMD group each.
        encoder.setComputePipelineState(recorder.pipeline)
        encoder.setBuffer(recorder.pressures, offset: 0, index: 0)
        encoder.setBuffer(recorder.awake, offset: 0, index: 1)
        encoder.setBuffer(recorder.sideBuffer, offset: 0, index: 3)
        encoder.setBuffer(recorder.sumList, offset: 0, index: 4)
        encoder.setBuffer(recorder.peaks, offset: 0, index: 5)
        encoder.setBuffer(recorder.bins, offset: 0, index: 6)
        encoder.setBuffer(recorder.maxima ?? recorder.bins, offset: 0, index: 7)
        encoder.setBuffer(recorder.flags, offset: 0, index: 8)
        encoder.setBuffer(recorder.current, offset: 0, index: 9)
        encoder.setBytes(&parameters, length: length, index: 10)
        encoder.setBuffer(recorder.stillPressure, offset: 0, index: 11)
        encoder.setBuffer(recorder.faceDispatch, offset: 0, index: 12)
        encoder.setBuffer(recorder.sumDispatch, offset: 0, index: 13)
        encoder.setBuffer(recorder.clock, offset: 0, index: 14)
        encoder.setBuffer(recorder.starts, offset: 0, index: 15)
        encoder.dispatchThreadgroups(
            indirectBuffer: recorder.sumDispatch, indirectBufferOffset: 0,
            threadsPerThreadgroup: MTLSize(width: 32, height: 1, depth: 1))
        // The clock moves on by the step, once every component has it.
        encoder.setComputePipelineState(recorder.clockPipeline)
        encoder.dispatchThreads(
            MTLSize(width: 1, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
    }
}
