import BlastModel
import Foundation
import Metal
import simd

/// One finer level of the air: patches of (4r)^3 cells over the blocks of 4 x 4 x 4 cells of the
/// grid it refines that the shock crosses, from a pool that grows as they do up to a fixed size,
/// placed and advanced on the GPU (see `Refine.metal`). The first level refines the coarse grid; a second refines the first
/// (its `parent`), and its patch list, cells, outline and structure counts lie in the first
/// level's buffers after the first level's own, so that a kernel given the first level's can
/// reach both. Owned by `BlastSolver`.
final class AirRefinement {
    /// Coarse cells along a patch's edge.
    static let patchSize = 4
    let ratio: Int
    let bodyComposition: Bool
    /// Fine cells along a patch's edge.
    let side: Int
    /// The patches the pool holds now; it grows (`grow`) towards `capacity` as more are wanted,
    /// each patch keeping its place, so that a level that never fills it steps as one made at
    /// `capacity` would.
    private(set) var maxPatches: Int
    /// For tests: the allocations to make before one fails, as when memory runs out part way through
    /// growing (`grow`).
    var allocationsBeforeFailure: Int?
    /// The most patches the pool may hold (its memory's worth).
    let capacity: Int
    /// The grid's size in blocks of `patchSize` cells.
    let tileDims: SIMD3<Int>
    /// The level this one refines, or nil for the coarse grid.
    let parent: AirRefinement?
    /// The parent's cells along a coarse cell's edge: 1 for the first level.
    let parentScale: Int
    /// A block's edge, m: `patchSize` of the parent's cells.
    let blockSize: Float
    /// Where this level's patch list, and its cells, start in the buffers it shares with its
    /// parent, in entries (0 for the first level).
    let patchOffset: Int
    private(set) var cellOffset: Int

    /// Per block: its patch, or -1.
    let patchOfTile: MTLBuffer
    /// Per pool slot: the block it refines, or `UInt32.max` while free.
    private(set) var tileOfPatch: MTLBuffer
    private var freeStack: MTLBuffer
    /// The free stack's height, the count of new patches and the count of listed patches.
    private var counters: MTLBuffer
    private(set) var patchList: MTLBuffer
    private var newPatches: MTLBuffer
    /// Threadgroup counts of the sweep, halo, reflux, restriction, fill and ghost dispatches, then
    /// the number of patches in use.
    let arguments: MTLBuffer
    let wanted: MTLBuffer
    /// Per coarse cell of each patch: whether it was solid when the fine cells last saw it.
    private var seenMask: MTLBuffer
    /// Per pool slot: whether the patch lies over an outline that differs from the coarse cells',
    /// and so stays until the next reset.
    private(set) var pinned: MTLBuffer
    /// Per fine cell: solid (bit 0) and rigid (bit 1), the fine cells' own outline; the velocity
    /// of the structure where it is solid; and the structure's points counted into it.
    private(set) var fineMask: MTLBuffer
    private(set) var fineWall: MTLBuffer
    var useLocalBoxRemap = true
    var boxRemapMode: ExperimentalBoxRemap = .redistribution
    var measureBoxRemap = false
    private(set) var boxRemapProfile: [String: Double] = [:]
    private var experimentalBoxImpulse: MTLBuffer?
    private(set) var fineOccupancy: MTLBuffer
    /// Gravity's background at this level's resolution (see `gravityCellOf` in Solver.metal),
    /// while the air has gravity.
    var gravityTable: MTLBuffer?
    /// And at the resolution of the level it refines.
    var parentGravityTable: MTLBuffer?
    /// The coarse cells' eddy viscosity while the air has sub-grid mixing.
    var viscosity: MTLBuffer?
    /// Whether afterburning has its extinction limit.
    var burnLimit = false
    /// Whether afterburning is limited by the sub-grid mixing (`MixedAfterburning`).
    var burnMixing = false
    private var combinedBodyOccupancy: MTLBuffer?
    private var bodyComposePipeline: MTLComputePipelineState?
    private var bodyPublishPipeline: MTLComputePipelineState?
    /// The rigid blocks, as minimum and maximum corners, for the fine outline; none to take the
    /// coarse cells' rigid mask instead.
    private var boxes: MTLBuffer
    /// The blocks near each block of this level, so that a new patch's fill looks only at those
    /// (`refineFill`): their count, then where each block's list starts (one more than the
    /// blocks), then the lists of indices into `boxes`.
    private var boxIndex: MTLBuffer
    /// The terrain's heights and grid for the fine outline (`TerrainUniforms` in Refine.metal);
    /// `enabled` 0 without one.
    private var terrainHeights: MTLBuffer
    private var terrainUniforms = TerrainUniforms()
    /// The fine state, twice for the sweeps to alternate between; the first is current between
    /// coarse steps, since a step takes an even number of fine sweeps.
    private(set) var fine: [MTLBuffer]
    private var halo: MTLBuffer
    /// Two fine cells either side of each patch along the sweep under way, and what they are.
    private var ghosts: MTLBuffer
    private var ghostKinds: MTLBuffer
    private var fineFlux: MTLBuffer
    /// Each fine cell's impulse since its patch was placed, and each coarse cell's impulse then.
    private(set) var fineImpulse: MTLBuffer
    private var impulseBase: MTLBuffer
    private(set) var coarseFlux: MTLBuffer
    /// With afterburning: the fine cells' fuel and oxygen (twice, as `fine`), their ghosts', and
    /// their flux registers, fine and coarse, laid out as the others; each a placeholder without.
    let species: Bool
    private(set) var fineSpecies: [MTLBuffer]
    private var ghostSpecies: MTLBuffer
    private var fineSpeciesFlux: MTLBuffer
    private(set) var coarseSpeciesFlux: MTLBuffer
    private let device: MTLDevice

    private let library: MTLLibrary
    /// The fine sweep, reading the gas model from its uniforms; and, for each gas model used so
    /// far, the sweep compiled for that model alone, which leaves the others' code out of it.
    private let sweepPipeline: MTLComputePipelineState
    private var sweepPipelines: [AirModel: MTLComputePipelineState] = [:]
    /// The sweep for each gas model, and the ghosts, refluxing and filling, with gravity in the air
    /// compiled in (see `airGravityConstant` in Solver.metal), made when first needed.
    private var gravityPipelines: [String: MTLComputePipelineState] = [:]
    private let ghostPipeline: MTLComputePipelineState
    private let haloPipeline: MTLComputePipelineState
    private let refluxPipeline: MTLComputePipelineState
    private let restrictPipeline: MTLComputePipelineState
    /// The band beside envelope faces in which refinement is held while the air is loaded
    /// (Refine.metal's `FacadeBand`); off without one.
    var facadeBand: MTLBuffer?
    var facadeBandParameters = FacadeBandParameters()
    private let flagPipeline: MTLComputePipelineState
    private let flagTilesPipeline: MTLComputePipelineState
    private let flagFinePipeline: MTLComputePipelineState
    private let nestPipeline: MTLComputePipelineState
    private let syncPipeline: MTLComputePipelineState
    private let conservePipeline: MTLComputePipelineState
    private let remaskPreparePipeline: MTLComputePipelineState
    private let remaskApplyPipeline: MTLComputePipelineState
    private let releasePipeline: MTLComputePipelineState
    private let allocatePipeline: MTLComputePipelineState
    private let requestPipeline: MTLComputePipelineState
    /// With the solver's detailed GPU profiling, switches to an encoder of the stage's own and
    /// returns it.
    var stage: ((String) -> MTLComputeCommandEncoder)?
    private let levelStepsPipeline: MTLComputePipelineState
    private let keepPipeline: MTLComputePipelineState
    /// With the levels' own steps (`refineLevelSteps`): a copy of `arguments` for each substep
    /// this level may take in a step (for a level beneath another, in each substep of its
    /// parent's), of no threadgroups where it does not take it; and the dispatch that copies its
    /// state back into its first buffer after an odd number of sweeps, one per parent substep.
    private let substepArguments: MTLBuffer
    private let keepArguments: MTLBuffer
    private let grantPipeline: MTLComputePipelineState
    /// Per group of `allocationGroup` blocks: how many ask for a new patch, then where their
    /// requests start among all.
    private let groupCounts: MTLBuffer
    /// Blocks per threadgroup of the allocation's kernels (`allocationGroup` in Refine.metal).
    static let allocationGroup = 256
    private let listPipeline: MTLComputePipelineState
    private let argumentsPipeline: MTLComputePipelineState
    private let fillPipeline: MTLComputePipelineState
    private let openPanesPipeline: MTLComputePipelineState
    /// Envelope venting's panes (`EnvelopeVenting.sortedPaneCells` and their status), so that the
    /// fine cells under a broken pane are air; nil without venting.
    private var panes: (cells: MTLBuffer, status: MTLBuffer, lookup: PaneLookup)?
    /// A lookup of no panes, for fills without venting.
    private let noPanes: MTLBuffer

    /// With the terrain's cut cells on the coarse grid (`coarseCut`): each fine cell's share of air
    /// and apertures (two float4 a cell), the differences its sweeps keep (two more), whether each
    /// patch has cut cells, and what each fine column passes up out of the top of its stack of
    /// patches (two float4 a column of each patch). See Refine.metal.
    let cutTerrain: Bool
    private var fineCut: MTLBuffer?
    private var fineDefects: MTLBuffer?
    var fineCutBuffer: MTLBuffer? { fineCut }
    private var patchCut: MTLBuffer?
    private var passedUp: MTLBuffer?
    /// The coarse grid's cut cells, which refluxing, restriction and filling read and write (set on
    /// every level; a level beneath another reads its parent's fine geometry instead).
    var coarseCut: TerrainCutBuffers? {
        didSet { terrainUniforms.cutSamples = UInt32(coarseCut?.geometry.samples ?? 8) }
    }
    /// The parent's cut cells' shares and apertures, and their differences: the coarse grid's
    /// records, or the parent level's fine geometry (see `parentCutLow` in Refine.metal).
    private var parentCutRecords: MTLBuffer? { parent?.fineCut ?? coarseCut?.records }
    private var parentCutDefects: MTLBuffer? { parent?.fineDefects ?? coarseCut?.defects }
    private lazy var redistributeCutPipeline: MTLComputePipelineState? =
        (try? ShaderLibrary.pipeline(
            "refineRedistributeCut", in: library)).map { withGravity($0, "refineRedistributeCut") }
    private lazy var capSliversPipeline: MTLComputePipelineState? = try? ShaderLibrary.pipeline(
        "refineRemaskCapSlivers", in: library)
    private lazy var capSliversApplyPipeline: MTLComputePipelineState? = try? ShaderLibrary.pipeline(
        "refineCapSliversApply", in: library)
    private lazy var cutPassUpPipeline: MTLComputePipelineState? =
        (try? ShaderLibrary.pipeline(
            "refineCutPassUp", in: library)).map { withGravity($0, "refineCutPassUp") }
    /// `base`, or with cut cells, compiled for them.
    private func cutSpecialised(_ base: MTLComputePipelineState, _ name: String) -> MTLComputePipelineState {
        cutTerrain ? withGravity(base, name) : base
    }

    /// Bytes one patch takes: two fine states, its halo and its flux registers, and with `species`
    /// their fuel and oxygen.
    static func bytesPerPatch(
        ratio: Int, species: Bool = false, bodyComposition: Bool = false, cut: Bool = false
    ) -> Int {
        let side = patchSize * ratio
        let cell = MemoryLayout<CellState>.stride
        let gas =
            2 * side * side * side * cell + side * side * side * (4 + 1 + 12 + 16) + 64 * 5 + 4 + 512
            * cell
            + 4 * side * side * (cell + 1) + 6 * side * side * 5 * 4 + 6 * patchSize * patchSize * 5 * 4
            + (cut ? side * side * side * 64 + side * side * 32 + 4 : 0)
        let composition = bodyComposition ? side * side * side * 16 : 0
        guard species else { return gas + composition }
        return gas + composition + 2 * side * side * side * 8 + 4 * side * side * 8 + 6 * side * side * 8
            + 6 * patchSize * patchSize * 8
    }

    /// The size in blocks of a level whose parent has `parentScale` cells along each coarse
    /// cell's edge, and how many patches `memory` holds.
    static func layout(
        grid: Grid, ratio: Int, parentScale: Int, memory: Int, species: Bool, bodyComposition: Bool,
        cut: Bool = false
    ) -> (tileDims: SIMD3<Int>, maxPatches: Int) {
        let block = patchSize
        let cells = SIMD3(grid.nx, grid.ny, grid.nz) &* parentScale
        let tileDims = (cells &+ (block - 1)) / block
        let tiles = tileDims.x * tileDims.y * tileDims.z
        let patches = max(
            1,
            min(
                tiles,
                memory
                    / bytesPerPatch(
                        ratio: ratio, species: species, bodyComposition: bodyComposition, cut: cut)))
        return (tileDims, patches)
    }

    /// A level of `memory` bytes. With `parent`, it refines that level (of the same ratio), whose
    /// shared buffers must have been made with room for it (`reserve`, in blocks and in cells).
    /// The pool starts with `start` patches, or its whole `memory`'s worth.
    init(
        device: MTLDevice, library: MTLLibrary, grid: Grid, ratio: Int, memory: Int, species: Bool = false,
        bodyComposition: Bool = false, parent: AirRefinement? = nil,
        reserve: (tiles: Int, cells: Int) = (0, 0), cut: Bool = false, start: Int? = nil
    )
        throws
    {
        precondition(ratio == 2 || ratio == 4, "The air is refined by 2 or 4")
        precondition(parent.map { $0.ratio == ratio } ?? true, "Every level is refined by the same ratio")
        self.ratio = ratio
        self.cutTerrain = cut
        self.bodyComposition = bodyComposition
        self.species = species
        self.parent = parent
        parentScale = parent.map { $0.parentScale * $0.ratio } ?? 1
        blockSize = grid.cellSize / Float(parentScale) * Float(Self.patchSize)
        side = Self.patchSize * ratio
        let layout = Self.layout(
            grid: grid, ratio: ratio, parentScale: parentScale, memory: memory, species: species,
            bodyComposition: bodyComposition, cut: cut)
        tileDims = layout.tileDims
        capacity = layout.maxPatches
        maxPatches = min(max(start ?? capacity, 1), capacity)
        let tiles = tileDims.x * tileDims.y * tileDims.z
        let fineCells = maxPatches * side * side * side

        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            try ShaderLibrary.pipeline(name, in: library)
        }
        sweepPipeline = try pipeline("refineSweep")
        ghostPipeline = try pipeline("refineGhosts")
        haloPipeline = try pipeline("refineSaveHalo")
        refluxPipeline = try pipeline("refineReflux")
        restrictPipeline = try pipeline("refineRestrict")
        flagPipeline = try pipeline("refineFlag")
        flagTilesPipeline = try pipeline("refineFlagTiles")
        flagFinePipeline = try pipeline("refineFlagFine")
        nestPipeline = try pipeline("refineNest")
        syncPipeline = try pipeline("refineSync")
        conservePipeline = try pipeline("refineFillConserve")
        remaskPreparePipeline = try pipeline("refineRemaskPrepare")
        remaskApplyPipeline = try pipeline("refineRemaskApply")
        releasePipeline = try pipeline("refineRelease")
        allocatePipeline = try pipeline("refineAllocate")
        requestPipeline = try pipeline("refineRequest")
        levelStepsPipeline = try pipeline("refineLevelSteps")
        keepPipeline = try pipeline("refineKeepCurrent")
        grantPipeline = try pipeline("refineGrant")
        listPipeline = try pipeline("refineList")
        argumentsPipeline = try pipeline("refineArguments")
        fillPipeline = try pipeline("refineFill")
        openPanesPipeline = try pipeline("refineOpenPanes")
        noPanes = try buffer(MemoryLayout<PaneLookup>.stride, "no panes")
        memset(noPanes.contents(), 0, noPanes.length)

        func buffer(_ length: Int, _ label: String) throws -> MTLBuffer {
            guard let buffer = device.makeBuffer(length: max(length, 16), options: .storageModeShared) else {
                throw BlastError.allocationFailed("\(label) (\(length) bytes)")
            }
            buffer.label = label
            return buffer
        }
        let cell = MemoryLayout<CellState>.stride
        let fineLength = fineCells * cell
        if let parent {
            // In the parent's buffers, after its own entries.
            patchOffset = parent.tileDims.x * parent.tileDims.y * parent.tileDims.z
            cellOffset = parent.maxPatches * parent.side * parent.side * parent.side
            precondition(
                parent.patchOfTile.length >= (patchOffset + tiles) * 4
                    && parent.fineMask.length >= cellOffset + fineCells,
                "The parent level has no room for this one")
            patchOfTile = parent.patchOfTile
            fineMask = parent.fineMask
            fineOccupancy = parent.fineOccupancy
            fine = [parent.fine[0], try buffer(fineLength, "fine state B")]
        } else {
            patchOffset = 0
            cellOffset = 0
            patchOfTile = try buffer((tiles + reserve.tiles) * 4, "patch of tile")
            fineMask = try buffer(fineCells + reserve.cells, "fine mask")
            fineOccupancy = try buffer((fineCells + reserve.cells) * 16, "fine occupancy")
            fine = [
                try buffer(fineLength + reserve.cells * cell, "fine state A"),
                try buffer(fineLength, "fine state B"),
            ]
        }
        tileOfPatch = try buffer(maxPatches * 4, "tile of patch")
        freeStack = try buffer(maxPatches * 4, "free patches")
        counters = try buffer(32, "refinement counters")
        patchList = try buffer(maxPatches * 4, "patches in use")
        newPatches = try buffer(maxPatches * 4, "new patches")
        arguments = try buffer(32 * 4, "refinement dispatches")
        substepArguments = try buffer(ratio * ratio * 32 * 4, "refinement dispatches per substep")
        keepArguments = try buffer(ratio * 3 * 4, "copies back after odd sweeps")
        wanted = try buffer(tiles, "blocks flagged")
        groupCounts = try buffer(
            (tiles + Self.allocationGroup - 1) / Self.allocationGroup * 4, "requests per group of blocks")
        seenMask = try buffer(maxPatches * Self.patchSize * Self.patchSize * Self.patchSize, "mask seen")
        pinned = try buffer(maxPatches * 4, "pinned patches")
        fineWall = try buffer(fineCells * 12, "fine wall velocity")
        boxes = try buffer(32, "rigid blocks")
        boxIndex = try buffer(16, "rigid blocks by block")
        terrainHeights = try buffer(16, "terrain heights")
        self.device = device
        self.library = library
        halo = try buffer(maxPatches * 512 * cell, "halo")
        ghosts = try buffer(maxPatches * 4 * side * side * cell, "ghost cells")
        ghostKinds = try buffer(maxPatches * 4 * side * side, "ghost kinds")
        fineFlux = try buffer(maxPatches * 6 * side * side * 5 * 4, "fine flux sums")
        fineImpulse = try buffer(maxPatches * side * side * side * 4, "fine impulse")
        impulseBase = try buffer(
            maxPatches * Self.patchSize * Self.patchSize * Self.patchSize * 4, "impulse before refinement")
        coarseFlux = try buffer(maxPatches * 6 * Self.patchSize * Self.patchSize * 5 * 4, "coarse fluxes")
        let pair = species ? 8 : 0
        fineSpecies = [
            try buffer(fineCells * pair, "fine species A"), try buffer(fineCells * pair, "fine species B"),
        ]
        ghostSpecies = try buffer(maxPatches * 4 * side * side * pair, "ghost species")
        fineSpeciesFlux = try buffer(maxPatches * 6 * side * side * pair, "fine species flux sums")
        coarseSpeciesFlux = try buffer(
            maxPatches * 6 * Self.patchSize * Self.patchSize * pair, "coarse species fluxes")
        if cut {
            fineCut = try buffer(fineCells * 32, "fine cut cells")
            fineDefects = try buffer(fineCells * 32, "fine cut differences")
            patchCut = try buffer(maxPatches * 4, "patches with cut cells")
            passedUp = try buffer(maxPatches * side * side * 32, "passed up out of the patches")
        } else {
            (fineCut, fineDefects, patchCut, passedUp) = (nil, nil, nil, nil)
        }
        if bodyComposition {
            combinedBodyOccupancy = try buffer(fineCells * 16, "combined fine body occupancy")
            memset(combinedBodyOccupancy!.contents(), 0, combinedBodyOccupancy!.length)
            bodyComposePipeline = try pipeline("composeFineBodyOccupancy")
            bodyPublishPipeline = try pipeline("publishFineBodyOccupancy")
        }
    }

    /// Bytes this level holds. A level beneath another holds part of its parent's buffers, which
    /// the parent counts.
    var memoryFootprint: Int {
        let shared =
            parent == nil ? [patchOfTile, fineMask, fineOccupancy, fine[0]].reduce(0) { $0 + $1.length } : 0
        return
            ([
                tileOfPatch, freeStack, patchList, newPatches, wanted, groupCounts, seenMask, halo, ghosts,
                ghostKinds,
                fineFlux, fineImpulse, impulseBase, coarseFlux, fineWall, ghostSpecies,
                fineSpeciesFlux, coarseSpeciesFlux, fine[1],
            ] + fineSpecies + [fineCut, fineDefects, patchCut, passedUp].compactMap { $0 }).reduce(0) {
                $0 + $1.length
            } + shared + (experimentalBoxImpulse?.length ?? 0)
            + (combinedBodyOccupancy?.length ?? 0)
    }

    /// Byte offset of this level's entries in `buffer`, one of those it may share with its parent.
    private func offset(of buffer: MTLBuffer) -> Int {
        if buffer === patchOfTile { return patchOffset * 4 }
        if buffer === fineMask { return cellOffset }
        if buffer === fineOccupancy { return cellOffset * 16 }
        if buffer === fine[0] { return cellOffset * MemoryLayout<CellState>.stride }
        return 0
    }

    /// With detailed profiling, moves `encoder` on to this level's stage `name`. Each method
    /// starts with this, as the encoder it is given may have been ended by a stage before.
    private func stage(_ name: String, _ encoder: inout MTLComputeCommandEncoder) {
        if let stage { encoder = stage("L\(parent == nil ? 1 : 2) " + name) }
    }

    /// Binds this level's own part of `buffer`.
    func bind(_ encoder: MTLComputeCommandEncoder, _ buffer: MTLBuffer, _ index: Int) {
        encoder.setBuffer(buffer, offset: offset(of: buffer), index: index)
    }

    /// The grid a level refines, as its kernels see it: the coarse grid's fields, or the parent
    /// level's, each with its byte offset.
    struct ParentView {
        var state: (MTLBuffer, Int)
        var species: (MTLBuffer, Int)
        var mask: (MTLBuffer, Int)
        var rigid: (MTLBuffer, Int)
        var wallVelocity: (MTLBuffer, Int)
        var impulse: (MTLBuffer, Int)
        /// The parent level's patch of each block (any buffer for the coarse grid).
        var patches: (MTLBuffer, Int)

        /// The coarse grid.
        init(
            state: MTLBuffer, species: MTLBuffer, mask: MTLBuffer, rigid: MTLBuffer, wallVelocity: MTLBuffer,
            impulse: MTLBuffer, placeholder: MTLBuffer
        ) {
            self.state = (state, 0)
            self.species = (species, 0)
            self.mask = (mask, 0)
            self.rigid = (rigid, 0)
            self.wallVelocity = (wallVelocity, 0)
            self.impulse = (impulse, 0)
            patches = (placeholder, 0)
        }

        init(level: AirRefinement, current n: Int) {
            state = (level.fine[n], n == 0 ? level.offset(of: level.fine[0]) : 0)
            species = (level.fineSpecies[n], 0)
            mask = (level.fineMask, level.offset(of: level.fineMask))
            rigid = mask
            wallVelocity = (level.fineWall, 0)
            impulse = (level.fineImpulse, 0)
            patches = (level.patchOfTile, level.offset(of: level.patchOfTile))
        }
    }

    /// This level as the grid a level beneath it refines, with its fine state `n` current.
    func view(current n: Int = 0) -> ParentView { ParentView(level: self, current: n) }

    private func set(_ encoder: MTLComputeCommandEncoder, _ bound: (MTLBuffer, Int), _ index: Int) {
        encoder.setBuffer(bound.0, offset: bound.1, index: index)
    }

    func encodeComposeBody(
        _ encoder: MTLComputeCommandEncoder, threshold: UInt32,
        interaction: MTLBuffer, uniforms: SolverUniforms
    ) {
        var encoder = encoder
        stage("remask", &encoder)
        guard let combinedBodyOccupancy, let bodyComposePipeline else { return }
        var threshold = threshold
        var uniforms = uniforms
        stage("remask", &encoder)
        encoder.setComputePipelineState(bodyComposePipeline)
        bind(encoder, fineOccupancy, 0)
        encoder.setBuffer(combinedBodyOccupancy, offset: 0, index: 1)
        encoder.setBytes(&threshold, length: 4, index: 2)
        setUniforms(encoder, &uniforms, index: 3)
        encoder.setBuffer(patchList, offset: 0, index: 4)
        encoder.setBuffer(interaction, offset: 0, index: 5)
        encoder.dispatchThreadgroups(
            indirectBuffer: arguments, indirectBufferOffset: 72,
            threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
    }

    func encodePublishBodies(_ encoder: MTLComputeCommandEncoder, uniforms: SolverUniforms) {
        var encoder = encoder
        stage("remask", &encoder)
        guard let combinedBodyOccupancy, let bodyPublishPipeline else { return }
        var uniforms = uniforms
        stage("remask", &encoder)
        encoder.setComputePipelineState(bodyPublishPipeline)
        bind(encoder, fineOccupancy, 0)
        encoder.setBuffer(combinedBodyOccupancy, offset: 0, index: 1)
        setUniforms(encoder, &uniforms, index: 2)
        encoder.setBuffer(patchList, offset: 0, index: 3)
        encoder.dispatchThreadgroups(
            indirectBuffer: arguments, indirectBufferOffset: 72,
            threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
    }

    /// Patches in use after the last regrid.
    var patchCount: Int { Int(arguments.contents().load(fromByteOffset: 24 * 4, as: UInt32.self)) }
    /// The most patches in use at once since the last reset, and whether the pool ever ran out
    /// (more blocks wanted refining than it had patches free, so some were not).
    var poolUse: (most: Int, ranOut: Bool) {
        let count = counters.contents().bindMemory(to: Int32.self, capacity: 8)
        return (Int(count[4]), count[5] != 0)
    }
    /// Patches placed since the last reset, each filled from the air beneath it.
    var patchesPlaced: Int { Int(counters.contents().bindMemory(to: Int32.self, capacity: 8)[6]) }

    /// This level's cells along each axis.
    func cellDims(_ grid: Grid) -> SIMD3<Int> { SIMD3(grid.nx, grid.ny, grid.nz) &* (parentScale * ratio) }

    /// The gas the patches hold: which cells of the grid they refine they cover (as indices into
    /// that grid, the coarse grid's or the parent level's cells numbered through its whole
    /// extent), and the mass, energy, momentum and (with afterburning) fuel and oxygen of their
    /// fluid fine cells, leaving out those in `excluding` (this level's cells, numbered so),
    /// which a level beneath holds.
    func gas(in grid: Grid, excluding: Set<Int> = []) -> (
        covered: Set<Int>, mass: Double, energy: Double, momentum: SIMD3<Double>, species: SIMD2<Double>
    ) {
        let block = Self.patchSize
        let cells = side * side * side
        let volume = Double(pow(grid.cellSize / Float(parentScale * ratio), 3))
        let parentDims = SIMD3(grid.nx, grid.ny, grid.nz) &* parentScale
        let dims = parentDims &* ratio
        let owners = tileOfPatch.contents().bindMemory(to: UInt32.self, capacity: maxPatches)
        let state = (fine[0].contents() + offset(of: fine[0])).bindMemory(
            to: CellState.self, capacity: maxPatches * cells)
        let solid = (fineMask.contents() + offset(of: fineMask)).bindMemory(
            to: UInt8.self, capacity: maxPatches * cells)
        let fuelAndOxygen = fineSpecies[0].contents().bindMemory(
            to: SIMD2<Float>.self, capacity: species ? maxPatches * cells : 0)
        // With cut cells, each fine cell holds its share of air.
        let shares = fineCut?.contents().bindMemory(to: SIMD4<Float>.self, capacity: 2 * maxPatches * cells)
        var covered = Set<Int>()
        var (mass, energy, momentum, carried) = (0.0, 0.0, SIMD3<Double>.zero, SIMD2<Double>.zero)
        for patch in 0..<maxPatches where owners[patch] != .max {
            let tile = Int(owners[patch])
            let origin =
                SIMD3(
                    tile % tileDims.x, (tile / tileDims.x) % tileDims.y, tile / (tileDims.x * tileDims.y))
                &* block
            for n in 0..<cells {
                let local = SIMD3(n % side, (n / side) % side, n / (side * side))
                let cell = origin &+ local / ratio
                guard all(cell .< parentDims) else { continue }
                covered.insert(cell.x + parentDims.x * (cell.y + parentDims.y * cell.z))
                guard solid[patch * cells + n] & 1 == 0 else { continue }
                if !excluding.isEmpty {
                    let at = origin &* ratio &+ local
                    guard !excluding.contains(at.x + dims.x * (at.y + dims.y * at.z)) else { continue }
                }
                let c = state[patch * cells + n]
                let held = volume * Double(shares?[2 * (patch * cells + n)].x ?? 1)
                mass += Double(c.density) * held
                energy += Double(c.energy) * held
                momentum += SIMD3(Double(c.momentumX), Double(c.momentumY), Double(c.momentumZ)) * held
                if species { carried += SIMD2<Double>(fuelAndOxygen[patch * cells + n]) * held }
            }
        }
        return (covered, mass, energy, momentum, carried)
    }

    /// Whether a patch refines any of the parent's cells from `low` through `high`.
    func holdsAny(from low: SIMD3<Int>, through high: SIMD3<Int>) -> Bool {
        let map = (patchOfTile.contents() + offset(of: patchOfTile)).bindMemory(
            to: Int32.self, capacity: tileDims.x * tileDims.y * tileDims.z)
        let first = simd_max(low / Self.patchSize, .zero)
        let last = simd_min(high / Self.patchSize, tileDims &- 1)
        guard all(first .<= last) else { return false }
        for z in first.z...last.z {
            for y in first.y...last.y {
                for x in first.x...last.x where map[x + tileDims.x * (y + tileDims.y * z)] >= 0 {
                    return true
                }
            }
        }
        return false
    }

    /// Reads this level's air cell by cell, by its own cells' coordinates: a cell's state and its
    /// unburnt products (zero without afterburning) where a patch holds it and it is not solid,
    /// else nil. For reading between batches only.
    func fineReader() -> (SIMD3<Int>) -> (state: CellState, products: Float)? {
        let side = side
        let tileDims = tileDims
        let total = side * side * side
        let map = UnsafePointer(
            (patchOfTile.contents() + offset(of: patchOfTile)).bindMemory(
                to: Int32.self, capacity: tileDims.x * tileDims.y * tileDims.z))
        let solid = UnsafePointer(
            (fineMask.contents() + offset(of: fineMask)).bindMemory(
                to: UInt8.self, capacity: maxPatches * total))
        let state = UnsafePointer(
            (fine[0].contents() + offset(of: fine[0])).bindMemory(
                to: CellState.self, capacity: maxPatches * total))
        let carried =
            species
            ? UnsafePointer(
                fineSpecies[0].contents().bindMemory(to: SIMD2<Float>.self, capacity: maxPatches * total))
            : nil
        return { cell in
            let block = cell / side
            guard all(cell .>= 0), all(block .< tileDims) else { return nil }
            let patch = Int(map[block.x + tileDims.x * (block.y + tileDims.y * block.z)])
            guard patch >= 0 else { return nil }
            let local = cell &- block &* side
            let at = patch * total + local.x + side * (local.y + side * local.z)
            guard solid[at] & 1 == 0 else { return nil }
            return (state[at], carried?[at].x ?? 0)
        }
    }

    /// Reads this level's fine cells, by their fine coordinates, for editing between batches: a
    /// cell's state and its fuel and oxygen (zero without afterburning) where a patch holds it and
    /// it is not solid, else nil.
    func fineCells() -> (SIMD3<Int>) -> (state: CellState, species: SIMD2<Float>)? {
        let side = side
        let tileDims = tileDims
        let total = side * side * side
        let map = UnsafePointer(
            (patchOfTile.contents() + offset(of: patchOfTile)).bindMemory(
                to: Int32.self, capacity: tileDims.x * tileDims.y * tileDims.z))
        let solid = UnsafePointer(
            (fineMask.contents() + offset(of: fineMask)).bindMemory(
                to: UInt8.self, capacity: maxPatches * total))
        let state = UnsafePointer(
            (fine[0].contents() + offset(of: fine[0])).bindMemory(
                to: CellState.self, capacity: maxPatches * total))
        let carried =
            species
            ? UnsafePointer(
                fineSpecies[0].contents().bindMemory(to: SIMD2<Float>.self, capacity: maxPatches * total))
            : nil
        return { cell in
            let block = cell / side
            guard all(cell .>= 0), all(block .< tileDims) else { return nil }
            let patch = Int(map[block.x + tileDims.x * (block.y + tileDims.y * block.z)])
            guard patch >= 0 else { return nil }
            let local = cell &- block &* side
            let at = patch * total + local.x + side * (local.y + side * local.z)
            guard solid[at] & 1 == 0 else { return nil }
            return (state[at], carried?[at] ?? .zero)
        }
    }

    /// Adds `added` (by coarse cell index) to the impulse the patches holding those cells count
    /// theirs from: impulse laid on the coarse cells during the run, which the patches' fine cells
    /// did not see.
    func addImpulseBase(_ added: [Int: Float], grid: Grid) {
        guard !added.isEmpty else { return }
        let tiles = tileOfPatch.contents().bindMemory(to: UInt32.self, capacity: maxPatches)
        let size = Self.patchSize
        let perPatch = size * size * size
        let base = impulseBase.contents().bindMemory(to: Float.self, capacity: maxPatches * perPatch)
        for patch in 0..<maxPatches where tiles[patch] != UInt32.max {
            let tile = Int(tiles[patch])
            let origin =
                SIMD3(tile % tileDims.x, (tile / tileDims.x) % tileDims.y, tile / (tileDims.x * tileDims.y))
                &* size
            for z in 0..<size {
                for y in 0..<size {
                    for x in 0..<size {
                        let cell = origin &+ SIMD3(x, y, z)
                        guard cell.x < grid.nx, cell.y < grid.ny, cell.z < grid.nz,
                            let more = added[grid.index(cell.x, cell.y, cell.z)]
                        else { continue }
                        base[patch * perPatch + x + size * (y + size * z)] += more
                    }
                }
            }
        }
    }

    /// Sets fine cells, by their fine coordinates, where a patch holds them, with their fuel and
    /// oxygen where afterburning is on.
    func setFine(_ cells: [SIMD3<Int>: (state: CellState, species: SIMD2<Float>)]) {
        let total = side * side * side
        let map = (patchOfTile.contents() + offset(of: patchOfTile)).bindMemory(
            to: Int32.self, capacity: tileDims.x * tileDims.y * tileDims.z)
        let state = (fine[0].contents() + offset(of: fine[0])).bindMemory(
            to: CellState.self, capacity: maxPatches * total)
        let carried = fineSpecies[0].contents().bindMemory(
            to: SIMD2<Float>.self, capacity: species ? maxPatches * total : 0)
        for (fine, cell) in cells {
            let block = fine / side
            guard all(block .< tileDims) else { continue }
            let patch = Int(map[block.x + tileDims.x * (block.y + tileDims.y * block.z)])
            guard patch >= 0 else { continue }
            let local = fine &- block &* side
            let at = patch * total + local.x + side * (local.y + side * local.z)
            state[at] = cell.state
            if species { carried[at] = cell.species }
        }
    }

    /// Sets the rigid blocks whose outline the fine cells follow; nil to follow the coarse cells'.
    func setBoxes(_ list: [Box]?) {
        let list = list ?? []
        let corners = list.flatMap { [SIMD4($0.min, 0), SIMD4($0.max, 0)] }
        if corners.count * 16 > boxes.length,
            let bigger = device.makeBuffer(length: corners.count * 16, options: .storageModeShared)
        {
            boxes = bigger
        }
        corners.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress {
                boxes.contents().copyMemory(from: base, byteCount: bytes.count)
            }
        }
        // Each block's list: the boxes overlapping it widened by two of this level's cells, more
        // than the fine cell above the block's top that the fill also asks about. Whether a point
        // lies in any box is the same asked of every box or only of these.
        let tiles = tileDims.x * tileDims.y * tileDims.z
        var lists = [[UInt32]](repeating: [], count: list.isEmpty ? 0 : tiles)
        let pad = 2 * blockSize / Float(Self.patchSize * ratio)
        for (n, box) in list.enumerated() {
            let low = simd_max(SIMD3<Int>(((box.min - pad) / blockSize).rounded(.down)), .zero)
            let high = simd_min(SIMD3<Int>(((box.max + pad) / blockSize).rounded(.down)), tileDims &- 1)
            guard all(low .<= high) else { continue }
            for z in low.z...high.z {
                for y in low.y...high.y {
                    for x in low.x...high.x { lists[x + tileDims.x * (y + tileDims.y * z)].append(UInt32(n)) }
                }
            }
        }
        var index: [UInt32] = [UInt32(list.count)]
        if !list.isEmpty {
            index.reserveCapacity(2 + tiles + lists.reduce(0) { $0 + $1.count })
            var start: UInt32 = 0
            for entries in lists {
                index.append(start)
                start += UInt32(entries.count)
            }
            index.append(start)
            for entries in lists { index += entries }
        }
        if index.count * 4 > boxIndex.length,
            let bigger = device.makeBuffer(length: index.count * 4, options: .storageModeShared)
        {
            boxIndex = bigger
        }
        index.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress {
                boxIndex.contents().copyMemory(from: base, byteCount: bytes.count)
            }
        }
    }

    /// Every fine cell the patches hold, by its coordinates at this level, and whether its outline
    /// marks it rigid. For tests.
    func rigidOutline(_ grid: Grid) -> [(cell: SIMD3<Int>, rigid: Bool)] {
        let cells = side * side * side
        let dims = cellDims(grid)
        let owners = tileOfPatch.contents().bindMemory(to: UInt32.self, capacity: maxPatches)
        let mask = (fineMask.contents() + offset(of: fineMask)).bindMemory(
            to: UInt8.self, capacity: maxPatches * cells)
        var outline: [(cell: SIMD3<Int>, rigid: Bool)] = []
        for patch in 0..<maxPatches where owners[patch] != .max {
            let tile = Int(owners[patch])
            let origin =
                SIMD3(tile % tileDims.x, (tile / tileDims.x) % tileDims.y, tile / (tileDims.x * tileDims.y))
                &* side
            for n in 0..<cells {
                let cell = origin &+ SIMD3(n % side, (n / side) % side, n / (side * side))
                guard all(cell .< dims) else { continue }
                outline.append((cell, mask[patch * cells + n] & 2 != 0))
            }
        }
        return outline
    }

    /// Sets the terrain whose outline the fine cells follow, besides the blocks'; nil for none.
    func setTerrain(_ terrain: Terrain?) {
        guard let terrain else {
            terrainUniforms = TerrainUniforms()
            return
        }
        if terrain.heights.count * 4 > terrainHeights.length,
            let bigger = device.makeBuffer(length: terrain.heights.count * 4, options: .storageModeShared)
        {
            terrainHeights = bigger
        }
        terrain.heights.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress {
                terrainHeights.contents().copyMemory(from: base, byteCount: bytes.count)
            }
        }
        terrainUniforms = TerrainUniforms(
            origin: terrain.origin, spacing: terrain.spacing, columns: UInt32(terrain.columns),
            rows: UInt32(terrain.rows), enabled: 1, cutSamples: UInt32(coarseCut?.geometry.samples ?? 8))
    }

    /// The pool slots of the patches in use over any of these ranges of blocks (block coordinates,
    /// inclusive), in the blocks' order (x fastest): not the pool's, which the GPU's placing of
    /// patches decides, so that what is summed over them comes out the same every run.
    func patches(inBlocks ranges: [(low: SIMD3<Int>, high: SIMD3<Int>)]) -> [Int] {
        let map = (patchOfTile.contents() + offset(of: patchOfTile)).bindMemory(
            to: Int32.self, capacity: tileDims.x * tileDims.y * tileDims.z)
        var found = Set<Int>()
        for range in ranges {
            let low = simd_max(range.low, .zero)
            let high = simd_min(range.high, tileDims &- 1)
            guard all(low .<= high) else { continue }
            for z in low.z...high.z {
                for y in low.y...high.y {
                    for x in low.x...high.x {
                        let tile = x + tileDims.x * (y + tileDims.y * z)
                        if map[tile] >= 0 { found.insert(tile) }
                    }
                }
            }
        }
        return found.sorted().map { Int(map[$0]) }
    }

    /// Whether any of these patches has a fine cell of an experimental box.
    func hasBoxCells(in patches: [Int]) -> Bool {
        let mask = fineMask.contents().bindMemory(to: UInt8.self, capacity: maxPatches * side * side * side)
        let cells = side * side * side
        for patch in patches {
            for n in 0..<cells where mask[patch * cells + n] & 8 != 0 { return true }
        }
        return false
    }

    /// Makes sure the fine impulses can be recorded. Only cells beside a box's record, and
    /// `takeBoxFaceImpulses` zeroes what it reads, so the rest stay zero.
    func clearBoxImpulse() throws {
        let cells = side * side * side
        let length = maxPatches * cells * 6 * MemoryLayout<Float>.stride
        if experimentalBoxImpulse == nil {
            experimentalBoxImpulse = device.makeBuffer(length: length, options: .storageModeShared)
            if let buffer = experimentalBoxImpulse { memset(buffer.contents(), 0, buffer.length) }
        }
        guard experimentalBoxImpulse != nil else {
            throw BlastError.allocationFailed("fine rigid-box impulses")
        }
    }

    /// Passes each fine face's impulse recorded on `patches` (which must hold every patch beside
    /// a box) to `face`, with the box `owner` gives it, the fine cell's coordinates and the face's
    /// axis and side (0 low, 1 high), and zeroes them. `owner` is asked side by side over the
    /// patches; `face` is called in turn, in the patches' order and each one's cells'.
    func takeBoxFaceImpulses(
        in patches: [Int], owner: (SIMD3<Int>, Int, Int) -> Int,
        face: (Int, SIMD3<Int>, Int, Int, Double) -> Void
    ) {
        guard let buffer = experimentalBoxImpulse else { return }
        let values = buffer.contents().bindMemory(to: Float.self, capacity: buffer.length / 4)
        let owners = tileOfPatch.contents().bindMemory(to: UInt32.self, capacity: maxPatches)
        let cells = side * side * side
        let side = side
        let tileDims = tileDims
        var faces = [[(box: Int, cell: SIMD3<Int>, axis: Int, side: Int, impulse: Double)]](
            repeating: [], count: patches.count)
        faces.withUnsafeMutableBufferPointer { faces in
            concurrently(iterations: patches.count) { p in
                let patch = patches[p]
                let tile = Int(owners[patch])
                let origin =
                    SIMD3(
                        tile % tileDims.x, (tile / tileDims.x) % tileDims.y, tile / (tileDims.x * tileDims.y))
                    &* side
                for n in 0..<cells {
                    let base = 6 * (patch * cells + n)
                    for slot in 0..<6 where values[base + slot] != 0 {
                        let cell = origin &+ SIMD3(n % side, (n / side) % side, n / (side * side))
                        faces[p].append(
                            (
                                owner(cell, slot / 2, slot % 2), cell, slot / 2, slot % 2,
                                Double(values[base + slot])
                            ))
                    }
                }
                memset(buffer.contents() + patch * cells * 6 * MemoryLayout<Float>.stride, 0, cells * 6 * 4)
            }
        }
        for list in faces {
            for entry in list { face(entry.box, entry.cell, entry.axis, entry.side, entry.impulse) }
        }
    }

    /// Takes each placed patch's record of its coarse cells' impulse before it (what the coarse
    /// cells' impulse is rebuilt from) afresh from `impulse`, the parent's field: for a first level
    /// whose coarse impulse was laid down after its patches were placed, as a charge mapped from
    /// one dimension lays its passage's.
    func reseedImpulseBase(from impulse: UnsafeBufferPointer<Float>, grid: Grid) {
        let tiles = tileOfPatch.contents().bindMemory(to: UInt32.self, capacity: maxPatches)
        let size = Self.patchSize
        let perPatch = size * size * size
        let base = impulseBase.contents().bindMemory(to: Float.self, capacity: maxPatches * perPatch)
        for patch in 0..<maxPatches where tiles[patch] != UInt32.max {
            let tile = Int(tiles[patch])
            let origin =
                SIMD3(tile % tileDims.x, (tile / tileDims.x) % tileDims.y, tile / (tileDims.x * tileDims.y))
                &* size
            for z in 0..<size {
                for y in 0..<size {
                    for x in 0..<size {
                        let cell = origin &+ SIMD3(x, y, z)
                        guard cell.x < grid.nx, cell.y < grid.ny, cell.z < grid.nz else { continue }
                        base[patch * perPatch + x + size * (y + size * z)] =
                            impulse[grid.index(cell.x, cell.y, cell.z)]
                    }
                }
            }
        }
    }

    func reset() {
        let tiles = tileDims.x * tileDims.y * tileDims.z
        let cells = maxPatches * side * side * side
        memset(patchOfTile.contents() + offset(of: patchOfTile), 0xFF, tiles * 4)
        memset(tileOfPatch.contents(), 0xFF, maxPatches * 4)
        let stack = freeStack.contents().bindMemory(to: UInt32.self, capacity: maxPatches)
        for n in 0..<maxPatches { stack[n] = UInt32(maxPatches - 1 - n) }
        let count = counters.contents().bindMemory(to: Int32.self, capacity: 8)
        (count[0], count[1], count[2], count[3]) = (Int32(maxPatches), 0, 0, 0)
        (count[4], count[5], count[6]) = (0, 0, 0)
        memset(arguments.contents(), 0, arguments.length)
        memset(wanted.contents(), 0, wanted.length)
        memset(fineFlux.contents(), 0, fineFlux.length)
        memset(fineSpeciesFlux.contents(), 0, fineSpeciesFlux.length)
        memset(fineImpulse.contents(), 0, fineImpulse.length)
        memset(fineOccupancy.contents() + offset(of: fineOccupancy), 0, cells * 16)
        if let combinedBodyOccupancy {
            memset(combinedBodyOccupancy.contents(), 0, combinedBodyOccupancy.length)
        }
        memset(pinned.contents(), 0, pinned.length)
        for buffer in [fineCut, fineDefects, patchCut, passedUp].compactMap({ $0 }) {
            memset(buffer.contents(), 0, buffer.length)
        }
    }

    /// Patches in use after the last regrid, read while the GPU is idle.
    var livePatches: Int { maxPatches - Int(counters.contents().load(as: Int32.self)) }

    /// Makes the pool hold `patches` (no more than `capacity`) while the GPU is idle. Every patch
    /// keeps its slot and its cells, the new slots are as a pool made that size holds slots never
    /// used, and they go to the bottom of the free stack in the order such a pool would hand them
    /// out, so that a run whose pool grows ahead of the patches it uses steps exactly as one
    /// made at full size. A first level holding its child's part of the shared buffers moves that
    /// part after its own (`child`, in cells before and after the child grows): call `adopt()` on
    /// the child after. Each buffer is swapped for its larger one before the next is made, so
    /// that only one is held twice over at a time.
    func grow(to patches: Int, child: (old: Int, new: Int) = (0, 0)) throws {
        let patches = min(max(patches, maxPatches), capacity)
        guard patches > maxPatches || child.new != child.old else { return }
        let old = maxPatches
        let added = patches - old
        let cells = side * side * side
        let state = MemoryLayout<CellState>.stride
        func regrow(_ buffer: MTLBuffer, _ perPatch: Int, fill: Int32 = 0) throws -> MTLBuffer {
            guard perPatch > 0, added > 0 else { return buffer }
            let new = try makeBuffer(patches * perPatch, buffer.label ?? "refinement")
            memcpy(new.contents(), buffer.contents(), old * perPatch)
            memset(new.contents() + old * perPatch, fill, added * perPatch)
            return new
        }
        // This level's own buffers first: a failure part way leaves some larger than the pool, which
        // does no harm, as the free stack (last) still holds only the slots there were. The shared
        // buffers are swapped only after all of them: swapped first, a failure after (which the
        // solver passes over, keeping the pools as they are) left this level's in the new and its
        // child's in the old, as the child never adopted them.
        if added > 0 {
            tileOfPatch = try regrow(tileOfPatch, 4, fill: 0xFF)
            patchList = try regrow(patchList, 4)
            newPatches = try regrow(newPatches, 4)
            pinned = try regrow(pinned, 4)
            let block = Self.patchSize * Self.patchSize * Self.patchSize
            seenMask = try regrow(seenMask, block)
            fineWall = try regrow(fineWall, cells * 12)
            halo = try regrow(halo, 512 * state)
            ghosts = try regrow(ghosts, 4 * side * side * state)
            ghostKinds = try regrow(ghostKinds, 4 * side * side)
            fineFlux = try regrow(fineFlux, 6 * side * side * 5 * 4)
            fineImpulse = try regrow(fineImpulse, cells * 4)
            impulseBase = try regrow(impulseBase, block * 4)
            coarseFlux = try regrow(coarseFlux, 6 * Self.patchSize * Self.patchSize * 5 * 4)
            fine[1] = try regrow(fine[1], cells * state)
            let pair = species ? 8 : 0
            fineSpecies[0] = try regrow(fineSpecies[0], cells * pair)
            fineSpecies[1] = try regrow(fineSpecies[1], cells * pair)
            ghostSpecies = try regrow(ghostSpecies, 4 * side * side * pair)
            fineSpeciesFlux = try regrow(fineSpeciesFlux, 6 * side * side * pair)
            coarseSpeciesFlux = try regrow(coarseSpeciesFlux, 6 * Self.patchSize * Self.patchSize * pair)
            if let buffer = fineCut { fineCut = try regrow(buffer, cells * 32) }
            if let buffer = fineDefects { fineDefects = try regrow(buffer, cells * 32) }
            if let buffer = patchCut { patchCut = try regrow(buffer, 4) }
            if let buffer = passedUp { passedUp = try regrow(buffer, side * side * 32) }
            if let buffer = combinedBodyOccupancy { combinedBodyOccupancy = try regrow(buffer, cells * 16) }
            if let buffer = experimentalBoxImpulse {
                experimentalBoxImpulse = try regrow(buffer, cells * 6 * 4)
            }
        }
        // The last allocations, the free stack and the shared buffers, before anything that holds
        // the pool's size (the shared buffers, the stack, the counters) changes.
        let stackBuffer = added > 0 ? try makeBuffer(patches * 4, "free patches") : nil
        if parent == nil {
            // The shared buffers: this level's cells, then its child's. All three are made before
            // any is swapped, so that the child's part never lies in two places.
            func regrowShared(_ buffer: MTLBuffer, _ perCell: Int) throws -> (MTLBuffer, MTLBuffer, Int) {
                (
                    buffer,
                    try makeBuffer((patches * cells + child.new) * perCell, buffer.label ?? "refinement"),
                    perCell
                )
            }
            let shared = [
                try regrowShared(fineMask, 1), try regrowShared(fineOccupancy, 16),
                try regrowShared(fine[0], state),
            ]
            for (buffer, new, perCell) in shared {
                memcpy(new.contents(), buffer.contents(), old * cells * perCell)
                memset(new.contents() + old * cells * perCell, 0, added * cells * perCell)
                memcpy(
                    new.contents() + patches * cells * perCell, buffer.contents() + old * cells * perCell,
                    min(child.old, child.new) * perCell)
                if child.new > child.old {
                    memset(
                        new.contents() + (patches * cells + child.old) * perCell, 0,
                        (child.new - child.old) * perCell)
                }
            }
            (fineMask, fineOccupancy, fine[0]) = (shared[0].1, shared[1].1, shared[2].1)
        }
        if let stackBuffer {
            let stack = stackBuffer.contents().bindMemory(to: UInt32.self, capacity: patches)
            for n in 0..<added { stack[n] = UInt32(patches - 1 - n) }
            memcpy(stackBuffer.contents() + added * 4, freeStack.contents(), old * 4)
            freeStack = stackBuffer
            let count = counters.contents().bindMemory(to: Int32.self, capacity: 8)
            count[0] += Int32(added)
            count[3] += Int32(added)
        }
        maxPatches = patches
    }

    /// Takes up the parent's shared buffers, and this level's place in them, after the parent
    /// grew (`grow`).
    func adopt() {
        guard let parent else { return }
        fineMask = parent.fineMask
        fineOccupancy = parent.fineOccupancy
        fine[0] = parent.fine[0]
        cellOffset = parent.maxPatches * parent.side * parent.side * parent.side
    }

    private func makeBuffer(_ length: Int, _ label: String) throws -> MTLBuffer {
        if let left = allocationsBeforeFailure {
            allocationsBeforeFailure = left > 1 ? left - 1 : nil
            if left <= 1 {
                throw BlastError.allocationFailed("\(label) (\(length) bytes, as the test asked)")
            }
        }
        guard let buffer = device.makeBuffer(length: max(length, 16), options: .storageModeShared) else {
            throw BlastError.allocationFailed("\(label) (\(length) bytes)")
        }
        buffer.label = label
        return buffer
    }

    private func group(_ pipeline: MTLComputePipelineState, _ width: Int) -> MTLSize {
        MTLSize(width: min(width, pipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1)
    }

    private func setUniforms(
        _ encoder: MTLComputeCommandEncoder, _ uniforms: inout SolverUniforms, index: Int
    ) {
        encoder.setBytes(&uniforms, length: MemoryLayout<SolverUniforms>.stride, index: index)
    }

    /// Step 1: the parent's cells around each patch, at the start of the parent's step.
    func encodeSaveHalo(
        _ encoder: MTLComputeCommandEncoder, parent: ParentView, uniforms: SolverUniforms, control: MTLBuffer,
        dispatches: (MTLBuffer, Int)? = nil
    ) {
        var encoder = encoder
        let dispatches = dispatches ?? (arguments, 0)
        var uniforms = uniforms
        stage("halo", &encoder)
        encoder.setComputePipelineState(haloPipeline)
        set(encoder, parent.state, 0)
        encoder.setBuffer(halo, offset: 0, index: 1)
        setUniforms(encoder, &uniforms, index: 2)
        encoder.setBuffer(tileOfPatch, offset: 0, index: 3)
        encoder.setBuffer(patchList, offset: 0, index: 4)
        encoder.setBuffer(control, offset: 0, index: 5)
        set(encoder, parent.patches, 6)
        encoder.dispatchThreadgroups(
            indirectBuffer: dispatches.0, indirectBufferOffset: dispatches.1 + 12,
            threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
    }

    /// Where the dispatches of substep `substep` (in substep `parentSubstep` of the parent's
    /// step, for a level beneath another) are found: `arguments`, or with the levels' own steps
    /// that substep's copy, empty where it is not taken.
    private func substepDispatches(_ substep: Int, parentSubstep: Int?, ownSteps: Bool) -> (MTLBuffer, Int) {
        guard ownSteps else { return (arguments, 0) }
        return (substepArguments, ((parentSubstep ?? 0) * ratio + substep) * 32 * 4)
    }

    /// With the levels' own steps, once per step after `prepareStep`: each level's substeps and
    /// their length, from its fastest wave (see `refineLevelSteps`). For the first level, with
    /// `child` the second.
    func encodeLevelSteps(
        _ encoder: MTLComputeCommandEncoder, control: MTLBuffer, maxSpeed: MTLBuffer,
        uniforms: SolverUniforms,
        child: AirRefinement?
    ) {
        var uniforms = uniforms
        var levels: UInt32 = child == nil ? 1 : 2
        encoder.setComputePipelineState(levelStepsPipeline)
        encoder.setBuffer(control, offset: 0, index: 0)
        encoder.setBuffer(maxSpeed, offset: 0, index: 1)
        setUniforms(encoder, &uniforms, index: 2)
        encoder.setBuffer(arguments, offset: 0, index: 3)
        encoder.setBuffer(substepArguments, offset: 0, index: 4)
        encoder.setBuffer(keepArguments, offset: 0, index: 5)
        encoder.setBuffer(child?.arguments ?? arguments, offset: 0, index: 6)
        encoder.setBuffer(child?.substepArguments ?? substepArguments, offset: 0, index: 7)
        encoder.setBuffer(child?.keepArguments ?? keepArguments, offset: 0, index: 8)
        encoder.setBytes(&levels, length: 4, index: 9)
        encoder.dispatchThreads(
            MTLSize(width: 1, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
    }

    /// The fine sweep compiled for `model`, made the first time it is used; the general one if
    /// that fails.
    /// `base`, kernel `name`, or with gravity compiled in while the air has gravity (`model` for the
    /// gas model's specialisation, if any).
    private func withGravity(_ base: MTLComputePipelineState, _ name: String, model: AirModel? = nil)
        -> MTLComputePipelineState
    {
        let gravity = gravityTable != nil
        let mixing = viscosity != nil && name == "refineSweep"
        let limit = burnLimit && name == "refineSweep"
        let burnMixed = burnMixing && mixing
        let cut = cutTerrain
        guard gravity || mixing || limit || cut else { return base }
        let key =
            "\(name) \(model.map { "\($0.rawValue)" } ?? "-") \(gravity) \(mixing) \(limit) \(cut)"
            + (burnMixed ? " burnMixing" : "")
        if let pipeline = gravityPipelines[key] { return pipeline }
        var constants = MTLFunctionConstantValues()
        if var value = model?.rawValue {
            constants.setConstantValue(&value, type: .uint, index: ShaderLibrary.airModelConstant)
        }
        if gravity { constants = ShaderLibrary.withGravity(constants) }
        if mixing { constants = ShaderLibrary.withMixing(constants) }
        if limit { constants = ShaderLibrary.withBurnLimit(constants) }
        if burnMixed { constants = ShaderLibrary.withBurnMixing(constants) }
        if cut { constants = ShaderLibrary.withCutCells(constants) }
        guard let pipeline = try? ShaderLibrary.pipeline(name, in: library, constants: constants) else {
            return base
        }
        gravityPipelines[key] = pipeline
        return pipeline
    }

    private func sweepPipeline(for model: AirModel?) -> MTLComputePipelineState {
        guard let model else { return withGravity(sweepPipeline, "refineSweep") }
        if gravityTable != nil || viscosity != nil || burnLimit || cutTerrain {
            return withGravity(sweepPipeline, "refineSweep", model: model)
        }
        if let pipeline = sweepPipelines[model] { return pipeline }
        let constants = MTLFunctionConstantValues()
        var value = model.rawValue
        constants.setConstantValue(&value, type: .uint, index: ShaderLibrary.airModelConstant)
        guard let pipeline = try? ShaderLibrary.pipeline("refineSweep", in: library, constants: constants)
        else {
            return sweepPipeline
        }
        sweepPipelines[model] = pipeline
        return pipeline
    }

    /// A level beneath this one, as this level's substeps advance it: the level and its uniforms.
    typealias Child = (level: AirRefinement, uniforms: SolverUniforms)

    /// Step 3: r substeps of every patch, each sweeping `axes` in order, each sweep after filling
    /// the patches' ghosts along its axis. With `child`, that level takes its own r substeps
    /// within each of these (steps 1 to 5 for it, this level standing for the coarse grid).
    func encodeSubsteps(
        _ encoder: MTLComputeCommandEncoder, axes: [Int], parent: ParentView, peak: MTLBuffer,
        control: MTLBuffer, maxSpeed: MTLBuffer, uniforms: SolverUniforms, child: Child? = nil,
        parentSubstep: Int? = nil
    ) {
        var encoder = encoder
        stage("ghosts", &encoder)
        var uniforms = uniforms
        let ownSteps = uniforms.ownSteps != 0
        let sweepPipeline = sweepPipeline(for: AirModel(rawValue: uniforms.airModel))
        var depth = 8
        while depth > 1 && 64 * depth > sweepPipeline.maxTotalThreadsPerThreadgroup { depth /= 2 }
        var sweep = 0
        for substep in 0..<ratio {
            uniforms.refineSubstep = UInt32(substep)
            uniforms.refineAlpha = Float(substep) / Float(ratio)
            // The order of the sweeps alternates from substep to substep, starting with the coarse
            // step's, so that the splitting stays second order.
            let order = substep.isMultiple(of: 2) ? axes : axes.reversed()
            let dispatches = substepDispatches(substep, parentSubstep: parentSubstep, ownSteps: ownSteps)
            // The second level's work in this substep, empty where this substep is not taken.
            let childDispatches = child.map {
                $0.level.substepDispatches(0, parentSubstep: substep, ownSteps: ownSteps)
            }
            if let child {
                child.level.encodeSaveHalo(
                    encoder, parent: view(current: sweep % 2), uniforms: child.uniforms, control: control,
                    dispatches: childDispatches)
            }
            for (n, axis) in order.enumerated() {
                uniforms.axis = UInt32(axis)
                uniforms.finalSweep = n == order.count - 1 ? 1 : 0
                let source = fine[sweep % 2]
                let sourceOffset = sweep % 2 == 0 ? offset(of: fine[0]) : 0

                stage("ghosts", &encoder)
                encoder.setComputePipelineState(withGravity(ghostPipeline, "refineGhosts"))
                encoder.setBuffer(source, offset: sourceOffset, index: 0)
                encoder.setBuffer(ghosts, offset: 0, index: 1)
                encoder.setBuffer(ghostKinds, offset: 0, index: 2)
                set(encoder, parent.mask, 3)
                setUniforms(encoder, &uniforms, index: 4)
                bind(encoder, patchOfTile, 5)
                encoder.setBuffer(tileOfPatch, offset: 0, index: 6)
                encoder.setBuffer(patchList, offset: 0, index: 7)
                set(encoder, parent.state, 8)
                encoder.setBuffer(halo, offset: 0, index: 9)
                set(encoder, parent.wallVelocity, 10)
                bind(encoder, fineMask, 11)
                encoder.setBuffer(fineWall, offset: 0, index: 12)
                encoder.setBuffer(fineFlux, offset: 0, index: 13)
                encoder.setBuffer(control, offset: 0, index: 14)
                encoder.setBuffer(fineSpecies[sweep % 2], offset: 0, index: 15)
                encoder.setBuffer(ghostSpecies, offset: 0, index: 16)
                set(encoder, parent.species, 17)
                set(encoder, parent.patches, 18)
                // Not read without gravity.
                encoder.setBuffer(parentGravityTable ?? ghosts, offset: 0, index: 19)
                encoder.setBuffer(gravityTable ?? ghosts, offset: 0, index: 20)
                // Not read without cut cells.
                var terrain = terrainUniforms
                encoder.setBuffer(terrainHeights, offset: 0, index: 21)
                encoder.setBytes(&terrain, length: MemoryLayout<TerrainUniforms>.stride, index: 22)
                encoder.dispatchThreadgroups(
                    indirectBuffer: dispatches.0, indirectBufferOffset: dispatches.1 + 60,
                    threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))

                stage("sweeps", &encoder)
                encoder.setComputePipelineState(sweepPipeline)
                encoder.setBuffer(source, offset: sourceOffset, index: 0)
                let destination = fine[1 - sweep % 2]
                encoder.setBuffer(
                    destination, offset: destination === fine[0] ? offset(of: fine[0]) : 0, index: 1)
                set(encoder, parent.mask, 2)
                encoder.setBuffer(peak, offset: 0, index: 3)
                encoder.setBuffer(control, offset: 0, index: 4)
                encoder.setBuffer(maxSpeed, offset: 0, index: 5)
                setUniforms(encoder, &uniforms, index: 6)
                encoder.setBuffer(ghosts, offset: 0, index: 7)
                encoder.setBuffer(ghostKinds, offset: 0, index: 8)
                encoder.setBuffer(tileOfPatch, offset: 0, index: 9)
                encoder.setBuffer(patchList, offset: 0, index: 10)
                encoder.setBuffer(fineFlux, offset: 0, index: 12)
                encoder.setBuffer(fineImpulse, offset: 0, index: 13)
                bind(encoder, fineMask, 14)
                encoder.setBuffer(fineWall, offset: 0, index: 15)
                encoder.setBuffer(fineSpecies[sweep % 2], offset: 0, index: 16)
                encoder.setBuffer(fineSpecies[1 - sweep % 2], offset: 0, index: 17)
                encoder.setBuffer(ghostSpecies, offset: 0, index: 18)
                encoder.setBuffer(fineSpeciesFlux, offset: 0, index: 19)
                bind(encoder, patchOfTile, 20)
                encoder.setBuffer(experimentalBoxImpulse ?? fineImpulse, offset: 0, index: 21)
                if let child {
                    child.level.bind(encoder, child.level.patchOfTile, 22)
                    encoder.setBuffer(child.level.coarseFlux, offset: 0, index: 23)
                    encoder.setBuffer(child.level.coarseSpeciesFlux, offset: 0, index: 24)
                } else {
                    // Not read without a level beneath.
                    encoder.setBuffer(fineFlux, offset: 0, index: 22)
                    encoder.setBuffer(fineFlux, offset: 0, index: 23)
                    encoder.setBuffer(fineFlux, offset: 0, index: 24)
                }
                // Not read without gravity.
                encoder.setBuffer(gravityTable ?? fineFlux, offset: 0, index: 25)
                encoder.setBuffer(viscosity ?? fineFlux, offset: 0, index: 26)
                // Not read without cut cells.
                encoder.setBuffer(fineCut ?? fineFlux, offset: 0, index: 27)
                encoder.setBuffer(fineDefects ?? fineFlux, offset: 0, index: 28)
                encoder.setBuffer(terrainHeights, offset: 0, index: 29)
                encoder.setBytes(&terrain, length: MemoryLayout<TerrainUniforms>.stride, index: 30)
                encoder.dispatchThreadgroups(
                    indirectBuffer: dispatches.0, indirectBufferOffset: dispatches.1,
                    threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: depth))
                sweep += 1
                if uniforms.finalSweep != 0, child == nil {
                    encodeCutRedistribution(
                        encoder, sweep: sweep, uniforms: uniforms, control: control, maxSpeed: maxSpeed,
                        parent: parent)
                }
            }
            if let child {
                let now = view(current: sweep % 2)
                child.level.encodeSubsteps(
                    encoder, axes: order, parent: now, peak: peak, control: control, maxSpeed: maxSpeed,
                    uniforms: child.uniforms, parentSubstep: substep)
                child.level.encodeRefluxAndRestrict(
                    encoder, axes: order, parent: now, control: control, uniforms: child.uniforms,
                    dispatches: childDispatches)
                if cutTerrain {
                    // This level's differences, after the level beneath has refluxed into them; then
                    // what reached cells it covers is carried down to it.
                    encodeCutRedistribution(
                        encoder, sweep: sweep, uniforms: uniforms, control: control, maxSpeed: maxSpeed,
                        parent: parent,
                        child: child.level)
                    child.level.encodeSync(encoder, parent: now, control: control, uniforms: child.uniforms)
                }
            }
        }
        precondition(sweep.isMultiple(of: 2), "A coarse step must take an even number of fine sweeps")
        if ownSteps {
            // After an odd number of sweeps taken, the state is in the second buffer.
            stage("sweeps", &encoder)
            encoder.setComputePipelineState(keepPipeline)
            bind(encoder, fine[0], 0)
            encoder.setBuffer(fine[1], offset: 0, index: 1)
            encoder.setBuffer(fineSpecies[0], offset: 0, index: 2)
            encoder.setBuffer(fineSpecies[1], offset: 0, index: 3)
            bind(encoder, fineMask, 4)
            encoder.setBuffer(patchList, offset: 0, index: 5)
            setUniforms(encoder, &uniforms, index: 6)
            encoder.dispatchThreadgroups(
                indirectBuffer: keepArguments, indirectBufferOffset: (parentSubstep ?? 0) * 12,
                threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        }
    }

    /// With cut cells, after a substep's final sweep (`sweep` sweeps done): the fine cut cells'
    /// differences shared out up their columns (`refineRedistributeCut`).
    private func encodeCutRedistribution(
        _ encoder: MTLComputeCommandEncoder, sweep: Int, uniforms: SolverUniforms, control: MTLBuffer,
        maxSpeed: MTLBuffer, parent: ParentView, child: AirRefinement? = nil
    ) {
        guard cutTerrain, let pipeline = redistributeCutPipeline, let fineCut, let fineDefects, let patchCut,
            let passedUp
        else { return }
        var encoder = encoder
        stage("cut cells", &encoder)
        var uniforms = uniforms
        encoder.setComputePipelineState(pipeline)
        let state = fine[sweep % 2]
        encoder.setBuffer(state, offset: state === fine[0] ? offset(of: fine[0]) : 0, index: 0)
        encoder.setBuffer(fineSpecies[sweep % 2], offset: 0, index: 1)
        encoder.setBuffer(fineCut, offset: 0, index: 2)
        encoder.setBuffer(fineDefects, offset: 0, index: 3)
        setUniforms(encoder, &uniforms, index: 4)
        bind(encoder, patchOfTile, 5)
        encoder.setBuffer(tileOfPatch, offset: 0, index: 6)
        encoder.setBuffer(patchList, offset: 0, index: 7)
        encoder.setBuffer(patchCut, offset: 0, index: 8)
        encoder.setBuffer(passedUp, offset: 0, index: 9)
        encoder.setBuffer(control, offset: 0, index: 10)
        set(encoder, parent.mask, 11)
        bind(encoder, fineMask, 12)
        encoder.setBuffer(maxSpeed, offset: 0, index: 13)
        // Not read without gravity.
        encoder.setBuffer(gravityTable ?? fineCut, offset: 0, index: 14)
        set(encoder, parent.patches, 15)
        // Not read without a level beneath.
        if let child {
            child.bind(encoder, child.patchOfTile, 16)
        } else {
            encoder.setBuffer(fineCut, offset: 0, index: 16)
        }
        encoder.dispatchThreadgroups(
            indirectBuffer: arguments, indirectBufferOffset: 60,
            threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
    }

    /// Steps 4 and 5: refluxing along each of `axes`, then the parent's cells under the patches.
    /// With cut cells, first what the stacks of patches passed up out of their tops goes to the
    /// coarse cells above them, and `beforeRestricting` runs between refluxing and restriction
    /// (the coarse grid's cut cells shared out, `redistributeCutDefects`).
    func encodeRefluxAndRestrict(
        _ encoder: MTLComputeCommandEncoder, axes: [Int], parent: ParentView, control: MTLBuffer,
        uniforms: SolverUniforms, beforeRestricting: ((MTLComputeCommandEncoder) -> Void)? = nil,
        dispatches: (MTLBuffer, Int)? = nil
    ) {
        var encoder = encoder
        var uniforms = uniforms
        let dispatches = dispatches ?? (arguments, 0)
        if cutTerrain, let pipeline = cutPassUpPipeline, let coarseCut, let passedUp {
            stage("cut cells", &encoder)
            encoder.setComputePipelineState(pipeline)
            set(encoder, parent.state, 0)
            set(encoder, parent.species, 1)
            encoder.setBuffer(coarseCut.columns, offset: 0, index: 2)
            encoder.setBuffer(parentCutDefects ?? coarseCut.defects, offset: 0, index: 3)
            setUniforms(encoder, &uniforms, index: 4)
            encoder.setBuffer(tileOfPatch, offset: 0, index: 5)
            encoder.setBuffer(patchList, offset: 0, index: 6)
            encoder.setBuffer(passedUp, offset: 0, index: 7)
            encoder.setBuffer(control, offset: 0, index: 8)
            set(encoder, parent.patches, 9)
            encoder.setBuffer(parentCutRecords ?? coarseCut.records, offset: 0, index: 10)
            encoder.dispatchThreadgroups(
                indirectBuffer: arguments, indirectBufferOffset: 36,
                threadsPerThreadgroup: MTLSize(
                    width: Self.patchSize * Self.patchSize * Self.patchSize, height: 1, depth: 1))
        }
        stage("reflux", &encoder)
        encoder.setComputePipelineState(withGravity(refluxPipeline, "refineReflux"))
        set(encoder, parent.state, 0)
        set(encoder, parent.mask, 1)
        bind(encoder, patchOfTile, 3)
        encoder.setBuffer(tileOfPatch, offset: 0, index: 4)
        encoder.setBuffer(patchList, offset: 0, index: 5)
        encoder.setBuffer(fineFlux, offset: 0, index: 6)
        encoder.setBuffer(coarseFlux, offset: 0, index: 7)
        encoder.setBuffer(control, offset: 0, index: 8)
        encoder.setBuffer(fineSpeciesFlux, offset: 0, index: 9)
        encoder.setBuffer(coarseSpeciesFlux, offset: 0, index: 10)
        set(encoder, parent.species, 11)
        set(encoder, parent.patches, 12)
        // Not read without cut cells.
        encoder.setBuffer(coarseCut?.columns ?? fineFlux, offset: 0, index: 13)
        encoder.setBuffer(parentCutDefects ?? fineFlux, offset: 0, index: 14)
        encoder.setBuffer(parentCutRecords ?? fineFlux, offset: 0, index: 15)
        // One axis at a time: a coarse cell can border patches across several of its faces, but
        // across only one along any axis.
        for axis in axes {
            uniforms.axis = UInt32(axis)
            setUniforms(encoder, &uniforms, index: 2)
            encoder.dispatchThreadgroups(
                indirectBuffer: dispatches.0, indirectBufferOffset: dispatches.1 + 24,
                threadsPerThreadgroup: MTLSize(
                    width: 2 * Self.patchSize * Self.patchSize, height: 1, depth: 1))
        }
        if let beforeRestricting { beforeRestricting(encoder) }
        stage("restrict", &encoder)
        encoder.setComputePipelineState(cutSpecialised(restrictPipeline, "refineRestrict"))
        set(encoder, parent.state, 0)
        set(encoder, parent.mask, 1)
        setUniforms(encoder, &uniforms, index: 2)
        encoder.setBuffer(tileOfPatch, offset: 0, index: 3)
        encoder.setBuffer(patchList, offset: 0, index: 4)
        bind(encoder, fine[0], 5)
        encoder.setBuffer(control, offset: 0, index: 6)
        set(encoder, parent.impulse, 7)
        encoder.setBuffer(fineImpulse, offset: 0, index: 8)
        encoder.setBuffer(impulseBase, offset: 0, index: 9)
        bind(encoder, fineMask, 10)
        encoder.setBuffer(fineSpecies[0], offset: 0, index: 11)
        set(encoder, parent.species, 12)
        set(encoder, parent.patches, 13)
        // Not read without cut cells.
        encoder.setBuffer(coarseCut?.columns ?? fineFlux, offset: 0, index: 14)
        encoder.setBuffer(parentCutRecords ?? fineFlux, offset: 0, index: 15)
        encoder.setBuffer(fineCut ?? fineFlux, offset: 0, index: 16)
        encoder.dispatchThreadgroups(
            indirectBuffer: dispatches.0, indirectBufferOffset: dispatches.1 + 36,
            threadsPerThreadgroup: MTLSize(
                width: Self.patchSize * Self.patchSize * Self.patchSize, height: 1, depth: 1))
    }

    /// After the structure's points have been counted into the fine cells (with the coarse
    /// remask): the fine cells' outline follows the structure, a fine cell being solid where
    /// `threshold` of its points are.
    /// With `capSlivers` (a structure standing on the terrain's cut cells), the fine slivers it
    /// shuts in become solid (`refineRemaskCapSlivers`).
    func encodeRemask(
        _ encoder: MTLComputeCommandEncoder, parent: ParentView, threshold: UInt32, uniforms: SolverUniforms,
        capSlivers: Bool = false
    ) {
        var encoder = encoder
        stage("remask", &encoder)
        var uniforms = uniforms
        var threshold = threshold
        stage("remask", &encoder)
        encoder.setComputePipelineState(remaskPreparePipeline)
        bind(encoder, fineMask, 0)
        encoder.setBuffer(fineWall, offset: 0, index: 1)
        bind(encoder, fineOccupancy, 2)
        bind(encoder, fine[0], 3)
        set(encoder, parent.state, 4)
        setUniforms(encoder, &uniforms, index: 5)
        encoder.setBuffer(tileOfPatch, offset: 0, index: 6)
        encoder.setBuffer(patchList, offset: 0, index: 7)
        encoder.setBytes(&threshold, length: 4, index: 8)
        set(encoder, parent.mask, 9)
        encoder.setBuffer(pinned, offset: 0, index: 10)
        set(encoder, parent.patches, 11)
        encoder.dispatchThreadgroups(
            indirectBuffer: arguments, indirectBufferOffset: 72,
            threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        if capSlivers {
            stage("remask", &encoder)
            encodeCapSlivers(encoder, parent: parent, uniforms: uniforms, outline: 6)
        }
        stage("remask", &encoder)
        encoder.setComputePipelineState(remaskApplyPipeline)
        bind(encoder, fineMask, 0)
        bind(encoder, fineOccupancy, 1)
        setUniforms(encoder, &uniforms, index: 2)
        encoder.setBuffer(patchList, offset: 0, index: 3)
        encoder.dispatchThreadgroups(
            indirectBuffer: arguments, indirectBufferOffset: 72,
            threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
    }

    /// Marks the fine slivers a structure shuts in (`refineRemaskCapSlivers`), reading `outline`'s
    /// bits of the fine masks as solid.
    private func encodeCapSlivers(
        _ encoder: MTLComputeCommandEncoder, parent: ParentView, uniforms: SolverUniforms, outline: UInt32
    ) {
        guard cutTerrain, let pipeline = capSliversPipeline, let fineCut, let fineDefects, let patchCut else {
            return
        }
        var uniforms = uniforms
        var outline = outline
        encoder.setComputePipelineState(pipeline)
        bind(encoder, fineMask, 0)
        encoder.setBuffer(fineCut, offset: 0, index: 1)
        encoder.setBuffer(fineDefects, offset: 0, index: 2)
        setUniforms(encoder, &uniforms, index: 3)
        bind(encoder, patchOfTile, 4)
        encoder.setBuffer(tileOfPatch, offset: 0, index: 5)
        encoder.setBuffer(patchList, offset: 0, index: 6)
        encoder.setBuffer(patchCut, offset: 0, index: 7)
        set(encoder, parent.mask, 8)
        set(encoder, parent.patches, 9)
        encoder.setBytes(&outline, length: 4, index: 10)
        encoder.dispatchThreadgroups(
            indirectBuffer: arguments, indirectBufferOffset: 60,
            threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
    }

    /// After patches are placed and filled, where a structure stands on cut terrain: the slivers
    /// it shuts in under the new patches are solid before their first sweep, not only from the
    /// next remask on (`refineCapSliversApply`).
    func encodeCapSliversAfterPlacing(
        _ encoder: MTLComputeCommandEncoder, parent: ParentView, uniforms: SolverUniforms
    ) {
        guard cutTerrain, let apply = capSliversApplyPipeline else { return }
        var encoder = encoder
        stage("place", &encoder)
        encodeCapSlivers(encoder, parent: parent, uniforms: uniforms, outline: 3)
        stage("place", &encoder)
        var uniforms = uniforms
        encoder.setComputePipelineState(apply)
        bind(encoder, fineMask, 0)
        setUniforms(encoder, &uniforms, index: 1)
        encoder.setBuffer(patchList, offset: 0, index: 2)
        encoder.dispatchThreadgroups(
            indirectBuffer: arguments, indirectBufferOffset: 72,
            threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
    }

    /// Each fine cell the patches hold, by its coordinates at this level, and its mask (bit 0
    /// solid, bit 1 rigid). For tests.
    func fineOutline(_ grid: Grid) -> [(cell: SIMD3<Int>, mask: UInt8)] {
        let cells = side * side * side
        let dims = cellDims(grid)
        let owners = tileOfPatch.contents().bindMemory(to: UInt32.self, capacity: maxPatches)
        let mask = (fineMask.contents() + offset(of: fineMask)).bindMemory(
            to: UInt8.self, capacity: maxPatches * cells)
        var outline: [(cell: SIMD3<Int>, mask: UInt8)] = []
        for patch in 0..<maxPatches where owners[patch] != .max {
            let tile = Int(owners[patch])
            let origin =
                SIMD3(tile % tileDims.x, (tile / tileDims.x) % tileDims.y, tile / (tileDims.x * tileDims.y))
                &* side
            for n in 0..<cells {
                let cell = origin &+ SIMD3(n % side, (n / side) % side, n / (side * side))
                guard all(cell .< dims) else { continue }
                outline.append((cell, mask[patch * cells + n]))
            }
        }
        return outline
    }

    /// Step 6, after a structure's substeps: carries into the fine cells what it changed in the
    /// parent's cells under the patches.
    func encodeSync(
        _ encoder: MTLComputeCommandEncoder, parent: ParentView, control: MTLBuffer, uniforms: SolverUniforms
    ) {
        var encoder = encoder
        stage("sync", &encoder)
        var uniforms = uniforms
        stage("sync", &encoder)
        encoder.setComputePipelineState(cutSpecialised(syncPipeline, "refineSync"))
        bind(encoder, fine[0], 0)
        set(encoder, parent.state, 1)
        set(encoder, parent.mask, 2)
        setUniforms(encoder, &uniforms, index: 3)
        encoder.setBuffer(tileOfPatch, offset: 0, index: 4)
        encoder.setBuffer(patchList, offset: 0, index: 5)
        encoder.setBuffer(seenMask, offset: 0, index: 6)
        encoder.setBuffer(control, offset: 0, index: 7)
        bind(encoder, fineMask, 8)
        set(encoder, parent.patches, 9)
        // Not read without cut cells.
        encoder.setBuffer(coarseCut?.columns ?? fineWall, offset: 0, index: 10)
        encoder.setBuffer(parentCutRecords ?? fineWall, offset: 0, index: 11)
        encoder.setBuffer(fineCut ?? fineWall, offset: 0, index: 12)
        encoder.dispatchThreadgroups(
            indirectBuffer: arguments, indirectBufferOffset: 36,
            threadsPerThreadgroup: MTLSize(
                width: Self.patchSize * Self.patchSize * Self.patchSize, height: 1, depth: 1))
    }

    /// Step 7a for the first level: flags the blocks the coarse state asks to be refined. With
    /// `tiles` (the awake tiles' list and its dispatch), only awake tiles are searched.
    func encodeFlag(
        _ encoder: MTLComputeCommandEncoder, coarse: MTLBuffer, mask: MTLBuffer, control: MTLBuffer,
        tiles: (list: MTLBuffer, dispatch: MTLBuffer, threads: MTLSize)?, grid: Grid,
        uniforms: SolverUniforms,
        boxDefinition: MTLBuffer? = nil
    ) {
        var encoder = encoder
        stage("flag", &encoder)
        var uniforms = uniforms
        encoder.setBuffer(boxDefinition ?? wanted, offset: 0, index: 6)
        var band = facadeBandParameters
        encoder.setBuffer(facadeBand ?? wanted, offset: 0, index: 7)
        encoder.setBytes(&band, length: MemoryLayout<FacadeBandParameters>.stride, index: 8)
        if let tiles {
            stage("flag", &encoder)
            encoder.setComputePipelineState(flagTilesPipeline)
            encoder.setBuffer(coarse, offset: 0, index: 0)
            encoder.setBuffer(mask, offset: 0, index: 1)
            encoder.setBuffer(wanted, offset: 0, index: 2)
            setUniforms(encoder, &uniforms, index: 3)
            encoder.setBuffer(control, offset: 0, index: 4)
            encoder.setBuffer(tiles.list, offset: 0, index: 5)
            encoder.dispatchThreadgroups(
                indirectBuffer: tiles.dispatch, indirectBufferOffset: 0, threadsPerThreadgroup: tiles.threads)
        } else {
            stage("flag", &encoder)
            encoder.setComputePipelineState(flagPipeline)
            encoder.setBuffer(coarse, offset: 0, index: 0)
            encoder.setBuffer(mask, offset: 0, index: 1)
            encoder.setBuffer(wanted, offset: 0, index: 2)
            setUniforms(encoder, &uniforms, index: 3)
            encoder.setBuffer(control, offset: 0, index: 4)
            let width = flagPipeline.threadExecutionWidth
            encoder.dispatchThreads(
                MTLSize(width: grid.nx, height: grid.ny, depth: grid.nz),
                threadsPerThreadgroup: MTLSize(
                    width: width, height: max(1, flagPipeline.maxTotalThreadsPerThreadgroup / width), depth: 1
                ))
        }
    }

    /// Step 7a for a level beneath another: flags the blocks its parent's cells ask to be
    /// refined, then marks the parent's blocks this level needs around it.
    func encodeFlagFromParent(
        _ encoder: MTLComputeCommandEncoder, control: MTLBuffer, uniforms: SolverUniforms
    ) {
        var encoder = encoder
        stage("flag", &encoder)
        guard let parent else { return }
        var uniforms = uniforms
        let view = parent.view()
        stage("flag", &encoder)
        encoder.setComputePipelineState(flagFinePipeline)
        set(encoder, view.state, 0)
        set(encoder, view.mask, 1)
        encoder.setBuffer(wanted, offset: 0, index: 2)
        setUniforms(encoder, &uniforms, index: 3)
        encoder.setBuffer(control, offset: 0, index: 4)
        set(encoder, view.patches, 5)
        encoder.setBuffer(parent.tileOfPatch, offset: 0, index: 6)
        encoder.setBuffer(parent.patchList, offset: 0, index: 7)
        var band = facadeBandParameters
        encoder.setBuffer(facadeBand ?? wanted, offset: 0, index: 8)
        encoder.setBytes(&band, length: MemoryLayout<FacadeBandParameters>.stride, index: 9)
        encoder.dispatchThreadgroups(
            indirectBuffer: parent.arguments, indirectBufferOffset: 72,
            threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
    }

    /// Step 7a', after the parent is flagged too: the parent's blocks around those this level
    /// wants or keeps are wanted, so that it stays nested.
    func encodeNest(_ encoder: MTLComputeCommandEncoder, control: MTLBuffer, uniforms: SolverUniforms) {
        var encoder = encoder
        stage("nest", &encoder)
        guard let parent else { return }
        var uniforms = uniforms
        stage("nest", &encoder)
        encoder.setComputePipelineState(nestPipeline)
        encoder.setBuffer(wanted, offset: 0, index: 0)
        bind(encoder, patchOfTile, 1)
        encoder.setBuffer(pinned, offset: 0, index: 2)
        encoder.setBuffer(parent.wanted, offset: 0, index: 3)
        setUniforms(encoder, &uniforms, index: 4)
        encoder.setBuffer(control, offset: 0, index: 5)
        encoder.dispatchThreads(
            MTLSize(width: tileDims.x * tileDims.y * tileDims.z, height: 1, depth: 1),
            threadsPerThreadgroup: group(nestPipeline, 256))
    }

    /// Steps 7b to 7f: places the patches afresh where flagged, filled from `parent`, and lists
    /// them for the next step.
    func encodePlace(
        _ encoder: MTLComputeCommandEncoder, parent: ParentView, control: MTLBuffer, tileFlags: MTLBuffer,
        uniforms: SolverUniforms, boxDefinition: MTLBuffer? = nil, maxSpeed: MTLBuffer? = nil
    ) {
        var encoder = encoder
        stage("place", &encoder)
        var uniforms = uniforms
        let perTile = MTLSize(width: tileDims.x * tileDims.y * tileDims.z, height: 1, depth: 1)

        stage("place", &encoder)
        encoder.setComputePipelineState(releasePipeline)
        bind(encoder, patchOfTile, 0)
        encoder.setBuffer(tileOfPatch, offset: 0, index: 1)
        encoder.setBuffer(freeStack, offset: 0, index: 2)
        encoder.setBuffer(counters, offset: 0, index: 3)
        encoder.setBuffer(wanted, offset: 0, index: 4)
        encoder.setBuffer(pinned, offset: 0, index: 5)
        setUniforms(encoder, &uniforms, index: 6)
        encoder.setBuffer(control, offset: 0, index: 7)
        encoder.dispatchThreads(perTile, threadsPerThreadgroup: group(releasePipeline, 256))

        // Granted in block order (see `refineGrant`), in groups of exactly `allocationGroup`.
        let groups = MTLSize(
            width: (perTile.width + Self.allocationGroup - 1) / Self.allocationGroup, height: 1, depth: 1)
        let groupSize = MTLSize(width: Self.allocationGroup, height: 1, depth: 1)
        stage("place", &encoder)
        encoder.setComputePipelineState(requestPipeline)
        bind(encoder, patchOfTile, 0)
        encoder.setBuffer(wanted, offset: 0, index: 1)
        encoder.setBuffer(groupCounts, offset: 0, index: 2)
        setUniforms(encoder, &uniforms, index: 3)
        set(encoder, parent.patches, 4)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: groupSize)

        stage("place", &encoder)
        encoder.setComputePipelineState(grantPipeline)
        encoder.setBuffer(groupCounts, offset: 0, index: 0)
        encoder.setBuffer(counters, offset: 0, index: 1)
        setUniforms(encoder, &uniforms, index: 2)
        encoder.setBuffer(control, offset: 0, index: 3)
        encoder.dispatchThreads(
            MTLSize(width: 1, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))

        stage("place", &encoder)
        encoder.setComputePipelineState(allocatePipeline)
        bind(encoder, patchOfTile, 0)
        encoder.setBuffer(tileOfPatch, offset: 0, index: 1)
        encoder.setBuffer(freeStack, offset: 0, index: 2)
        encoder.setBuffer(counters, offset: 0, index: 3)
        encoder.setBuffer(wanted, offset: 0, index: 4)
        encoder.setBuffer(newPatches, offset: 0, index: 5)
        encoder.setBuffer(tileFlags, offset: 0, index: 6)
        setUniforms(encoder, &uniforms, index: 7)
        encoder.setBuffer(control, offset: 0, index: 8)
        encoder.setBuffer(pinned, offset: 0, index: 9)
        set(encoder, parent.patches, 10)
        encoder.setBuffer(groupCounts, offset: 0, index: 11)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: groupSize)

        stage("place", &encoder)
        encoder.setComputePipelineState(listPipeline)
        encoder.setBuffer(tileOfPatch, offset: 0, index: 0)
        encoder.setBuffer(patchList, offset: 0, index: 1)
        encoder.setBuffer(counters, offset: 0, index: 2)
        setUniforms(encoder, &uniforms, index: 3)
        encoder.dispatchThreads(
            MTLSize(width: maxPatches, height: 1, depth: 1), threadsPerThreadgroup: group(listPipeline, 256))

        stage("place", &encoder)
        encoder.setComputePipelineState(argumentsPipeline)
        encoder.setBuffer(counters, offset: 0, index: 0)
        encoder.setBuffer(arguments, offset: 0, index: 1)
        setUniforms(encoder, &uniforms, index: 2)
        encoder.setBuffer(control, offset: 0, index: 3)
        encoder.dispatchThreads(
            MTLSize(width: 1, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))

        stage("fill", &encoder)
        encoder.setComputePipelineState(withGravity(fillPipeline, "refineFill"))
        bind(encoder, fine[0], 0)
        set(encoder, parent.state, 1)
        set(encoder, parent.mask, 2)
        setUniforms(encoder, &uniforms, index: 3)
        encoder.setBuffer(tileOfPatch, offset: 0, index: 4)
        encoder.setBuffer(newPatches, offset: 0, index: 5)
        encoder.setBuffer(fineImpulse, offset: 0, index: 6)
        set(encoder, parent.impulse, 7)
        encoder.setBuffer(impulseBase, offset: 0, index: 8)
        encoder.setBuffer(seenMask, offset: 0, index: 9)
        set(encoder, parent.rigid, 10)
        encoder.setBuffer(boxes, offset: 0, index: 11)
        encoder.setBuffer(boxIndex, offset: 0, index: 12)
        bind(encoder, fineMask, 13)
        encoder.setBuffer(fineWall, offset: 0, index: 14)
        set(encoder, parent.wallVelocity, 15)
        set(encoder, parent.species, 16)
        encoder.setBuffer(fineSpecies[0], offset: 0, index: 17)
        encoder.setBuffer(boxDefinition ?? fine[0], offset: 0, index: 18)
        set(encoder, parent.patches, 19)
        encoder.setBuffer(terrainHeights, offset: 0, index: 20)
        var terrain = terrainUniforms
        encoder.setBytes(&terrain, length: MemoryLayout<TerrainUniforms>.stride, index: 21)
        // Not read without gravity.
        encoder.setBuffer(gravityTable ?? fine[0], offset: 0, index: 22)
        encoder.setBuffer(parentGravityTable ?? fine[0], offset: 0, index: 23)
        // Not read without cut cells.
        encoder.setBuffer(fineCut ?? fineWall, offset: 0, index: 24)
        encoder.setBuffer(coarseCut?.columns ?? fineWall, offset: 0, index: 25)
        encoder.setBuffer(patchCut ?? fineWall, offset: 0, index: 26)
        encoder.setBuffer(parentCutRecords ?? fineWall, offset: 0, index: 27)
        // Read only with the levels' own steps.
        encoder.setBuffer(maxSpeed ?? fine[1], offset: 0, index: 28)
        // Without venting, a lookup of no panes (the placeholder is zeroed).
        encoder.setBuffer(panes?.cells ?? noPanes, offset: 0, index: 29)
        encoder.setBuffer(panes?.status ?? fineWall, offset: 0, index: 30)
        encoder.dispatchThreadgroups(
            indirectBuffer: arguments, indirectBufferOffset: 48,
            threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))

        stage("fill", &encoder)
        encoder.setComputePipelineState(cutSpecialised(conservePipeline, "refineFillConserve"))
        bind(encoder, fine[0], 0)
        set(encoder, parent.mask, 1)
        setUniforms(encoder, &uniforms, index: 2)
        encoder.setBuffer(tileOfPatch, offset: 0, index: 3)
        encoder.setBuffer(newPatches, offset: 0, index: 4)
        bind(encoder, fineMask, 5)
        encoder.setBuffer(pinned, offset: 0, index: 6)
        encoder.setBuffer(fineSpecies[0], offset: 0, index: 7)
        set(encoder, parent.patches, 8)
        // Not read without cut cells.
        set(encoder, parent.state, 9)
        set(encoder, parent.species, 10)
        encoder.setBuffer(coarseCut?.columns ?? fineWall, offset: 0, index: 11)
        encoder.setBuffer(parentCutRecords ?? fineWall, offset: 0, index: 12)
        encoder.setBuffer(fineCut ?? fineWall, offset: 0, index: 13)
        encoder.setBuffer(patchCut ?? fineWall, offset: 0, index: 14)
        encoder.dispatchThreadgroups(
            indirectBuffer: arguments, indirectBufferOffset: 84,
            threadsPerThreadgroup: MTLSize(
                width: Self.patchSize * Self.patchSize * Self.patchSize, height: 1, depth: 1))
    }

    /// The uniforms' refinement fields, for the first level (`uniforms` being the coarse grid's).
    func configure(_ uniforms: inout SolverUniforms, threshold: Float) {
        uniforms.refineRatio = UInt32(ratio)
        uniforms.refineTileNx = UInt32(tileDims.x)
        uniforms.refineTileNy = UInt32(tileDims.y)
        uniforms.refineTileNz = UInt32(tileDims.z)
        uniforms.refineThreshold = threshold
        uniforms.refineMaxPatches = UInt32(maxPatches)
        uniforms.parentScale = 1
    }

    /// The uniforms a level beneath another runs with, from the coarse grid's (`base`): its
    /// parent's grid stands for the coarse grid's, and the fields of skipping still air, moving
    /// solids and the experimental box are cleared, as its parent's patches handle those.
    func levelUniforms(from base: SolverUniforms, threshold: Float, grid: Grid) -> SolverUniforms {
        guard let parent else {
            var uniforms = base
            configure(&uniforms, threshold: threshold)
            return uniforms
        }
        var uniforms = base
        let dims = SIMD3(grid.nx, grid.ny, grid.nz) &* parentScale
        uniforms.nx = UInt32(dims.x)
        uniforms.ny = UInt32(dims.y)
        uniforms.nz = UInt32(dims.z)
        uniforms.dx = grid.cellSize / Float(parentScale)
        configure(&uniforms, threshold: threshold)
        uniforms.parentScale = UInt32(parentScale)
        uniforms.parentSide = UInt32(parent.side)
        uniforms.parentTileNx = UInt32(parent.tileDims.x)
        uniforms.parentTileNy = UInt32(parent.tileDims.y)
        uniforms.childTileNx = 0
        uniforms.childTileNy = 0
        uniforms.childTileNz = 0
        uniforms.tileNx = 0
        uniforms.tileNy = 0
        uniforms.tileNz = 0
        uniforms.regionNx = 0
        uniforms.regionNy = 0
        uniforms.regionNz = 0
        uniforms.couplingMapCount = 0
        uniforms.experimentalBox = 0
        uniforms.refineLevel = 2
        return uniforms
    }
}

extension AirRefinement {
    /// Prepare without writes so a coverage/collision/remap failure cannot half-change the gas.
    /// Commit the fine state and its coarse proxy only after the driver validates the whole step.
    /// `boxes` are those whose cells lie within `low`...`high` (m), before and after, and no
    /// others' do; each in the air must keep a fine cell.
    ///
    /// The region's fine cells are numbered through it, x fastest, and every sum is taken in that
    /// order. Their outline is found in slabs side by side; only the cells that open or close are
    /// redistributed, and only those whose state, outline or wall changes are written back, so the
    /// gas comes out as from taking every cell in turn, to the bit.
    func prepareBoxRemap(
        _ boxes: [ExperimentalBoxGeometry], low unionLow: SIMD3<Float>, high unionHigh: SIMD3<Float>,
        grid: Grid
    ) throws
        -> (UnsafeMutableBufferPointer<CellState>) -> Void
    {
        var stamp = measureBoxRemap ? Date.timeIntervalSinceReferenceDate : 0
        func phase(_ name: String) {
            guard measureBoxRemap else { return }
            let now = Date.timeIntervalSinceReferenceDate
            boxRemapProfile[name, default: 0] += now - stamp
            stamp = now
        }
        let h = grid.cellSize / Float(ratio)
        let r = ratio
        // Use complete coarse cells so averaging their fine children remains unchanged.
        // One coarse-cell margin contains every donor adjacent to an opening/closing cell.
        let gridDims = SIMD3(grid.nx, grid.ny, grid.nz)
        let low =
            useLocalBoxRemap
            ? simd_max(SIMD3<Int>((unionLow / grid.cellSize).rounded(.down)) &- 1, .zero) : .zero
        let high =
            useLocalBoxRemap
            ? simd_min(SIMD3<Int>((unionHigh / grid.cellSize).rounded(.up)) &+ 1, gridDims &- 1)
            : gridDims &- 1
        let side = side
        let perPatch = side * side * side
        let tileDims = tileDims
        let tiles = (patchOfTile.contents() + offset(of: patchOfTile)).bindMemory(
            to: Int32.self, capacity: tileDims.x * tileDims.y * tileDims.z)
        let masks = fineMask.contents().bindMemory(to: UInt8.self, capacity: maxPatches * perPatch)
        let states = fine[0].contents().bindMemory(to: CellState.self, capacity: maxPatches * perPatch)
        let walls = fineWall.contents().bindMemory(to: Float.self, capacity: maxPatches * perPatch * 3)
        // The fine cells over the complete coarse cells low...high, numbered x fastest.
        let fineLow = low &* r
        let extent = (high &- low &+ 1) &* r
        let total = extent.x * extent.y * extent.z
        func dense(_ p: SIMD3<Int>) -> Int? {
            let q = p &- fineLow
            guard all(q .>= 0), all(q .< extent) else { return nil }
            return q.x + extent.x * (q.y + extent.y * q.z)
        }
        func position(_ d: Int) -> SIMD3<Int> {
            fineLow &+ SIMD3(d % extent.x, (d / extent.x) % extent.y, d / (extent.x * extent.y))
        }
        // Pool slot of each, -1 where unrefined: the patches over the region's blocks, side by side
        // (each writes only its own cells).
        var slotOf = [Int32](repeating: -1, count: total)
        let tileLow = low / Self.patchSize
        let tileHigh = high / Self.patchSize
        var placed: [(origin: SIMD3<Int>, patch: Int)] = []
        for tz in tileLow.z...tileHigh.z {
            for ty in tileLow.y...tileHigh.y {
                for tx in tileLow.x...tileHigh.x {
                    let patch = Int(tiles[tx + tileDims.x * (ty + tileDims.y * tz)])
                    if patch >= 0 { placed.append((SIMD3(tx, ty, tz) &* side, patch)) }
                }
            }
        }
        // Fine cells of the region whose coarse cells lie in the grid.
        let fineHigh = simd_min(fineLow &+ extent, gridDims &* r)
        slotOf.withUnsafeMutableBufferPointer { slotOf in
            concurrently(iterations: placed.count) { n in
                let (origin, patch) = placed[n]
                let first = simd_max(origin, fineLow)
                let last = simd_min(origin &+ side, fineHigh)
                guard all(first .< last) else { return }
                for z in first.z..<last.z {
                    for y in first.y..<last.y {
                        let row = (y - fineLow.y + extent.y * (z - fineLow.z)) * extent.x - fineLow.x
                        let local =
                            patch * perPatch + side * ((y - origin.y) + side * (z - origin.z)) - origin.x
                        for x in first.x..<last.x { slotOf[row + x] = Int32(local + x) }
                    }
                }
            }
        }
        phase("slots")
        // Each cell's outline now, in slabs of fine layers side by side: which change solidity,
        // which change outline, which a box holds (for its wall) or held before (to clear it).
        struct Slab {
            var changed: [Int] = []
            var remasked: [Int] = []
            var owned: [(cell: Int, box: Int)] = []
            var released: [Int] = []
            var held: [Bool]
            var collision = false
        }
        var next = [UInt8](repeating: 0, count: total)
        let layers = extent.z
        let slabCount = min(layers, max(1, 4 * ProcessInfo.processInfo.activeProcessorCount))
        var slabs = [Slab](
            repeating: Slab(held: Array(repeating: false, count: boxes.count)), count: slabCount)
        slotOf.withUnsafeBufferPointer { slotOf in
            next.withUnsafeMutableBufferPointer { next in
                slabs.withUnsafeMutableBufferPointer { slabs in
                    concurrently(iterations: slabCount) { s in
                        var slab = slabs[s]
                        let layer = extent.x * extent.y
                        for d in (layers * s / slabCount * layer)..<(layers * (s + 1) / slabCount * layer) {
                            let at = Int(slotOf[d])
                            guard at >= 0 else { continue }
                            let point = (SIMD3<Float>(position(d)) + 0.5) * h
                            let owner = ExperimentalBoxGeometry.owner(of: point, among: boxes, cellSize: h)
                            let own = owner != nil
                            if let owner { slab.held[owner] = true }
                            let old = masks[at]
                            let rigid = old & 2 != 0
                            if own && rigid { slab.collision = true }
                            let mask = UInt8((own || rigid ? 1 : 0) | (rigid ? 2 : 0) | (own ? 8 : 0))
                            next[d] = mask
                            if (old ^ mask) & 1 != 0 { slab.changed.append(d) }
                            if old != mask { slab.remasked.append(d) }
                            if let owner {
                                slab.owned.append((d, owner))
                            } else if old & 8 != 0 {
                                slab.released.append(d)
                            }
                        }
                        slabs[s] = slab
                    }
                }
            }
        }
        phase("snapshot")
        guard !slabs.contains(where: \.collision) else {
            throw ExperimentalRigidBoxSimulation.Failure.sceneryCollision
        }
        guard
            boxes.indices.allSatisfy({ b in boxes[b].isAbsent || slabs.contains { $0.held[b] } })
        else {
            throw ExperimentalRigidBoxSimulation.Failure.unresolvedBox
        }
        let offsets = [
            SIMD3(-1, 0, 0), SIMD3(1, 0, 0), SIMD3(0, -1, 0), SIMD3(0, 1, 0), SIMD3(0, 0, -1), SIMD3(0, 0, 1),
        ]
        func neighbours(_ d: Int) -> [Int] {
            let p = position(d)
            return offsets.compactMap { offset in
                guard let e = dense(p &+ offset), slotOf[e] >= 0 else { return nil }
                return e
            }
        }
        // The new state of each cell the redistribution changes (cells taken in region order).
        var changedState: [Int: CellState] = [:]
        let changed = slabs.flatMap(\.changed)
        if !changed.isEmpty {
            if boxRemapMode == .redistribution {
                try ConservativeCellRemap.redistribute(
                    opening: changed.filter { next[$0] & 1 == 0 },
                    closing: changed.filter { next[$0] & 1 != 0 },
                    newSolid: { next[$0] & 1 != 0 }, neighbours: neighbours,
                    read: { changedState[$0] ?? states[Int(slotOf[$0])] }, write: { changedState[$0] = $1 })
            } else {
                // Connected transport moves gas along paths through the whole region: every cell.
                let cells = (0..<total).filter { slotOf[$0] >= 0 }
                var number = [Int](repeating: -1, count: total)
                for (n, d) in cells.enumerated() { number[d] = n }
                let remapped = try ConservativeCellRemap.apply(
                    cells.map { states[Int(slotOf[$0])] },
                    oldSolid: cells.map { masks[Int(slotOf[$0])] & 1 != 0 },
                    newSolid: cells.map { next[$0] & 1 != 0 }, mode: boxRemapMode
                ) { n in neighbours(cells[n]).map { number[$0] } }
                for (n, d) in cells.enumerated() { changedState[d] = remapped[n] }
            }
        }
        phase("redistribution")
        // Every body face must have a fine cell on both sides (except the domain ground). Within
        // the region every fine cell has one but those of coarse cells left unrefined, so it is
        // enough that none of theirs lies beside a box's cell.
        let coarseExtent = high &- low &+ 1
        var uncovered = [Bool](repeating: false, count: coarseExtent.z)
        slotOf.withUnsafeBufferPointer { slotOf in
            next.withUnsafeBufferPointer { next in
                uncovered.withUnsafeMutableBufferPointer { uncovered in
                    concurrently(iterations: coarseExtent.z) { z in
                        for y in 0..<coarseExtent.y {
                            for x in 0..<coarseExtent.x {
                                let c = low &+ SIMD3(x, y, z)
                                guard let first = dense(c &* r), slotOf[first] < 0 else { continue }
                                for n in 0..<(r * r * r) {
                                    let q = c &* r &+ SIMD3(n % r, (n / r) % r, n / (r * r))
                                    for offset in offsets {
                                        guard let e = dense(q &+ offset), slotOf[e] >= 0, next[e] & 8 != 0
                                        else {
                                            continue
                                        }
                                        uncovered[z] = true
                                        return
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        guard !uncovered.contains(true) else {
            throw ExperimentalRigidBoxSimulation.Failure.unsupportedConfiguration
        }
        phase("coverage")
        return { coarse in
            let started = self.measureBoxRemap ? Date.timeIntervalSinceReferenceDate : 0
            for (d, state) in changedState { states[Int(slotOf[d])] = state }
            // Each slab's own cells, side by side.
            concurrently(iterations: slabs.count) { s in
                let slab = slabs[s]
                for d in slab.remasked { masks[Int(slotOf[d])] = next[d] }
                for (d, box) in slab.owned {
                    let at = Int(slotOf[d])
                    let velocity = boxes[box].velocity(at: (SIMD3<Float>(position(d)) + 0.5) * h)
                    for axis in 0..<3 { walls[3 * at + axis] = velocity[axis] }
                }
                for d in slab.released {
                    let at = Int(slotOf[d])
                    for axis in 0..<3 { walls[3 * at + axis] = 0 }
                }
            }
            // Each coarse cell low...high over a patch, the mean of its fluid fine cells, summed
            // in region order; side by side over its layers.
            slotOf.withUnsafeBufferPointer { slotOf in
                next.withUnsafeBufferPointer { next in
                    concurrently(iterations: coarseExtent.z) { z in
                        for y in 0..<coarseExtent.y {
                            for x in 0..<coarseExtent.x {
                                let c = low &+ SIMD3(x, y, z)
                                var sum = SIMD8<Double>.zero
                                for e in 0..<r {
                                    for b in 0..<r {
                                        for a in 0..<r {
                                            guard let d = dense(c &* r &+ SIMD3(a, b, e)), slotOf[d] >= 0,
                                                next[d] & 1 == 0
                                            else { continue }
                                            let state = states[Int(slotOf[d])]
                                            sum += SIMD8(
                                                Double(state.density), Double(state.momentumX),
                                                Double(state.momentumY), Double(state.momentumZ),
                                                Double(state.energy), 0, 0, 1)
                                        }
                                    }
                                }
                                guard sum[7] > 0 else { continue }
                                let mean = sum / sum[7]
                                let index = grid.index(c.x, c.y, c.z)
                                coarse[index].density = Float(mean[0])
                                coarse[index].momentumX = Float(mean[1])
                                coarse[index].momentumY = Float(mean[2])
                                coarse[index].momentumZ = Float(mean[3])
                                coarse[index].energy = Float(mean[4])
                            }
                        }
                    }
                }
            }
            if self.measureBoxRemap {
                self.boxRemapProfile["commit", default: 0] += Date.timeIntervalSinceReferenceDate - started
            }
        }
    }
}

extension AirRefinement {
    /// Venting's panes, for the fine cells to open under them (`cells` led by `lookup`, the header
    /// `PaneLookup` in Refine.metal); nil without venting.
    func setPanes(_ panes: (cells: MTLBuffer, status: MTLBuffer, lookup: PaneLookup)?) {
        self.panes = panes
    }

    /// After the step a pane broke in: this level's fine cells under it, in patches placed, opened
    /// (`refineOpenPanes`). `uniforms` are this level's.
    func encodeOpenPanes(_ encoder: MTLComputeCommandEncoder, uniforms: SolverUniforms, control: MTLBuffer) {
        guard let panes, panes.lookup.count > 0 else { return }
        var uniforms = uniforms
        var scale = UInt32(parentScale * ratio)
        encoder.setComputePipelineState(openPanesPipeline)
        bind(encoder, fine[0], 0)
        encoder.setBuffer(fine[1], offset: 0, index: 1)
        encoder.setBuffer(fineSpecies[0], offset: 0, index: 2)
        encoder.setBuffer(fineSpecies[1], offset: 0, index: 3)
        bind(encoder, fineMask, 4)
        encoder.setBuffer(fineWall, offset: 0, index: 5)
        bind(encoder, patchOfTile, 6)
        encoder.setBuffer(panes.cells, offset: 0, index: 7)
        encoder.setBuffer(panes.status, offset: 0, index: 8)
        encoder.setBytes(&uniforms, length: MemoryLayout<SolverUniforms>.stride, index: 10)
        encoder.setBuffer(control, offset: 0, index: 11)
        encoder.setBytes(&scale, length: 4, index: 12)
        // Read only under gravity.
        encoder.setBuffer(gravityTable ?? fineWall, offset: 0, index: 13)
        encoder.dispatchThreads(
            MTLSize(width: Int(panes.lookup.count) * Int(scale * scale * scale), height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
    }
}

// A level's state for a checkpoint (`SolverCheckpoint`): its pool's tables, its fine cells and
// what they carry from step to step. A second level's cells, mask, occupancy and blocks lie in its
// parent's buffers, after the parent's own, and each level saves its own slice. What every step
// rewrites before reading (the halo, the ghosts, the flux sums, the requests) is not saved.
extension AirRefinement: SolverCheckpointing {
    var checkpointName: String { parent == nil ? "refinement1" : "refinement2" }
    var checkpointVersion: Int { 1 }

    /// The level's own buffers, saved whole, by name.
    private var checkpointBuffers: [(String, MTLBuffer)] {
        var buffers: [(String, MTLBuffer)] = [
            ("tileOfPatch", tileOfPatch), ("freeStack", freeStack), ("counters", counters),
            ("patchList", patchList), ("arguments", arguments), ("pinned", pinned), ("seenMask", seenMask),
            ("fineWall", fineWall), ("fineImpulse", fineImpulse), ("impulseBase", impulseBase),
            ("fineB", fine[1]),
        ]
        if species { buffers += [("speciesA", fineSpecies[0]), ("speciesB", fineSpecies[1])] }
        if let fineCut, let fineDefects, let patchCut {
            buffers += [("fineCut", fineCut), ("fineDefects", fineDefects), ("patchCut", patchCut)]
        }
        return buffers
    }

    /// Its slices of the buffers a second level shares with its parent: (name, buffer, offset, length).
    private var checkpointSlices: [(String, MTLBuffer, Int, Int)] {
        let cells = maxPatches * side * side * side
        let tiles = tileDims.x * tileDims.y * tileDims.z
        return [
            ("patchOfTile", patchOfTile, patchOffset * 4, tiles * 4),
            (
                "fineA", fine[0], cellOffset * MemoryLayout<CellState>.stride,
                cells * MemoryLayout<CellState>.stride
            ),
            ("fineMask", fineMask, cellOffset, cells),
            ("fineOccupancy", fineOccupancy, cellOffset * 16, cells * 16),
        ]
    }

    func checkpointParts() -> [SolverCheckpoint.Part] {
        var scalars = SolverCheckpoint.Writer()
        scalars.append(maxPatches)
        scalars.append(cellOffset)
        return [.bytes("scalars", scalars.data)]
            + checkpointBuffers.map { .buffer($0.0, $0.1, 0..<$0.1.length) }
            + checkpointSlices.map { .buffer($0.0, $0.1, $0.2..<($0.2 + $0.3)) }
    }

    func restoreCheckpoint(_ parts: [String: Data]) throws {
        var scalars = SolverCheckpoint.Reader(parts["scalars"] ?? Data())
        let patches = scalars.read(Int.self)
        let offset = scalars.read(Int.self)
        try scalars.finish(checkpointName)
        guard patches == maxPatches, offset == cellOffset else {
            throw SolverCheckpoint.Refusal(
                description:
                    "\(checkpointName)'s pool is \(maxPatches) patches where it was saved at \(patches)")
        }
        for (name, buffer) in checkpointBuffers {
            try SolverCheckpoint.restore(
                parts[name], into: buffer, offset: 0, length: buffer.length, name: "\(checkpointName).\(name)"
            )
        }
        for (name, buffer, offset, length) in checkpointSlices {
            try SolverCheckpoint.restore(
                parts[name], into: buffer, offset: offset, length: length, name: "\(checkpointName).\(name)")
        }
    }
}

extension AirRefinement {
    /// Folds this level's fine cells (state and, with afterburning, species) into `hash`, block by
    /// block in the level's order, so that it does not depend on which pool slot holds which block
    /// (slots freed in a step are handed back in whatever order the GPU's atomics took them).
    func digest(into hash: inout UInt64) {
        let tiles = tileDims.x * tileDims.y * tileDims.z
        let cells = side * side * side
        let owners = (patchOfTile.contents() + patchOffset * 4).bindMemory(to: Int32.self, capacity: tiles)
        let state = (fine[0].contents() + cellOffset * MemoryLayout<CellState>.stride)
            .bindMemory(to: UInt32.self, capacity: maxPatches * cells * 5)
        let pairs =
            species
            ? fineSpecies[0].contents().bindMemory(to: UInt32.self, capacity: maxPatches * cells * 2) : nil
        func fold(_ word: UInt32) { hash = (hash ^ UInt64(word)) &* 0x100_0000_01b3 }
        for tile in 0..<tiles where owners[tile] >= 0 {
            fold(UInt32(tile))
            let patch = Int(owners[tile])
            for n in (patch * cells * 5)..<((patch + 1) * cells * 5) { fold(state[n]) }
            if let pairs { for n in (patch * cells * 2)..<((patch + 1) * cells * 2) { fold(pairs[n]) } }
        }
    }
}
