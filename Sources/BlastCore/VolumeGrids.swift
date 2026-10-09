import Foundation
import Metal

extension BlastSolver {
    /// The default thresholds below which `volumeGrids` leaves voxels out.
    public static let volumeThresholds = (
        overpressure: Float(0.5), shock: Float(5), peak: Float(0.5), impulse: Float(0.5)
    )
    /// The grids `volumeGrids` can write, and those it writes unless asked for others.
    public static let volumeFields = ["overpressure", "shock", "peak", "impulse"]
    public static let defaultVolumeFields = ["overpressure", "shock"]

    /// The air now as OpenVDB grids, by name:
    /// - `overpressure` in kPa and `shock`, the magnitude of the pressure gradient in kPa/m, which
    ///   picks out the fronts, read from the visualisation volume the app ray-marches;
    /// - `peak`, the highest overpressure each cell has seen so far, in kPa, and `impulse`, its
    ///   positive overpressure integrated over time so far, in Pa·s, read from the solver's own
    ///   fields in full precision.
    /// Voxel centres are the cell centres; solid cells are left out. Voxels below a threshold in
    /// magnitude are left out too, which keeps still air out of the files. Blocks until done; call
    /// it only while no batch is in flight.
    public func volumeGrids(
        fields: [String] = defaultVolumeFields,
        overpressureThreshold: Float = volumeThresholds.overpressure,
        shockThreshold: Float = volumeThresholds.shock
    ) -> [OpenVDBWriter.Grid] {
        let cells = grid.cellCount
        let mask = maskBuffer.contents().bindMemory(to: UInt8.self, capacity: cells)
        let dimensions = SIMD3(grid.nx, grid.ny, grid.nz)
        let h = Double(grid.cellSize)
        let origin = SIMD3(repeating: h / 2)
        func volume(_ name: String, _ values: [Float], _ threshold: Float) -> OpenVDBWriter.Grid {
            OpenVDBWriter.Grid(
                name: name, dimensions: dimensions, voxelSize: h, origin: origin, values: values,
                threshold: threshold)
        }

        var texels: UnsafeMutablePointer<SIMD4<Float16>>?
        var copy: MTLBuffer?
        if fields.contains("overpressure") || fields.contains("shock") {
            refreshVisualization()
            guard let buffer = device.makeBuffer(length: cells * 8, options: .storageModeShared),
                let commandBuffer = commandQueue.makeCommandBuffer(),
                let blit = commandBuffer.makeBlitCommandEncoder()
            else { return [] }
            blit.copy(
                from: visualizationTexture, sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: grid.nx, height: grid.ny, depth: grid.nz),
                to: buffer, destinationOffset: 0,
                destinationBytesPerRow: grid.nx * 8,
                destinationBytesPerImage: grid.nx * grid.ny * 8)
            blit.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            copy = buffer
            // Each texel holds overpressure, peak, impulse and the gradient, pressures over ambient.
            texels = buffer.contents().bindMemory(to: SIMD4<Float16>.self, capacity: cells)
        }
        let kiloPascals = configuration.ambientPressure / 1000
        var grids: [OpenVDBWriter.Grid] = []
        for field in fields {
            var values = [Float](repeating: 0, count: cells)
            switch field {
            case "overpressure":
                for n in 0..<cells where mask[n] == 0 { values[n] = Float(texels![n].x) * kiloPascals }
                grids.append(volume(field, values, overpressureThreshold))
            case "shock":
                let perMetre = kiloPascals / grid.cellSize
                for n in 0..<cells where mask[n] == 0 { values[n] = Float(texels![n].w) * perMetre }
                grids.append(volume(field, values, shockThreshold))
            case "peak", "impulse":
                setFields { peak, impulse in
                    if field == "peak" {
                        for n in 0..<cells where mask[n] == 0 { values[n] = peak[n] / 1000 }
                    } else {
                        for n in 0..<cells where mask[n] == 0 { values[n] = impulse[n] }
                    }
                }
                grids.append(
                    volume(
                        field, values,
                        field == "peak" ? Self.volumeThresholds.peak : Self.volumeThresholds.impulse))
            default:
                preconditionFailure("No volume field \(field)")
            }
        }
        withExtendedLifetime(copy) {}
        return grids
    }
}
