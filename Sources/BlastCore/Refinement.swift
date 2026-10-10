import Foundation
import Metal
import simd

/// One finer level of the air: patches of (4r)^3 cells over the blocks of 4 x 4 x 4 cells of the
/// grid it refines that the shock crosses, from a pool of fixed size, placed and advanced on the
/// GPU (see `Refine.metal`). The first level refines the coarse grid; a second refines the first
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
    let maxPatches: Int
    /// The grid's size in blocks of `patchSize` cells.
    let tileDims: SIMD3<Int>
    /// The level this one refines, or nil for the coarse grid.
    let parent: AirRefinement?
    /// The parent's cells along a coarse cell's edge: 1 for the first level.
    let parentScale: Int
    /// Where this level's patch list, and its cells, start in the buffers it shares with its
    /// parent, in entries (0 for the first level).
    let patchOffset: Int
    let cellOffset: Int

    /// Per block: its patch, or -1.
    let patchOfTile: MTLBuffer
    /// Per pool slot: the block it refines, or `UInt32.max` while free.
    let tileOfPatch: MTLBuffer
    private let freeStack: MTLBuffer
    /// The free stack's height, the count of new patches and the count of listed patches.
    private let counters: MTLBuffer
    let patchList: MTLBuffer
    private let newPatches: MTLBuffer
    /// Threadgroup counts of the sweep, halo, reflux, restriction, fill and ghost dispatches, then
    /// the number of patches in use.
    let arguments: MTLBuffer
    let wanted: MTLBuffer
    /// Per coarse cell of each patch: whether it was solid when the fine cells last saw it.
    private let seenMask: MTLBuffer
    /// Per pool slot: whether the patch lies over an outline that differs from the coarse cells',
    /// and so stays until the next reset.
    let pinned: MTLBuffer
    /// Per fine cell: solid (bit 0) and rigid (bit 1), the fine cells' own outline; the velocity
    /// of the structure where it is solid; and the structure's points counted into it.
    let fineMask: MTLBuffer
    let fineWall: MTLBuffer
    var useLocalBoxRemap = true
    var boxRemapMode: ExperimentalBoxRemap = .redistribution
    var measureBoxRemap = false
    private(set) var boxRemapProfile: [String: Double] = [:]
    private var experimentalBoxImpulse: MTLBuffer?
    let fineOccupancy: MTLBuffer
    /// Gravity's background at this level's resolution (see `gravityCellOf` in Solver.metal),
    /// while the air has gravity.
    var gravityTable: MTLBuffer?
    /// And at the resolution of the level it refines.
    var parentGravityTable: MTLBuffer?
    /// The coarse cells' eddy viscosity while the air has sub-grid mixing.
    var viscosity: MTLBuffer?
    /// Whether afterburning has its extinction limit.
    var burnLimit = false
    private var combinedBodyOccupancy: MTLBuffer?
    private var bodyComposePipeline: MTLComputePipelineState?
    private var bodyPublishPipeline: MTLComputePipelineState?
    /// The rigid blocks, as minimum and maximum corners, for the fine outline; none to take the
    /// coarse cells' rigid mask instead.
    private var boxes: MTLBuffer
    private var boxCount: UInt32 = 0
    /// The terrain's heights and grid for the fine outline (`TerrainUniforms` in Refine.metal);
    /// `enabled` 0 without one.
    private var terrainHeights: MTLBuffer
    private var terrainUniforms = TerrainUniforms()
    /// The fine state, twice for the sweeps to alternate between; the first is current between
    /// coarse steps, since a step takes an even number of fine sweeps.
    let fine: [MTLBuffer]
    private let halo: MTLBuffer
    /// Two fine cells either side of each patch along the sweep under way, and what they are.
    private let ghosts: MTLBuffer
    private let ghostKinds: MTLBuffer
    private let fineFlux: MTLBuffer
    /// Each fine cell's impulse since its patch was placed, and each coarse cell's impulse then.
    let fineImpulse: MTLBuffer
    private let impulseBase: MTLBuffer
    let coarseFlux: MTLBuffer
    /// With afterburning: the fine cells' fuel and oxygen (twice, as `fine`), their ghosts', and
    /// their flux registers, fine and coarse, laid out as the others; each a placeholder without.
    let species: Bool
    let fineSpecies: [MTLBuffer]
    private let ghostSpecies: MTLBuffer
    private let fineSpeciesFlux: MTLBuffer
    let coarseSpeciesFlux: MTLBuffer
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
    private let grantPipeline: MTLComputePipelineState
    /// Per group of `allocationGroup` blocks: how many ask for a new patch, then where their
    /// requests start among all.
    private let groupCounts: MTLBuffer
    /// Blocks per threadgroup of the allocation's kernels (`allocationGroup` in Refine.metal).
    static let allocationGroup = 256
    private let listPipeline: MTLComputePipelineState
    private let argumentsPipeline: MTLComputePipelineState
    private let fillPipeline: MTLComputePipelineState

    /// Bytes one patch takes: two fine states, its halo and its flux registers, and with `species`
    /// their fuel and oxygen.
    static func bytesPerPatch(ratio: Int, species: Bool = false, bodyComposition: Bool = false) -> Int {
        let side = patchSize * ratio
        let cell = MemoryLayout<CellState>.stride
        let gas =
            2 * side * side * side * cell + side * side * side * (4 + 1 + 12 + 16) + 64 * 5 + 4 + 512
            * cell
            + 4 * side * side * (cell + 1) + 6 * side * side * 5 * 4 + 6 * patchSize * patchSize * 5 * 4
        let composition = bodyComposition ? side * side * side * 16 : 0
        guard species else { return gas + composition }
        return gas + composition + 2 * side * side * side * 8 + 4 * side * side * 8 + 6 * side * side * 8
            + 6 * patchSize * patchSize * 8
    }

    /// The size in blocks of a level whose parent has `parentScale` cells along each coarse
    /// cell's edge, and how many patches `memory` holds.
    static func layout(
        grid: Grid, ratio: Int, parentScale: Int, memory: Int, species: Bool, bodyComposition: Bool
    ) -> (tileDims: SIMD3<Int>, maxPatches: Int) {
        let block = patchSize
        let cells = SIMD3(grid.nx, grid.ny, grid.nz) &* parentScale
        let tileDims = (cells &+ (block - 1)) / block
        let tiles = tileDims.x * tileDims.y * tileDims.z
        let patches = max(
            1,
            min(
                tiles,
                memory / bytesPerPatch(ratio: ratio, species: species, bodyComposition: bodyComposition)))
        return (tileDims, patches)
    }

    /// A level of `memory` bytes. With `parent`, it refines that level (of the same ratio), whose
    /// shared buffers must have been made with room for it (`reserve`, in blocks and in cells).
    init(
        device: MTLDevice, library: MTLLibrary, grid: Grid, ratio: Int, memory: Int, species: Bool = false,
        bodyComposition: Bool = false, parent: AirRefinement? = nil,
        reserve: (tiles: Int, cells: Int) = (0, 0)
    )
        throws
    {
        precondition(ratio == 2 || ratio == 4, "The air is refined by 2 or 4")
        precondition(parent.map { $0.ratio == ratio } ?? true, "Every level is refined by the same ratio")
        self.ratio = ratio
        self.bodyComposition = bodyComposition
        self.species = species
        self.parent = parent
        parentScale = parent.map { $0.parentScale * $0.ratio } ?? 1
        side = Self.patchSize * ratio
        let layout = Self.layout(
            grid: grid, ratio: ratio, parentScale: parentScale, memory: memory, species: species,
            bodyComposition: bodyComposition)
        tileDims = layout.tileDims
        maxPatches = layout.maxPatches
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
        grantPipeline = try pipeline("refineGrant")
        listPipeline = try pipeline("refineList")
        argumentsPipeline = try pipeline("refineArguments")
        fillPipeline = try pipeline("refineFill")

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
        counters = try buffer(16, "refinement counters")
        patchList = try buffer(maxPatches * 4, "patches in use")
        newPatches = try buffer(maxPatches * 4, "new patches")
        arguments = try buffer(32 * 4, "refinement dispatches")
        wanted = try buffer(tiles, "blocks flagged")
        groupCounts = try buffer(
            (tiles + Self.allocationGroup - 1) / Self.allocationGroup * 4, "requests per group of blocks")
        seenMask = try buffer(maxPatches * Self.patchSize * Self.patchSize * Self.patchSize, "mask seen")
        pinned = try buffer(maxPatches * 4, "pinned patches")
        fineWall = try buffer(fineCells * 12, "fine wall velocity")
        boxes = try buffer(32, "rigid blocks")
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
            ] + fineSpecies).reduce(0) { $0 + $1.length } + shared + (experimentalBoxImpulse?.length ?? 0)
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

    /// Binds this level's own part of `buffer`.
    private func bind(_ encoder: MTLComputeCommandEncoder, _ buffer: MTLBuffer, _ index: Int) {
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
        guard let combinedBodyOccupancy, let bodyComposePipeline else { return }
        var threshold = threshold
        var uniforms = uniforms
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
        guard let combinedBodyOccupancy, let bodyPublishPipeline else { return }
        var uniforms = uniforms
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
                mass += Double(c.density) * volume
                energy += Double(c.energy) * volume
                momentum += SIMD3(Double(c.momentumX), Double(c.momentumY), Double(c.momentumZ)) * volume
                if species { carried += SIMD2<Double>(fuelAndOxygen[patch * cells + n]) * volume }
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
        let corners = (list ?? []).flatMap { [SIMD4($0.min, 0), SIMD4($0.max, 0)] }
        boxCount = UInt32(corners.count / 2)
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
            rows: UInt32(terrain.rows), enabled: 1)
    }

    /// The pool slots of the patches in use whose block passes `near` (block coordinates).
    func patches(near: (SIMD3<Int>) -> Bool) -> [Int] {
        let owners = tileOfPatch.contents().bindMemory(to: UInt32.self, capacity: maxPatches)
        return (0..<maxPatches).filter { patch in
            guard owners[patch] != .max else { return false }
            let tile = Int(owners[patch])
            return near(
                SIMD3(tile % tileDims.x, (tile / tileDims.x) % tileDims.y, tile / (tileDims.x * tileDims.y)))
        }
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
    /// a box) to `face`, with the fine cell's coordinates and the face's axis and side (0 low,
    /// 1 high), and zeroes them.
    func takeBoxFaceImpulses(in patches: [Int], _ face: (SIMD3<Int>, Int, Int, Double) -> Void) {
        guard let buffer = experimentalBoxImpulse else { return }
        let values = buffer.contents().bindMemory(to: Float.self, capacity: buffer.length / 4)
        let owners = tileOfPatch.contents().bindMemory(to: UInt32.self, capacity: maxPatches)
        let cells = side * side * side
        for patch in patches {
            let tile = Int(owners[patch])
            let origin =
                SIMD3(tile % tileDims.x, (tile / tileDims.x) % tileDims.y, tile / (tileDims.x * tileDims.y))
                &* side
            for n in 0..<cells {
                let base = 6 * (patch * cells + n)
                for slot in 0..<6 where values[base + slot] != 0 {
                    face(
                        origin &+ SIMD3(n % side, (n / side) % side, n / (side * side)), slot / 2, slot % 2,
                        Double(values[base + slot]))
                }
            }
            memset(buffer.contents() + patch * cells * 6 * MemoryLayout<Float>.stride, 0, cells * 6 * 4)
        }
    }

    func reset() {
        let tiles = tileDims.x * tileDims.y * tileDims.z
        let cells = maxPatches * side * side * side
        memset(patchOfTile.contents() + offset(of: patchOfTile), 0xFF, tiles * 4)
        memset(tileOfPatch.contents(), 0xFF, maxPatches * 4)
        let stack = freeStack.contents().bindMemory(to: UInt32.self, capacity: maxPatches)
        for n in 0..<maxPatches { stack[n] = UInt32(maxPatches - 1 - n) }
        let count = counters.contents().bindMemory(to: Int32.self, capacity: 4)
        (count[0], count[1], count[2], count[3]) = (Int32(maxPatches), 0, 0, 0)
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
        _ encoder: MTLComputeCommandEncoder, parent: ParentView, uniforms: SolverUniforms, control: MTLBuffer
    ) {
        var uniforms = uniforms
        encoder.setComputePipelineState(haloPipeline)
        set(encoder, parent.state, 0)
        encoder.setBuffer(halo, offset: 0, index: 1)
        setUniforms(encoder, &uniforms, index: 2)
        encoder.setBuffer(tileOfPatch, offset: 0, index: 3)
        encoder.setBuffer(patchList, offset: 0, index: 4)
        encoder.setBuffer(control, offset: 0, index: 5)
        set(encoder, parent.patches, 6)
        encoder.dispatchThreadgroups(
            indirectBuffer: arguments, indirectBufferOffset: 12,
            threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
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
        guard gravity || mixing || limit else { return base }
        let key = "\(name) \(model.map { "\($0.rawValue)" } ?? "-") \(gravity) \(mixing) \(limit)"
        if let pipeline = gravityPipelines[key] { return pipeline }
        var constants = MTLFunctionConstantValues()
        if var value = model?.rawValue {
            constants.setConstantValue(&value, type: .uint, index: ShaderLibrary.airModelConstant)
        }
        if gravity { constants = ShaderLibrary.withGravity(constants) }
        if mixing { constants = ShaderLibrary.withMixing(constants) }
        if limit { constants = ShaderLibrary.withBurnLimit(constants) }
        guard let pipeline = try? ShaderLibrary.pipeline(name, in: library, constants: constants) else {
            return base
        }
        gravityPipelines[key] = pipeline
        return pipeline
    }

    private func sweepPipeline(for model: AirModel?) -> MTLComputePipelineState {
        guard let model else { return withGravity(sweepPipeline, "refineSweep") }
        if gravityTable != nil || viscosity != nil || burnLimit {
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
        control: MTLBuffer, maxSpeed: MTLBuffer, uniforms: SolverUniforms, child: Child? = nil
    ) {
        var uniforms = uniforms
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
            if let child {
                child.level.encodeSaveHalo(
                    encoder, parent: view(current: sweep % 2), uniforms: child.uniforms, control: control)
            }
            for (n, axis) in order.enumerated() {
                uniforms.axis = UInt32(axis)
                uniforms.finalSweep = n == order.count - 1 ? 1 : 0
                let source = fine[sweep % 2]
                let sourceOffset = sweep % 2 == 0 ? offset(of: fine[0]) : 0

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
                encoder.dispatchThreadgroups(
                    indirectBuffer: arguments, indirectBufferOffset: 60,
                    threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))

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
                encoder.dispatchThreadgroups(
                    indirectBuffer: arguments, indirectBufferOffset: 0,
                    threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: depth))
                sweep += 1
            }
            if let child {
                let now = view(current: sweep % 2)
                child.level.encodeSubsteps(
                    encoder, axes: order, parent: now, peak: peak, control: control, maxSpeed: maxSpeed,
                    uniforms: child.uniforms)
                child.level.encodeRefluxAndRestrict(
                    encoder, axes: order, parent: now, control: control, uniforms: child.uniforms)
            }
        }
        precondition(sweep.isMultiple(of: 2), "A coarse step must take an even number of fine sweeps")
    }

    /// Steps 4 and 5: refluxing along each of `axes`, then the parent's cells under the patches.
    func encodeRefluxAndRestrict(
        _ encoder: MTLComputeCommandEncoder, axes: [Int], parent: ParentView, control: MTLBuffer,
        uniforms: SolverUniforms
    ) {
        var uniforms = uniforms
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
        // One axis at a time: a coarse cell can border patches across several of its faces, but
        // across only one along any axis.
        for axis in axes {
            uniforms.axis = UInt32(axis)
            setUniforms(encoder, &uniforms, index: 2)
            encoder.dispatchThreadgroups(
                indirectBuffer: arguments, indirectBufferOffset: 24,
                threadsPerThreadgroup: MTLSize(
                    width: 2 * Self.patchSize * Self.patchSize, height: 1, depth: 1))
        }
        encoder.setComputePipelineState(restrictPipeline)
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
        encoder.dispatchThreadgroups(
            indirectBuffer: arguments, indirectBufferOffset: 36,
            threadsPerThreadgroup: MTLSize(
                width: Self.patchSize * Self.patchSize * Self.patchSize, height: 1, depth: 1))
    }

    /// After the structure's points have been counted into the fine cells (with the coarse
    /// remask): the fine cells' outline follows the structure, a fine cell being solid where
    /// `threshold` of its points are.
    func encodeRemask(
        _ encoder: MTLComputeCommandEncoder, parent: ParentView, threshold: UInt32, uniforms: SolverUniforms
    ) {
        var uniforms = uniforms
        var threshold = threshold
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
        encoder.setComputePipelineState(remaskApplyPipeline)
        bind(encoder, fineMask, 0)
        bind(encoder, fineOccupancy, 1)
        setUniforms(encoder, &uniforms, index: 2)
        encoder.setBuffer(patchList, offset: 0, index: 3)
        encoder.dispatchThreadgroups(
            indirectBuffer: arguments, indirectBufferOffset: 72,
            threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
    }

    /// Step 6, after a structure's substeps: carries into the fine cells what it changed in the
    /// parent's cells under the patches.
    func encodeSync(
        _ encoder: MTLComputeCommandEncoder, parent: ParentView, control: MTLBuffer, uniforms: SolverUniforms
    ) {
        var uniforms = uniforms
        encoder.setComputePipelineState(syncPipeline)
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
        var uniforms = uniforms
        encoder.setBuffer(boxDefinition ?? wanted, offset: 0, index: 6)
        if let tiles {
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
        guard let parent else { return }
        var uniforms = uniforms
        let view = parent.view()
        encoder.setComputePipelineState(flagFinePipeline)
        set(encoder, view.state, 0)
        set(encoder, view.mask, 1)
        encoder.setBuffer(wanted, offset: 0, index: 2)
        setUniforms(encoder, &uniforms, index: 3)
        encoder.setBuffer(control, offset: 0, index: 4)
        set(encoder, view.patches, 5)
        encoder.setBuffer(parent.tileOfPatch, offset: 0, index: 6)
        encoder.setBuffer(parent.patchList, offset: 0, index: 7)
        encoder.dispatchThreadgroups(
            indirectBuffer: parent.arguments, indirectBufferOffset: 72,
            threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
    }

    /// Step 7a', after the parent is flagged too: the parent's blocks around those this level
    /// wants or keeps are wanted, so that it stays nested.
    func encodeNest(_ encoder: MTLComputeCommandEncoder, control: MTLBuffer, uniforms: SolverUniforms) {
        guard let parent else { return }
        var uniforms = uniforms
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
        uniforms: SolverUniforms, boxDefinition: MTLBuffer? = nil
    ) {
        var uniforms = uniforms
        let perTile = MTLSize(width: tileDims.x * tileDims.y * tileDims.z, height: 1, depth: 1)

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
        encoder.setComputePipelineState(requestPipeline)
        bind(encoder, patchOfTile, 0)
        encoder.setBuffer(wanted, offset: 0, index: 1)
        encoder.setBuffer(groupCounts, offset: 0, index: 2)
        setUniforms(encoder, &uniforms, index: 3)
        set(encoder, parent.patches, 4)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: groupSize)

        encoder.setComputePipelineState(grantPipeline)
        encoder.setBuffer(groupCounts, offset: 0, index: 0)
        encoder.setBuffer(counters, offset: 0, index: 1)
        setUniforms(encoder, &uniforms, index: 2)
        encoder.setBuffer(control, offset: 0, index: 3)
        encoder.dispatchThreads(
            MTLSize(width: 1, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))

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

        encoder.setComputePipelineState(listPipeline)
        encoder.setBuffer(tileOfPatch, offset: 0, index: 0)
        encoder.setBuffer(patchList, offset: 0, index: 1)
        encoder.setBuffer(counters, offset: 0, index: 2)
        setUniforms(encoder, &uniforms, index: 3)
        encoder.dispatchThreads(
            MTLSize(width: maxPatches, height: 1, depth: 1), threadsPerThreadgroup: group(listPipeline, 256))

        encoder.setComputePipelineState(argumentsPipeline)
        encoder.setBuffer(counters, offset: 0, index: 0)
        encoder.setBuffer(arguments, offset: 0, index: 1)
        setUniforms(encoder, &uniforms, index: 2)
        encoder.setBuffer(control, offset: 0, index: 3)
        encoder.dispatchThreads(
            MTLSize(width: 1, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))

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
        var count = boxCount
        encoder.setBytes(&count, length: 4, index: 12)
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
        encoder.dispatchThreadgroups(
            indirectBuffer: arguments, indirectBufferOffset: 48,
            threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))

        encoder.setComputePipelineState(conservePipeline)
        bind(encoder, fine[0], 0)
        set(encoder, parent.mask, 1)
        setUniforms(encoder, &uniforms, index: 2)
        encoder.setBuffer(tileOfPatch, offset: 0, index: 3)
        encoder.setBuffer(newPatches, offset: 0, index: 4)
        bind(encoder, fineMask, 5)
        encoder.setBuffer(pinned, offset: 0, index: 6)
        encoder.setBuffer(fineSpecies[0], offset: 0, index: 7)
        set(encoder, parent.patches, 8)
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
        return uniforms
    }
}

extension AirRefinement {
    /// Prepare without writes so a coverage/collision/remap failure cannot half-change the gas.
    /// Commit the fine state and its coarse proxy only after the driver validates the whole step.
    /// `boxes` are those whose cells lie within `low`...`high` (m), before and after, and no
    /// others' do; each in the air must keep a fine cell.
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
        let perPatch = side * side * side
        let owners = tileOfPatch.contents().bindMemory(to: UInt32.self, capacity: maxPatches)
        let masks = fineMask.contents().bindMemory(to: UInt8.self, capacity: maxPatches * perPatch)
        let states = fine[0].contents().bindMemory(to: CellState.self, capacity: maxPatches * perPatch)
        let walls = fineWall.contents().bindMemory(to: Float.self, capacity: maxPatches * perPatch * 3)
        // Pool slot of each fine cell over the complete coarse cells low...high, -1 where unrefined.
        let fineLow = low &* ratio
        let extent = (high &- low &+ 1) &* ratio
        var slotOf = [Int](repeating: -1, count: extent.x * extent.y * extent.z)
        func dense(_ p: SIMD3<Int>) -> Int? {
            let q = p &- fineLow
            guard all(q .>= 0), all(q .< extent) else { return nil }
            return q.x + extent.x * (q.y + extent.y * q.z)
        }
        for patch in 0..<maxPatches where owners[patch] != .max {
            let tile = Int(owners[patch])
            let origin =
                SIMD3(tile % tileDims.x, (tile / tileDims.x) % tileDims.y, tile / (tileDims.x * tileDims.y))
                &* side
            let coarseOrigin = origin / ratio
            guard all(coarseOrigin .<= high), all((coarseOrigin &+ (Self.patchSize - 1)) .>= low) else {
                continue
            }
            for n in 0..<perPatch {
                let p = origin &+ SIMD3(n % side, (n / side) % side, n / (side * side))
                let coarse = p / ratio
                guard grid.contains(coarse.x, coarse.y, coarse.z), let d = dense(p) else { continue }
                slotOf[d] = patch * perPatch + n
            }
        }
        // Spatial order, never pool-slot order: sequential donor redistribution must not
        // depend on nondeterministic GPU patch allocation.
        var coordinates: [SIMD3<Int>] = []
        var slots: [Int] = []
        var oldMask: [UInt8] = []
        var nextMask: [UInt8] = []
        var initial: [CellState] = []
        var ownerOf: [Int] = []
        var held = [Bool](repeating: false, count: boxes.count)
        var lookup = [Int](repeating: -1, count: slotOf.count)
        for d in slotOf.indices where slotOf[d] >= 0 {
            let at = slotOf[d]
            let p = fineLow &+ SIMD3(d % extent.x, (d / extent.x) % extent.y, d / (extent.x * extent.y))
            let point = (SIMD3<Float>(p) + 0.5) * h
            let owner = ExperimentalBoxGeometry.owner(of: point, among: boxes, cellSize: h)
            let own = owner != nil
            if let owner { held[owner] = true }
            let rigid = masks[at] & 2 != 0
            guard !(own && rigid) else { throw ExperimentalRigidBoxSimulation.Failure.sceneryCollision }
            lookup[d] = coordinates.count
            coordinates.append(p)
            slots.append(at)
            oldMask.append(masks[at])
            nextMask.append((own || rigid ? 1 : 0) | (rigid ? 2 : 0) | (own ? 8 : 0))
            ownerOf.append(owner ?? -1)
            initial.append(states[at])
        }
        phase("snapshot")
        guard boxes.indices.allSatisfy({ held[$0] || boxes[$0].isAbsent }) else {
            throw ExperimentalRigidBoxSimulation.Failure.unresolvedBox
        }
        phase("ordering")
        func index(_ p: SIMD3<Int>) -> Int? {
            guard let d = dense(p), lookup[d] >= 0 else { return nil }
            return lookup[d]
        }
        let offsets = [
            SIMD3(-1, 0, 0), SIMD3(1, 0, 0), SIMD3(0, -1, 0), SIMD3(0, 1, 0), SIMD3(0, 0, -1), SIMD3(0, 0, 1),
        ]
        phase("lookup")
        let remapped = try ConservativeCellRemap.apply(
            initial,
            oldSolid: oldMask.map { $0 & 1 != 0 }, newSolid: nextMask.map { $0 & 1 != 0 }, mode: boxRemapMode
        ) { n in
            offsets.compactMap { index(coordinates[n] &+ $0) }
        }
        phase("redistribution")
        // Every body face must have a fine cell on both sides (except the domain ground).
        for n in coordinates.indices where nextMask[n] & 8 != 0 {
            for offset in offsets {
                let q = coordinates[n] &+ offset
                let c = q / ratio
                guard all(q .>= 0), grid.contains(c.x, c.y, c.z) else { continue }
                guard index(q) != nil else {
                    throw ExperimentalRigidBoxSimulation.Failure.unsupportedConfiguration
                }
            }
        }
        phase("coverage")
        return { coarse in
            let started = self.measureBoxRemap ? Date.timeIntervalSinceReferenceDate : 0
            // Coarse cells low...high, in the order of their first fluid fine child.
            let coarseExtent = high &- low &+ 1
            var sums = [SIMD8<Double>](
                repeating: .zero, count: coarseExtent.x * coarseExtent.y * coarseExtent.z)
            var order: [(coarse: Int, index: Int)] = []
            for n in coordinates.indices {
                let at = slots[n]
                let p = coordinates[n]
                states[at] = remapped[n]
                masks[at] = nextMask[n]
                let velocity =
                    ownerOf[n] >= 0 ? boxes[ownerOf[n]].velocity(at: (SIMD3<Float>(p) + 0.5) * h) : .zero
                for axis in 0..<3 { walls[3 * at + axis] = velocity[axis] }
                guard nextMask[n] & 1 == 0 else { continue }
                let c = p / self.ratio
                let q = c &- low
                let slot = q.x + coarseExtent.x * (q.y + coarseExtent.y * q.z)
                let state = remapped[n]
                if sums[slot][7] == 0 { order.append((slot, grid.index(c.x, c.y, c.z))) }
                sums[slot] += SIMD8(
                    Double(state.density), Double(state.momentumX), Double(state.momentumY),
                    Double(state.momentumZ), Double(state.energy), 0, 0, 1)
            }
            for (slot, index) in order {
                let mean = sums[slot] / sums[slot][7]
                coarse[index].density = Float(mean[0])
                coarse[index].momentumX = Float(mean[1])
                coarse[index].momentumY = Float(mean[2])
                coarse[index].momentumZ = Float(mean[3])
                coarse[index].energy = Float(mean[4])
            }
            if self.measureBoxRemap {
                self.boxRemapProfile["commit", default: 0] += Date.timeIntervalSinceReferenceDate - started
            }
        }
    }
}

/// Matches `TerrainUniforms` in Refine.metal.
struct TerrainUniforms {
    var origin: SIMD2<Float> = .zero
    var spacing: Float = 1
    var columns: UInt32 = 0
    var rows: UInt32 = 0
    var enabled: UInt32 = 0
}
