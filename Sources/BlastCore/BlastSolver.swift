import Foundation
import Metal
import simd

/// GPU finite-volume solver for the compressible Euler equations around rigid obstacles.
///
/// The solver is not thread-safe: drive it from one isolation domain. Stepping is split into
/// `encodeBatch` / `completeBatch` so an app can commit work without blocking, while
/// `advance(steps:)` and `advance(until:)` wrap the pair synchronously for tools and tests.
public final class BlastSolver {
    public static let maxStepsPerBatch = 256
    public static let maxGauges = 16

    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    public let grid: Grid
    public var configuration: SolverConfiguration

    /// Simulated time in seconds since the last `restart()`.
    public private(set) var time: Double = 0
    public private(set) var stepCount = 0
    /// One pressure history per gauge, in the order passed to `setGauges`.
    public private(set) var gaugeHistories: [[GaugeSample]] = []
    /// `rgba16Float` volume: overpressure and peak overpressure (both in units of ambient
    /// pressure), positive impulse (Pa s) and a solid flag. Refreshed on request.
    public let visualizationTexture: MTLTexture
    /// The deformable body advanced alongside the air, if the scenario has one.
    public private(set) var structure: StructureSolver?
    /// Sound speed of the undisturbed air, used to bound the fluid time step.
    var ambientSoundSpeed: Float = 340
    var ambientDensity: Float = 1.225
    /// Cells of the air grid, around the structure, whose solid flag follows the structure.
    private var couplingRegion: (origin: SIMD3<Int>, dims: SIMD3<Int>)?
    private var occupancyBuffer: MTLBuffer?
    /// What loose debris takes from the air in each cell of the coupling region during one air step.
    private var debrisExchangeBuffer: MTLBuffer?
    /// The frontal area of the loose debris in each cell of the coupling region.
    private var debrisAreaBuffer: MTLBuffer?
    /// Velocity of the solid in each cell of the coupling region, three floats per cell. A
    /// single zero cell stands in when there is no structure.
    private var wallVelocityBuffer: MTLBuffer
    private let stillWallBuffer: MTLBuffer

    let library: MTLLibrary
    private let sweepPipeline: MTLComputePipelineState
    private let preparePipeline: MTLComputePipelineState
    private let measurePipeline: MTLComputePipelineState
    private let visualizationPipeline: MTLComputePipelineState
    private let splatPipeline: MTLComputePipelineState
    private let remaskPreparePipeline: MTLComputePipelineState
    private let remaskApplyPipeline: MTLComputePipelineState
    private let debrisExchangePipeline: MTLComputePipelineState

    private let stateBuffers: [MTLBuffer]
    private var current = 0
    private let maskBuffer: MTLBuffer
    /// Solid flags of the rigid blocks alone, which never change.
    private let rigidMaskBuffer: MTLBuffer
    private let peakBuffer: MTLBuffer
    private let impulseBuffer: MTLBuffer
    private let controlBuffer: MTLBuffer
    private let maxSpeedBuffer: MTLBuffer
    private let gaugeLogBuffer: MTLBuffer
    private let gaugeCellBuffer: MTLBuffer
    private var gaugeCount = 0
    private var batchInFlight = false
    /// True once the blast has left and the air has been frozen; only the structure advances.
    public private(set) var airIsAsleep = false
    /// The air's time step at the end of the last batch, which sizes the next batch's substeps.
    private var lastFluidStep: Float = 0

    public init(
        device: MTLDevice,
        commandQueue: MTLCommandQueue? = nil,
        grid: Grid,
        configuration: SolverConfiguration = SolverConfiguration()
    ) throws {
        self.device = device
        self.grid = grid
        self.configuration = configuration
        guard let queue = commandQueue ?? device.makeCommandQueue() else {
            throw BlastError.allocationFailed("command queue")
        }
        self.commandQueue = queue

        let library = try ShaderLibrary.make(device: device)
        self.library = library
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else {
                throw BlastError.missingFunction(name)
            }
            return try device.makeComputePipelineState(function: function)
        }
        sweepPipeline = try pipeline("sweep")
        preparePipeline = try pipeline("prepareStep")
        measurePipeline = try pipeline("measureWaveSpeed")
        visualizationPipeline = try pipeline("updateVisualization")
        splatPipeline = try pipeline("splatStructure")
        remaskPreparePipeline = try pipeline("remaskPrepare")
        remaskApplyPipeline = try pipeline("remaskApply")
        debrisExchangePipeline = try pipeline("debrisExchange")

        func buffer(_ length: Int, _ label: String) throws -> MTLBuffer {
            guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else {
                throw BlastError.allocationFailed("\(label) (\(length) bytes)")
            }
            buffer.label = label
            return buffer
        }
        let cells = grid.cellCount
        let stateLength = cells * MemoryLayout<CellState>.stride
        stateBuffers = [try buffer(stateLength, "state A"), try buffer(stateLength, "state B")]
        maskBuffer = try buffer(cells, "solid mask")
        rigidMaskBuffer = try buffer(cells, "rigid mask")
        stillWallBuffer = try buffer(3 * MemoryLayout<Float>.stride, "still wall")
        memset(stillWallBuffer.contents(), 0, stillWallBuffer.length)
        wallVelocityBuffer = stillWallBuffer
        peakBuffer = try buffer(cells * MemoryLayout<Float>.stride, "peak overpressure")
        impulseBuffer = try buffer(cells * MemoryLayout<Float>.stride, "impulse")
        controlBuffer = try buffer(MemoryLayout<StepControl>.stride, "step control")
        maxSpeedBuffer = try buffer(2 * MemoryLayout<UInt32>.stride, "max wave speed and overpressure")
        gaugeLogBuffer = try buffer(
            Self.maxStepsPerBatch * (Self.maxGauges + 1) * MemoryLayout<Float>.stride, "gauge log")
        gaugeCellBuffer = try buffer(Self.maxGauges * MemoryLayout<UInt32>.stride, "gauge cells")

        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba16Float
        descriptor.width = grid.nx
        descriptor.height = grid.ny
        descriptor.depth = grid.nz
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw BlastError.allocationFailed("visualization texture")
        }
        texture.label = "visualization"
        visualizationTexture = texture

        memset(maskBuffer.contents(), 0, cells)
        memset(rigidMaskBuffer.contents(), 0, cells)
        fill(uniform: Primitive(density: 1.225, pressure: configuration.ambientPressure))
    }

    // MARK: - Initial conditions

    /// Sets every cell to the same state and restarts the clock.
    public func fill(uniform primitive: Primitive) {
        let cell = CellState(primitive, gamma: configuration.gamma)
        for buffer in stateBuffers {
            buffer.contents().bindMemory(to: CellState.self, capacity: grid.cellCount)
                .update(repeating: cell, count: grid.cellCount)
        }
        restart()
    }

    /// Sets every cell from a closure and restarts the clock. Intended for small grids.
    public func fill(_ body: (_ i: Int, _ j: Int, _ k: Int) -> Primitive) {
        let gamma = configuration.gamma
        mutateState { cells in
            for k in 0..<grid.nz {
                for j in 0..<grid.ny {
                    for i in 0..<grid.nx {
                        cells[grid.index(i, j, k)] = CellState(body(i, j, k), gamma: gamma)
                    }
                }
            }
        }
        restart()
    }

    /// Direct access to the current conserved state. Call `restart()` after editing.
    public func mutateState(_ body: (UnsafeMutableBufferPointer<CellState>) throws -> Void) rethrows {
        precondition(!batchInFlight, "Cannot edit state while a batch is in flight")
        let pointer = stateBuffers[current].contents().bindMemory(
            to: CellState.self, capacity: grid.cellCount)
        try body(UnsafeMutableBufferPointer(start: pointer, count: grid.cellCount))
    }

    /// Direct access to the solid mask (non-zero marks a rigid cell). Call `restart()` after editing.
    public func mutateMask(_ body: (UnsafeMutableBufferPointer<UInt8>) throws -> Void) rethrows {
        precondition(!batchInFlight, "Cannot edit the mask while a batch is in flight")
        let pointer = maskBuffer.contents().bindMemory(to: UInt8.self, capacity: grid.cellCount)
        try body(UnsafeMutableBufferPointer(start: pointer, count: grid.cellCount))
    }

    /// Chooses the cells whose pressure is recorded every step. Clears existing histories.
    public func setGauges(cells: [(i: Int, j: Int, k: Int)]) {
        precondition(cells.count <= Self.maxGauges, "At most \(Self.maxGauges) gauges are supported")
        let pointer = gaugeCellBuffer.contents().bindMemory(to: UInt32.self, capacity: Self.maxGauges)
        for (n, cell) in cells.enumerated() {
            precondition(grid.contains(cell.i, cell.j, cell.k), "Gauge outside the grid")
            pointer[n] = UInt32(grid.index(cell.i, cell.j, cell.k))
        }
        gaugeCount = cells.count
        gaugeHistories = Array(repeating: [], count: gaugeCount)
    }

    /// Replaces the deformable body. The current solid mask is taken as the rigid scenery, and
    /// the structure is added to it at the next `restart()`.
    public func setStructure(_ model: StructureModel?) throws {
        precondition(!batchInFlight, "Cannot change the structure while a batch is in flight")
        structure = nil
        couplingRegion = nil
        occupancyBuffer = nil
        debrisExchangeBuffer = nil
        debrisAreaBuffer = nil
        wallVelocityBuffer = stillWallBuffer
        memcpy(rigidMaskBuffer.contents(), maskBuffer.contents(), grid.cellCount)
        guard let model else { return }
        structure = try StructureSolver(
            device: device, commandQueue: commandQueue, library: library, model: model)

        // Follow the structure within a few metres of where it starts.
        let bounds = model.bounds
        let margin = SIMD3<Float>(4, 4, 3)
        let low = grid.cell(containing: bounds.min - margin)
        let high = grid.cell(containing: bounds.max + margin)
        let origin = SIMD3(low.i, low.j, low.k)
        let dims = SIMD3(high.i - low.i + 1, high.j - low.j + 1, high.k - low.k + 1)
        // Four counters per cell: the number of elements in it and the sum of their velocities.
        let regionCells = dims.x * dims.y * dims.z
        guard
            let occupancy = device.makeBuffer(
                length: 4 * regionCells * MemoryLayout<UInt32>.stride, options: .storageModeShared),
            let wallVelocity = device.makeBuffer(
                length: 3 * regionCells * MemoryLayout<Float>.stride, options: .storageModeShared),
            let exchange = device.makeBuffer(
                length: 4 * regionCells * MemoryLayout<Int32>.stride, options: .storageModeShared),
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
        wallVelocityBuffer = wallVelocity
        debrisExchangeBuffer = exchange
        debrisAreaBuffer = debrisArea
        resetDebrisExchange()
    }

    private func resetDebrisExchange() {
        if let debrisExchangeBuffer {
            memset(debrisExchangeBuffer.contents(), 0, debrisExchangeBuffer.length)
        }
        if let debrisAreaBuffer { memset(debrisAreaBuffer.contents(), 0, debrisAreaBuffer.length) }
    }

    private func couplingUniforms(
        _ structure: StructureSolver, _ region: (origin: SIMD3<Int>, dims: SIMD3<Int>)
    ) -> CouplingUniforms {
        let h = structure.model.elementSize
        let perCell = pow(grid.cellSize / h, 3)
        return CouplingUniforms(
            regionX: UInt32(region.origin.x), regionY: UInt32(region.origin.y),
            regionZ: UInt32(region.origin.z),
            regionNx: UInt32(region.dims.x), regionNy: UInt32(region.dims.y), regionNz: UInt32(region.dims.z),
            fluidNx: UInt32(grid.nx), fluidNy: UInt32(grid.ny), fluidNz: UInt32(grid.nz),
            // A cell is solid when at least a third of it is filled with intact elements.
            threshold: UInt32(max(1, (perCell / 3).rounded(.up))),
            ex: UInt32(structure.ex), ey: UInt32(structure.ey),
            fluidCell: grid.cellSize, h: h,
            originX: structure.origin.x, originY: structure.origin.y, originZ: structure.origin.z,
            gamma: configuration.gamma, ambientDensity: ambientDensity,
            ambientPressure: configuration.ambientPressure)
    }

    private func regionThreads(_ pipeline: MTLComputePipelineState) -> MTLSize {
        let width = pipeline.threadExecutionWidth
        return MTLSize(width: width, height: max(1, pipeline.maxTotalThreadsPerThreadgroup / width), depth: 1)
    }

    /// Encodes the return to the air of what loose debris took from it during the substeps.
    private func encodeDebrisExchange(_ encoder: MTLComputeCommandEncoder) {
        guard let structure, let region = couplingRegion, let debrisExchangeBuffer else { return }
        var uniforms = couplingUniforms(structure, region)
        encoder.setComputePipelineState(debrisExchangePipeline)
        encoder.setBuffer(stateBuffers[current], offset: 0, index: 0)
        encoder.setBuffer(debrisExchangeBuffer, offset: 0, index: 1)
        encoder.setBytes(&uniforms, length: MemoryLayout<CouplingUniforms>.stride, index: 2)
        encoder.setBuffer(debrisAreaBuffer, offset: 0, index: 3)
        encoder.dispatchThreads(
            MTLSize(width: region.dims.x, height: region.dims.y, depth: region.dims.z),
            threadsPerThreadgroup: regionThreads(debrisExchangePipeline))
    }

    /// Encodes one update of the solid mask from the structure's current shape.
    private func encodeRemask(_ encoder: MTLComputeCommandEncoder) {
        guard let structure, let region = couplingRegion, let occupancyBuffer else { return }
        var uniforms = couplingUniforms(structure, region)
        let length = MemoryLayout<CouplingUniforms>.stride

        encoder.setComputePipelineState(splatPipeline)
        encoder.setBuffer(structure.instanceBuffer, offset: 0, index: 0)
        encoder.setBuffer(structure.flagBuffer, offset: 0, index: 1)
        encoder.setBuffer(structure.nodeBuffer, offset: 0, index: 2)
        encoder.setBuffer(occupancyBuffer, offset: 0, index: 3)
        encoder.setBytes(&uniforms, length: length, index: 4)
        encoder.setBuffer(structure.nodeMapBuffer, offset: 0, index: 5)
        encoder.dispatchThreads(
            MTLSize(width: structure.elementCount, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: splatPipeline.maxTotalThreadsPerThreadgroup, height: 1, depth: 1))

        let size = MTLSize(width: region.dims.x, height: region.dims.y, depth: region.dims.z)
        let width = remaskPreparePipeline.threadExecutionWidth
        let group = MTLSize(
            width: width, height: max(1, remaskPreparePipeline.maxTotalThreadsPerThreadgroup / width),
            depth: 1)
        encoder.setComputePipelineState(remaskPreparePipeline)
        encoder.setBuffer(maskBuffer, offset: 0, index: 0)
        encoder.setBuffer(rigidMaskBuffer, offset: 0, index: 1)
        encoder.setBuffer(occupancyBuffer, offset: 0, index: 2)
        encoder.setBuffer(stateBuffers[current], offset: 0, index: 3)
        encoder.setBytes(&uniforms, length: length, index: 4)
        encoder.setBuffer(wallVelocityBuffer, offset: 0, index: 5)
        encoder.dispatchThreads(size, threadsPerThreadgroup: group)

        encoder.setComputePipelineState(remaskApplyPipeline)
        encoder.setBuffer(maskBuffer, offset: 0, index: 0)
        encoder.setBuffer(occupancyBuffer, offset: 0, index: 1)
        encoder.setBytes(&uniforms, length: length, index: 2)
        encoder.dispatchThreads(size, threadsPerThreadgroup: group)
    }

    /// Resets time, histories and the peak/impulse fields, treating the current state as initial.
    /// The structure, if any, returns to its undeformed state.
    public func restart() {
        precondition(!batchInFlight, "Cannot restart while a batch is in flight")
        time = 0
        stepCount = 0
        lastFluidStep = 0
        structure?.reset()
        if structure != nil, let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeComputeCommandEncoder()
        {
            // Mark the undeformed structure in the solid mask.
            encodeRemask(encoder)
            encoder.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
        }
        gaugeHistories = Array(repeating: [], count: gaugeCount)
        resetDebrisExchange()
        memset(peakBuffer.contents(), 0, peakBuffer.length)
        memset(impulseBuffer.contents(), 0, impulseBuffer.length)
        maxSpeedBuffer.contents().storeBytes(of: 0, as: UInt64.self)
        airIsAsleep = false

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return }
        var uniforms = makeUniforms()
        encoder.setComputePipelineState(measurePipeline)
        encoder.setBuffer(stateBuffers[current], offset: 0, index: 0)
        encoder.setBuffer(maskBuffer, offset: 0, index: 1)
        encoder.setBuffer(maxSpeedBuffer, offset: 0, index: 2)
        encoder.setBytes(&uniforms, length: MemoryLayout<SolverUniforms>.stride, index: 3)
        dispatchGrid(encoder, pipeline: measurePipeline)
        encodeVisualization(encoder)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    // MARK: - Stepping

    /// Encodes up to `steps` time steps into a new, uncommitted command buffer.
    ///
    /// Commit the buffer, wait for it to complete, then call `completeBatch()` before encoding
    /// another. Steps that would pass `timeLimit` (absolute simulation time) become no-ops.
    public func encodeBatch(
        steps: Int, timeLimit: Double? = nil, updateVisualization: Bool = false
    ) -> MTLCommandBuffer? {
        precondition(!batchInFlight, "completeBatch() must be called before encoding another batch")
        let steps = min(max(steps, 1), Self.maxStepsPerBatch)
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return nil }

        var control = StepControl()
        if let timeLimit {
            control.timeLimit = Float(max(timeLimit - time, 0))
        }
        controlBuffer.contents().storeBytes(of: control, as: StepControl.self)

        let extents = [grid.nx, grid.ny, grid.nz]
        var substeps = structureSubsteps
        if let structure, lastFluidStep > 0 {
            let likely = Int((1.25 * lastFluidStep / structure.criticalTimeStep).rounded(.up)) + 1
            substeps = min(max(likely, 1), structureSubsteps)
        }
        for step in 0..<steps {
            let globalStep = stepCount + step
            let ramp = min(1, Float(globalStep + 1) / Float(max(configuration.startupSteps, 1)))
            var uniforms = makeUniforms(cfl: configuration.cfl * ramp)
            // With the air asleep, each step is exactly as long as the structure's substeps cover.
            let asleep = airIsAsleep && structure != nil
            if asleep, let structure {
                uniforms.forcedStep = 0.999 * Float(structureSubsteps) * structure.criticalTimeStep
            } else if let structure {
                // Only the substeps this step is likely to need are encoded, a quarter more than
                // the last batch's step took; the air may step no further than they cover.
                uniforms.maxStep = 0.999 * Float(substeps) * structure.criticalTimeStep
            }

            encoder.setComputePipelineState(preparePipeline)
            encoder.setBuffer(controlBuffer, offset: 0, index: 0)
            encoder.setBuffer(maxSpeedBuffer, offset: 0, index: 1)
            encoder.setBuffer(stateBuffers[current], offset: 0, index: 2)
            encoder.setBuffer(gaugeLogBuffer, offset: 0, index: 3)
            encoder.setBuffer(gaugeCellBuffer, offset: 0, index: 4)
            encoder.setBytes(&uniforms, length: MemoryLayout<SolverUniforms>.stride, index: 5)
            encoder.dispatchThreads(
                MTLSize(width: 1, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))

            // Alternate the sweep order each step so the splitting error stays second order.
            let order = globalStep.isMultiple(of: 2) ? [0, 1, 2] : [2, 1, 0]
            // An axis with a single cell has identical fluxes on both faces and can be skipped,
            // but at least one sweep must run to keep the bookkeeping kernels going.
            var axes = order.filter { extents[$0] > 1 }
            if axes.isEmpty { axes = [0] }

            encoder.setComputePipelineState(sweepPipeline)
            encoder.setBuffer(maskBuffer, offset: 0, index: 2)
            encoder.setBuffer(peakBuffer, offset: 0, index: 3)
            encoder.setBuffer(impulseBuffer, offset: 0, index: 4)
            encoder.setBuffer(controlBuffer, offset: 0, index: 5)
            encoder.setBuffer(maxSpeedBuffer, offset: 0, index: 6)
            encoder.setBuffer(wallVelocityBuffer, offset: 0, index: 8)
            for (n, axis) in axes.enumerated() where !asleep {
                uniforms.axis = UInt32(axis)
                uniforms.finalSweep = n == axes.count - 1 ? 1 : 0
                encoder.setBuffer(stateBuffers[current], offset: 0, index: 0)
                encoder.setBuffer(stateBuffers[1 - current], offset: 0, index: 1)
                encoder.setBytes(&uniforms, length: MemoryLayout<SolverUniforms>.stride, index: 7)
                dispatchGrid(encoder, pipeline: sweepPipeline)
                current = 1 - current
            }

            if let structure {
                // The structure covers the same interval in several smaller steps, loaded by
                // the pressure the air has just reached.
                // While the air is frozen it cannot take back what debris would take from it, so
                // debris then moves on without it.
                let binding = StructureSolver.FluidBinding(
                    state: stateBuffers[current], mask: maskBuffer, control: controlBuffer, grid: grid,
                    gamma: configuration.gamma, ambientPressure: configuration.ambientPressure,
                    exchange: asleep ? nil : debrisExchangeBuffer, debrisArea: debrisAreaBuffer,
                    exchangeRegion: couplingRegion)
                structure.encodeSubsteps(
                    encoder, count: asleep ? structureSubsteps : substeps, fluid: binding)
                if !asleep {
                    encodeDebrisExchange(encoder)
                }
                if configuration.twoWayCoupling && !asleep {
                    encodeRemask(encoder)
                }
            }
        }
        if updateVisualization {
            encodeVisualization(encoder)
        }
        encoder.endEncoding()
        batchInFlight = true
        return commandBuffer
    }

    /// Folds the results of the last completed batch into `time`, `stepCount` and the gauges.
    @discardableResult
    public func completeBatch() -> BatchResult {
        precondition(batchInFlight, "No batch to complete")
        batchInFlight = false
        let control = controlBuffer.contents().load(as: StepControl.self)
        let rows = Int(control.stepIndex)
        let rowStride = gaugeCount + 1
        let log = gaugeLogBuffer.contents().bindMemory(to: Float.self, capacity: rows * rowStride)
        for row in 0..<rows where gaugeCount > 0 {
            let sampleTime = time + Double(log[row * rowStride])
            for gauge in 0..<gaugeCount {
                // Steps clipped by the time limit repeat the previous sample; skip them.
                if let last = gaugeHistories[gauge].last, last.time >= sampleTime { continue }
                gaugeHistories[gauge].append(
                    GaugeSample(time: sampleTime, pressure: log[row * rowStride + 1 + gauge]))
            }
        }
        let elapsed = Double(control.batchTime)
        time += elapsed
        stepCount += Int(control.activeSteps)
        // Once the blast has left and the air is close to ambient everywhere, stop advancing it.
        if structure != nil, !airIsAsleep, control.activeSteps > 0 {
            let quiet =
                configuration.airSleepThreshold > 0
                && control.maxOverpressure < configuration.airSleepThreshold * configuration.ambientPressure
            let crossing = Double(simd_length(grid.size) / ambientSoundSpeed)
            let late =
                configuration.airSleepCrossings > 0
                && time > Double(configuration.airSleepCrossings) * crossing
            airIsAsleep = quiet || late
        }
        if control.activeSteps > 0 { lastFluidStep = control.dt }
        return BatchResult(
            steps: Int(control.activeSteps), elapsed: elapsed, lastTimeStep: Double(control.dt),
            isStable: control.batchTime.isFinite && control.dt.isFinite,
            maxOverpressure: control.maxOverpressure)
    }

    /// Advances by `steps` time steps, blocking until the GPU has finished.
    @discardableResult
    public func advance(steps: Int, timeLimit: Double? = nil) -> BatchResult {
        var total = BatchResult(steps: 0, elapsed: 0, lastTimeStep: 0, isStable: true)
        var remaining = steps
        while remaining > 0 {
            let count = min(remaining, Self.maxStepsPerBatch)
            guard let commandBuffer = encodeBatch(steps: count, timeLimit: timeLimit) else { break }
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            let result = completeBatch()
            total.steps += result.steps
            total.elapsed += result.elapsed
            total.lastTimeStep = result.lastTimeStep
            total.maxOverpressure = result.maxOverpressure
            total.isStable = total.isStable && result.isStable && commandBuffer.error == nil
            remaining -= count
            if result.steps < count || !result.isStable { break }
        }
        return total
    }

    /// Advances until simulation time reaches `endTime`, blocking until the GPU has finished.
    @discardableResult
    public func advance(until endTime: Double) -> BatchResult {
        var total = BatchResult(steps: 0, elapsed: 0, lastTimeStep: 0, isStable: true)
        while endTime - time > 1e-7 * max(endTime, 1e-3) {
            let result = advance(steps: 64, timeLimit: endTime)
            total.steps += result.steps
            total.elapsed += result.elapsed
            total.lastTimeStep = result.lastTimeStep
            total.maxOverpressure = result.maxOverpressure
            total.isStable = total.isStable && result.isStable
            if result.steps == 0 || !result.isStable { break }
        }
        return total
    }

    /// Rebuilds `visualizationTexture` from the current state, blocking until done.
    public func refreshVisualization() {
        precondition(!batchInFlight, "Cannot refresh while a batch is in flight")
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return }
        encodeVisualization(encoder)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    // MARK: - Reading results

    /// Read-only view of the current conserved state. Solid cells hold stale values.
    public func withState<R>(_ body: (UnsafeBufferPointer<CellState>) throws -> R) rethrows -> R {
        precondition(!batchInFlight, "Cannot read state while a batch is in flight")
        let pointer = stateBuffers[current].contents().bindMemory(
            to: CellState.self, capacity: grid.cellCount)
        return try body(UnsafeBufferPointer(start: pointer, count: grid.cellCount))
    }

    public func primitive(_ i: Int, _ j: Int, _ k: Int) -> Primitive {
        withState { $0[grid.index(i, j, k)].primitive(gamma: configuration.gamma) }
    }

    public func isSolid(_ i: Int, _ j: Int, _ k: Int) -> Bool {
        maskBuffer.contents().load(fromByteOffset: grid.index(i, j, k), as: UInt8.self) != 0
    }

    /// Largest overpressure (Pa) seen so far in a cell.
    public func peakOverpressure(_ i: Int, _ j: Int, _ k: Int) -> Float {
        peakBuffer.contents().load(
            fromByteOffset: grid.index(i, j, k) * MemoryLayout<Float>.stride, as: Float.self)
    }

    /// Positive-phase impulse (Pa s) accumulated so far in a cell.
    public func impulse(_ i: Int, _ j: Int, _ k: Int) -> Float {
        impulseBuffer.contents().load(
            fromByteOffset: grid.index(i, j, k) * MemoryLayout<Float>.stride, as: Float.self)
    }

    /// Total mass (kg) and energy (J) of the gas, summed over fluid cells.
    public func totals() -> (mass: Double, energy: Double) {
        let mask = maskBuffer.contents().bindMemory(to: UInt8.self, capacity: grid.cellCount)
        let volume = Double(grid.cellSize) * Double(grid.cellSize) * Double(grid.cellSize)
        return withState { cells in
            var mass = 0.0
            var energy = 0.0
            for index in 0..<grid.cellCount where mask[index] == 0 {
                mass += Double(cells[index].density)
                energy += Double(cells[index].energy)
            }
            return (mass * volume, energy * volume)
        }
    }

    /// Total momentum of the gas in kg m/s.
    public func momentum() -> SIMD3<Double> {
        let mask = maskBuffer.contents().bindMemory(to: UInt8.self, capacity: grid.cellCount)
        let volume = Double(grid.cellSize) * Double(grid.cellSize) * Double(grid.cellSize)
        return withState { cells in
            var total = SIMD3<Double>.zero
            for index in 0..<grid.cellCount where mask[index] == 0 {
                total += SIMD3(
                    Double(cells[index].momentumX), Double(cells[index].momentumY),
                    Double(cells[index].momentumZ))
            }
            return total * volume
        }
    }

    public var fluidCellCount: Int {
        let mask = maskBuffer.contents().bindMemory(to: UInt8.self, capacity: grid.cellCount)
        var count = 0
        for index in 0..<grid.cellCount where mask[index] == 0 { count += 1 }
        return count
    }

    /// Bytes of GPU memory held by the solver's fields.
    public var memoryFootprint: Int {
        let buffers = stateBuffers + [maskBuffer, peakBuffer, impulseBuffer]
        return buffers.reduce(0) { $0 + $1.length } + grid.cellCount * 8 + (structure?.memoryFootprint ?? 0)
    }

    /// Structural substeps encoded per fluid step. The fluid step never exceeds the CFL limit
    /// for (slightly cooled) ambient air, which bounds how many are needed.
    public var structureSubsteps: Int {
        guard let structure else { return 0 }
        let bound = configuration.cfl * grid.cellSize / (0.8 * ambientSoundSpeed)
        return structure.substeps(forFluidStepBound: bound)
    }

    // MARK: - Encoding helpers

    private func makeUniforms(cfl: Float? = nil) -> SolverUniforms {
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
            boundaryFlags: configuration.reflectiveFaces.rawValue,
            gaugeCount: UInt32(gaugeCount))
        if let region = couplingRegion, configuration.movingWalls {
            uniforms.regionX = UInt32(region.origin.x)
            uniforms.regionY = UInt32(region.origin.y)
            uniforms.regionZ = UInt32(region.origin.z)
            uniforms.regionNx = UInt32(region.dims.x)
            uniforms.regionNy = UInt32(region.dims.y)
            uniforms.regionNz = UInt32(region.dims.z)
        }
        return uniforms
    }

    private func dispatchGrid(_ encoder: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState) {
        let width = pipeline.threadExecutionWidth
        let height = max(1, pipeline.maxTotalThreadsPerThreadgroup / width)
        encoder.dispatchThreads(
            MTLSize(width: grid.nx, height: grid.ny, depth: grid.nz),
            threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1))
    }

    private func encodeVisualization(_ encoder: MTLComputeCommandEncoder) {
        var uniforms = makeUniforms()
        encoder.setComputePipelineState(visualizationPipeline)
        encoder.setBuffer(stateBuffers[current], offset: 0, index: 0)
        encoder.setBuffer(maskBuffer, offset: 0, index: 1)
        encoder.setBuffer(peakBuffer, offset: 0, index: 2)
        encoder.setBuffer(impulseBuffer, offset: 0, index: 3)
        encoder.setBytes(&uniforms, length: MemoryLayout<SolverUniforms>.stride, index: 4)
        encoder.setTexture(visualizationTexture, index: 0)
        dispatchGrid(encoder, pipeline: visualizationPipeline)
    }
}
