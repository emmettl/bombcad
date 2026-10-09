import Foundation
import Metal

/// A horizontal plane of fixed Eulerian probes, sampled after each complete air step.
/// Pressure is trilinearly interpolated from coarse cell centres at fixed physical points.
/// Values include restricted fine state, rather than fine-cell maxima.
/// Arrival is the first endpoint at or above an absolute overpressure threshold.
public struct ExposurePlaneSnapshot: Codable, Sendable {
    public var nx: Int
    public var ny: Int
    public var cellSizeM: Float
    public var airCellSizeM: Float
    public var heightM: Float
    public var thresholdPa: Float
    public var elapsedS: Double
    public var peakPa: [Float?]
    public var positiveImpulsePaS: [Float?]
    public var arrivalS: [Float?]
    /// A stencil that ever included a solid cell is excluded from all three maps.
    public var everSolid: [Bool]
}

final class ExposurePlane {
    let layer: Int
    let nx: Int
    let ny: Int
    let spacing: Float
    let threshold: Float
    let height: Float
    let weight: Float
    let buffer: MTLBuffer
    let pipeline: MTLComputePipelineState

    init(device: MTLDevice, library: MTLLibrary, grid: Grid, height: Float, threshold: Float, spacing: Float?)
        throws
    {
        let spacing = spacing ?? grid.cellSize
        guard spacing.isFinite, spacing > 0,
            grid.size.x / spacing < Float(Int32.max), grid.size.y / spacing < Float(Int32.max)
        else { throw BlastError.allocationFailed("valid exposure probe spacing") }
        nx = max(1, Int((grid.size.x / spacing).rounded()))
        ny = max(1, Int((grid.size.y / spacing).rounded()))
        guard height.isFinite, height >= 0.5 * grid.cellSize, height <= grid.size.z - 0.5 * grid.cellSize,
            threshold.isFinite, threshold > 0,
            abs(Float(nx) * spacing - grid.size.x) < 1e-5,
            abs(Float(ny) * spacing - grid.size.y) < 1e-5,
            let buffer = device.makeBuffer(length: nx * ny * 16, options: .storageModeShared)
        else { throw BlastError.allocationFailed("valid exposure plane") }
        let coordinate = min(max(height / grid.cellSize - 0.5, 0), Float(grid.nz - 1))
        layer = Int(coordinate.rounded(.down))
        weight = coordinate - Float(layer)
        self.height = height
        self.spacing = spacing
        self.threshold = threshold
        self.buffer = buffer
        pipeline = try ShaderLibrary.pipeline("sampleExposurePlane", in: library)
        reset()
    }

    func reset() {
        buffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: buffer.length / 16)
            .update(repeating: SIMD4(0, 0, -1, 0), count: buffer.length / 16)
    }

    func snapshot(grid: Grid, elapsed: Double) -> ExposurePlaneSnapshot {
        let records = buffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: nx * ny)
        let rows = Array(UnsafeBufferPointer(start: records, count: nx * ny))
        return ExposurePlaneSnapshot(
            nx: nx, ny: ny, cellSizeM: spacing, airCellSizeM: grid.cellSize,
            heightM: height, thresholdPa: threshold,
            elapsedS: elapsed,
            peakPa: rows.map { $0.w != 0 ? nil : $0.x },
            positiveImpulsePaS: rows.map { $0.w != 0 ? nil : $0.y },
            arrivalS: rows.map { $0.w != 0 || $0.z < 0 ? nil : $0.z },
            everSolid: rows.map { $0.w != 0 })
    }
}
