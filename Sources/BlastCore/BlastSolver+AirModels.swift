import BlastModel
import Foundation
import Metal
import RadialBlast
import simd

// The air solver's options on the air itself: gravity's hydrostatic fill and background tables,
// sub-grid mixing's eddy viscosity, periodic sides, and the species (unburnt products and oxygen)
// the air carries.
extension BlastSolver {
    /// Whether the air carries fuel and oxygen, so that its charges burn.
    var hasSpecies: Bool { !speciesBuffers.isEmpty }
    /// The current fuel and oxygen, or a placeholder without them.
    var currentSpecies: MTLBuffer { hasSpecies ? speciesBuffers[current] : noSpecies }
    /// Mass fraction of oxygen in air, and the oxygen TNT's products need to burn completely
    /// (C7H5N3O6 + 5.25 O2 -> 7 CO2 + 2.5 H2O + 1.5 N2), per kilogram.
    static let oxygenInAir: Float = 0.232
    static let oxygenPerFuel: Float = 5.25 * 32 / 227.13
    /// Whether a deflagration's flame burns in the air (rather than only vent panels standing).
    var hasFlame: Bool { deflagrationStage?.deflagration != nil }
    /// Whether the species hold afterburning's detonation products and oxygen (rather than a
    /// deflagration's unburnt mixture, or nothing).
    public var speciesHoldDetonationProducts: Bool { hasSpecies && !hasFlame }

    /// Fills both state buffers, and the oxygen with afterburning, with gravity's hydrostatic
    /// background, on the GPU, as the sweeps work it out (see `AirGravity`).
    func fillHydrostatic() {
        gravityTables = [:]
        let constants = MTLFunctionConstantValues()
        var model = configuration.airModel.rawValue
        constants.setConstantValue(&model, type: .uint, index: ShaderLibrary.airModelConstant)
        guard
            let table = gravityTable(scale: 1),
            let pipeline = try? ShaderLibrary.pipeline("fillHydrostatic", in: library, constants: constants),
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return }
        var uniforms = makeUniforms()
        var oxygen: Float = hasSpecies ? Self.oxygenInAir : 0
        encoder.setComputePipelineState(pipeline)
        encoder.setBytes(&oxygen, length: MemoryLayout<Float>.stride, index: 2)
        encoder.setBytes(&uniforms, length: MemoryLayout<SolverUniforms>.stride, index: 3)
        encoder.setBuffer(table, offset: 0, index: 4)
        for n in 0..<2 {
            encoder.setBuffer(stateBuffers[n], offset: 0, index: 0)
            encoder.setBuffer(hasSpecies ? speciesBuffers[n] : noSpecies, offset: 0, index: 1)
            dispatchGrid(encoder, pipeline: pipeline)
        }
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    /// `base`, kernel `name`, or with gravity in the air compiled in while the air has gravity.
    func gravityVariant(_ base: MTLComputePipelineState, _ name: String) -> MTLComputePipelineState {
        guard configuration.gravity != nil else { return base }
        if let pipeline = gravityPipelines[name] { return pipeline }
        guard
            let pipeline = try? ShaderLibrary.pipeline(
                name, in: library, constants: ShaderLibrary.withGravity(MTLFunctionConstantValues()))
        else { return base }
        gravityPipelines[name] = pipeline
        return pipeline
    }

    /// The eddy viscosity's buffer while the air has sub-grid mixing, made when first needed.
    func mixingViscosity() -> MTLBuffer? {
        guard configuration.mixing != nil else { return nil }
        if let viscosityBuffer { return viscosityBuffer }
        viscosityBuffer = device.makeBuffer(
            length: grid.cellCount * MemoryLayout<Float>.stride, options: .storageModeShared)
        viscosityBuffer?.label = "eddy viscosity"
        if let viscosityBuffer { memset(viscosityBuffer.contents(), 0, viscosityBuffer.length) }
        return viscosityBuffer
    }

    /// Encodes the eddy viscosity of every coarse cell from the state at the start of the step.
    func encodeEddyViscosity(_ encoder: MTLComputeCommandEncoder, uniforms: SolverUniforms) {
        guard let viscosity = mixingViscosity() else { return }
        if viscosityPipeline == nil {
            viscosityPipeline = try? ShaderLibrary.pipeline("eddyViscosity", in: library)
        }
        guard let pipeline = viscosityPipeline else { return }
        var uniforms = uniforms
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(stateBuffers[current], offset: 0, index: 0)
        encoder.setBuffer(maskBuffer, offset: 0, index: 1)
        encoder.setBuffer(viscosity, offset: 0, index: 2)
        encoder.setBytes(&uniforms, length: MemoryLayout<SolverUniforms>.stride, index: 3)
        encoder.setBuffer(controlBuffer, offset: 0, index: 4)
        dispatchGrid(encoder, pipeline: pipeline)
    }

    /// Refills the periodic halo of the current state (see `SolverConfiguration.periodicSides`),
    /// then restores the sweep's own pipeline and buffers.
    func encodePeriodicHalo(_ encoder: MTLComputeCommandEncoder, uniforms: SolverUniforms) {
        if periodicPipeline == nil {
            periodicPipeline = try? ShaderLibrary.pipeline("periodicHalo", in: library)
        }
        guard let pipeline = periodicPipeline, let kernels = try? cellKernels() else { return }
        var uniforms = uniforms
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(stateBuffers[current], offset: 0, index: 0)
        encoder.setBytes(&uniforms, length: MemoryLayout<SolverUniforms>.stride, index: 1)
        dispatchGrid(encoder, pipeline: pipeline)
        encoder.setComputePipelineState(tilesEnabled ? kernels.sweepTiles : kernels.sweep)
        encoder.setBuffer(maskBuffer, offset: 0, index: 2)
    }

    /// Gives each refined level gravity's background at its resolution and its parent's.
    func assignGravityTables() {
        for level in refinementLevels {
            level.gravityTable = gravityTable(scale: level.parentScale * level.ratio)
            level.parentGravityTable = gravityTable(scale: level.parentScale)
            level.viscosity = mixingViscosity()
            level.burnLimit = configuration.afterburnLimit != nil
            level.burnMixing = configuration.afterburnMixing != nil && level.viscosity != nil
        }
    }

    /// Gravity's background for the level with `scale` cells along a coarse cell's edge: a row a
    /// cell of its height, from 4 below the ground to 4 above the top (see `gravityCellOf`).
    func gravityTable(scale: Int) -> MTLBuffer? {
        guard configuration.gravity != nil else { return nil }
        if let table = gravityTables[scale] { return table }
        let constants = MTLFunctionConstantValues()
        var model = configuration.airModel.rawValue
        constants.setConstantValue(&model, type: .uint, index: ShaderLibrary.airModelConstant)
        var rows = UInt32(grid.nz * scale + 8)
        var dz = grid.cellSize / Float(scale)
        guard
            let pipeline = try? ShaderLibrary.pipeline("gravityTable", in: library, constants: constants),
            let table = device.makeBuffer(
                length: 2 * Int(rows) * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared),
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return nil }
        table.label = "gravity's background"
        var uniforms = makeUniforms()
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(table, offset: 0, index: 0)
        encoder.setBytes(&rows, length: MemoryLayout<UInt32>.stride, index: 1)
        encoder.setBytes(&dz, length: MemoryLayout<Float>.stride, index: 2)
        encoder.setBytes(&uniforms, length: MemoryLayout<SolverUniforms>.stride, index: 3)
        encoder.dispatchThreads(
            MTLSize(width: Int(rows), height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: min(Int(rows), 256), height: 1, depth: 1))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        gravityTables[scale] = table
        return table
    }

    /// Direct access to the densities of unburnt detonation products (x) and oxygen (y).
    func mutateSpecies(_ body: (UnsafeMutableBufferPointer<SIMD2<Float>>) throws -> Void) rethrows {
        precondition(!batchInFlight, "Cannot edit state while a batch is in flight")
        guard hasSpecies else { return }
        let pointer = speciesBuffers[current].contents().bindMemory(
            to: SIMD2<Float>.self, capacity: grid.cellCount)
        try body(UnsafeMutableBufferPointer(start: pointer, count: grid.cellCount))
    }

    /// The densities of unburnt detonation products (x) and oxygen (y) to read, or nil without
    /// afterburning.
    public func readSpecies<R>(_ body: (UnsafeBufferPointer<SIMD2<Float>>?) throws -> R) rethrows -> R {
        precondition(!batchInFlight, "Cannot read state while a batch is in flight")
        guard hasSpecies else { return try body(nil) }
        let pointer = speciesBuffers[current].contents().bindMemory(
            to: SIMD2<Float>.self, capacity: grid.cellCount)
        return try body(UnsafeBufferPointer(start: pointer, count: grid.cellCount))
    }

    /// Calls `body` with every coarse cell's eddy viscosity (m²/s) as the last step's sub-grid mixing
    /// worked it out, or nil without sub-grid mixing.
    public func readEddyViscosity<R>(_ body: (UnsafeBufferPointer<Float>?) throws -> R) rethrows -> R {
        precondition(!batchInFlight, "Cannot read state while a batch is in flight")
        guard let viscosity = mixingViscosity() else { return try body(nil) }
        let pointer = viscosity.contents().bindMemory(to: Float.self, capacity: grid.cellCount)
        return try body(UnsafeBufferPointer(start: pointer, count: grid.cellCount))
    }

    /// Total unburnt detonation products (kg) and oxygen (kg) in the air.
    public func speciesTotals() -> (fuel: Double, oxygen: Double) {
        precondition(!batchInFlight, "Cannot read state while a batch is in flight")
        guard hasSpecies else { return (0, 0) }
        let mask = maskContents.bindMemory(to: UInt8.self, capacity: grid.cellCount)
        let species = speciesBuffers[current].contents().bindMemory(
            to: SIMD2<Float>.self, capacity: grid.cellCount)
        let volume = Double(grid.cellSize) * Double(grid.cellSize) * Double(grid.cellSize)
        let fine = refinedGas()
        var total = SIMD2<Double>.zero
        for index in 0..<grid.cellCount where mask[index] == 0 && fine?.covered.contains(index) != true {
            total += SIMD2(Double(species[index].x), Double(species[index].y)) * openShare(index)
        }
        total = total * volume + (fine?.species ?? .zero)
        return (total.x, total.y)
    }
}
