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
    /// The deformable body when it is meshed with shells; `structure` is then nil, unless the
    /// body is mixed.
    public private(set) var shells: ShellSolver?
    /// A body meshed partly with solid elements and partly with shells; its parts are
    /// `structure` and `shells`.
    public private(set) var mixed: MixedStructure?
    /// Whether there is a deformable body of either kind.
    public var hasBody: Bool { structure != nil || shells != nil }
    /// The deformable body's stable time step.
    private var bodyStep: Float? { structure?.criticalTimeStep ?? shells?.criticalTimeStep }
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
    private let sweepTilesPipeline: MTLComputePipelineState
    private let wakeTilesPipeline: MTLComputePipelineState
    private let collectTilesPipeline: MTLComputePipelineState
    private let preparePipeline: MTLComputePipelineState
    private let measurePipeline: MTLComputePipelineState
    private let visualizationPipeline: MTLComputePipelineState
    private let splatPipeline: MTLComputePipelineState
    private let remaskPreparePipeline: MTLComputePipelineState
    private let remaskApplyPipeline: MTLComputePipelineState
    private let debrisExchangePipeline: MTLComputePipelineState
    private let shellSplatPipeline: MTLComputePipelineState
    private let beamSplatPipeline: MTLComputePipelineState

    private let stateBuffers: [MTLBuffer]
    /// Densities of unburnt detonation products and of oxygen in each cell, kept alongside the
    /// state for afterburning; made when the air is filled with afterburning on. Until then a
    /// one-cell stand-in is bound.
    private var speciesBuffers: [MTLBuffer] = []
    private let noSpecies: MTLBuffer
    /// Whether the air carries fuel and oxygen, so that its charges burn.
    private var hasSpecies: Bool { !speciesBuffers.isEmpty }
    /// The current fuel and oxygen, or a placeholder without them.
    private var currentSpecies: MTLBuffer { hasSpecies ? speciesBuffers[current] : noSpecies }
    /// Mass fraction of oxygen in air, and the oxygen TNT's products need to burn completely
    /// (C7H5N3O6 + 5.25 O2 -> 7 CO2 + 2.5 H2O + 1.5 N2), per kilogram.
    static let oxygenInAir: Float = 0.232
    static let oxygenPerFuel: Float = 5.25 * 32 / 227.13
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
    /// Still air: one flag per tile of 8 x 8 x 8 cells (still, awake, or woken during the last
    /// step), the list of awake tiles, its length, and the sweeps' threadgroup counts.
    static let tileSize = 8
    let tileDims: SIMD3<Int>
    private let tileFlagBuffer: MTLBuffer
    private let tileListBuffer: MTLBuffer
    private let tileCountBuffer: MTLBuffer
    private let tileDispatchBuffer: MTLBuffer
    /// Whether still air is being skipped since the last restart.
    private var tilesEnabled = false
    /// The largest charge deposited since the air was last filled, kg, which sets how fast its
    /// products burn.
    var largestCharge: Float = 0
    /// The uniform state the air was last filled with: air still in it is not swept.
    private var stillCell = CellState(Primitive(density: 1.225, pressure: 101_325), gamma: 1.4)
    private var batchInFlight = false
    /// True once the blast has left and the air has been frozen; only the structure advances.
    public private(set) var airIsAsleep = false
    /// The air's time step at the end of the last batch, which sizes the next batch's substeps.
    private var lastFluidStep: Float = 0
    /// The finer level of the air, while it is refined (see `SolverConfiguration.refinement`).
    private(set) var refinement: AirRefinement?
    /// Bound in place of the refinement's buffers while the air is not refined.
    private let refinementPlaceholder: MTLBuffer
    /// Per gauge: the fine cell of its cell that holds its point, as x + r (y + r z), or
    /// `UInt32.max` to read the coarse cell.
    private let gaugeChildBuffer: MTLBuffer
    private var gaugePoints: [SIMD3<Float>?] = []
    /// The scenario's rigid blocks, whose outline the refined air follows at its own resolution;
    /// nil once the mask has been edited by hand.
    var rigidBoxes: [Box]?
    /// Charges laid down in fine cells for refined air (see `deposit`): what each fine cell gained,
    /// density and energy per volume, over the uniform state the air was filled with. Given to the
    /// fine cells at the next `restart()`; forgotten when the air is filled or edited by hand.
    var fineDeposit: [SIMD3<Int>: SIMD2<Float>] = [:]

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
        sweepTilesPipeline = try pipeline("sweepTiles")
        wakeTilesPipeline = try pipeline("wakeTiles")
        collectTilesPipeline = try pipeline("collectTiles")
        preparePipeline = try pipeline("prepareStep")
        measurePipeline = try pipeline("measureWaveSpeed")
        visualizationPipeline = try pipeline("updateVisualization")
        splatPipeline = try pipeline("splatStructure")
        remaskPreparePipeline = try pipeline("remaskPrepare")
        remaskApplyPipeline = try pipeline("remaskApply")
        debrisExchangePipeline = try pipeline("debrisExchange")
        shellSplatPipeline = try pipeline("shellSplat")
        beamSplatPipeline = try pipeline("beamSplat")

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
        noSpecies = try buffer(MemoryLayout<SIMD2<Float>>.stride, "no species")
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
        gaugeChildBuffer = try buffer(Self.maxGauges * MemoryLayout<UInt32>.stride, "gauge fine cells")
        memset(gaugeChildBuffer.contents(), 0xFF, gaugeChildBuffer.length)
        refinementPlaceholder = try buffer(64, "no refinement")
        memset(refinementPlaceholder.contents(), 0xFF, refinementPlaceholder.length)
        let tile = Self.tileSize
        tileDims = SIMD3(
            (grid.nx + tile - 1) / tile, (grid.ny + tile - 1) / tile, (grid.nz + tile - 1) / tile)
        let tiles = tileDims.x * tileDims.y * tileDims.z
        tileFlagBuffer = try buffer(tiles, "tile flags")
        tileListBuffer = try buffer(tiles * MemoryLayout<UInt32>.stride, "awake tiles")
        tileCountBuffer = try buffer(MemoryLayout<UInt32>.stride, "awake tile count")
        tileDispatchBuffer = try buffer(3 * MemoryLayout<UInt32>.stride, "tile dispatch")

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
        let cell = cellState(primitive)
        stillCell = cell
        largestCharge = 0
        fineDeposit = [:]
        for buffer in stateBuffers {
            buffer.contents().bindMemory(to: CellState.self, capacity: grid.cellCount)
                .update(repeating: cell, count: grid.cellCount)
        }
        if configuration.afterburning && !hasSpecies {
            let length = grid.cellCount * MemoryLayout<SIMD2<Float>>.stride
            if let first = device.makeBuffer(length: length, options: .storageModeShared),
                let second = device.makeBuffer(length: length, options: .storageModeShared)
            {
                speciesBuffers = [first, second]
            }
        } else if !configuration.afterburning {
            speciesBuffers = []
        }
        let air = SIMD2<Float>(0, Self.oxygenInAir * primitive.density)
        for buffer in speciesBuffers {
            buffer.contents().bindMemory(to: SIMD2<Float>.self, capacity: grid.cellCount)
                .update(repeating: air, count: grid.cellCount)
        }
        restart()
    }

    /// Direct access to the densities of unburnt detonation products (x) and oxygen (y).
    func mutateSpecies(_ body: (UnsafeMutableBufferPointer<SIMD2<Float>>) throws -> Void) rethrows {
        precondition(!batchInFlight, "Cannot edit state while a batch is in flight")
        guard hasSpecies else { return }
        let pointer = speciesBuffers[current].contents().bindMemory(
            to: SIMD2<Float>.self, capacity: grid.cellCount)
        try body(UnsafeMutableBufferPointer(start: pointer, count: grid.cellCount))
    }

    /// Total unburnt detonation products (kg) and oxygen (kg) in the air.
    public func speciesTotals() -> (fuel: Double, oxygen: Double) {
        precondition(!batchInFlight, "Cannot read state while a batch is in flight")
        guard hasSpecies else { return (0, 0) }
        let mask = maskBuffer.contents().bindMemory(to: UInt8.self, capacity: grid.cellCount)
        let species = speciesBuffers[current].contents().bindMemory(
            to: SIMD2<Float>.self, capacity: grid.cellCount)
        let volume = Double(grid.cellSize) * Double(grid.cellSize) * Double(grid.cellSize)
        let fine = refinement?.gas(in: grid)
        var total = SIMD2<Double>.zero
        for index in 0..<grid.cellCount where mask[index] == 0 && fine?.covered.contains(index) != true {
            total += SIMD2(Double(species[index].x), Double(species[index].y))
        }
        total = total * volume + (fine?.species ?? .zero)
        return (total.x, total.y)
    }

    /// Sets every cell from a closure and restarts the clock. Intended for small grids.
    public func fill(_ body: (_ i: Int, _ j: Int, _ k: Int) -> Primitive) {
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
        var primitive = cell.primitive(gamma: configuration.gamma)
        let kinetic = 0.5 * primitive.density * simd_length_squared(primitive.velocity)
        primitive.pressure = configuration.airModel.pressure(
            density: primitive.density, internalEnergy: cell.energy - kinetic, gamma: configuration.gamma)
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
        let pointer = stateBuffers[current].contents().bindMemory(
            to: CellState.self, capacity: grid.cellCount)
        try body(UnsafeMutableBufferPointer(start: pointer, count: grid.cellCount))
    }

    /// Direct access to the solid mask (non-zero marks a rigid cell). Call `restart()` after editing.
    public func mutateMask(_ body: (UnsafeMutableBufferPointer<UInt8>) throws -> Void) rethrows {
        precondition(!batchInFlight, "Cannot edit the mask while a batch is in flight")
        rigidBoxes = nil
        let pointer = maskBuffer.contents().bindMemory(to: UInt8.self, capacity: grid.cellCount)
        try body(UnsafeMutableBufferPointer(start: pointer, count: grid.cellCount))
    }

    /// Chooses the cells whose pressure is recorded every step. Clears existing histories. With
    /// `points`, one per cell, a gauge whose cell is refined reads the fine cell holding its point.
    public func setGauges(cells: [(i: Int, j: Int, k: Int)], points: [SIMD3<Float>]? = nil) {
        precondition(cells.count <= Self.maxGauges, "At most \(Self.maxGauges) gauges are supported")
        let pointer = gaugeCellBuffer.contents().bindMemory(to: UInt32.self, capacity: Self.maxGauges)
        for (n, cell) in cells.enumerated() {
            precondition(grid.contains(cell.i, cell.j, cell.k), "Gauge outside the grid")
            pointer[n] = UInt32(grid.index(cell.i, cell.j, cell.k))
        }
        gaugeCount = cells.count
        gaugeHistories = Array(repeating: [], count: gaugeCount)
        gaugePoints = (0..<cells.count).map { points?[$0] }
        updateGaugeChildren()
    }

    /// Which fine cell of its cell each gauge reads, for the current refinement.
    private func updateGaugeChildren() {
        let pointer = gaugeChildBuffer.contents().bindMemory(to: UInt32.self, capacity: Self.maxGauges)
        let cells = gaugeCellBuffer.contents().bindMemory(to: UInt32.self, capacity: Self.maxGauges)
        for n in 0..<Self.maxGauges {
            pointer[n] = .max
            guard let refinement, n < gaugePoints.count, let point = gaugePoints[n] else { continue }
            let index = Int(cells[n])
            let cell = SIMD3(index % grid.nx, (index / grid.nx) % grid.ny, index / (grid.nx * grid.ny))
            let r = refinement.ratio
            let within = simd_clamp(
                point / grid.cellSize - SIMD3<Float>(cell), .zero, SIMD3(repeating: 0.999))
            let child = SIMD3<Int>((within * Float(r)).rounded(.down))
            pointer[n] = UInt32(child.x + r * (child.y + r * child.z))
        }
    }

    /// Replaces the deformable body. The current solid mask is taken as the rigid scenery, and
    /// the structure is added to it at the next `restart()`.
    public func setStructure(_ model: StructureModel?) throws {
        precondition(!batchInFlight, "Cannot change the structure while a batch is in flight")
        structure = nil
        shells = nil
        mixed = nil
        couplingRegion = nil
        occupancyBuffer = nil
        debrisExchangeBuffer = nil
        debrisAreaBuffer = nil
        wallVelocityBuffer = stillWallBuffer
        memcpy(rigidMaskBuffer.contents(), maskBuffer.contents(), grid.cellCount)
        guard let model else { return }
        if model.isMixed {
            let body = try MixedStructure(
                device: device, commandQueue: commandQueue, library: library, model: model)
            mixed = body
            structure = body.solids
            shells = body.shells
        } else if model.elementKind == .shell {
            shells = try ShellSolver(
                device: device, commandQueue: commandQueue, library: library, model: model)
        } else {
            structure = try StructureSolver(
                device: device, commandQueue: commandQueue, library: library, model: model)
        }

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

    private func couplingUniforms(_ region: (origin: SIMD3<Int>, dims: SIMD3<Int>)) -> CouplingUniforms {
        var uniforms = CouplingUniforms(
            regionX: UInt32(region.origin.x), regionY: UInt32(region.origin.y),
            regionZ: UInt32(region.origin.z),
            regionNx: UInt32(region.dims.x), regionNy: UInt32(region.dims.y), regionNz: UInt32(region.dims.z),
            fluidNx: UInt32(grid.nx), fluidNy: UInt32(grid.ny), fluidNz: UInt32(grid.nz),
            // A cell any shell passes through is solid.
            threshold: 1, ex: 0, ey: 0, fluidCell: grid.cellSize, h: 0, originX: 0, originY: 0, originZ: 0,
            gamma: configuration.gamma, ambientDensity: ambientDensity,
            ambientPressure: configuration.ambientPressure, airModel: configuration.airModel.rawValue)
        if let refinement {
            uniforms.refineRatio = UInt32(refinement.ratio)
            uniforms.blocksX = UInt32(refinement.tileDims.x)
            uniforms.blocksY = UInt32(refinement.tileDims.y)
        }
        if let structure {
            let h = structure.model.elementSize
            // A cell is solid when at least a third of it is filled with intact elements. Elements
            // larger than the cells are sampled at points no further apart than a cell.
            let coarse = max(1, Int((h / grid.cellSize - 1e-3).rounded(.up)))
            uniforms.coarseSamples = UInt32(coarse)
            let perCell = pow(grid.cellSize * Float(coarse) / h, 3)
            uniforms.threshold = UInt32(max(1, (perCell / 3).rounded(.up)))
            if let refinement {
                // For the fine cells, each element is sampled at points no further apart than a
                // fine cell, and a fine cell is solid when a third of it is covered.
                let fineCell = grid.cellSize / Float(refinement.ratio)
                let samples = max(1, Int((h / fineCell - 1e-3).rounded(.up)))
                uniforms.fineSamples = UInt32(samples)
                uniforms.fineThreshold = UInt32(
                    max(1, (pow(fineCell * Float(samples) / h, 3) / 3).rounded(.up)))
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

    /// Encodes the return to the air of what loose debris took from it during the substeps.
    private func encodeDebrisExchange(_ encoder: MTLComputeCommandEncoder) {
        guard hasBody, let region = couplingRegion, let debrisExchangeBuffer else { return }
        var uniforms = couplingUniforms(region)
        encoder.setComputePipelineState(debrisExchangePipeline)
        encoder.setBuffer(stateBuffers[current], offset: 0, index: 0)
        encoder.setBuffer(debrisExchangeBuffer, offset: 0, index: 1)
        encoder.setBytes(&uniforms, length: MemoryLayout<CouplingUniforms>.stride, index: 2)
        encoder.setBuffer(debrisAreaBuffer, offset: 0, index: 3)
        encoder.dispatchThreads(
            MTLSize(width: region.dims.x, height: region.dims.y, depth: region.dims.z),
            threadsPerThreadgroup: regionThreads(debrisExchangePipeline))
    }

    /// Encodes one update of the solid mask from the structure's current shape, and of the fine
    /// cells' outline too where the air is refined, unless `fine` is false.
    private func encodeRemask(_ encoder: MTLComputeCommandEncoder, fine: Bool = true) {
        guard hasBody, let region = couplingRegion, let occupancyBuffer else { return }
        var uniforms = couplingUniforms(region)
        if !fine { uniforms.refineRatio = 0 }
        let length = MemoryLayout<CouplingUniforms>.stride
        let patches = refinement?.patchOfTile ?? refinementPlaceholder
        let fineOccupancy = refinement?.fineOccupancy ?? refinementPlaceholder

        if let structure {
            encoder.setComputePipelineState(splatPipeline)
            encoder.setBuffer(structure.instanceBuffer, offset: 0, index: 0)
            encoder.setBuffer(structure.flagBuffer, offset: 0, index: 1)
            encoder.setBuffer(structure.nodeBuffer, offset: 0, index: 2)
            encoder.setBuffer(occupancyBuffer, offset: 0, index: 3)
            encoder.setBytes(&uniforms, length: length, index: 4)
            encoder.setBuffer(structure.nodeMapBuffer, offset: 0, index: 5)
            encoder.setBuffer(patches, offset: 0, index: 6)
            encoder.setBuffer(fineOccupancy, offset: 0, index: 7)
            encoder.dispatchThreads(
                MTLSize(width: structure.elementCount, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(
                    width: splatPipeline.maxTotalThreadsPerThreadgroup, height: 1, depth: 1))
        }
        if let shells {
            // In a mixed body, one shell point fills a cell, as a third of it in solid elements does.
            uniforms.splatWeight = structure != nil ? uniforms.threshold : 1
            if shells.beamCount > 0 {
                var beams = UInt32(shells.beamCount)
                encoder.setComputePipelineState(beamSplatPipeline)
                encoder.setBuffer(shells.beamBuffer, offset: 0, index: 0)
                encoder.setBuffer(shells.beamFlagBuffer, offset: 0, index: 1)
                encoder.setBuffer(shells.nodeBuffer, offset: 0, index: 2)
                encoder.setBuffer(shells.referenceBuffer, offset: 0, index: 3)
                encoder.setBuffer(occupancyBuffer, offset: 0, index: 4)
                encoder.setBytes(&uniforms, length: length, index: 5)
                encoder.setBytes(&beams, length: 4, index: 6)
                encoder.setBuffer(patches, offset: 0, index: 7)
                encoder.setBuffer(fineOccupancy, offset: 0, index: 8)
                encoder.dispatchThreads(
                    MTLSize(width: shells.beamCount, height: 1, depth: 1),
                    threadsPerThreadgroup: MTLSize(
                        width: beamSplatPipeline.threadExecutionWidth, height: 1, depth: 1))
            }
            var count = UInt32(shells.elementCount)
            encoder.setComputePipelineState(shellSplatPipeline)
            encoder.setBuffer(shells.elementBuffer, offset: 0, index: 0)
            encoder.setBuffer(shells.flagBuffer, offset: 0, index: 1)
            encoder.setBuffer(shells.nodeBuffer, offset: 0, index: 2)
            encoder.setBuffer(shells.referenceBuffer, offset: 0, index: 3)
            encoder.setBuffer(occupancyBuffer, offset: 0, index: 4)
            encoder.setBytes(&uniforms, length: length, index: 5)
            encoder.setBytes(&count, length: 4, index: 6)
            encoder.setBuffer(patches, offset: 0, index: 7)
            encoder.setBuffer(fineOccupancy, offset: 0, index: 8)
            if shells.elementCount > 0 {
                encoder.dispatchThreads(
                    MTLSize(width: shells.elementCount, height: 1, depth: 1),
                    threadsPerThreadgroup: MTLSize(
                        width: shellSplatPipeline.threadExecutionWidth, height: 1, depth: 1))
            }
        }

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

        if fine, let refinement {
            refinement.encodeRemask(
                encoder, coarse: stateBuffers[current], mask: maskBuffer, threshold: uniforms.fineThreshold,
                uniforms: makeUniforms())
        }
    }

    /// Sets the clock without touching the state, after `restart()`: for a blast laid down as it
    /// is some time after detonation.
    func startClock(at start: Double) {
        time = start
    }

    /// Direct access to the peak overpressure and impulse fields.
    func setFields(_ body: (UnsafeMutableBufferPointer<Float>, UnsafeMutableBufferPointer<Float>) -> Void) {
        let peak = peakBuffer.contents().bindMemory(to: Float.self, capacity: grid.cellCount)
        let impulse = impulseBuffer.contents().bindMemory(to: Float.self, capacity: grid.cellCount)
        body(
            UnsafeMutableBufferPointer(start: peak, count: grid.cellCount),
            UnsafeMutableBufferPointer(start: impulse, count: grid.cellCount))
    }

    /// Puts `samples` in front of gauge `index`'s history.
    func prependGaugeHistory(_ index: Int, _ samples: [GaugeSample]) {
        guard gaugeHistories.indices.contains(index) else { return }
        gaugeHistories[index] = samples + gaugeHistories[index]
    }

    /// Resets time, histories and the peak/impulse fields, treating the current state as initial.
    /// The structure, if any, returns to its undeformed state.
    public func restart() {
        precondition(!batchInFlight, "Cannot restart while a batch is in flight")
        time = 0
        stepCount = 0
        lastFluidStep = 0
        if let mixed {
            mixed.reset()
        } else {
            structure?.reset()
            shells?.reset()
        }
        if hasBody, let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeComputeCommandEncoder()
        {
            // Mark the undeformed structure in the solid mask.
            encodeRemask(encoder, fine: false)
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
        // Both state buffers start alike, so that a tile never swept holds the same state in each.
        memcpy(
            stateBuffers[1 - current].contents(), stateBuffers[current].contents(),
            stateBuffers[current].length)
        if hasSpecies {
            memcpy(
                speciesBuffers[1 - current].contents(), speciesBuffers[current].contents(),
                speciesBuffers[current].length)
        }
        tilesEnabled = configuration.skipStillAir
        memset(tileFlagBuffer.contents(), 0, tileFlagBuffer.length)
        tileCountBuffer.contents().storeBytes(of: 0, as: UInt32.self)
        if tilesEnabled, let region = couplingRegion {
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
        if tilesEnabled {
            encoder.setComputePipelineState(wakeTilesPipeline)
            encoder.setBuffer(stateBuffers[current], offset: 0, index: 0)
            encoder.setBuffer(maskBuffer, offset: 0, index: 1)
            encoder.setBuffer(tileFlagBuffer, offset: 0, index: 2)
            encoder.setBytes(&uniforms, length: MemoryLayout<SolverUniforms>.stride, index: 3)
            encoder.setBuffer(hasSpecies ? speciesBuffers[current] : noSpecies, offset: 0, index: 4)
            dispatchGrid(encoder, pipeline: wakeTilesPipeline)
        }
        if let refinement {
            // Refine around the charge from the start; the regrid acts only on a step that
            // advances, so the clock is given one.
            var control = StepControl()
            control.dt = 1
            controlBuffer.contents().storeBytes(of: control, as: StepControl.self)
            refinement.encodeRegrid(
                encoder, coarse: stateBuffers[current], coarseSpecies: currentSpecies, mask: maskBuffer,
                rigidMask: hasBody ? rigidMaskBuffer : maskBuffer, wallVelocity: wallVelocityBuffer,
                control: controlBuffer, impulse: impulseBuffer, tileFlags: tileFlagBuffer, tiles: nil,
                grid: grid,
                uniforms: uniforms)
            // The structure's own outline in the new patches.
            encodeRemask(encoder)
        }
        encodeVisualization(encoder)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let refinement, !fineDeposit.isEmpty {
            // The charges' fine cells, and every other fine cell of the coarse cells they touch,
            // whose mean the coarse cells already hold.
            // With afterburning, the products are all unburnt fuel, and the air keeps its oxygen.
            let r = refinement.ratio
            let stillOxygen = Self.oxygenInAir * stillCell.density
            var cells: [SIMD3<Int>: (state: CellState, species: SIMD2<Float>)] = [:]
            for coarse in Set(fineDeposit.keys.map { $0 / r }) {
                for n in 0..<(r * r * r) {
                    let fine = coarse &* r &+ SIMD3(n % r, (n / r) % r, n / (r * r))
                    var cell = stillCell
                    var species = SIMD2<Float>(0, stillOxygen)
                    if let added = fineDeposit[fine] {
                        cell.density += added.x
                        cell.energy += added.y
                        species.x += added.x
                    }
                    cells[fine] = (cell, species)
                }
            }
            refinement.setFine(cells)
        }
    }

    /// Makes, keeps or drops the finer level for the configuration, and releases its patches.
    private func setUpRefinement() {
        let ratio = configuration.refinement
        guard ratio > 1 else {
            refinement = nil
            updateGaugeChildren()
            return
        }
        let memory = configuration.refinementMemory
        let patches = memory / AirRefinement.bytesPerPatch(ratio: ratio, species: hasSpecies)
        if refinement?.ratio != ratio || refinement?.species != hasSpecies
            || refinement?.maxPatches != max(1, patches)
        {
            refinement = nil
            refinement = try? AirRefinement(
                device: device, library: library, grid: grid, ratio: ratio, memory: memory,
                species: hasSpecies)
        }
        refinement?.reset()
        refinement?.setBoxes(rigidBoxes)
        updateGaugeChildren()
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
        if let bodyStep, lastFluidStep > 0 {
            let likely = Int((1.25 * lastFluidStep / bodyStep).rounded(.up)) + 1
            substeps = min(max(likely, 1), structureSubsteps)
        }
        for step in 0..<steps {
            let globalStep = stepCount + step
            let ramp = min(1, Float(globalStep + 1) / Float(max(configuration.startupSteps, 1)))
            var uniforms = makeUniforms(cfl: configuration.cfl * ramp)
            // With the air asleep, each step is exactly as long as the structure's substeps cover.
            let asleep = airIsAsleep && hasBody
            if asleep, let bodyStep {
                uniforms.forcedStep = 0.999 * Float(structureSubsteps) * bodyStep
            } else if let bodyStep {
                // Only the substeps this step is likely to need are encoded, a quarter more than
                // the last batch's step took; the air may step no further than they cover.
                uniforms.maxStep = 0.999 * Float(substeps) * bodyStep
            }

            if asleep {
                uniforms.tileNx = 0
            } else if tilesEnabled {
                let tiles = tileDims.x * tileDims.y * tileDims.z
                encoder.setComputePipelineState(collectTilesPipeline)
                encoder.setBuffer(tileFlagBuffer, offset: 0, index: 0)
                encoder.setBuffer(tileListBuffer, offset: 0, index: 1)
                encoder.setBuffer(tileCountBuffer, offset: 0, index: 2)
                encoder.setBuffer(maxSpeedBuffer, offset: 0, index: 3)
                encoder.setBytes(&uniforms, length: MemoryLayout<SolverUniforms>.stride, index: 4)
                encoder.dispatchThreads(
                    MTLSize(width: tiles, height: 1, depth: 1),
                    threadsPerThreadgroup: MTLSize(
                        width: min(tiles, collectTilesPipeline.maxTotalThreadsPerThreadgroup), height: 1,
                        depth: 1))
            }

            encoder.setComputePipelineState(preparePipeline)
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
            encoder.dispatchThreads(
                MTLSize(width: 1, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))

            let refining = refinement != nil && !asleep
            if let refinement, refining {
                refinement.encodeSaveHalo(
                    encoder, coarse: stateBuffers[current], uniforms: uniforms, control: controlBuffer)
            }

            // Alternate the sweep order each step so the splitting error stays second order.
            let order = globalStep.isMultiple(of: 2) ? [0, 1, 2] : [2, 1, 0]
            // An axis with a single cell has identical fluxes on both faces and can be skipped,
            // but at least one sweep must run to keep the bookkeeping kernels going.
            var axes = order.filter { extents[$0] > 1 }
            if axes.isEmpty { axes = [0] }

            encoder.setComputePipelineState(tilesEnabled ? sweepTilesPipeline : sweepPipeline)
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
            for (n, axis) in axes.enumerated() where !asleep {
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
                    dispatchGrid(encoder, pipeline: sweepPipeline)
                }
                current = 1 - current
            }
            if let refinement, refining {
                refinement.encodeSubsteps(
                    encoder, axes: axes, coarse: stateBuffers[current], coarseSpecies: currentSpecies,
                    mask: maskBuffer, peak: peakBuffer, control: controlBuffer, maxSpeed: maxSpeedBuffer,
                    wallVelocity: wallVelocityBuffer, uniforms: uniforms)
                refinement.encodeRefluxAndRestrict(
                    encoder, axes: axes, coarse: stateBuffers[current], coarseSpecies: currentSpecies,
                    mask: maskBuffer, control: controlBuffer, impulse: impulseBuffer, uniforms: uniforms)
            }

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
                if let refinement {
                    binding.refinement = (
                        refinement.patchOfTile, refinement.fine[0], refinement.fineMask, refinement.ratio,
                        refinement.tileDims
                    )
                }
                let count = asleep ? structureSubsteps : substeps
                if let mixed {
                    mixed.encodeSubsteps(encoder, count: count, fluid: binding)
                } else if let structure {
                    structure.encodeSubsteps(encoder, count: count, fluid: binding)
                } else if let shells {
                    shells.encodeSubsteps(encoder, count: count, fluid: binding)
                }
                if !asleep {
                    encodeDebrisExchange(encoder)
                }
                if configuration.twoWayCoupling && !asleep {
                    encodeRemask(encoder)
                }
                if let refinement, refining {
                    refinement.encodeSync(
                        encoder, coarse: stateBuffers[current], mask: maskBuffer, control: controlBuffer,
                        uniforms: uniforms)
                }
            }
            if let refinement, refining {
                refinement.encodeRegrid(
                    encoder, coarse: stateBuffers[current], coarseSpecies: currentSpecies, mask: maskBuffer,
                    rigidMask: hasBody ? rigidMaskBuffer : maskBuffer, wallVelocity: wallVelocityBuffer,
                    control: controlBuffer, impulse: impulseBuffer, tileFlags: tileFlagBuffer,
                    tiles: tilesEnabled ? (tileListBuffer, tileDispatchBuffer, tileThreads) : nil, grid: grid,
                    uniforms: uniforms)
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
        if hasBody, !airIsAsleep, control.activeSteps > 0 {
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
        var swept = 1.0
        if tilesEnabled {
            let tiles = Double(tileDims.x * tileDims.y * tileDims.z)
            swept =
                control.activeSteps > 0
                ? Double(control.tileSweeps) / (Double(control.activeSteps) * tiles) : 0
        }
        return BatchResult(
            steps: Int(control.activeSteps), elapsed: elapsed, lastTimeStep: Double(control.dt),
            isStable: control.batchTime.isFinite && control.dt.isFinite,
            maxOverpressure: control.maxOverpressure, sweptFraction: swept,
            refinedTiles: refinement?.patchCount ?? 0)
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
            total.sweptFraction = Self.mergeSwept(total, result)
            total.steps += result.steps
            total.elapsed += result.elapsed
            total.lastTimeStep = result.lastTimeStep
            total.maxOverpressure = result.maxOverpressure
            total.isStable = total.isStable && result.isStable && commandBuffer.error == nil
            total.refinedTiles = result.refinedTiles
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
            total.sweptFraction = Self.mergeSwept(total, result)
            total.steps += result.steps
            total.elapsed += result.elapsed
            total.lastTimeStep = result.lastTimeStep
            total.maxOverpressure = result.maxOverpressure
            total.isStable = total.isStable && result.isStable
            total.refinedTiles = result.refinedTiles
            if result.steps == 0 || !result.isStable { break }
        }
        return total
    }

    /// The swept fraction of two runs of steps together, weighted by their steps.
    private static func mergeSwept(_ total: BatchResult, _ result: BatchResult) -> Double {
        let steps = total.steps + result.steps
        guard steps > 0 else { return result.sweptFraction }
        return (total.sweptFraction * Double(total.steps) + result.sweptFraction * Double(result.steps))
            / Double(steps)
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
        withState { primitive(of: $0[grid.index(i, j, k)]) }
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

    /// Total mass (kg) and energy (J) of the gas, summed over fluid cells; under the patches of
    /// refined air, over their fluid fine cells.
    public func totals() -> (mass: Double, energy: Double) {
        let mask = maskBuffer.contents().bindMemory(to: UInt8.self, capacity: grid.cellCount)
        let volume = Double(grid.cellSize) * Double(grid.cellSize) * Double(grid.cellSize)
        let fine = refinement?.gas(in: grid)
        return withState { cells in
            var mass = 0.0
            var energy = 0.0
            for index in 0..<grid.cellCount where mask[index] == 0 && fine?.covered.contains(index) != true {
                mass += Double(cells[index].density)
                energy += Double(cells[index].energy)
            }
            return (mass * volume + (fine?.mass ?? 0), energy * volume + (fine?.energy ?? 0))
        }
    }

    /// Total momentum of the gas in kg m/s, counted as `totals()` is.
    public func momentum() -> SIMD3<Double> {
        let mask = maskBuffer.contents().bindMemory(to: UInt8.self, capacity: grid.cellCount)
        let volume = Double(grid.cellSize) * Double(grid.cellSize) * Double(grid.cellSize)
        let fine = refinement?.gas(in: grid)
        return withState { cells in
            var total = SIMD3<Double>.zero
            for index in 0..<grid.cellCount where mask[index] == 0 && fine?.covered.contains(index) != true {
                total += SIMD3(
                    Double(cells[index].momentumX), Double(cells[index].momentumY),
                    Double(cells[index].momentumZ))
            }
            return total * volume + (fine?.momentum ?? .zero)
        }
    }

    public var fluidCellCount: Int {
        let mask = maskBuffer.contents().bindMemory(to: UInt8.self, capacity: grid.cellCount)
        var count = 0
        for index in 0..<grid.cellCount where mask[index] == 0 { count += 1 }
        return count
    }

    /// Damage and deflection of the deformable body, both parts of it if mixed.
    public func bodySummary() -> StructureSummary? {
        switch (structure?.summary(), shells?.summary()) {
        case (let solid?, let shell?): solid.combined(with: shell)
        case (let solid?, nil): solid
        case (nil, let shell?): shell
        default: nil
        }
    }

    /// Bytes of GPU memory held by the solver's fields.
    public var memoryFootprint: Int {
        let buffers = stateBuffers + speciesBuffers + [maskBuffer, peakBuffer, impulseBuffer]
        return buffers.reduce(0) { $0 + $1.length } + grid.cellCount * 8 + (structure?.memoryFootprint ?? 0)
            + (shells?.memoryFootprint ?? 0) + (refinement?.memoryFootprint ?? 0)
    }

    /// Structural substeps encoded per fluid step. The fluid step never exceeds the CFL limit
    /// for (slightly cooled) ambient air, which bounds how many are needed.
    public var structureSubsteps: Int {
        guard let bodyStep else { return 0 }
        let bound = configuration.cfl * grid.cellSize / (0.8 * ambientSoundSpeed)
        return min(max(Int((bound / bodyStep).rounded(.up)), 1), 96)
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
        if hasSpecies {
            uniforms.afterburnEnergy = configuration.afterburnEnergy
            uniforms.oxygenPerFuel = Self.oxygenPerFuel
            uniforms.stillOxygen = Self.oxygenInAir * stillCell.density
            uniforms.afterburnRate =
                1 / max(configuration.afterburnTime * cbrt(max(largestCharge, 1e-3)), 1e-9)
        }
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

    /// Threads per tile in the tiled sweep: a column through the tile for each, or several if the
    /// pipeline cannot hold a whole tile's worth.
    private var tileThreads: MTLSize {
        var depth = Self.tileSize
        while depth > 1
            && Self.tileSize * Self.tileSize * depth > sweepTilesPipeline.maxTotalThreadsPerThreadgroup
        {
            depth /= 2
        }
        return MTLSize(width: Self.tileSize, height: Self.tileSize, depth: depth)
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
