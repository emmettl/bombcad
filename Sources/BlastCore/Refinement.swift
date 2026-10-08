import Foundation
import Metal
import simd

/// The air's finer level: patches of (4r)^3 cells over the blocks of 4 x 4 x 4 cells the shock
/// crosses, from a pool of fixed size, placed and advanced on the GPU (see `Refine.metal`). Owned
/// by `BlastSolver`.
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

    /// Per block: its patch, or -1.
    let patchOfTile: MTLBuffer
    /// Per pool slot: the block it refines, or `UInt32.max` while free.
    let tileOfPatch: MTLBuffer
    private let freeStack: MTLBuffer
    /// The free stack's height, the count of new patches and the count of listed patches.
    private let counters: MTLBuffer
    private let patchList: MTLBuffer
    private let newPatches: MTLBuffer
    /// Threadgroup counts of the sweep, halo, reflux, restriction, fill and ghost dispatches, then
    /// the number of patches in use.
    private let arguments: MTLBuffer
    private let wanted: MTLBuffer
    /// Per coarse cell of each patch: whether it was solid when the fine cells last saw it.
    private let seenMask: MTLBuffer
    /// Per pool slot: whether the patch lies over an outline that differs from the coarse cells',
    /// and so stays until the next reset.
    private let pinned: MTLBuffer
    /// Per fine cell: solid (bit 0) and rigid (bit 1), the fine cells' own outline; the velocity
    /// of the structure where it is solid; and the structure's points counted into it.
    let fineMask: MTLBuffer
    private let fineWall: MTLBuffer
    var useLocalBoxRemap = true
    var boxRemapMode: ExperimentalBoxRemap = .redistribution
    var measureBoxRemap = false
    private(set) var boxRemapProfile: [String: Double] = [:]
    private var experimentalBoxImpulse: MTLBuffer?
    let fineOccupancy: MTLBuffer
    private var combinedBodyOccupancy: MTLBuffer?
    private var bodyComposePipeline: MTLComputePipelineState?
    private var bodyPublishPipeline: MTLComputePipelineState?
    /// The rigid blocks, as minimum and maximum corners, for the fine outline; none to take the
    /// coarse cells' rigid mask instead.
    private var boxes: MTLBuffer
    private var boxCount: UInt32 = 0
    /// The fine state, twice for the sweeps to alternate between; the first is current between
    /// coarse steps, since a step takes an even number of fine sweeps.
    let fine: [MTLBuffer]
    private let halo: MTLBuffer
    /// Two fine cells either side of each patch along the sweep under way, and what they are.
    private let ghosts: MTLBuffer
    private let ghostKinds: MTLBuffer
    private let fineFlux: MTLBuffer
    /// Each fine cell's impulse since its patch was placed, and each coarse cell's impulse then.
    private let fineImpulse: MTLBuffer
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
    private let ghostPipeline: MTLComputePipelineState
    private let haloPipeline: MTLComputePipelineState
    private let refluxPipeline: MTLComputePipelineState
    private let restrictPipeline: MTLComputePipelineState
    private let flagPipeline: MTLComputePipelineState
    private let flagTilesPipeline: MTLComputePipelineState
    private let syncPipeline: MTLComputePipelineState
    private let conservePipeline: MTLComputePipelineState
    private let remaskPreparePipeline: MTLComputePipelineState
    private let remaskApplyPipeline: MTLComputePipelineState
    private let releasePipeline: MTLComputePipelineState
    private let allocatePipeline: MTLComputePipelineState
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

    init(
        device: MTLDevice, library: MTLLibrary, grid: Grid, ratio: Int, memory: Int, species: Bool = false,
        bodyComposition: Bool = false
    )
        throws
    {
        precondition(ratio == 2 || ratio == 4, "The air is refined by 2 or 4")
        self.ratio = ratio
        self.bodyComposition = bodyComposition
        self.species = species
        side = Self.patchSize * ratio
        let block = Self.patchSize
        tileDims = SIMD3(
            (grid.nx + block - 1) / block, (grid.ny + block - 1) / block, (grid.nz + block - 1) / block)
        let tiles = tileDims.x * tileDims.y * tileDims.z
        maxPatches = max(
            1,
            min(
                tiles,
                memory / Self.bytesPerPatch(ratio: ratio, species: species, bodyComposition: bodyComposition))
        )

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
        syncPipeline = try pipeline("refineSync")
        conservePipeline = try pipeline("refineFillConserve")
        remaskPreparePipeline = try pipeline("refineRemaskPrepare")
        remaskApplyPipeline = try pipeline("refineRemaskApply")
        releasePipeline = try pipeline("refineRelease")
        allocatePipeline = try pipeline("refineAllocate")
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
        patchOfTile = try buffer(tiles * 4, "patch of tile")
        tileOfPatch = try buffer(maxPatches * 4, "tile of patch")
        freeStack = try buffer(maxPatches * 4, "free patches")
        counters = try buffer(16, "refinement counters")
        patchList = try buffer(maxPatches * 4, "patches in use")
        newPatches = try buffer(maxPatches * 4, "new patches")
        arguments = try buffer(32 * 4, "refinement dispatches")
        wanted = try buffer(tiles, "blocks flagged")
        seenMask = try buffer(maxPatches * Self.patchSize * Self.patchSize * Self.patchSize, "mask seen")
        let fineCells = maxPatches * side * side * side
        fineMask = try buffer(fineCells, "fine mask")
        pinned = try buffer(maxPatches * 4, "pinned patches")
        fineWall = try buffer(fineCells * 12, "fine wall velocity")
        fineOccupancy = try buffer(fineCells * 16, "fine occupancy")
        boxes = try buffer(32, "rigid blocks")
        self.device = device
        self.library = library
        let fineLength = maxPatches * side * side * side * cell
        fine = [try buffer(fineLength, "fine state A"), try buffer(fineLength, "fine state B")]
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
            combinedBodyOccupancy = try buffer(fineOccupancy.length, "combined fine body occupancy")
            memset(combinedBodyOccupancy!.contents(), 0, combinedBodyOccupancy!.length)
            bodyComposePipeline = try pipeline("composeFineBodyOccupancy")
            bodyPublishPipeline = try pipeline("publishFineBodyOccupancy")
        }
    }

    var memoryFootprint: Int {
        ([
            patchOfTile, tileOfPatch, freeStack, patchList, newPatches, wanted, seenMask, halo, ghosts,
            ghostKinds,
            fineFlux, fineImpulse, impulseBase, coarseFlux, fineMask, fineWall, fineOccupancy, ghostSpecies,
            fineSpeciesFlux, coarseSpeciesFlux,
        ] + fine + fineSpecies).reduce(0) { $0 + $1.length } + (experimentalBoxImpulse?.length ?? 0)
            + (combinedBodyOccupancy?.length ?? 0)
    }

    func encodeComposeBody(
        _ encoder: MTLComputeCommandEncoder, threshold: UInt32,
        interaction: MTLBuffer, uniforms: SolverUniforms
    ) {
        guard let combinedBodyOccupancy, let bodyComposePipeline else { return }
        var threshold = threshold
        var uniforms = uniforms
        encoder.setComputePipelineState(bodyComposePipeline)
        encoder.setBuffer(fineOccupancy, offset: 0, index: 0)
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
        encoder.setBuffer(fineOccupancy, offset: 0, index: 0)
        encoder.setBuffer(combinedBodyOccupancy, offset: 0, index: 1)
        setUniforms(encoder, &uniforms, index: 2)
        encoder.setBuffer(patchList, offset: 0, index: 3)
        encoder.dispatchThreadgroups(
            indirectBuffer: arguments, indirectBufferOffset: 72,
            threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
    }

    /// Patches in use after the last regrid.
    var patchCount: Int { Int(arguments.contents().load(fromByteOffset: 24 * 4, as: UInt32.self)) }

    /// The gas the patches hold: which coarse cells they cover, and the mass, energy, momentum and
    /// (with afterburning) fuel and oxygen of their fluid fine cells.
    func gas(in grid: Grid) -> (
        covered: Set<Int>, mass: Double, energy: Double, momentum: SIMD3<Double>, species: SIMD2<Double>
    ) {
        let block = Self.patchSize
        let cells = side * side * side
        let volume = Double(pow(grid.cellSize / Float(ratio), 3))
        let owners = tileOfPatch.contents().bindMemory(to: UInt32.self, capacity: maxPatches)
        let state = fine[0].contents().bindMemory(to: CellState.self, capacity: maxPatches * cells)
        let solid = fineMask.contents().bindMemory(to: UInt8.self, capacity: maxPatches * cells)
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
                guard grid.contains(cell.x, cell.y, cell.z) else { continue }
                covered.insert(grid.index(cell.x, cell.y, cell.z))
                guard solid[patch * cells + n] & 1 == 0 else { continue }
                let c = state[patch * cells + n]
                mass += Double(c.density) * volume
                energy += Double(c.energy) * volume
                momentum += SIMD3(Double(c.momentumX), Double(c.momentumY), Double(c.momentumZ)) * volume
                if species { carried += SIMD2<Double>(fuelAndOxygen[patch * cells + n]) * volume }
            }
        }
        return (covered, mass, energy, momentum, carried)
    }

    /// Sets fine cells, by their fine coordinates, where a patch holds them, with their fuel and
    /// oxygen where afterburning is on.
    func setFine(_ cells: [SIMD3<Int>: (state: CellState, species: SIMD2<Float>)]) {
        let total = side * side * side
        let map = patchOfTile.contents().bindMemory(
            to: Int32.self, capacity: tileDims.x * tileDims.y * tileDims.z)
        let state = fine[0].contents().bindMemory(to: CellState.self, capacity: maxPatches * total)
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

    /// Releases every patch.
    var hasBoxCells: Bool {
        let owners = tileOfPatch.contents().bindMemory(to: UInt32.self, capacity: maxPatches)
        let mask = fineMask.contents().bindMemory(to: UInt8.self, capacity: maxPatches * side * side * side)
        let cells = side * side * side
        for patch in 0..<maxPatches where owners[patch] != .max {
            for n in 0..<cells where mask[patch * cells + n] & 8 != 0 { return true }
        }
        return false
    }

    func clearBoxImpulse() throws {
        let length = maxPatches * side * side * side * 6 * MemoryLayout<Float>.stride
        if experimentalBoxImpulse == nil {
            experimentalBoxImpulse = device.makeBuffer(length: length, options: .storageModeShared)
        }
        guard let buffer = experimentalBoxImpulse else {
            throw BlastError.allocationFailed("fine rigid-box impulses")
        }
        memset(buffer.contents(), 0, buffer.length)
    }

    func boxImpulses() -> (linear: SIMD3<Double>, angular: SIMD3<Double>) {
        var linear = SIMD3<Double>.zero
        var angular = SIMD3<Double>.zero
        guard let buffer = experimentalBoxImpulse else { return (linear, angular) }
        let values = buffer.contents().bindMemory(to: Float.self, capacity: buffer.length / 4)
        for n in 0..<(buffer.length / 24) {
            for a in 0..<3 {
                linear[a] += Double(values[6 * n + a])
                angular[a] += Double(values[6 * n + 3 + a])
            }
        }
        return (linear, angular)
    }

    func reset() {
        let tiles = tileDims.x * tileDims.y * tileDims.z
        memset(patchOfTile.contents(), 0xFF, tiles * 4)
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
        memset(fineOccupancy.contents(), 0, fineOccupancy.length)
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

    /// Step 1: the coarse cells around each patch, at the start of the step.
    func encodeSaveHalo(
        _ encoder: MTLComputeCommandEncoder, coarse: MTLBuffer, uniforms: SolverUniforms, control: MTLBuffer
    ) {
        var uniforms = uniforms
        encoder.setComputePipelineState(haloPipeline)
        encoder.setBuffer(coarse, offset: 0, index: 0)
        encoder.setBuffer(halo, offset: 0, index: 1)
        setUniforms(encoder, &uniforms, index: 2)
        encoder.setBuffer(tileOfPatch, offset: 0, index: 3)
        encoder.setBuffer(patchList, offset: 0, index: 4)
        encoder.setBuffer(control, offset: 0, index: 5)
        encoder.dispatchThreadgroups(
            indirectBuffer: arguments, indirectBufferOffset: 12,
            threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
    }

    /// The fine sweep compiled for `model`, made the first time it is used; the general one if
    /// that fails.
    private func sweepPipeline(for model: AirModel?) -> MTLComputePipelineState {
        guard let model else { return sweepPipeline }
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

    /// Step 3: r substeps of every patch, each sweeping `axes` in order, each sweep after filling
    /// the patches' ghosts along its axis.
    func encodeSubsteps(
        _ encoder: MTLComputeCommandEncoder, axes: [Int], coarse: MTLBuffer, coarseSpecies: MTLBuffer,
        mask: MTLBuffer, peak: MTLBuffer, control: MTLBuffer, maxSpeed: MTLBuffer, wallVelocity: MTLBuffer,
        uniforms: SolverUniforms
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
            for (n, axis) in order.enumerated() {
                uniforms.axis = UInt32(axis)
                uniforms.finalSweep = n == order.count - 1 ? 1 : 0
                let source = fine[sweep % 2]

                encoder.setComputePipelineState(ghostPipeline)
                encoder.setBuffer(source, offset: 0, index: 0)
                encoder.setBuffer(ghosts, offset: 0, index: 1)
                encoder.setBuffer(ghostKinds, offset: 0, index: 2)
                encoder.setBuffer(mask, offset: 0, index: 3)
                setUniforms(encoder, &uniforms, index: 4)
                encoder.setBuffer(patchOfTile, offset: 0, index: 5)
                encoder.setBuffer(tileOfPatch, offset: 0, index: 6)
                encoder.setBuffer(patchList, offset: 0, index: 7)
                encoder.setBuffer(coarse, offset: 0, index: 8)
                encoder.setBuffer(halo, offset: 0, index: 9)
                encoder.setBuffer(wallVelocity, offset: 0, index: 10)
                encoder.setBuffer(fineMask, offset: 0, index: 11)
                encoder.setBuffer(fineWall, offset: 0, index: 12)
                encoder.setBuffer(fineFlux, offset: 0, index: 13)
                encoder.setBuffer(control, offset: 0, index: 14)
                encoder.setBuffer(fineSpecies[sweep % 2], offset: 0, index: 15)
                encoder.setBuffer(ghostSpecies, offset: 0, index: 16)
                encoder.setBuffer(coarseSpecies, offset: 0, index: 17)
                encoder.dispatchThreadgroups(
                    indirectBuffer: arguments, indirectBufferOffset: 60,
                    threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))

                encoder.setComputePipelineState(sweepPipeline)
                encoder.setBuffer(source, offset: 0, index: 0)
                encoder.setBuffer(fine[1 - sweep % 2], offset: 0, index: 1)
                encoder.setBuffer(mask, offset: 0, index: 2)
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
                encoder.setBuffer(fineMask, offset: 0, index: 14)
                encoder.setBuffer(fineWall, offset: 0, index: 15)
                encoder.setBuffer(fineSpecies[sweep % 2], offset: 0, index: 16)
                encoder.setBuffer(fineSpecies[1 - sweep % 2], offset: 0, index: 17)
                encoder.setBuffer(ghostSpecies, offset: 0, index: 18)
                encoder.setBuffer(fineSpeciesFlux, offset: 0, index: 19)
                encoder.setBuffer(patchOfTile, offset: 0, index: 20)
                encoder.setBuffer(experimentalBoxImpulse ?? fineImpulse, offset: 0, index: 21)
                encoder.dispatchThreadgroups(
                    indirectBuffer: arguments, indirectBufferOffset: 0,
                    threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: depth))
                sweep += 1
            }
        }
        precondition(sweep.isMultiple(of: 2), "A coarse step must take an even number of fine sweeps")
    }

    /// Steps 4 and 5: refluxing along each of `axes`, then the coarse cells under the patches.
    func encodeRefluxAndRestrict(
        _ encoder: MTLComputeCommandEncoder, axes: [Int], coarse: MTLBuffer, coarseSpecies: MTLBuffer,
        mask: MTLBuffer, control: MTLBuffer, impulse: MTLBuffer, uniforms: SolverUniforms
    ) {
        var uniforms = uniforms
        encoder.setComputePipelineState(refluxPipeline)
        encoder.setBuffer(coarse, offset: 0, index: 0)
        encoder.setBuffer(mask, offset: 0, index: 1)
        encoder.setBuffer(patchOfTile, offset: 0, index: 3)
        encoder.setBuffer(tileOfPatch, offset: 0, index: 4)
        encoder.setBuffer(patchList, offset: 0, index: 5)
        encoder.setBuffer(fineFlux, offset: 0, index: 6)
        encoder.setBuffer(coarseFlux, offset: 0, index: 7)
        encoder.setBuffer(control, offset: 0, index: 8)
        encoder.setBuffer(fineSpeciesFlux, offset: 0, index: 9)
        encoder.setBuffer(coarseSpeciesFlux, offset: 0, index: 10)
        encoder.setBuffer(coarseSpecies, offset: 0, index: 11)
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
        encoder.setBuffer(coarse, offset: 0, index: 0)
        encoder.setBuffer(mask, offset: 0, index: 1)
        setUniforms(encoder, &uniforms, index: 2)
        encoder.setBuffer(tileOfPatch, offset: 0, index: 3)
        encoder.setBuffer(patchList, offset: 0, index: 4)
        encoder.setBuffer(fine[0], offset: 0, index: 5)
        encoder.setBuffer(control, offset: 0, index: 6)
        encoder.setBuffer(impulse, offset: 0, index: 7)
        encoder.setBuffer(fineImpulse, offset: 0, index: 8)
        encoder.setBuffer(impulseBase, offset: 0, index: 9)
        encoder.setBuffer(fineMask, offset: 0, index: 10)
        encoder.setBuffer(fineSpecies[0], offset: 0, index: 11)
        encoder.setBuffer(coarseSpecies, offset: 0, index: 12)
        encoder.dispatchThreadgroups(
            indirectBuffer: arguments, indirectBufferOffset: 36,
            threadsPerThreadgroup: MTLSize(
                width: Self.patchSize * Self.patchSize * Self.patchSize, height: 1, depth: 1))
    }

    /// After the structure's points have been counted into the fine cells (with the coarse
    /// remask): the fine cells' outline follows the structure, a fine cell being solid where
    /// `threshold` of its points are.
    func encodeRemask(
        _ encoder: MTLComputeCommandEncoder, coarse: MTLBuffer, mask: MTLBuffer, threshold: UInt32,
        uniforms: SolverUniforms
    ) {
        var uniforms = uniforms
        var threshold = threshold
        encoder.setComputePipelineState(remaskPreparePipeline)
        encoder.setBuffer(fineMask, offset: 0, index: 0)
        encoder.setBuffer(fineWall, offset: 0, index: 1)
        encoder.setBuffer(fineOccupancy, offset: 0, index: 2)
        encoder.setBuffer(fine[0], offset: 0, index: 3)
        encoder.setBuffer(coarse, offset: 0, index: 4)
        setUniforms(encoder, &uniforms, index: 5)
        encoder.setBuffer(tileOfPatch, offset: 0, index: 6)
        encoder.setBuffer(patchList, offset: 0, index: 7)
        encoder.setBytes(&threshold, length: 4, index: 8)
        encoder.setBuffer(mask, offset: 0, index: 9)
        encoder.setBuffer(pinned, offset: 0, index: 10)
        encoder.dispatchThreadgroups(
            indirectBuffer: arguments, indirectBufferOffset: 72,
            threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        encoder.setComputePipelineState(remaskApplyPipeline)
        encoder.setBuffer(fineMask, offset: 0, index: 0)
        encoder.setBuffer(fineOccupancy, offset: 0, index: 1)
        setUniforms(encoder, &uniforms, index: 2)
        encoder.setBuffer(patchList, offset: 0, index: 3)
        encoder.dispatchThreadgroups(
            indirectBuffer: arguments, indirectBufferOffset: 72,
            threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
    }

    /// Step 6, after a structure's substeps: carries into the fine cells what it changed in the
    /// coarse cells under the patches.
    func encodeSync(
        _ encoder: MTLComputeCommandEncoder, coarse: MTLBuffer, mask: MTLBuffer, control: MTLBuffer,
        uniforms: SolverUniforms
    ) {
        var uniforms = uniforms
        encoder.setComputePipelineState(syncPipeline)
        encoder.setBuffer(fine[0], offset: 0, index: 0)
        encoder.setBuffer(coarse, offset: 0, index: 1)
        encoder.setBuffer(mask, offset: 0, index: 2)
        setUniforms(encoder, &uniforms, index: 3)
        encoder.setBuffer(tileOfPatch, offset: 0, index: 4)
        encoder.setBuffer(patchList, offset: 0, index: 5)
        encoder.setBuffer(seenMask, offset: 0, index: 6)
        encoder.setBuffer(control, offset: 0, index: 7)
        encoder.setBuffer(fineMask, offset: 0, index: 8)
        encoder.dispatchThreadgroups(
            indirectBuffer: arguments, indirectBufferOffset: 36,
            threadsPerThreadgroup: MTLSize(
                width: Self.patchSize * Self.patchSize * Self.patchSize, height: 1, depth: 1))
    }

    /// Step 7: places the patches afresh from the coarse state, and lists them for the next step.
    /// With `tiles` (the awake tiles' list and its dispatch), only awake tiles are searched.
    func encodeRegrid(
        _ encoder: MTLComputeCommandEncoder, coarse: MTLBuffer, coarseSpecies: MTLBuffer, mask: MTLBuffer,
        rigidMask: MTLBuffer, wallVelocity: MTLBuffer, control: MTLBuffer, impulse: MTLBuffer,
        tileFlags: MTLBuffer,
        tiles: (list: MTLBuffer, dispatch: MTLBuffer, threads: MTLSize)?, grid: Grid,
        uniforms: SolverUniforms, boxDefinition: MTLBuffer? = nil
    ) {
        var uniforms = uniforms
        let tileCount = tileDims.x * tileDims.y * tileDims.z
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
        let perTile = MTLSize(width: tileCount, height: 1, depth: 1)

        encoder.setComputePipelineState(releasePipeline)
        encoder.setBuffer(patchOfTile, offset: 0, index: 0)
        encoder.setBuffer(tileOfPatch, offset: 0, index: 1)
        encoder.setBuffer(freeStack, offset: 0, index: 2)
        encoder.setBuffer(counters, offset: 0, index: 3)
        encoder.setBuffer(wanted, offset: 0, index: 4)
        encoder.setBuffer(pinned, offset: 0, index: 5)
        setUniforms(encoder, &uniforms, index: 6)
        encoder.setBuffer(control, offset: 0, index: 7)
        encoder.dispatchThreads(perTile, threadsPerThreadgroup: group(releasePipeline, 256))

        encoder.setComputePipelineState(allocatePipeline)
        encoder.setBuffer(patchOfTile, offset: 0, index: 0)
        encoder.setBuffer(tileOfPatch, offset: 0, index: 1)
        encoder.setBuffer(freeStack, offset: 0, index: 2)
        encoder.setBuffer(counters, offset: 0, index: 3)
        encoder.setBuffer(wanted, offset: 0, index: 4)
        encoder.setBuffer(newPatches, offset: 0, index: 5)
        encoder.setBuffer(tileFlags, offset: 0, index: 6)
        setUniforms(encoder, &uniforms, index: 7)
        encoder.setBuffer(control, offset: 0, index: 8)
        encoder.setBuffer(pinned, offset: 0, index: 9)
        encoder.dispatchThreads(perTile, threadsPerThreadgroup: group(allocatePipeline, 256))

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

        encoder.setComputePipelineState(fillPipeline)
        encoder.setBuffer(fine[0], offset: 0, index: 0)
        encoder.setBuffer(coarse, offset: 0, index: 1)
        encoder.setBuffer(mask, offset: 0, index: 2)
        setUniforms(encoder, &uniforms, index: 3)
        encoder.setBuffer(tileOfPatch, offset: 0, index: 4)
        encoder.setBuffer(newPatches, offset: 0, index: 5)
        encoder.setBuffer(fineImpulse, offset: 0, index: 6)
        encoder.setBuffer(impulse, offset: 0, index: 7)
        encoder.setBuffer(impulseBase, offset: 0, index: 8)
        encoder.setBuffer(seenMask, offset: 0, index: 9)
        encoder.setBuffer(rigidMask, offset: 0, index: 10)
        encoder.setBuffer(boxes, offset: 0, index: 11)
        var count = boxCount
        encoder.setBytes(&count, length: 4, index: 12)
        encoder.setBuffer(fineMask, offset: 0, index: 13)
        encoder.setBuffer(fineWall, offset: 0, index: 14)
        encoder.setBuffer(wallVelocity, offset: 0, index: 15)
        encoder.setBuffer(coarseSpecies, offset: 0, index: 16)
        encoder.setBuffer(fineSpecies[0], offset: 0, index: 17)
        encoder.setBuffer(boxDefinition ?? fine[0], offset: 0, index: 18)
        encoder.dispatchThreadgroups(
            indirectBuffer: arguments, indirectBufferOffset: 48,
            threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))

        encoder.setComputePipelineState(conservePipeline)
        encoder.setBuffer(fine[0], offset: 0, index: 0)
        encoder.setBuffer(mask, offset: 0, index: 1)
        setUniforms(encoder, &uniforms, index: 2)
        encoder.setBuffer(tileOfPatch, offset: 0, index: 3)
        encoder.setBuffer(newPatches, offset: 0, index: 4)
        encoder.setBuffer(fineMask, offset: 0, index: 5)
        encoder.setBuffer(pinned, offset: 0, index: 6)
        encoder.setBuffer(fineSpecies[0], offset: 0, index: 7)
        encoder.dispatchThreadgroups(
            indirectBuffer: arguments, indirectBufferOffset: 84,
            threadsPerThreadgroup: MTLSize(
                width: Self.patchSize * Self.patchSize * Self.patchSize, height: 1, depth: 1))
    }

    /// The uniforms' refinement fields.
    func configure(_ uniforms: inout SolverUniforms, threshold: Float) {
        uniforms.refineRatio = UInt32(ratio)
        uniforms.refineTileNx = UInt32(tileDims.x)
        uniforms.refineTileNy = UInt32(tileDims.y)
        uniforms.refineTileNz = UInt32(tileDims.z)
        uniforms.refineThreshold = threshold
        uniforms.refineMaxPatches = UInt32(maxPatches)
    }
}

extension AirRefinement {
    /// Prepare without writes so a coverage/collision/remap failure cannot half-change the gas.
    /// Commit the fine state and its coarse proxy only after the driver validates the whole step.
    func prepareBoxRemap(
        _ body: RigidBoxBody, grid: Grid,
        previousBounds: (min: SIMD3<Float>, max: SIMD3<Float>)? = nil
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
        let geometry = ExperimentalBoxGeometry(body)
        let h = grid.cellSize / Float(ratio)
        // Use complete coarse cells so averaging their fine children remains unchanged.
        // One coarse-cell margin contains every donor adjacent to an opening/closing cell.
        let newLow = body.corners.reduce(SIMD3<Float>(repeating: .infinity)) {
            simd_min($0, SIMD3<Float>($1))
        }
        let newHigh = body.corners.reduce(SIMD3<Float>(repeating: -.infinity)) {
            simd_max($0, SIMD3<Float>($1))
        }
        let unionLow = simd_min(newLow, previousBounds?.min ?? newLow)
        let unionHigh = simd_max(newHigh, previousBounds?.max ?? newHigh)
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
        var coordinates: [SIMD3<Int>] = []
        var slots: [Int] = []
        var oldMask: [UInt8] = []
        var nextMask: [UInt8] = []
        var initial: [CellState] = []
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
                guard all(coarse .>= low), all(coarse .<= high), grid.contains(coarse.x, coarse.y, coarse.z)
                else { continue }
                let at = patch * perPatch + n
                let point = (SIMD3<Float>(p) + 0.5) * h
                let own = geometry.contains(point, cellSize: h)
                let rigid = masks[at] & 2 != 0
                guard !(own && rigid) else { throw ExperimentalRigidBoxSimulation.Failure.sceneryCollision }
                coordinates.append(p)
                slots.append(at)
                oldMask.append(masks[at])
                nextMask.append((own || rigid ? 1 : 0) | (rigid ? 2 : 0) | (own ? 8 : 0))
                initial.append(states[at])
            }
        }
        phase("snapshot")
        // Spatial order, never pool-slot order: sequential donor redistribution must not
        // depend on nondeterministic GPU patch allocation.
        let order = coordinates.indices.sorted {
            let a = coordinates[$0]
            let b = coordinates[$1]
            if a.z != b.z { return a.z < b.z }
            if a.y != b.y { return a.y < b.y }
            return a.x < b.x
        }
        coordinates = order.map { coordinates[$0] }
        slots = order.map { slots[$0] }
        initial = order.map { initial[$0] }
        oldMask = order.map { oldMask[$0] }
        nextMask = order.map { nextMask[$0] }
        guard nextMask.contains(where: { $0 & 8 != 0 }) else {
            throw ExperimentalRigidBoxSimulation.Failure.unresolvedBox
        }
        phase("ordering")
        let lookup = Dictionary(uniqueKeysWithValues: coordinates.enumerated().map { ($1, $0) })
        let offsets = [
            SIMD3(-1, 0, 0), SIMD3(1, 0, 0), SIMD3(0, -1, 0), SIMD3(0, 1, 0), SIMD3(0, 0, -1), SIMD3(0, 0, 1),
        ]
        phase("lookup")
        let remapped = try ConservativeCellRemap.apply(
            initial,
            oldSolid: oldMask.map { $0 & 1 != 0 }, newSolid: nextMask.map { $0 & 1 != 0 }, mode: boxRemapMode
        ) { n in
            offsets.compactMap { lookup[coordinates[n] &+ $0] }
        }
        phase("redistribution")
        // Every body face must have a fine cell on both sides (except the domain ground).
        for n in coordinates.indices where nextMask[n] & 8 != 0 {
            for offset in offsets {
                let q = coordinates[n] &+ offset
                let c = q / ratio
                guard all(q .>= 0), grid.contains(c.x, c.y, c.z) else { continue }
                guard lookup[q] != nil else {
                    throw ExperimentalRigidBoxSimulation.Failure.unsupportedConfiguration
                }
            }
        }
        phase("coverage")
        return { coarse in
            let started = self.measureBoxRemap ? Date.timeIntervalSinceReferenceDate : 0
            var sums: [Int: (value: SIMD8<Double>, count: Double)] = [:]
            for n in coordinates.indices {
                let at = slots[n]
                let p = coordinates[n]
                states[at] = remapped[n]
                masks[at] = nextMask[n]
                let velocity =
                    nextMask[n] & 8 != 0 ? geometry.velocity(at: (SIMD3<Float>(p) + 0.5) * h) : .zero
                for axis in 0..<3 { walls[3 * at + axis] = velocity[axis] }
                guard nextMask[n] & 1 == 0 else { continue }
                let c = p / self.ratio
                let index = grid.index(c.x, c.y, c.z)
                let state = remapped[n]
                let value = SIMD8(
                    Double(state.density), Double(state.momentumX), Double(state.momentumY),
                    Double(state.momentumZ), Double(state.energy), 0, 0, 0)
                let before = sums[index] ?? (.zero, 0)
                sums[index] = (before.value + value, before.count + 1)
            }
            for (index, sum) in sums {
                let mean = sum.value / sum.count
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
