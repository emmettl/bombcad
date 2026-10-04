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
    private let keep: MTLBuffer
    private let blocked: MTLBuffer
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

    private let sweepPipeline: MTLComputePipelineState
    private let ghostPipeline: MTLComputePipelineState
    private let haloPipeline: MTLComputePipelineState
    private let refluxPipeline: MTLComputePipelineState
    private let restrictPipeline: MTLComputePipelineState
    private let flagPipeline: MTLComputePipelineState
    private let flagTilesPipeline: MTLComputePipelineState
    private let dilatePipeline: MTLComputePipelineState
    private let releasePipeline: MTLComputePipelineState
    private let allocatePipeline: MTLComputePipelineState
    private let listPipeline: MTLComputePipelineState
    private let argumentsPipeline: MTLComputePipelineState
    private let fillPipeline: MTLComputePipelineState

    /// Bytes one patch takes: two fine states, its halo and its flux registers.
    static func bytesPerPatch(ratio: Int) -> Int {
        let side = patchSize * ratio
        let cell = MemoryLayout<CellState>.stride
        return 2 * side * side * side * cell + side * side * side * 4 + 64 * 4 + 512 * cell + 4 * side * side
            * (cell + 1) + 6 * side * side * 5
            * 4
            + 6 * patchSize * patchSize * 5 * 4
    }

    init(device: MTLDevice, library: MTLLibrary, grid: Grid, ratio: Int, memory: Int) throws {
        precondition(ratio == 2 || ratio == 4, "The air is refined by 2 or 4")
        self.ratio = ratio
        side = Self.patchSize * ratio
        let block = Self.patchSize
        tileDims = SIMD3(
            (grid.nx + block - 1) / block, (grid.ny + block - 1) / block, (grid.nz + block - 1) / block)
        let tiles = tileDims.x * tileDims.y * tileDims.z
        maxPatches = max(1, min(tiles, memory / Self.bytesPerPatch(ratio: ratio)))

        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else {
                throw BlastError.missingFunction(name)
            }
            return try device.makeComputePipelineState(function: function)
        }
        sweepPipeline = try pipeline("refineSweep")
        ghostPipeline = try pipeline("refineGhosts")
        haloPipeline = try pipeline("refineSaveHalo")
        refluxPipeline = try pipeline("refineReflux")
        restrictPipeline = try pipeline("refineRestrict")
        flagPipeline = try pipeline("refineFlag")
        flagTilesPipeline = try pipeline("refineFlagTiles")
        dilatePipeline = try pipeline("refineDilate")
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
        wanted = try buffer(tiles, "tiles flagged")
        keep = try buffer(tiles, "tiles to refine")
        blocked = try buffer(tiles, "tiles kept coarse")
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
    }

    var memoryFootprint: Int {
        ([
            patchOfTile, tileOfPatch, freeStack, patchList, newPatches, wanted, keep, blocked, halo, ghosts,
            ghostKinds,
            fineFlux, fineImpulse, impulseBase, coarseFlux,
        ] + fine).reduce(0) { $0 + $1.length }
    }

    /// Patches in use after the last regrid.
    var patchCount: Int { Int(arguments.contents().load(fromByteOffset: 18 * 4, as: UInt32.self)) }

    /// Releases every patch, and keeps coarse the blocks within a block of `region` (cells).
    func reset(keepingCoarse region: (origin: SIMD3<Int>, dims: SIMD3<Int>)?) {
        let tiles = tileDims.x * tileDims.y * tileDims.z
        memset(patchOfTile.contents(), 0xFF, tiles * 4)
        memset(tileOfPatch.contents(), 0xFF, maxPatches * 4)
        let stack = freeStack.contents().bindMemory(to: UInt32.self, capacity: maxPatches)
        for n in 0..<maxPatches { stack[n] = UInt32(maxPatches - 1 - n) }
        let count = counters.contents().bindMemory(to: Int32.self, capacity: 4)
        (count[0], count[1], count[2], count[3]) = (Int32(maxPatches), 0, 0, 0)
        memset(arguments.contents(), 0, arguments.length)
        memset(wanted.contents(), 0, wanted.length)
        memset(keep.contents(), 0, keep.length)
        memset(fineFlux.contents(), 0, fineFlux.length)
        memset(fineImpulse.contents(), 0, fineImpulse.length)
        memset(blocked.contents(), 0, blocked.length)
        if let region {
            let flags = blocked.contents().bindMemory(to: UInt8.self, capacity: tiles)
            // The region's blocks, widened by the two cells its edge can reach in a step, and by a
            // block, so that no coarse cell beside a patch lies in it.
            let block = Self.patchSize
            let low = simd_max(simd_max(region.origin &- 2, .zero) / block &- 1, .zero)
            let high = simd_min((region.origin &+ region.dims &+ 1) / block &+ 1, tileDims &- 1)
            if all(low .<= high) {
                for z in low.z...high.z {
                    for y in low.y...high.y {
                        for x in low.x...high.x { flags[x + tileDims.x * (y + tileDims.y * z)] = 1 }
                    }
                }
            }
        }
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

    /// Step 3: r substeps of every patch, each sweeping `axes` in order, each sweep after filling
    /// the patches' ghosts along its axis.
    func encodeSubsteps(
        _ encoder: MTLComputeCommandEncoder, axes: [Int], coarse: MTLBuffer, mask: MTLBuffer, peak: MTLBuffer,
        control: MTLBuffer, maxSpeed: MTLBuffer, uniforms: SolverUniforms
    ) {
        var uniforms = uniforms
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
        _ encoder: MTLComputeCommandEncoder, axes: [Int], coarse: MTLBuffer, mask: MTLBuffer,
        control: MTLBuffer, impulse: MTLBuffer, uniforms: SolverUniforms
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
        encoder.dispatchThreadgroups(
            indirectBuffer: arguments, indirectBufferOffset: 36,
            threadsPerThreadgroup: MTLSize(
                width: Self.patchSize * Self.patchSize * Self.patchSize, height: 1, depth: 1))
    }

    /// Step 6: places the patches afresh from the coarse state, and lists them for the next step.
    /// With `tiles` (the awake tiles' list and its dispatch), only awake tiles are searched.
    func encodeRegrid(
        _ encoder: MTLComputeCommandEncoder, coarse: MTLBuffer, mask: MTLBuffer, control: MTLBuffer,
        impulse: MTLBuffer, tileFlags: MTLBuffer,
        tiles: (list: MTLBuffer, dispatch: MTLBuffer, threads: MTLSize)?, grid: Grid, uniforms: SolverUniforms
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

        encoder.setComputePipelineState(dilatePipeline)
        encoder.setBuffer(wanted, offset: 0, index: 0)
        encoder.setBuffer(keep, offset: 0, index: 1)
        encoder.setBuffer(blocked, offset: 0, index: 2)
        setUniforms(encoder, &uniforms, index: 3)
        encoder.setBuffer(control, offset: 0, index: 4)
        encoder.dispatchThreads(perTile, threadsPerThreadgroup: group(dilatePipeline, 256))

        encoder.setComputePipelineState(releasePipeline)
        encoder.setBuffer(patchOfTile, offset: 0, index: 0)
        encoder.setBuffer(tileOfPatch, offset: 0, index: 1)
        encoder.setBuffer(freeStack, offset: 0, index: 2)
        encoder.setBuffer(counters, offset: 0, index: 3)
        encoder.setBuffer(keep, offset: 0, index: 4)
        encoder.setBuffer(wanted, offset: 0, index: 5)
        setUniforms(encoder, &uniforms, index: 6)
        encoder.setBuffer(control, offset: 0, index: 7)
        encoder.dispatchThreads(perTile, threadsPerThreadgroup: group(releasePipeline, 256))

        encoder.setComputePipelineState(allocatePipeline)
        encoder.setBuffer(patchOfTile, offset: 0, index: 0)
        encoder.setBuffer(tileOfPatch, offset: 0, index: 1)
        encoder.setBuffer(freeStack, offset: 0, index: 2)
        encoder.setBuffer(counters, offset: 0, index: 3)
        encoder.setBuffer(keep, offset: 0, index: 4)
        encoder.setBuffer(newPatches, offset: 0, index: 5)
        encoder.setBuffer(tileFlags, offset: 0, index: 6)
        setUniforms(encoder, &uniforms, index: 7)
        encoder.setBuffer(control, offset: 0, index: 8)
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
        encoder.dispatchThreadgroups(
            indirectBuffer: arguments, indirectBufferOffset: 48,
            threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
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
