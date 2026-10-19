import BlastModel
import Foundation
import Metal
import simd

/// The cut cells' buffers on the GPU, bound to the sweeps at 20 to 23.
final class TerrainCutBuffers {
    let geometry: TerrainCutGeometry
    let columns: MTLBuffer
    let records: MTLBuffer
    let walls: MTLBuffer
    /// Each cut cell's difference over the step so far: mass and momentum, then fuel, oxygen and energy.
    let defects: MTLBuffer
    let cutColumns: MTLBuffer
    /// `geometry.tileCeilings` for the sweeps' tiles.
    let ceilings: MTLBuffer

    init(geometry: TerrainCutGeometry, device: MTLDevice) throws {
        func buffer<T>(_ values: [T], _ label: String) throws -> MTLBuffer {
            let length = max(values.count * MemoryLayout<T>.stride, 16)
            guard let made = device.makeBuffer(length: length, options: .storageModeShared) else {
                throw BlastError.allocationFailed(label)
            }
            values.withUnsafeBytes { bytes in
                if let base = bytes.baseAddress {
                    made.contents().copyMemory(from: base, byteCount: bytes.count)
                }
            }
            made.label = label
            return made
        }
        self.geometry = geometry
        columns = try buffer(geometry.columns, "cut-cell columns")
        records = try buffer(geometry.records, "cut-cell records")
        walls = try buffer(geometry.walls, "cut-cell walls")
        defects = try buffer(
            [SIMD4<Float>](repeating: .zero, count: 2 * geometry.records.count), "cut-cell differences")
        cutColumns = try buffer(geometry.cutColumns, "columns with cut cells")
        ceilings = try buffer(geometry.tileCeilings(tileSize: BlastSolver.tileSize), "cut cells' ceilings")
    }
}
