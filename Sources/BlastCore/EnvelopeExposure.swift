import BlastModel
import Foundation
import Metal
import simd

/// Read-only diagnostics on the stationary voxel boundary. No structural reaction prediction.
/// Each exposed solid/fluid cell face samples its adjacent coarse fluid centre, including
/// restricted fine state. Temporal integrals are right-endpoint sums after full fluid steps.
final class EnvelopeExposure {
    struct Face {
        var solid: UInt32
        var fluid: UInt32
        var axis: UInt32
        var positive: UInt32
    }
    let objects: [SceneObject]
    let owners: [Int]
    let faces: [Face]
    let faceBuffer: MTLBuffer
    let values: MTLBuffer
    let signed: MTLBuffer
    let pipeline: MTLComputePipelineState
    /// Whether a face whose air is in a still tile reads the still air rather than its cell, which
    /// holds the same; off only to show that the two agree.
    var skipStillTiles = true

    init(
        device: MTLDevice, library: MTLLibrary, grid: Grid, mask: UnsafeBufferPointer<UInt8>,
        objects: [SceneObject]
    ) throws {
        guard !objects.isEmpty, Set(objects.map(\.id)).count == objects.count else {
            throw BlastError.allocationFailed("unique stationary envelope observer owners")
        }
        let resolved = try Self.resolvedFaces(grid: grid, mask: mask, objects: objects)
        let faces = resolved.faces.map(\.face)
        let owners = resolved.faces.map(\.owner)
        // A building with no face on the air (buried in the terrain, or walled in by others) is
        // kept, with nothing recorded; a district has some.
        guard !faces.isEmpty,
            let faceBuffer = device.makeBuffer(bytes: faces, length: faces.count * MemoryLayout<Face>.stride),
            let values = device.makeBuffer(length: faces.count * 16, options: .storageModeShared),
            let signed = device.makeBuffer(length: faces.count * 4, options: .storageModeShared)
        else { throw BlastError.allocationFailed("resolved envelope faces") }
        self.objects = objects
        self.owners = owners
        self.faces = faces
        self.faceBuffer = faceBuffer
        self.values = values
        self.signed = signed
        pipeline = try ShaderLibrary.pipeline("sampleEnvelopeExposure", in: library)
        reset()
    }

    var memoryFootprint: Int { faceBuffer.length + values.length + signed.length }

    /// Every owned solid cell face next to a fluid cell, with its owner and the block of the
    /// owner's envelope holding the solid cell; and each owner's envelope.
    static func resolvedFaces(
        grid: Grid, mask: UnsafeBufferPointer<UInt8>, objects: [SceneObject]
    ) throws -> (faces: [(face: Face, owner: Int, block: Int)], geometry: [BuildingEnvelope]) {
        let geometry = try objects.map { object -> BuildingEnvelope in
            if let envelope = object.envelope { return envelope }
            guard let body = object.structure else { throw SceneObjectError.unsupportedRepresentation }
            return try BuildingEnvelope(structure: body)
        }
        // Each block's cells (centre inside, half-open as `Box.contains`), over its own range of
        // cells rather than every block for every solid cell: a district holds tens of thousands.
        // Within an owner the first block holding a cell is its block; two owners holding one cell
        // are in contact.
        var owned: [Int: (owner: Int, block: Int)] = [:]
        var shared = Set<Int>()
        let dx = grid.cellSize
        for (owner, envelope) in geometry.enumerated() {
            for (index, block) in envelope.blocks.enumerated() {
                let low = simd_max(SIMD3<Int>((block.min / dx - 0.5).rounded(.down)) &- 1, .zero)
                let high = simd_min(
                    SIMD3<Int>((block.max / dx - 0.5).rounded(.up)) &+ 1,
                    SIMD3(grid.nx - 1, grid.ny - 1, grid.nz - 1))
                guard all(low .<= high) else { continue }
                for k in low.z...high.z {
                    for j in low.y...high.y {
                        for i in low.x...high.x {
                            guard block.contains(grid.cellCentre(i, j, k)) else { continue }
                            let cell = grid.index(i, j, k)
                            if let held = owned[cell] {
                                if held.owner != owner { shared.insert(cell) }
                                continue
                            }
                            owned[cell] = (owner, index)
                        }
                    }
                }
            }
        }
        // The cells standing for each pane are its own, whichever block (if any) holds their centres
        // (`BuildingEnvelope.paneCells`).
        for (owner, envelope) in geometry.enumerated() {
            for pane in envelope.panes.indices {
                guard let block = envelope.blockSources.firstIndex(of: .pane(pane)) else { continue }
                for cell in envelope.paneCells(pane, grid: grid) {
                    owned[cell] = (owner, block)
                    shared.remove(cell)
                }
            }
        }
        guard shared.allSatisfy({ mask[$0] == 0 }) else { throw SceneObjectError.interObjectContact }
        var faces: [(face: Face, owner: Int, block: Int)] = []
        for cell in owned.keys.sorted() where mask[cell] != 0 {
            let match = owned[cell]!
            let (i, j, k) = (cell % grid.nx, (cell / grid.nx) % grid.ny, cell / (grid.nx * grid.ny))
            for axis in 0..<3 {
                for side in [-1, 1] {
                    var neighbour = SIMD3(i, j, k)
                    neighbour[axis] += side
                    guard grid.contains(neighbour.x, neighbour.y, neighbour.z) else { continue }
                    let fluid = grid.index(neighbour.x, neighbour.y, neighbour.z)
                    guard mask[fluid] == 0 else { continue }
                    faces.append(
                        (
                            Face(
                                solid: UInt32(cell), fluid: UInt32(fluid),
                                axis: UInt32(axis), positive: side > 0 ? 1 : 0),
                            match.owner, match.block
                        ))
                }
            }
        }
        return (faces, geometry)
    }

    func reset() {
        memset(values.contents(), 0, values.length)
        memset(signed.contents(), 0, signed.length)
    }

    func snapshot(grid: Grid, elapsed: Double) -> [EnvelopeExposureSnapshot] {
        let records = values.contents().bindMemory(to: SIMD4<Float>.self, capacity: faces.count)
        let integrals = signed.contents().bindMemory(to: Float.self, capacity: faces.count)
        var result = objects.map {
            EnvelopeExposureSnapshot(
                id: $0.id, name: $0.name,
                elapsedS: elapsed, airCellSizeM: grid.cellSize, surfaces: [])
        }
        for (index, face) in faces.enumerated() {
            let cell = Int(face.solid)
            var point = grid.cellCentre(
                cell % grid.nx, (cell / grid.nx) % grid.ny, cell / (grid.nx * grid.ny))
            var normal = SIMD3<Float>.zero
            normal[Int(face.axis)] = face.positive != 0 ? 1 : -1
            point += normal * (0.5 * grid.cellSize)
            let record = records[index]
            result[owners[index]].surfaces.append(
                EnvelopeSurfaceExposure(
                    positionM: point, normal: normal,
                    areaM2: grid.cellSize * grid.cellSize, overpressurePa: record.x,
                    peakPositivePa: record.y, positiveImpulsePaS: record.z,
                    signedImpulsePaS: integrals[index], invalid: record.w != 0))
        }
        return result
    }

    /// Reduces GPU records without constructing the full per-face geometry on the CPU.
    func summaries(grid: Grid, elapsed: Double) -> [EnvelopeExposureSummary] {
        let records = values.contents().bindMemory(to: SIMD4<Float>.self, capacity: faces.count)
        let integrals = signed.contents().bindMemory(to: Float.self, capacity: faces.count)
        var result = objects.map {
            EnvelopeExposureSummary(
                id: $0.id, name: $0.name,
                elapsedS: elapsed, airCellSizeM: grid.cellSize, faceCount: 0)
        }
        let area = Double(grid.cellSize * grid.cellSize)
        for (index, face) in faces.enumerated() {
            let owner = owners[index]
            result[owner].faceCount += 1
            result[owner].areaM2 += area
            let record = records[index]
            if record.w != 0 {
                result[owner].invalidFaceCount += 1
                continue
            }
            result[owner].validAreaM2 += area
            result[owner].peakPositivePa = max(result[owner].peakPositivePa, record.y)
            result[owner].surfacePositiveImpulseNS += Double(record.z) * area
            let direction: Double = face.positive != 0 ? -1 : 1
            result[owner].forceN[Int(face.axis)] += direction * Double(record.x) * area
            result[owner].signedImpulseNS[Int(face.axis)] += direction * Double(integrals[index]) * area
        }
        return result
    }
}
