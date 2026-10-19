import BlastModel
import Foundation
import Metal
import RadialBlast
import simd

// The air solver's cut cells: structures' outlines laid as cut cells, and each step's
// redistribution of what cut cells could not hold, the terrain's up its column and the structures'
// along the wall's normal.
extension BlastSolver {
    /// Shares each structure cut cell's difference over the step out along its wall's normal, in
    /// `state` just swept (`keepStructureCut`, then `takeStructureCut`, in SolverCutCells.metal).
    func encodeStructureCutRedistribution(
        _ encoder: MTLComputeCommandEncoder, cut: StructureCutBuffers, kernels: CellKernels,
        uniforms: SolverUniforms, state: MTLBuffer, species: MTLBuffer
    ) {
        var uniforms = uniforms
        var count = UInt32(cut.geometry.cells.count)
        guard count > 0 else { return }
        encoder.setComputePipelineState(kernels.keepStructureCut)
        encoder.setBuffer(state, offset: 0, index: 0)
        encoder.setBuffer(species, offset: 0, index: 1)
        encoder.setBuffer(cut.cells, offset: 0, index: 2)
        encoder.setBuffer(cut.records, offset: 0, index: 3)
        encoder.setBuffer(cut.targets, offset: 0, index: 4)
        encoder.setBuffer(cut.defects, offset: 0, index: 5)
        encoder.setBuffer(cut.passed, offset: 0, index: 6)
        encoder.setBytes(&uniforms, length: MemoryLayout<SolverUniforms>.stride, index: 7)
        encoder.setBuffer(controlBuffer, offset: 0, index: 8)
        encoder.setBuffer(peakBuffer, offset: 0, index: 9)
        encoder.setBuffer(maxSpeedBuffer, offset: 0, index: 10)
        encoder.setBuffer(tileFlagBuffer, offset: 0, index: 11)
        encoder.setBytes(&count, length: 4, index: 12)
        encoder.dispatchThreads(
            MTLSize(width: Int(count), height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: min(Int(count), 256), height: 1, depth: 1))
        var receivers = UInt32(cut.geometry.receivers.count)
        guard receivers > 0 else { return }
        encoder.setComputePipelineState(kernels.takeStructureCut)
        encoder.setBuffer(cut.receivers, offset: 0, index: 2)
        encoder.setBuffer(cut.shares, offset: 0, index: 3)
        encoder.setBuffer(cut.starts, offset: 0, index: 4)
        encoder.setBuffer(cut.contributors, offset: 0, index: 5)
        encoder.setBytes(&receivers, length: 4, index: 12)
        encoder.dispatchThreads(
            MTLSize(width: Int(receivers), height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: min(Int(receivers), 256), height: 1, depth: 1))
    }

    /// Lays structures' outlines as cut cells (`configuration.structureCutCells`) from the bodies'
    /// models as built, and keeps their cells of air from the remask; none with refinement.
    func setUpStructureCut() throws {
        guard configuration.structureCutCells, hasBody, configuration.refinement <= 1 else {
            structureCut = nil
            return
        }
        // Solid elements only: shells' outlines are their midsurfaces, which a cut cell's air share
        // does not describe.
        let solids = bodies.map(\.model).filter { model in
            model.elementKind == .solid && model.solidElementKind.allSatisfy { ($0 ?? .solid) == .solid }
        }
        // The scene's own solids (the terrain below its cut cells, rigid blocks) as they stand before
        // the structures are counted in.
        let scenery = rigidMaskBuffer.contents().bindMemory(to: UInt8.self, capacity: grid.cellCount)
        let terrainGeometry = terrainCut?.geometry
        let grid = grid
        let geometry = StructureCutGeometry(
            models: solids, grid: grid, scenery: { scenery[$0] != 0 },
            terrainCut: { index in
                guard let terrainGeometry else { return false }
                return terrainGeometry.alpha(
                    index % grid.nx, (index / grid.nx) % grid.ny, index / (grid.nx * grid.ny)) < 1
            })
        // With no cell cut (a structure on the lattice), the air is as without cut cells, kernels
        // and all: specialised for them, fast math may round the same sums differently.
        guard !geometry.cells.isEmpty else {
            structureCut = nil
            return
        }
        func buffer<T>(_ values: [T], _ label: String) throws -> MTLBuffer {
            let length = max(values.count * MemoryLayout<T>.stride, 16)
            guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else {
                throw BlastError.allocationFailed(label)
            }
            _ = values.withUnsafeBytes { memcpy(buffer.contents(), $0.baseAddress!, $0.count) }
            buffer.label = label
            return buffer
        }
        let zeros = [SIMD4<Float>](repeating: .zero, count: 2 * max(geometry.cells.count, 1))
        structureCut = StructureCutBuffers(
            geometry: geometry, index: try buffer(geometry.index, "structure cut index"),
            cells: try buffer(geometry.cells, "structure cut cells"),
            records: try buffer(geometry.records, "structure cut records"),
            walls: try buffer(geometry.walls, "structure cut walls"),
            targets: try buffer(geometry.targets, "structure cut targets"),
            defects: try buffer(zeros, "structure cut differences"),
            passed: try buffer(zeros, "structure cut passed"),
            receivers: try buffer(geometry.receivers, "structure cut receivers"),
            shares: try buffer(geometry.receiverShares, "structure cut receivers' shares"),
            starts: try buffer(geometry.receiverStarts, "structure cut receivers' starts"),
            contributors: try buffer(geometry.contributors, "structure cut contributors"))
        for body in bodies { try body.solids?.readStructureCutCells() }
        // A cell the terrain's cut cells hold is theirs, and the remask's rules for it stand (a thin
        // one under a structure turns solid): only the structure's own are kept air.
        let terrain = terrainCut?.geometry
        try keepAir(
            geometry.cells.filter { cell in
                let index = Int(cell)
                return
                    (terrain?.alpha(index % grid.nx, (index / grid.nx) % grid.ny, index / (grid.nx * grid.ny))
                    ?? 1)
                    >= 1
            })
    }

    /// Shares each cut cell's difference over the step out up its column, in `state` just swept (see
    /// `redistributeCutDefects` in SolverCutCells.metal).
    func encodeCutRedistribution(
        _ encoder: MTLComputeCommandEncoder, cut: TerrainCutBuffers, pipeline: MTLComputePipelineState,
        uniforms: SolverUniforms, state: MTLBuffer, species: MTLBuffer
    ) {
        var uniforms = uniforms
        var count = UInt32(cut.geometry.cutColumns.count)
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(state, offset: 0, index: 0)
        encoder.setBuffer(species, offset: 0, index: 1)
        encoder.setBuffer(cut.columns, offset: 0, index: 2)
        encoder.setBuffer(cut.records, offset: 0, index: 3)
        encoder.setBytes(&uniforms, length: MemoryLayout<SolverUniforms>.stride, index: 4)
        encoder.setBuffer(controlBuffer, offset: 0, index: 5)
        encoder.setBuffer(peakBuffer, offset: 0, index: 6)
        encoder.setBuffer(maxSpeedBuffer, offset: 0, index: 7)
        encoder.setBuffer(cut.defects, offset: 0, index: 8)
        encoder.setBuffer(cut.cutColumns, offset: 0, index: 9)
        encoder.setBytes(&count, length: 4, index: 10)
        encoder.setBuffer(gravityTable(scale: 1) ?? cut.columns, offset: 0, index: 11)
        encoder.setBuffer(maskBuffer, offset: 0, index: 12)
        // Not read without refinement.
        let refined = refinement?.coarseCut != nil ? refinement : nil
        encoder.setBuffer(refined?.patchOfTile ?? cut.columns, offset: 0, index: 13)
        encoder.setBuffer(refined?.fine[0] ?? cut.columns, offset: 0, index: 14)
        encoder.setBuffer(refined?.fineCutBuffer ?? cut.columns, offset: 0, index: 15)
        encoder.setBuffer(refined?.fineSpecies[0] ?? cut.columns, offset: 0, index: 16)
        encoder.setBuffer(refined?.fineMask ?? cut.columns, offset: 0, index: 17)
        encoder.setBuffer(refined?.gravityTable ?? cut.columns, offset: 0, index: 18)
        encoder.setBuffer(tileFlagBuffer, offset: 0, index: 19)
        let width = min(pipeline.maxTotalThreadsPerThreadgroup, 64)
        encoder.dispatchThreads(
            MTLSize(width: Int(count), height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
    }
}
