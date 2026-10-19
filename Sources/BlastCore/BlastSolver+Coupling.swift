import BlastModel
import Foundation
import Metal
import RadialBlast
import simd

// The air solver's structures: laying out their coupling with the air, their envelopes and contact
// with each other, the debris they exchange with it, and settling them under their own weight
// before the blast.
extension BlastSolver {
    /// Compatibility views for single-body clients. Multi-body clients use `bodies` or IDs.
    public var structure: StructureSolver? { bodies.first?.solids }
    public var shells: ShellSolver? { bodies.first?.shells }
    public var mixed: MixedStructure? { bodies.first?.mixed }
    public var hasBody: Bool { !bodies.isEmpty }
    var bodyStep: Float? { bodies.map(\.criticalTimeStep).min() }
    public func body(id: UUID) -> StructuralBody? { bodies.first { $0.id == id } }
    public var couplingStatistics: CouplingStatistics {
        let cells = denseCouplingCells
        let active =
            tiledCoupling.map { min(Int(wallVelocityBuffer.contents().load(as: UInt32.self)), $0.capacity) }
            ?? 0
        return CouplingStatistics(
            layout: tiledCoupling == nil ? "dense" : "tiled", denseCells: cells,
            capacityCells: tiledCoupling?.capacityCells ?? cells,
            activeTiles: active, tileCapacity: tiledCoupling?.capacity ?? 0,
            bytes: (occupancyBuffer?.length ?? 0) + (combinedOccupancyBuffer?.length ?? 0)
                + (debrisExchangeBuffer?.length ?? 0) + (debrisAreaBuffer?.length ?? 0)
                + (couplingTiles?.length ?? 0) + (hasBody ? wallVelocityBuffer.length : 0))
    }

    /// Measures only repeated boundary composition/remasking on the current geometry.
    /// For benchmark drivers: does not advance time; run on a separate, stationary fixture.
    public func measureCouplingGPU(repetitions: Int) throws -> Double {
        precondition(!batchInFlight && repetitions > 0)
        guard let command = commandQueue.makeCommandBuffer(),
            let encoder = command.makeComputeCommandEncoder()
        else { throw BlastError.allocationFailed("coupling benchmark") }
        for _ in 0..<repetitions { encodeRemask(encoder) }
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        if let error = command.error { throw error }
        return (command.gpuEndTime - command.gpuStartTime) / Double(repetitions)
    }
    /// Independent bodies' envelopes or resolved cells overlap.
    public var bodyEnvelopesOverlap: Bool {
        interactionBuffer?.contents().load(as: UInt32.self) != nil
            && interactionBuffer!.contents().load(as: UInt32.self) & 1 != 0
    }
    /// Bodies came close with contact between them switched off: the run cannot go on.
    public var interObjectContactDetected: Bool { bodyEnvelopesOverlap && !configuration.interBodyContact }
    /// Whether the structures' coupling is laid out in tiles; for the tests.
    var usesTiledCoupling: Bool { tiledCoupling != nil }
    public var couplingCapacityExceeded: Bool {
        guard tiledCoupling != nil else { return false }
        return wallVelocityBuffer.contents().load(fromByteOffset: 4, as: UInt32.self) != 0
    }

    /// Replaces the deformable body, preserving scenery authored through `mutateMask`.
    /// The new outline is added at the next `restart()`; old body masks are removed.
    public func setStructure(_ model: StructureModel?) throws {
        try setStructures(model.map { [SceneObject.legacyStructure($0)] } ?? [])
    }

    public func setStructures(_ objects: [SceneObject]) throws {
        precondition(!batchInFlight, "Cannot change structures while a batch is in flight")
        // Freestanding objects are installed after the structures (`installExperimentalBoxes`).
        guard experimentalBoxes.isEmpty else { throw SceneObjectError.invalidOwnership }
        guard objects.count <= Scenario.maximumStructures, Set(objects.map(\.id)).count == objects.count,
            objects.allSatisfy({ $0.structure != nil })
        else { throw SceneObjectError.invalidOwnership }
        try SceneObject.validateSeparation(objects)
        let ordered = objects.count > 1 ? objects.sorted { $0.id.uuidString < $1.id.uuidString } : objects
        let compiled = try ordered.map {
            try StructuralBody(object: $0, device: device, queue: commandQueue, library: library)
        }
        clearEnvelopeExposure()
        bodies = compiled
        couplingRegion = nil
        tiledCoupling = nil
        couplingTiles = nil
        denseCouplingCells = 0
        occupancyBuffer = nil
        combinedOccupancyBuffer = nil
        interactionBuffer = nil
        bodyEnvelopeBuffer = nil
        debrisExchangeBuffer = nil
        debrisAreaBuffer = nil
        wallVelocityBuffer = stillWallBuffer
        if needsRigidMaskCapture {
            memcpy(rigidMaskBuffer.contents(), maskContents, grid.cellCount)
            needsRigidMaskCapture = false
        }
        // Replacing/removing bodies must clear their old outline outside the new coupling region.
        memcpy(maskContents, rigidMaskBuffer.contents(), grid.cellCount)
        guard !compiled.isEmpty else { return }
        try layOutBodyCoupling()
    }

    /// The structures' coupling buffers: over the region they may reach (or, with several, in
    /// tiles over the grid when that is smaller), or over the whole grid while freestanding
    /// objects share the air, whose wall velocities index every cell (`bodyCouplingWholeGrid`).
    func layOutBodyCoupling() throws {
        guard let first = bodies.first else { return }
        // Laid out afresh: a tiled plan from an earlier layout would leave the buffers sized and
        // addressed by its slots when the whole grid is now wanted.
        tiledCoupling = nil
        couplingTiles = nil
        let compiled = bodies
        let model = first.model
        // Follow the structure within a few metres of where it starts.
        let bounds = compiled.dropFirst().reduce(model.bounds) { bounds, body in
            Box(
                min: simd_min(bounds.min, body.model.bounds.min),
                max: simd_max(bounds.max, body.model.bounds.max))
        }
        let margin = configuration.debrisReach
        let low = grid.cell(containing: bounds.min - margin)
        let high = grid.cell(containing: bounds.max + margin)
        var origin = SIMD3(low.i, low.j, low.k)
        var dims = SIMD3(high.i - low.i + 1, high.j - low.j + 1, high.k - low.k + 1)
        // Four counters per cell: the number of elements in it and the sum of their velocities.
        if bodyCouplingWholeGrid {
            origin = .zero
            dims = SIMD3(grid.nx, grid.ny, grid.nz)
        }
        denseCouplingCells = dims.x * dims.y * dims.z
        if bodies.count > 1, configuration.bodyCouplingLayout != .dense, !bodyCouplingWholeGrid {
            let plan = try TiledCoupling(
                grid: grid, bodies: bodies, requestedCapacity: configuration.bodyCouplingTileCapacity)
            if configuration.bodyCouplingLayout == .tiled || plan.bytes < denseCouplingCells * 80 {
                tiledCoupling = plan
                origin = .zero
                dims = SIMD3(grid.nx, grid.ny, grid.nz)
            }
        }
        let regionCells = tiledCoupling?.capacityCells ?? denseCouplingCells
        let wallWords = 3 * regionCells + (tiledCoupling?.wallHeaderWords ?? 0)
        guard
            let occupancy = device.makeBuffer(
                length: 4 * regionCells * MemoryLayout<UInt32>.stride, options: .storageModeShared),
            let wallVelocity = device.makeBuffer(
                length: wallWords * MemoryLayout<Float>.stride, options: .storageModeShared),
            // Momentum and energy per cell, each a 64-bit sum in two words.
            let exchange = device.makeBuffer(
                length: 8 * regionCells * MemoryLayout<UInt32>.stride, options: .storageModeShared),
            let debrisArea = device.makeBuffer(
                length: regionCells * MemoryLayout<Int32>.stride, options: .storageModeShared)
        else {
            throw BlastError.allocationFailed("coupling occupancy")
        }
        memset(occupancy.contents(), 0, occupancy.length)
        memset(wallVelocity.contents(), 0, wallVelocity.length)
        memset(exchange.contents(), 0, exchange.length)
        couplingRegion = (origin, dims)
        occupancyBuffer = occupancy
        if bodies.count > 1 {
            guard let combined = device.makeBuffer(length: occupancy.length, options: .storageModeShared),
                let interaction = device.makeBuffer(length: 4, options: .storageModeShared),
                let envelopes = device.makeBuffer(length: bodies.count * 6 * 4, options: .storageModeShared)
            else { throw BlastError.allocationFailed("multi-body coupling") }
            memset(combined.contents(), 0, combined.length)
            memset(interaction.contents(), 0, interaction.length)
            combinedOccupancyBuffer = combined
            interactionBuffer = interaction
            bodyEnvelopeBuffer = envelopes
        }
        wallVelocityBuffer = wallVelocity
        if let plan = tiledCoupling {
            guard let tiles = device.makeBuffer(length: plan.capacity * 4, options: .storageModeShared)
            else { throw BlastError.allocationFailed("coupling page table") }
            memset(tiles.contents(), 0xFF, tiles.length)
            couplingTiles = tiles
            memset(wallVelocity.contents().advanced(by: 8), 0xFF, plan.mapCount * 4)
        }
        debrisExchangeBuffer = exchange
        debrisAreaBuffer = debrisArea
        resetDebrisExchange()
    }

    func resetDebrisExchange() {
        if let debrisExchangeBuffer {
            memset(debrisExchangeBuffer.contents(), 0, debrisExchangeBuffer.length)
        }
        if let debrisAreaBuffer { memset(debrisAreaBuffer.contents(), 0, debrisAreaBuffer.length) }
    }

    func couplingUniforms(
        _ region: (origin: SIMD3<Int>, dims: SIMD3<Int>), body: StructuralBody? = nil
    ) -> CouplingUniforms {
        var uniforms = CouplingUniforms(
            regionX: UInt32(region.origin.x), regionY: UInt32(region.origin.y),
            regionZ: UInt32(region.origin.z),
            regionNx: UInt32(region.dims.x), regionNy: UInt32(region.dims.y), regionNz: UInt32(region.dims.z),
            fluidNx: UInt32(grid.nx), fluidNy: UInt32(grid.ny), fluidNz: UInt32(grid.nz),
            // A cell any shell passes through is solid.
            threshold: 1, ex: 0, ey: 0, fluidCell: grid.cellSize, h: 0, originX: 0, originY: 0, originZ: 0,
            gamma: configuration.gamma, ambientDensity: ambientDensity,
            ambientPressure: configuration.ambientPressure, airModel: configuration.airModel.rawValue)
        uniforms.couplingMapCount = UInt32(tiledCoupling?.mapCount ?? 0)
        uniforms.couplingTileCapacity = UInt32(tiledCoupling?.capacity ?? 0)
        if let refinement {
            uniforms.refineRatio = UInt32(refinement.ratio)
            uniforms.blocksX = UInt32(refinement.tileDims.x)
            uniforms.blocksY = UInt32(refinement.tileDims.y)
        }
        if let deep = finerRefinement {
            uniforms.deepRatio = UInt32(deep.parentScale * deep.ratio)
            uniforms.deepBlocksX = UInt32(deep.tileDims.x)
            uniforms.deepBlocksY = UInt32(deep.tileDims.y)
            uniforms.deepPatchOffset = UInt32(deep.patchOffset)
            uniforms.deepCellOffset = UInt32(deep.cellOffset)
        }
        // Freestanding objects' cells are theirs, whatever the structure is built of.
        uniforms.holdsBoxes = experimentalBoxMask == nil ? 0 : 1
        if let structure = body?.solids ?? (bodies.count == 1 ? structure : nil) {
            let h = structure.model.elementSize
            // A cell is solid when at least a third of it is filled with intact elements. Elements
            // larger than the cells are sampled at points no further apart than a cell.
            let sampling = Float(configuration.structureMaskSampling ?? 1)
            let fill = configuration.structureMaskFill
            let coarse = max(1, Int((sampling * h / grid.cellSize - 1e-3).rounded(.up)))
            uniforms.coarseSamples = UInt32(coarse)
            let perCell = pow(grid.cellSize * Float(coarse) / h, 3)
            // As boxes, a sample counts `units` when wholly inside a cell.
            let units: UInt32 = configuration.structureMaskOverlap ? 16 : 0
            uniforms.overlapUnits = units
            uniforms.maskHysteresis = configuration.structureMaskOverlap ? 1 : 0
            uniforms.keepsAir = keptAirBuffer == nil ? 0 : 1
            let scale = Float(max(units, 1))
            uniforms.threshold = UInt32(
                max(1, (fill.map { perCell * scale * $0 } ?? perCell * scale / 3).rounded(.up)))
            if let refinement {
                // For the fine cells, each element is sampled at points no further apart than a
                // cell of the finest level, and a fine cell of each level is solid when a third
                // of it is covered.
                let finest = grid.cellSize / Float(refinementLevels.reduce(1) { $0 * $1.ratio })
                let samples = max(1, Int((sampling * h / finest - 1e-3).rounded(.up)))
                func threshold(_ cell: Float) -> UInt32 {
                    let perCell = pow(cell * Float(samples) / h, 3)
                    return UInt32(
                        max(1, (fill.map { perCell * scale * $0 } ?? perCell * scale / 3).rounded(.up)))
                }
                uniforms.fineSamples = UInt32(samples)
                uniforms.fineThreshold = threshold(grid.cellSize / Float(refinement.ratio))
                if finerRefinement != nil { uniforms.deepThreshold = threshold(finest) }
            }
            uniforms.ex = UInt32(structure.ex)
            uniforms.ey = UInt32(structure.ey)
            uniforms.h = h
            (uniforms.originX, uniforms.originY, uniforms.originZ) =
                (structure.origin.x, structure.origin.y, structure.origin.z)
        }
        return uniforms
    }

    private func regionThreads(_ pipeline: MTLComputePipelineState) -> MTLSize {
        let width = pipeline.threadExecutionWidth
        return MTLSize(width: width, height: max(1, pipeline.maxTotalThreadsPerThreadgroup / width), depth: 1)
    }

    func encodeBodyEnvelopes(_ encoder: MTLComputeCommandEncoder, clear: Bool) {
        guard let bounds = bodyEnvelopeBuffer else { return }
        var count = UInt32(bodies.count)
        if clear {
            encoder.setComputePipelineState(clearEnvelopesPipeline)
            encoder.setBuffer(bounds, offset: 0, index: 0)
            encoder.setBytes(&count, length: 4, index: 1)
            encoder.dispatchThreads(
                MTLSize(width: bodies.count, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        }
        for index in bodies.indices { encodeBodyEnvelope(encoder, index: index) }
    }

    func encodeBodyEnvelope(_ encoder: MTLComputeCommandEncoder, index: Int, substep: Int? = nil) {
        guard let bounds = bodyEnvelopeBuffer else { return }
        let body = bodies[index]
        var timing = SIMD2<Float>(substep == nil ? 0 : body.criticalTimeStep, Float(substep ?? 0))
        if let solids = body.solids, solids.nodeCount > 0 {
            var layout = SIMD4<UInt32>(
                UInt32(index), UInt32(solids.ex + 1), UInt32(solids.ey + 1), UInt32(solids.nodeCount))
            var origin = SIMD4<Float>(solids.origin, solids.model.elementSize)
            encoder.setComputePipelineState(solidEnvelopePipeline)
            encoder.setBuffer(solids.nodeBuffer, offset: 0, index: 0)
            encoder.setBuffer(solids.nodeListBuffer, offset: 0, index: 1)
            encoder.setBuffer(bounds, offset: 0, index: 2)
            encoder.setBytes(&layout, length: 16, index: 3)
            encoder.setBytes(&origin, length: 16, index: 4)
            encoder.setBuffer(controlBuffer, offset: 0, index: 5)
            encoder.setBytes(&timing, length: 8, index: 6)
            encoder.dispatchThreads(
                MTLSize(width: solids.nodeCount, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(
                    width: solidEnvelopePipeline.threadExecutionWidth, height: 1, depth: 1))
        }
        if let shells = body.shells, shells.nodeCount > 0 {
            var layout = SIMD4<UInt32>(UInt32(index), 0, 0, UInt32(shells.nodeCount))
            var parameters = SIMD4<Float>(0, 0, 0, body.shellEnvelopeMargin)
            encoder.setComputePipelineState(shellEnvelopePipeline)
            encoder.setBuffer(shells.nodeBuffer, offset: 0, index: 0)
            encoder.setBuffer(shells.referenceBuffer, offset: 0, index: 1)
            encoder.setBuffer(bounds, offset: 0, index: 2)
            encoder.setBytes(&layout, length: 16, index: 3)
            encoder.setBytes(&parameters, length: 16, index: 4)
            encoder.setBuffer(controlBuffer, offset: 0, index: 5)
            encoder.setBytes(&timing, length: 8, index: 6)
            encoder.dispatchThreads(
                MTLSize(width: shells.nodeCount, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(
                    width: shellEnvelopePipeline.threadExecutionWidth, height: 1, depth: 1))
        }
    }

    func encodeWakeCoupling(_ encoder: MTLComputeCommandEncoder) {
        guard tiledCoupling != nil, tilesEnabled else { return }
        var uniforms = makeUniforms()
        encoder.setComputePipelineState(wakeCouplingPipeline)
        encoder.setBuffer(wallVelocityBuffer, offset: 0, index: 0)
        encoder.setBuffer(tileFlagBuffer, offset: 0, index: 1)
        encoder.setBytes(&uniforms, length: MemoryLayout<SolverUniforms>.stride, index: 2)
        encoder.dispatchThreads(
            MTLSize(width: tileDims.x * tileDims.y * tileDims.z, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: wakeCouplingPipeline.threadExecutionWidth, height: 1, depth: 1))
    }
    func encodeAllocateCoupling(_ encoder: MTLComputeCommandEncoder) {
        guard let plan = tiledCoupling, let couplingTiles, let bodyEnvelopeBuffer, let region = couplingRegion
        else { return }
        var uniforms = couplingUniforms(region)
        var count = UInt32(bodies.count)
        encoder.setComputePipelineState(allocateCouplingPipeline)
        encoder.setBuffer(wallVelocityBuffer, offset: 0, index: 0)
        encoder.setBuffer(couplingTiles, offset: 0, index: 1)
        encoder.setBuffer(bodyEnvelopeBuffer, offset: 0, index: 2)
        encoder.setBytes(&count, length: 4, index: 3)
        encoder.setBytes(&uniforms, length: MemoryLayout<CouplingUniforms>.stride, index: 4)
        encoder.dispatchThreads(
            MTLSize(width: plan.mapCount, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: allocateCouplingPipeline.threadExecutionWidth, height: 1, depth: 1))
        encodeWakeCoupling(encoder)
    }
    func couplingSize(_ region: (origin: SIMD3<Int>, dims: SIMD3<Int>)) -> MTLSize {
        tiledCoupling.map { MTLSize(width: $0.capacityCells, height: 1, depth: 1) }
            ?? MTLSize(width: region.dims.x, height: region.dims.y, depth: region.dims.z)
    }
    func couplingThreads(_ pipeline: MTLComputePipelineState) -> MTLSize {
        tiledCoupling == nil
            ? regionThreads(pipeline)
            : MTLSize(width: pipeline.threadExecutionWidth, height: 1, depth: 1)
    }

    func encodeInteractionCheck(_ encoder: MTLComputeCommandEncoder) {
        guard let interactionBuffer, let bounds = bodyEnvelopeBuffer else { return }
        var count = UInt32(bodies.count)
        // With contact, bodies within one of their widest spheres of each other start it, before
        // any spheres can touch.
        var margin: Float =
            configuration.interBodyContact
            ? bodies.map { max($0.model.elementSize, 2 * $0.shellEnvelopeMargin) }.max() ?? 0 : 0
        encoder.setComputePipelineState(validateEnvelopesPipeline)
        encoder.setBuffer(bounds, offset: 0, index: 0)
        encoder.setBytes(&count, length: 4, index: 1)
        encoder.setBuffer(interactionBuffer, offset: 0, index: 2)
        encoder.setBytes(&margin, length: 4, index: 3)
        encoder.dispatchThreads(
            MTLSize(width: bodies.count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        if tiledCoupling != nil {
            encoder.setComputePipelineState(haltCouplingPipeline)
            encoder.setBuffer(wallVelocityBuffer, offset: 0, index: 0)
            encoder.setBuffer(interactionBuffer, offset: 0, index: 1)
            encoder.setBuffer(controlBuffer, offset: 0, index: 2)
            encoder.dispatchThreads(
                MTLSize(width: 1, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        }
        // Once in contact, bodies coming close is no reason to stop.
        var halting: UInt32 = bodiesInContact ? ~1 : ~0
        encoder.setComputePipelineState(haltInteractionPipeline)
        encoder.setBuffer(interactionBuffer, offset: 0, index: 0)
        encoder.setBuffer(controlBuffer, offset: 0, index: 1)
        encoder.setBytes(&halting, length: 4, index: 2)
        encoder.dispatchThreads(
            MTLSize(width: 1, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
    }

    /// Encodes `count` substeps of every body a substep at a time, side by side, with contact
    /// between them: each body fills its own contact table and finds its own contacts, then each
    /// pair of bodies meets (`encodeBodyContact`), and only then does any body move.
    func encodeBodiesInContact(
        _ encoder: MTLComputeCommandEncoder, count: Int, fluid: StructureSolver.FluidBinding
    ) {
        for substep in 0..<count {
            func nest(_ index: Int, _ parts: [(body: Int, part: StructuralBody.ContactPart)]) {
                guard index < bodies.count else {
                    encodeBodyContact(encoder, parts, control: fluid.control)
                    return
                }
                bodies[index].encodeSubsteps(
                    encoder, substeps: substep..<(substep + 1), prelude: substep == 0, fluid: fluid,
                    beforeNodes: { found in nest(index + 1, parts + found.map { (index, $0) }) },
                    afterSubstep: { [self] step in encodeBodyEnvelope(encoder, index: index, substep: step) })
            }
            nest(0, [])
        }
    }

    private func bodyContactPipeline(_ name: String) -> MTLComputePipelineState? {
        if let pipeline = bodyContactPipelines[name] { return pipeline }
        let pipeline = try? ShaderLibrary.pipeline(name, in: library)
        bodyContactPipelines[name] = pipeline
        return pipeline
    }

    /// Each part of each body against each part of every other, both ways round, with the same
    /// spring, damper and friction from both sides: the softer spring, less damping and less
    /// friction of the two.
    private func encodeBodyContact(
        _ encoder: MTLComputeCommandEncoder, _ parts: [(body: Int, part: StructuralBody.ContactPart)],
        control: MTLBuffer
    ) {
        guard let bounds = bodyEnvelopeBuffer, !bodyContactPairsSkipped else { return }
        struct Side {
            var width: Float
            var stiffness: Float
            var damping: Float
            var friction: Float
            var nodes: Int
        }
        func side(_ part: StructuralBody.ContactPart) -> Side {
            switch part {
            case .solid(let solver, let u):
                Side(
                    width: u.h, stiffness: u.contactStiffness, damping: u.contactDamping,
                    friction: u.contactFriction, nodes: solver.nodeCount)
            case .shell(let solver, let u):
                Side(
                    width: u.contactRadius, stiffness: u.contactStiffness, damping: u.contactDamping,
                    friction: u.contactFriction, nodes: solver.nodeCount)
            }
        }
        for a in parts.indices {
            for b in parts.indices where parts[a].body != parts[b].body {
                let own = side(parts[a].part)
                let other = side(parts[b].part)
                guard own.nodes > 0, other.nodes > 0 else { continue }
                var contact = StructuralBody.ContactParameters(
                    reach: 0.5 * (own.width + other.width), stiffness: min(own.stiffness, other.stiffness),
                    damping: min(own.damping, other.damping), friction: min(own.friction, other.friction),
                    own: UInt32(parts[a].body), other: UInt32(parts[b].body))
                let name: String
                switch (parts[a].part, parts[b].part) {
                case (.solid, .solid): name = "bodyContactSolidFromSolid"
                case (.solid, .shell): name = "bodyContactSolidFromShell"
                case (.shell, .solid): name = "bodyContactShellFromSolid"
                case (.shell, .shell): name = "bodyContactShellFromShell"
                }
                guard let pipeline = bodyContactPipeline(name) else { continue }
                encoder.setComputePipelineState(pipeline)
                switch parts[a].part {
                case .solid(let solver, var u):
                    encoder.setBuffer(solver.nodeListBuffer, offset: 0, index: 0)
                    encoder.setBuffer(solver.nodeBuffer, offset: 0, index: 1)
                    encoder.setBuffer(solver.contactSlotBuffer, offset: 0, index: 2)
                    encoder.setBytes(&u, length: MemoryLayout<StructureUniforms>.stride, index: 3)
                    encoder.setBuffer(solver.contactForceBuffer, offset: 0, index: 5)
                case .shell(let solver, var u):
                    encoder.setBuffer(solver.nodeBuffer, offset: 0, index: 0)
                    encoder.setBuffer(solver.referenceBuffer, offset: 0, index: 1)
                    encoder.setBuffer(solver.contactSlotBuffer, offset: 0, index: 2)
                    encoder.setBytes(&u, length: MemoryLayout<ShellUniforms>.stride, index: 3)
                    encoder.setBuffer(solver.contactForceBuffer, offset: 0, index: 5)
                }
                encoder.setBuffer(control, offset: 0, index: 4)
                switch parts[b].part {
                case .solid(let solver, var u):
                    encoder.setBuffer(solver.nodeListBuffer, offset: 0, index: 6)
                    encoder.setBuffer(solver.nodeBuffer, offset: 0, index: 7)
                    encoder.setBuffer(solver.contactHeadBuffer, offset: 0, index: 8)
                    encoder.setBuffer(solver.contactSlotBuffer, offset: 0, index: 9)
                    encoder.setBytes(&u, length: MemoryLayout<StructureUniforms>.stride, index: 10)
                case .shell(let solver, var u):
                    encoder.setBuffer(solver.nodeBuffer, offset: 0, index: 6)
                    encoder.setBuffer(solver.referenceBuffer, offset: 0, index: 7)
                    encoder.setBuffer(solver.contactHeadBuffer, offset: 0, index: 8)
                    encoder.setBuffer(solver.contactSlotBuffer, offset: 0, index: 9)
                    encoder.setBytes(&u, length: MemoryLayout<ShellUniforms>.stride, index: 10)
                }
                encoder.setBytes(
                    &contact, length: MemoryLayout<StructuralBody.ContactParameters>.stride, index: 11)
                encoder.setBuffer(bounds, offset: 0, index: 12)
                encoder.dispatchThreads(
                    MTLSize(width: own.nodes, height: 1, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: pipeline.threadExecutionWidth, height: 1, depth: 1))
            }
        }
    }

    /// Encodes the return to the air of what loose debris took from it during the substeps.
    func encodeDebrisExchange(_ encoder: MTLComputeCommandEncoder) {
        guard hasBody, let region = couplingRegion, let debrisExchangeBuffer else { return }
        var uniforms = couplingUniforms(region)
        encoder.setComputePipelineState(debrisExchangePipeline)
        encoder.setBuffer(stateBuffers[current], offset: 0, index: 0)
        encoder.setBuffer(debrisExchangeBuffer, offset: 0, index: 1)
        encoder.setBytes(&uniforms, length: MemoryLayout<CouplingUniforms>.stride, index: 2)
        encoder.setBuffer(debrisAreaBuffer, offset: 0, index: 3)
        encoder.setBuffer(couplingTiles ?? refinementPlaceholder, offset: 0, index: 4)
        encoder.dispatchThreads(
            couplingSize(region), threadsPerThreadgroup: couplingThreads(debrisExchangePipeline))
    }

    /// How one body was brought to rest under its own weight before the blast.
    public struct Settlement: Sendable {
        public var name: String
        /// Whether its motion died away; if not, it starts undeformed, as without settling.
        public var settled: Bool
        /// Time it was given, s, and the steps that took.
        public var time: Double
        public var steps: Int
        /// The wall-clock time it took, s.
        public var seconds: Double
        /// Its mean (mass-weighted root-mean-square) speed at the end, as a share of the largest
        /// on the way, and its largest displacement then, m.
        public var residualSpeed: Double
        public var displacement: Float
    }

    /// Settling's mass-proportional damping (1/s), the least time it gives a body, the time it
    /// gives a body at most, and how still a body must be, as its mean speed's share of the
    /// largest on the way.
    public static let settleDamping: Float = 50
    public static let settleMinimum = 0.02
    public static let settleLimit = 1.0
    public static let settleTolerance = 0.01

    /// Brings each body to rest under its own weight, alone and without the air, before the
    /// first step (the first batch does it if no one has): heavily damped until its motion has
    /// died away, then stopped where it is, its clock back at zero. Its deformation, stresses and
    /// any cracking from its own weight stay. A body that does not come to rest within
    /// `settleLimit` (one falling, or not standing) is put back undeformed and starts as it
    /// would without settling. Nothing is done with `configuration.settlesStructures` off (or
    /// `BOMBCAD_SETTLE=off` in the environment, for benches), once the run has started, or for a
    /// body without gravity, with motion set by the scene, or no longer as loaded (moved, set
    /// moving or broken since).
    public func settleStructures() {
        guard configuration.settlesStructures, !structuresSettled, stepCount == 0,
            ProcessInfo.processInfo.environment["BOMBCAD_SETTLE"] != "off"
        else { return }
        precondition(!batchInFlight, "Cannot settle while a batch is in flight")
        structuresSettled = true
        var moved = false
        for body in bodies where body.gravity > 0 && !body.hasSetMotion && body.isAsLoaded {
            let start = Date()
            let step = Double(body.criticalTimeStep)
            let chunk = max(1, Int((0.005 / step).rounded(.up)))
            let damping = body.damping
            body.damping = Self.settleDamping
            var elapsed = 0.0
            var steps = 0
            var peak = 0.0
            var speed = 0.0
            var settled = false
            var before: [(displacement: SIMD3<Float>, mass: Float)] = []
            while elapsed < Self.settleLimit {
                if elapsed + Double(chunk) * step >= Self.settleLimit { before = body.displacements() }
                // In a pool of its own: the steps' command buffers, and reading the motion back
                // (`MTLBuffer.contents()`), autorelease the body's buffers, and settling takes
                // thousands of steps on a thread whose pool may never drain.
                let (energy, mass) = autoreleasepool { () -> (Double, Double) in
                    body.advanceAlone(steps: chunk)
                    return body.motion()
                }
                steps += chunk
                elapsed += Double(chunk) * step
                speed = mass > 0 ? (2 * energy / mass).squareRoot() : 0
                peak = max(peak, speed)
                if elapsed >= Self.settleMinimum && speed <= Self.settleTolerance * peak {
                    settled = true
                    break
                }
            }
            if !settled, !before.isEmpty {
                // Still moving at the limit: settled all the same if it has come to rest over its last
                // chunk, its mean speed over it (its displacement's change) within the tolerance. A
                // joint on a footing chatters at rest, its nodes' speed never falling to 1% of the
                // sag's, its displacement still (`StructureOnTerrainTests`).
                let after = body.displacements()
                var squares = 0.0
                var mass = 0.0
                for (old, new) in zip(before, after) {
                    let moved = Double(simd_length(new.displacement - old.displacement))
                    squares += Double(new.mass) * moved * moved
                    mass += Double(new.mass)
                }
                let mean = mass > 0 ? (squares / mass).squareRoot() / (Double(chunk) * step) : 0
                if mean <= Double(Self.settleTolerance) * peak {
                    settled = true
                    speed = mean
                }
            }
            body.damping = damping
            if settled {
                body.holdStill()
            } else {
                body.reset()
            }
            moved = true
            settlements.append(
                Settlement(
                    name: body.name, settled: settled, time: elapsed, steps: steps,
                    seconds: Date().timeIntervalSince(start), residualSpeed: peak > 0 ? speed / peak : 0,
                    displacement: body.summary()?.selfWeightSag ?? 0))
        }
        guard moved, let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return }
        // Mark the settled structure in the solid mask.
        encodeBodyEnvelopes(encoder, clear: true)
        encodeRemask(encoder, fine: false)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    /// Damage and deflection of the deformable body, both parts of it if mixed.
    public func bodySummary() -> StructureSummary? {
        bodies.compactMap { $0.summary() }.reduce(nil) { total, summary in
            total.map { $0.combined(with: summary) } ?? summary
        }
    }

    /// Structural substeps encoded per fluid step. The fluid step never exceeds the CFL limit
    /// for (slightly cooled) ambient air, which bounds how many are needed.
    public var structureSubsteps: Int {
        guard let bodyStep else { return 0 }
        let bound = configuration.cfl * grid.cellSize / (0.8 * ambientSoundSpeed)
        return min(max(Int((bound / bodyStep).rounded(.up)), 1), 96)
    }
}
