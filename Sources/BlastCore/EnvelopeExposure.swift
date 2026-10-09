import Foundation
import Metal
import simd

/// Compact diagnostics for one stationary building. The positive scalar sum includes every
/// valid interior/exterior face; it is not a resultant vector impulse or structural reaction.
public struct EnvelopeExposureSummary: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var elapsedS: Double
    public var airCellSizeM: Float
    public var faceCount: Int
    public var invalidFaceCount = 0
    public var areaM2: Double = 0
    public var validAreaM2: Double = 0
    public var peakPositivePa: Float = 0
    public var surfacePositiveImpulseNS: Double = 0
    public var forceN = SIMD3<Double>.zero
    public var signedImpulseNS = SIMD3<Double>.zero

    public var meanPositiveImpulsePaS: Double? {
        validAreaM2 > 0 ? surfacePositiveImpulseNS / validAreaM2 : nil
    }
}

public struct EnvelopeSurfaceExposure: Codable, Sendable {
    public var positionM: SIMD3<Float>
    /// Outward from solid into air. Pressure force on the solid is -p A n.
    public var normal: SIMD3<Float>
    public var areaM2: Float
    public var overpressurePa: Float
    public var peakPositivePa: Float
    public var positiveImpulsePaS: Float
    public var signedImpulsePaS: Float
    public var invalid: Bool
}

public struct EnvelopeExposureSnapshot: Codable, Sendable {
    public var id: UUID
    public var name: String
    public var elapsedS: Double
    public var airCellSizeM: Float
    public var surfaces: [EnvelopeSurfaceExposure]
    /// Includes both interior and exterior resolved faces, excluding domain boundaries.
    public var forceN: SIMD3<Double> {
        surfaces.filter { !$0.invalid }.reduce(.zero) {
            $0 - SIMD3<Double>($1.normal) * Double($1.overpressurePa * $1.areaM2)
        }
    }
    public var signedImpulseNS: SIMD3<Double> {
        surfaces.filter { !$0.invalid }.reduce(.zero) {
            $0 - SIMD3<Double>($1.normal) * Double($1.signedImpulsePaS * $1.areaM2)
        }
    }
}

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

    init(
        device: MTLDevice, library: MTLLibrary, grid: Grid, mask: UnsafeBufferPointer<UInt8>,
        objects: [SceneObject]
    ) throws {
        guard !objects.isEmpty, Set(objects.map(\.id)).count == objects.count else {
            throw BlastError.allocationFailed("unique stationary envelope observer owners")
        }
        let geometry = try objects.map { object -> BuildingEnvelope in
            if let envelope = object.envelope { return envelope }
            guard let body = object.structure else { throw SceneObjectError.unsupportedRepresentation }
            return try BuildingEnvelope(solids: body.solids, openings: body.openings)
        }
        let blocks = geometry.map(\.blocks)
        var faces: [Face] = []
        var owners: [Int] = []
        for k in 0..<grid.nz {
            for j in 0..<grid.ny {
                for i in 0..<grid.nx {
                    let cell = grid.index(i, j, k)
                    guard mask[cell] != 0 else { continue }
                    let point = grid.cellCentre(i, j, k)
                    let matches = blocks.indices.filter { owner in
                        blocks[owner].contains { $0.contains(point) }
                    }
                    guard matches.count <= 1 else { throw SceneObjectError.interObjectContact }
                    guard let owner = matches.first else { continue }
                    for axis in 0..<3 {
                        for side in [-1, 1] {
                            var neighbour = SIMD3(i, j, k)
                            neighbour[axis] += side
                            guard grid.contains(neighbour.x, neighbour.y, neighbour.z) else { continue }
                            let fluid = grid.index(neighbour.x, neighbour.y, neighbour.z)
                            guard mask[fluid] == 0 else { continue }
                            faces.append(
                                Face(
                                    solid: UInt32(cell), fluid: UInt32(fluid),
                                    axis: UInt32(axis), positive: side > 0 ? 1 : 0))
                            owners.append(owner)
                        }
                    }
                }
            }
        }
        guard !faces.isEmpty, Set(owners).count == objects.count,
            let faceBuffer = device.makeBuffer(bytes: faces, length: faces.count * MemoryLayout<Face>.stride),
            let values = device.makeBuffer(length: faces.count * 16, options: .storageModeShared),
            let signed = device.makeBuffer(length: faces.count * 4, options: .storageModeShared)
        else { throw BlastError.allocationFailed("resolved envelope faces for every owner") }
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
