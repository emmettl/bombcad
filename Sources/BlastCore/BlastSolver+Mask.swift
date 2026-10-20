import BlastModel
import Foundation
import Metal
import RadialBlast
import simd

// The air solver's solid mask: editing it, keeping cells in the rigid mask, and remasking the air
// around structures as they move.
extension BlastSolver {
    /// Marks `cells` as kept air (see `remaskPrepare`), where a body can move.
    func keepAir(_ cells: [UInt32]) throws {
        guard hasBody, !cells.isEmpty else { return }
        if keptAirBuffer == nil {
            guard let buffer = device.makeBuffer(length: grid.cellCount, options: .storageModeShared) else {
                throw BlastError.allocationFailed("kept air beside envelopes")
            }
            memset(buffer.contents(), 0, grid.cellCount)
            buffer.label = "kept air"
            keptAirBuffer = buffer
        }
        let kept = keptAirBuffer!.contents().bindMemory(to: UInt8.self, capacity: grid.cellCount)
        for cell in cells where Int(cell) < grid.cellCount { kept[Int(cell)] = 1 }
    }

    /// The cells kept air beside the envelopes' recorded faces, or nil.
    var keptAirCells: [Int]? {
        guard let keptAirBuffer else { return nil }
        let kept = keptAirBuffer.contents().bindMemory(to: UInt8.self, capacity: grid.cellCount)
        return (0..<grid.cellCount).filter { kept[$0] != 0 }
    }

    /// Keeps `cells`, just made solid in the mask with structures already in place (the vent
    /// panels, placed after them), in the rigid mask their remasking starts from too, rather than
    /// leaving them to be lost at the first remask or recapturing a mask that holds their outlines.
    func keepInRigidMask(_ cells: [Int]) {
        guard !bodies.isEmpty else { return }
        let rigid = rigidMaskBuffer.contents().bindMemory(to: UInt8.self, capacity: grid.cellCount)
        for index in cells { rigid[index] = 1 }
        needsRigidMaskCapture = false
    }

    /// Direct access to the solid mask (non-zero marks a rigid cell). Call `restart()` after editing.
    public func mutateMask(_ body: (UnsafeMutableBufferPointer<UInt8>) throws -> Void) rethrows {
        precondition(!batchInFlight, "Cannot edit the mask while a batch is in flight")
        frameExtractor?.invalidate()
        rigidBoxes = nil
        terrain = nil
        terrainSurface = nil
        terrainCut = nil
        needsRigidMaskCapture = true
        let pointer = maskContents.bindMemory(to: UInt8.self, capacity: grid.cellCount)
        try body(UnsafeMutableBufferPointer(start: pointer, count: grid.cellCount))
    }

    /// The same, keeping the terrain's state (its cut cells, surface and heights): for cells that do
    /// not change the ground, such as a vent panel's.
    func editMaskKeepingTerrain(_ body: (UnsafeMutableBufferPointer<UInt8>) throws -> Void) rethrows {
        precondition(!batchInFlight, "Cannot edit the mask while a batch is in flight")
        frameExtractor?.invalidate()
        rigidBoxes = nil
        needsRigidMaskCapture = true
        let pointer = maskContents.bindMemory(to: UInt8.self, capacity: grid.cellCount)
        try body(UnsafeMutableBufferPointer(start: pointer, count: grid.cellCount))
    }

    /// Encodes one update of the solid mask from the structure's current shape, and of the fine
    /// cells' outline too where the air is refined, unless `fine` is false.
    /// With `allocate` false (the air asleep), only the coupling pages already allocated follow the
    /// structure: frozen-air mechanics take no new pages.
    func encodeRemask(_ encoder: MTLComputeCommandEncoder, fine: Bool = true, allocate: Bool = true) {
        guard hasBody, let region = couplingRegion, let occupancyBuffer else { return }
        // A refined level's call may move detailed profiling on to another encoder.
        var encoder = encoder
        if allocate { encodeAllocateCoupling(encoder) }
        var uniforms = couplingUniforms(region)
        uniforms.quietCoverage = allocate ? 0 : 1
        if !fine { (uniforms.refineRatio, uniforms.deepRatio) = (0, 0) }
        let length = MemoryLayout<CouplingUniforms>.stride
        let patches = refinement?.patchOfTile ?? refinementPlaceholder
        let fineOccupancy = refinement?.fineOccupancy ?? refinementPlaceholder

        for body in bodies {
            uniforms = couplingUniforms(region, body: body)
            uniforms.quietCoverage = allocate ? 0 : 1
            if !fine { (uniforms.refineRatio, uniforms.deepRatio) = (0, 0) }
            if let structure = body.solids {
                encoder.setComputePipelineState(splatPipeline)
                encoder.setBuffer(structure.instanceBuffer, offset: 0, index: 0)
                encoder.setBuffer(structure.flagBuffer, offset: 0, index: 1)
                encoder.setBuffer(structure.nodeBuffer, offset: 0, index: 2)
                encoder.setBuffer(occupancyBuffer, offset: 0, index: 3)
                encoder.setBytes(&uniforms, length: length, index: 4)
                encoder.setBuffer(structure.nodeMapBuffer, offset: 0, index: 5)
                encoder.setBuffer(patches, offset: 0, index: 6)
                encoder.setBuffer(fineOccupancy, offset: 0, index: 7)
                encoder.setBuffer(wallVelocityBuffer, offset: 0, index: 8)
                encoder.dispatchThreads(
                    MTLSize(width: structure.elementCount, height: 1, depth: 1),
                    threadsPerThreadgroup: MTLSize(
                        width: splatPipeline.maxTotalThreadsPerThreadgroup, height: 1, depth: 1))
            }
            if let shells = body.shells {
                // In a mixed body, one shell point fills a cell, as a third of it in solid elements does.
                uniforms.splatWeight = body.solids != nil ? uniforms.threshold : 1
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
                    encoder.setBuffer(wallVelocityBuffer, offset: 0, index: 9)
                    encoder.dispatchThreads(
                        MTLSize(width: shells.beamCount, height: 1, depth: 1),
                        threadsPerThreadgroup: MTLSize(
                            width: beamSplatPipeline.threadExecutionWidth, height: 1, depth: 1))
                }
                var count = UInt32(shells.elementCount)
                let splat =
                    body.model.hasInclinedSolids
                    ? inclinedShellSplatPipeline ?? shellSplatPipeline : shellSplatPipeline
                encoder.setComputePipelineState(splat)
                encoder.setBuffer(shells.elementBuffer, offset: 0, index: 0)
                encoder.setBuffer(shells.flagBuffer, offset: 0, index: 1)
                encoder.setBuffer(shells.nodeBuffer, offset: 0, index: 2)
                encoder.setBuffer(shells.referenceBuffer, offset: 0, index: 3)
                encoder.setBuffer(occupancyBuffer, offset: 0, index: 4)
                encoder.setBytes(&uniforms, length: length, index: 5)
                encoder.setBytes(&count, length: 4, index: 6)
                encoder.setBuffer(patches, offset: 0, index: 7)
                encoder.setBuffer(fineOccupancy, offset: 0, index: 8)
                encoder.setBuffer(wallVelocityBuffer, offset: 0, index: 9)
                if shells.elementCount > 0 {
                    encoder.dispatchThreads(
                        MTLSize(width: shells.elementCount, height: 1, depth: 1),
                        threadsPerThreadgroup: MTLSize(
                            width: splat.threadExecutionWidth, height: 1, depth: 1))
                }
            }

            if let combined = combinedOccupancyBuffer, let interactionBuffer {
                var threshold = uniforms.threshold
                var cells = UInt32(tiledCoupling?.capacityCells ?? denseCouplingCells)
                encoder.setComputePipelineState(bodyComposePipeline)
                encoder.setBuffer(occupancyBuffer, offset: 0, index: 0)
                encoder.setBuffer(combined, offset: 0, index: 1)
                encoder.setBytes(&threshold, length: 4, index: 2)
                encoder.setBytes(&cells, length: 4, index: 3)
                encoder.setBuffer(interactionBuffer, offset: 0, index: 4)
                encoder.dispatchThreads(
                    MTLSize(width: Int(cells), height: 1, depth: 1),
                    threadsPerThreadgroup: MTLSize(
                        width: bodyComposePipeline.threadExecutionWidth, height: 1, depth: 1))
                if fine {
                    refinement?.encodeComposeBody(
                        encoder, threshold: uniforms.fineThreshold,
                        interaction: interactionBuffer, uniforms: makeUniforms())
                    if let deep = finerUniforms(makeUniforms()) {
                        finerRefinement?.encodeComposeBody(
                            encoder, threshold: uniforms.deepThreshold, interaction: interactionBuffer,
                            uniforms: deep)
                    }
                    encoder = liveEncoder?() ?? encoder
                }
            }
        }
        uniforms = couplingUniforms(region)
        uniforms.quietCoverage = allocate ? 0 : 1
        if !fine { (uniforms.refineRatio, uniforms.deepRatio) = (0, 0) }
        let composed = combinedOccupancyBuffer ?? occupancyBuffer
        if fine, bodies.count > 1 {
            refinement?.encodePublishBodies(encoder, uniforms: makeUniforms())
            if let deep = finerUniforms(makeUniforms()) {
                finerRefinement?.encodePublishBodies(encoder, uniforms: deep)
            }
            encoder = liveEncoder?() ?? encoder
        }

        let size = couplingSize(region)
        let width = remaskPreparePipeline.threadExecutionWidth
        let group =
            tiledCoupling == nil
            ? MTLSize(
                width: width, height: max(1, remaskPreparePipeline.maxTotalThreadsPerThreadgroup / width),
                depth: 1) : couplingThreads(remaskPreparePipeline)
        encoder.setComputePipelineState(remaskPreparePipeline)
        encoder.setBuffer(maskBuffer, offset: 0, index: 0)
        encoder.setBuffer(rigidMaskBuffer, offset: 0, index: 1)
        encoder.setBuffer(composed, offset: 0, index: 2)
        encoder.setBuffer(stateBuffers[current], offset: 0, index: 3)
        encoder.setBytes(&uniforms, length: length, index: 4)
        encoder.setBuffer(wallVelocityBuffer, offset: 0, index: 5)
        encoder.setBuffer(couplingTiles ?? refinementPlaceholder, offset: 0, index: 6)
        encoder.setBuffer(keptAirBuffer ?? refinementPlaceholder, offset: 0, index: 7)
        encoder.setBuffer(experimentalBoxMask ?? refinementPlaceholder, offset: 0, index: 8)
        encoder.dispatchThreads(size, threadsPerThreadgroup: group)

        // A structure standing on the terrain's cut cells shuts in the slivers under it.
        if let terrainCut, !terrainCut.geometry.cutColumns.isEmpty,
            bodies.contains(where: { $0.model.ground != nil })
        {
            var dims = SIMD4<UInt32>(
                UInt32(grid.nx), UInt32(grid.ny), UInt32(grid.nz),
                UInt32(terrainCut.geometry.cutColumns.count))
            encoder.setComputePipelineState(remaskCapSliversPipeline)
            encoder.setBuffer(maskBuffer, offset: 0, index: 0)
            encoder.setBuffer(rigidMaskBuffer, offset: 0, index: 1)
            encoder.setBuffer(terrainCut.columns, offset: 0, index: 2)
            encoder.setBuffer(terrainCut.cutColumns, offset: 0, index: 3)
            encoder.setBuffer(terrainCut.defects, offset: 0, index: 4)
            encoder.setBytes(&dims, length: MemoryLayout<SIMD4<UInt32>>.stride, index: 5)
            if cappedSliverBuffer == nil {
                cappedSliverBuffer = device.makeBuffer(
                    length: 4 * terrainCut.geometry.cutColumns.count, options: .storageModeShared)
                if let cappedSliverBuffer {
                    memset(cappedSliverBuffer.contents(), 0, cappedSliverBuffer.length)
                }
            }
            encoder.setBuffer(cappedSliverBuffer, offset: 0, index: 6)
            encoder.dispatchThreads(
                MTLSize(width: terrainCut.geometry.cutColumns.count, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(
                    width: remaskCapSliversPipeline.threadExecutionWidth, height: 1, depth: 1))
        }

        encoder.setComputePipelineState(remaskApplyPipeline)
        encoder.setBuffer(maskBuffer, offset: 0, index: 0)
        encoder.setBuffer(composed, offset: 0, index: 1)
        encoder.setBytes(&uniforms, length: length, index: 2)
        encoder.setBuffer(couplingTiles ?? refinementPlaceholder, offset: 0, index: 3)
        encoder.dispatchThreads(size, threadsPerThreadgroup: group)

        if fine, let refinement {
            // Bit 31 asks the fine outline for the coarse one's hysteresis.
            let hysteresis: UInt32 = uniforms.maskHysteresis != 0 ? 1 << 31 : 0
            // A structure standing on the terrain's cut cells shuts in fine slivers too.
            let caps =
                !(terrainCut?.geometry.cutColumns.isEmpty ?? true)
                && bodies.contains(where: { $0.model.ground != nil })
            refinement.encodeRemask(
                encoder, parent: coarseView(species: currentSpecies),
                threshold: uniforms.fineThreshold | hysteresis, uniforms: makeUniforms(), capSlivers: caps)
            if let finerRefinement, let deep = finerUniforms(makeUniforms()) {
                finerRefinement.encodeRemask(
                    encoder, parent: refinement.view(), threshold: uniforms.deepThreshold | hysteresis,
                    uniforms: deep, capSlivers: caps)
            }
        }
    }
}
