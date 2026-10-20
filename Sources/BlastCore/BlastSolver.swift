import BlastModel
import Foundation
import Metal
import RadialBlast
import simd

/// GPU finite-volume solver for the compressible Euler equations around rigid obstacles.
///
/// The solver is not thread-safe: drive it from one isolation domain. Stepping is split into
/// `encodeBatch` / `completeBatch` so an app can commit work without blocking, while
/// `advance(steps:)` and `advance(until:)` wrap the pair synchronously for tools and tests.
public final class BlastSolver {
    public static let maxStepsPerBatch = 256
    /// With a body, how many steps apart the decisions that change what is encoded are taken:
    /// how many structural substeps each step may need (which caps the air's step), whether the
    /// air has gone quiet enough to freeze, and whether the body has failed (which brings in
    /// contact and debris). Batches end at these checkpoints, so that the decisions depend only
    /// on the step count, never on how the steps were batched.
    public static let checkpointInterval = 64
    public static let maxGauges = 64

    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    public let grid: Grid
    public var configuration: SolverConfiguration

    /// Simulated time in seconds since the last `restart()`.
    public internal(set) var time: Double = 0
    public internal(set) var stepCount = 0
    /// The run's clock on the GPU, in ticks of 2^-40 s (`StepControl.clock`), carried from batch to
    /// batch: the steps' times it gives are the same however the run is batched.
    var clockTicks: UInt64 = 0
    var exposurePlane: ExposurePlane?
    /// The one-dimensional solution a charge was mapped from, where it was and how far it reached,
    /// for an exposure plane set up after it (`configureExposurePlane`); nil otherwise.
    var mappedStart:
        [(blast: SphericalBlast, centre: SIMD3<Float>, radius: Float, charge: Charge, mirrors: Int)] =
            []
    /// How far out each mapped charge was laid from its one-dimensional solution, m; empty for the
    /// balloon.
    public var mappedRadii: [Float] { mappedStart.map(\.radius) }
    /// Charges still to fire, or mapped charges still to be laid, in order of time
    /// (`DelayedCharges.swift`).
    var pendingFirings: [PendingFiring] = []
    /// The charges' positions and the gauges' cells' centres the scene was loaded with, for those
    /// laid later.
    var firingCharges: [Charge] = []
    var firingProbes: [SIMD3<Float>] = []
    /// What became of each delayed charge: when it fired and how it was laid down.
    public internal(set) var firings: [Firing] = []
    /// The step from which the time step grows again from a small share of the CFL limit, as at the
    /// start: the step after a charge fired during the run.
    var rampStart = 0
    /// When the last charge laid down during the run was, s (0 without one): the air sleeps late
    /// counting from it.
    var lastFiring = 0.0
    /// The latest a mapped start may begin, s: its one-dimensional solution stops there should the
    /// shock not have reached its radius yet, so that a short run still steps the grid. Nil for no
    /// limit; the app sets half the run's duration. Takes effect at the next `load`.
    public var mappedStartLatest: Double?
    /// The most voxels, and the samples a side of each, the early fireball frames take
    /// (`earlyFireballFrames`); nil for their defaults. For studying their resolution.
    public var earlyFrameVoxelLimit: Int?
    public var earlyFrameSampleCount: Int?
    var exposureNeedsInitialSample = false
    var envelopeExposure: EnvelopeExposure?
    var envelopeNeedsInitialSample = false
    var envelopeComponentRecorder: EnvelopeComponentRecorder?
    var envelopeVenting: EnvelopeVenting?
    var componentsNeedInitialSample = false
    var gpuProfiler: BatchGPUProfiler?
    public internal(set) var lastBatchGPUProfile: BatchGPUProfile?

    /// The air beside the component recorder's faces (their fluid cells and a cell round them),
    /// and about each structure's solids (a cell beyond them), in which refinement is held while
    /// loaded (`SolverConfiguration.refinementHoldsEnvelopes`, `refinementHoldsStructures`).
    var facadeBand: MTLBuffer?

    /// The holes fragments make and the breaches close-in charges make, as venting opens them.
    var fragmentOpenings: [(component: Int, owner: Int, cells: [Int], time: Double, cause: String)] =
        []
    var breachOpenings: [(component: Int, owner: Int, cells: [Int], time: Double, cause: String)] = []

    /// Cells of air a moving body's outline may not take: beside the stationary envelopes' recorded
    /// faces, which the recorders read; nil when no body moves beside them.
    var keptAirBuffer: MTLBuffer?
    /// One pressure history per gauge, in the order passed to `setGauges`.
    public internal(set) var gaugeHistories: [[GaugeSample]] = []
    /// `rgba16Float` volume: overpressure and peak overpressure (both in units of ambient
    /// pressure), positive impulse (Pa s) and a solid flag. Refreshed on request.
    public let visualizationTexture: MTLTexture
    public internal(set) var bodies: [StructuralBody] = []
    /// Whether a pool ran out while it could still have grown, so that the run refined less than
    /// one whose pools were made at full size would have: it grew too late, which its room ahead
    /// (`makeRefinementRoom`) is meant never to allow.
    public internal(set) var refinementPoolGrewLate = false
    /// Independent bodies came close, and from then on are encoded a substep at a time, side by
    /// side, in contact with each other.
    public internal(set) var bodiesInContact = false
    /// For timing contact between bodies alone: with true, bodies in contact are encoded a
    /// substep at a time as usual but the pairs between them are not (`blastbench
    /// contact-profile`). Never for a result.
    public var bodyContactPairsSkipped = false
    /// Each body's own step overrides from before contact, which shares one step among them all.
    var stepsBeforeContact: [(solids: Float?, shells: Float?)] = []
    var bodyContactPipelines: [String: MTLComputePipelineState] = [:]
    var tiledCoupling: TiledCoupling?
    var couplingTiles: MTLBuffer?
    var denseCouplingCells = 0
    let allocateCouplingPipeline: MTLComputePipelineState
    let wakeCouplingPipeline: MTLComputePipelineState
    let haltCouplingPipeline: MTLComputePipelineState
    var combinedOccupancyBuffer: MTLBuffer?
    var interactionBuffer: MTLBuffer?
    var bodyEnvelopeBuffer: MTLBuffer?
    let bodyComposePipeline: MTLComputePipelineState
    let haltInteractionPipeline: MTLComputePipelineState
    let clearEnvelopesPipeline: MTLComputePipelineState
    let solidEnvelopePipeline: MTLComputePipelineState
    let shellEnvelopePipeline: MTLComputePipelineState
    let validateEnvelopesPipeline: MTLComputePipelineState
    /// Sound speed of the undisturbed air, used to bound the fluid time step.
    var ambientSoundSpeed: Float = 340
    var ambientDensity: Float = 1.225
    /// Cells of the air grid, around the structure, whose solid flag follows the structure.
    var couplingRegion: (origin: SIMD3<Int>, dims: SIMD3<Int>)?
    var occupancyBuffer: MTLBuffer?
    /// What loose debris takes from the air in each cell of the coupling region during one air step.
    var debrisExchangeBuffer: MTLBuffer?
    /// The frontal area of the loose debris in each cell of the coupling region.
    var debrisAreaBuffer: MTLBuffer?
    /// Velocity of the solid in each cell of the coupling region, three floats per cell. A
    /// single zero cell stands in when there is no structure.
    var wallVelocityBuffer: MTLBuffer
    let stillWallBuffer: MTLBuffer
    var experimentalBoxDefinition: MTLBuffer?
    var experimentalBoxMask: MTLBuffer?
    /// The structures' coupling laid over the whole grid, while freestanding objects share the air.
    var bodyCouplingWholeGrid = false
    var experimentalBoxImpulse: MTLBuffer?
    /// The experimental rigid boxes, as last placed; nil for one taken out of the air.
    var experimentalBoxes: [RigidBoxBody?] = []
    var experimentalBoxMaxStep: Float = 0
    /// A longest air step a driver sets while its objects are near a structure (nil for none), so
    /// that each air step is one of the structure's steps and contact keeps its time.
    var experimentalStepCeiling: Float?
    var experimentalBoxRemapMode: ExperimentalBoxRemap = .redistribution

    let library: MTLLibrary
    /// The kernels that run on every cell, compiled for one gas model so that the other models'
    /// code is left out of them (see `airModelOf` in Solver.metal).
    struct CellKernels {
        var sweep: MTLComputePipelineState
        var sweepTiles: MTLComputePipelineState
        var collectTiles: MTLComputePipelineState
        var redistributeCutDefects: MTLComputePipelineState
        var keepStructureCut: MTLComputePipelineState
        var takeStructureCut: MTLComputePipelineState
    }
    /// Structures' outlines as cut cells, when `configuration.structureCutCells` laid them at the
    /// last restart (`StructureCutGeometry`): per cell its record, the records, their walls,
    /// differences and what each sets aside, and the cells that take what is set aside.
    struct StructureCutBuffers {
        var geometry: StructureCutGeometry
        var index: MTLBuffer
        var cells: MTLBuffer
        var records: MTLBuffer
        var walls: MTLBuffer
        var targets: MTLBuffer
        var defects: MTLBuffer
        var passed: MTLBuffer
        var receivers: MTLBuffer
        var shares: MTLBuffer
        var starts: MTLBuffer
        var contributors: MTLBuffer
    }
    var structureCut: StructureCutBuffers?
    /// The terrain's cut cells, when `configuration.terrainCutCells` laid them at the last load.
    var terrainCut: TerrainCutBuffers?
    /// `CellKernels` for each gas model used so far, with gravity compiled in or not.
    var cellKernelsByModel: [Int: CellKernels] = [:]
    let wakeTilesPipeline: MTLComputePipelineState
    let preparePipeline: MTLComputePipelineState
    let sampleGaugesPipeline: MTLComputePipelineState
    /// Kernels compiled with gravity in the air, by name, made when first needed.
    var gravityPipelines: [String: MTLComputePipelineState] = [:]
    let measurePipeline: MTLComputePipelineState
    let visualizationPipeline: MTLComputePipelineState
    let splatPipeline: MTLComputePipelineState
    let remaskPreparePipeline: MTLComputePipelineState
    let remaskApplyPipeline: MTLComputePipelineState
    /// Shuts in the terrain's cut slivers under a structure standing on them (`remaskCapSlivers`).
    let remaskCapSliversPipeline: MTLComputePipelineState
    /// Per column with cut cells, its lowest cell shut in under a structure, plus one (`remaskCapSlivers`).
    var cappedSliverBuffer: MTLBuffer?
    let debrisExchangePipeline: MTLComputePipelineState
    let shellSplatPipeline: MTLComputePipelineState
    /// The shells' splat with elements at a pitch compiled in, for bodies that have them.
    lazy var inclinedShellSplatPipeline: MTLComputePipelineState? = {
        let constants = MTLFunctionConstantValues()
        var pitched = true
        constants.setConstantValue(&pitched, type: .bool, index: 25)
        return try? ShaderLibrary.pipeline("shellSplat", in: library, constants: constants)
    }()
    let beamSplatPipeline: MTLComputePipelineState

    let stateBuffers: [MTLBuffer]
    /// Densities of unburnt detonation products and of oxygen in each cell, kept alongside the
    /// state for afterburning; made when the air is filled with afterburning on. Until then a
    /// one-cell stand-in is bound.
    var speciesBuffers: [MTLBuffer] = []
    let noSpecies: MTLBuffer
    var current = 0
    let maskBuffer: MTLBuffer
    /// Solid flags of the rigid blocks alone, which never change.
    let rigidMaskBuffer: MTLBuffer
    var needsRigidMaskCapture = true
    let peakBuffer: MTLBuffer
    let impulseBuffer: MTLBuffer
    /// The CPU addresses of the state, mask, peak and impulse buffers, taken once: each
    /// `MTLBuffer.contents()` returns an inner pointer, for which the buffer is retained and
    /// autoreleased, so every per-cell read through it added an entry to the thread's autorelease
    /// pool, and on a thread whose pool never drains (a command-line tool, a worker) kept the
    /// buffer alive. Shared storage: the addresses never move.
    let stateContents: [UnsafeMutableRawPointer]
    let maskContents: UnsafeMutableRawPointer
    let peakContents: UnsafeMutableRawPointer
    let impulseContents: UnsafeMutableRawPointer
    let controlBuffer: MTLBuffer
    let maxSpeedBuffer: MTLBuffer
    let gaugeLogBuffer: MTLBuffer
    let gaugeCellBuffer: MTLBuffer
    var gaugeCount = 0
    /// Still air: one flag per tile of 8 x 8 x 8 cells (still, awake, or woken during the last
    /// step), the list of awake tiles, its length, and the sweeps' threadgroup counts.
    static let tileSize = 8
    let tileDims: SIMD3<Int>
    let tileFlagBuffer: MTLBuffer
    let tileListBuffer: MTLBuffer
    let tileCountBuffer: MTLBuffer
    let tileDispatchBuffer: MTLBuffer
    /// Whether still air is being skipped since the last restart.
    var tilesEnabled = false
    /// The largest charge deposited since the air was last filled, kg, which sets how fast its
    /// products burn.
    var largestCharge: Float = 0
    /// The deflagration laid down by `load`, if the scenario has one: its flame front and vent
    /// panels (see `Deflagration.metal`). Its unburnt mixture is the species' x.
    var deflagrationStage: DeflagrationStage?
    /// The uniform state the air was last filled with: air still in it is not swept.
    var stillCell = CellState(Primitive(density: 1.225, pressure: 101_325), gamma: 1.4)
    var batchInFlight = false
    /// True once the blast has left and the air has been frozen; only the structure advances.
    public internal(set) var airIsAsleep = false
    /// The air's last time step (before any clipping to a time limit), which at a checkpoint
    /// sizes the substeps of the steps up to the next.
    var lastFluidStep: Float = 0
    /// Structural substeps encoded per air step until the next checkpoint.
    var checkpointSubsteps = 0
    /// The substeps each step of the batch being encoded may take, set with its first part.
    var batchSubsteps = 0
    /// The finer level of the air, while it is refined (see `SolverConfiguration.refinement`).
    var refinement: AirRefinement?
    /// The second finer level, refining the first, with `SolverConfiguration.refinementLevels` 2.
    var finerRefinement: AirRefinement?
    /// With detailed GPU profiling, while a batch is encoded: the encoder now open.
    var liveEncoder: (() -> MTLComputeCommandEncoder)?
    /// Per refined level, for the room its pool keeps ahead (`makeRefinementRoom`): the most
    /// patches a step has added, the patches in use at the last look, and whether the pool could
    /// still grow then; and the steps encoded since.
    var poolGrowth: [Double] = []
    var poolLive: [Int] = []
    var poolCouldGrow: [Bool] = []
    var stepsSincePoolLook = 0
    /// Bound in place of the refinement's buffers while the air is not refined.
    let refinementPlaceholder: MTLBuffer
    /// The radiative cooling's kernels and buffers while it is on, what the gas has radiated since
    /// the restart, J, and that total at the end of each batch (see `RadiativeCooling`).
    var radiativeCoolingStage: RadiativeCoolingStage?
    /// The air at the ground when it was last filled, from which gravity's hydrostatic background
    /// rises (see `AirGravity`).
    var gravityGround = Primitive(density: 1.225, pressure: 101_325)
    /// Gravity's background for each level, by its cells along a coarse cell's edge, made when
    /// the air is filled or a level first needs one.
    var gravityTables: [Int: MTLBuffer] = [:]
    /// Sub-grid mixing's eddy viscosity in each coarse cell, worked out before each step's sweeps,
    /// and its kernel, while the air has sub-grid mixing.
    var viscosityBuffer: MTLBuffer?
    var viscosityPipeline: MTLComputePipelineState?
    var periodicPipeline: MTLComputePipelineState?
    public internal(set) var radiatedEnergy = 0.0
    public internal(set) var radiationHistory: [(time: Double, energy: Double)] = []
    /// Per gauge: the finest cell of its cell that holds its point, as x + R (y + R z) for R
    /// finest cells along a coarse cell's edge, or `UInt32.max` to read the coarse cell.
    let gaugeChildBuffer: MTLBuffer
    /// Each gauge's point (w 1) or none (w 0): a gauge whose cell turns solid reads the fluid cell
    /// beside it nearest the point.
    let gaugePointBuffer: MTLBuffer
    var gaugePoints: [SIMD3<Float>?] = []
    /// The congestion's per-cell fields and the turbulence its obstacles make; nil without
    /// congestion, whose code is then left out of the kernels.
    var congestion: CongestionBuffers?
    /// Its per-cell porosity and drag (`CongestionField.porosityDrag`).
    var congestionBuffer: MTLBuffer? { congestion?.porosityDrag }
    /// The scenario's rigid blocks, whose outline the refined air follows at its own resolution;
    /// What to cut out of the air on the GPU at the end of each batch that reaches its time limit,
    /// as one landing on a frame does, for `airSlice(region:stride:)` and
    /// `fireball(luminousTemperature:)` to return then instead of reading the state on the CPU
    /// while the GPU waits. Set it before encoding a batch that may end on a frame.
    public var frameRequest = FrameRequest()
    /// A timeline recorder's view field, cut out at the end of each batch that passes its next
    /// frame's time, so that `viewField(stride:)` then waits for nothing; nil while none records.
    /// It changes nothing in the run.
    public var viewFieldCapture: ViewFieldCapture?
    /// Built the first time a request is made.
    var frameExtractor: FrameExtractor?
    /// nil once the mask has been edited by hand.
    var rigidBoxes: [Box]?
    /// The ground's shape the mask was made with; nil for flat ground or once the mask has been
    /// edited by hand. The fine cells follow it as they follow `rigidBoxes`.
    public internal(set) var terrain: Terrain?
    /// Each charge loaded, and the sphere about it the refinement's ceiling spares.
    var ceilingExemptions: [(position: SIMD3<Float>, radius: Float)] = []
    /// The first cell of air above the terrain in each column, x fastest; nil for flat ground.
    public internal(set) var terrainSurface: [Int32]?
    /// Charges laid down in fine cells for refined air (see `deposit`): what each fine cell gained,
    /// density and energy per volume, over the uniform state the air was filled with. Given to the
    /// fine cells at the next `restart()`; forgotten when the air is filled or edited by hand.
    var fineDeposit: [SIMD3<Int>: SIMD2<Float>] = [:]
    /// The scene's charges (0 the main one, then the additional ones) that the last `load` laid
    /// nothing of, being inside a block, the ground or a structure (`Scenario.blocks`).
    public internal(set) var blockedCharges: [Int] = []

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
            try ShaderLibrary.pipeline(name, in: library)
        }
        wakeTilesPipeline = try pipeline("wakeTiles")
        preparePipeline = try pipeline("prepareStep")
        sampleGaugesPipeline = try pipeline("sampleGauges")
        measurePipeline = try pipeline("measureWaveSpeed")
        visualizationPipeline = try pipeline("updateVisualization")
        splatPipeline = try pipeline("splatStructure")
        bodyComposePipeline = try pipeline("composeBodyOccupancy")
        allocateCouplingPipeline = try pipeline("allocateCouplingTiles")
        wakeCouplingPipeline = try pipeline("wakeCouplingTiles")
        haltCouplingPipeline = try pipeline("haltCouplingCapacity")
        haltInteractionPipeline = try pipeline("haltBodyInteraction")
        clearEnvelopesPipeline = try pipeline("clearBodyEnvelopes")
        solidEnvelopePipeline = try pipeline("solidBodyEnvelope")
        shellEnvelopePipeline = try pipeline("shellBodyEnvelope")
        validateEnvelopesPipeline = try pipeline("validateBodyEnvelopes")
        remaskPreparePipeline = try pipeline("remaskPrepare")
        remaskCapSliversPipeline = try pipeline("remaskCapSlivers")
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
        stateContents = stateBuffers.map { $0.contents() }
        maskContents = maskBuffer.contents()
        peakContents = peakBuffer.contents()
        impulseContents = impulseBuffer.contents()
        controlBuffer = try buffer(MemoryLayout<StepControl>.stride, "step control")
        // The fastest wave and the largest overpressure; with refined levels' own steps, each
        // level's fastest wave.
        maxSpeedBuffer = try buffer(4 * MemoryLayout<UInt32>.stride, "max wave speed and overpressure")
        gaugeLogBuffer = try buffer(
            (Self.maxStepsPerBatch + 1) * (Self.maxGauges + 1) * MemoryLayout<Float>.stride, "gauge log")
        gaugeCellBuffer = try buffer(Self.maxGauges * MemoryLayout<UInt32>.stride, "gauge cells")
        gaugeChildBuffer = try buffer(Self.maxGauges * MemoryLayout<UInt32>.stride, "gauge fine cells")
        memset(gaugeChildBuffer.contents(), 0xFF, gaugeChildBuffer.length)
        gaugePointBuffer = try buffer(Self.maxGauges * MemoryLayout<SIMD4<Float>>.stride, "gauge points")
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

        memset(maskContents, 0, cells)
        memset(rigidMaskBuffer.contents(), 0, cells)
        fill(uniform: Primitive(density: 1.225, pressure: configuration.ambientPressure))
    }

    /// The bodies' settlements since the last `restart()`, once `settleStructures()` has run.
    public internal(set) var settlements: [Settlement] = []
    /// Whether `settleStructures()` has run since the last `restart()`.
    public internal(set) var structuresSettled = false

    /// The GPU's time for a step lately, from the buffers `advance` has waited for.
    var gpuSteps = GPUStepRate()
    /// The GPU's seconds in the batches' step buffers since the solver was made, each buffer's
    /// start to end. Other processes' work on the GPU between a buffer's start and end counts
    /// too, so on a shared Mac compare the least of several runs.
    public internal(set) var stepGPUSeconds: Double = 0
}
