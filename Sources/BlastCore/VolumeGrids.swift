import Foundation
import Metal

extension BlastSolver {
    /// The default thresholds below which `volumeGrids` leaves voxels out.
    public static let volumeThresholds = (overpressure: Float(0.5), shock: Float(5))

    /// The air now as two OpenVDB grids, read from the visualisation volume the app ray-marches:
    /// `overpressure` in kPa, and `shock`, the magnitude of the pressure gradient in kPa/m, which
    /// picks out the fronts. Voxel centres are the cell centres; solid cells are left out. Voxels
    /// below a threshold in magnitude are left out too, which keeps still air out of the files.
    /// Blocks until done; call it only while no batch is in flight.
    public func volumeGrids(
        overpressureThreshold: Float = volumeThresholds.overpressure,
        shockThreshold: Float = volumeThresholds.shock
    ) -> [OpenVDBWriter.Grid] {
        refreshVisualization()
        let cells = grid.cellCount
        guard let buffer = device.makeBuffer(length: cells * 8, options: .storageModeShared),
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let blit = commandBuffer.makeBlitCommandEncoder()
        else { return [] }
        blit.copy(
            from: visualizationTexture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: grid.nx, height: grid.ny, depth: grid.nz), to: buffer,
            destinationOffset: 0,
            destinationBytesPerRow: grid.nx * 8, destinationBytesPerImage: grid.nx * grid.ny * 8)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // Each texel holds overpressure, peak, impulse and the gradient, the pressures over ambient.
        let texels = buffer.contents().bindMemory(to: SIMD4<Float16>.self, capacity: cells)
        let mask = maskBuffer.contents().bindMemory(to: UInt8.self, capacity: cells)
        let kiloPascals = configuration.ambientPressure / 1000
        let perMetre = kiloPascals / grid.cellSize
        var overpressure = [Float](repeating: 0, count: cells)
        var shock = [Float](repeating: 0, count: cells)
        for n in 0..<cells where mask[n] == 0 {
            overpressure[n] = Float(texels[n].x) * kiloPascals
            shock[n] = Float(texels[n].w) * perMetre
        }
        let dimensions = SIMD3(grid.nx, grid.ny, grid.nz)
        let h = Double(grid.cellSize)
        let origin = SIMD3(repeating: h / 2)
        return [
            OpenVDBWriter.Grid(
                name: "overpressure", dimensions: dimensions, voxelSize: h, origin: origin,
                values: overpressure,
                threshold: overpressureThreshold),
            OpenVDBWriter.Grid(
                name: "shock", dimensions: dimensions, voxelSize: h, origin: origin, values: shock,
                threshold: shockThreshold),
        ]
    }
}
