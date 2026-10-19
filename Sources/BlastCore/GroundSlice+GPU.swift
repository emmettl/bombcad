import BlastModel
import Foundation
import simd

extension BlastSolver {
    /// The air now on the ground under the rectangle from `low` to `high`, (x, y) in metres: in
    /// each column the first cell of air above the terrain, or the bottom cell on flat ground.
    /// Reads the state and fields directly, so call it only while no batch is in flight.
    public func groundSlice(low: SIMD2<Float>, high: SIMD2<Float>) -> GroundSlice {
        let h = grid.cellSize
        let dims = SIMD2<Int32>(Int32(grid.nx), Int32(grid.ny))
        let first = simd_clamp(SIMD2<Int32>((low / h).rounded(.down)), .zero, dims &- 1)
        let last = simd_clamp(SIMD2<Int32>((high / h).rounded(.down)), first, dims &- 1)
        let counts = last &- first &+ 1
        let (nx, ny) = (Int(counts.x), Int(counts.y))
        var values = [Float](repeating: .nan, count: 3 * nx * ny)
        let gamma = configuration.gamma
        let airModel = configuration.airModel
        let ambient = configuration.ambientPressure
        let mask = maskContents.bindMemory(to: UInt8.self, capacity: grid.cellCount)
        let terrain = terrainSurface
        let grid = grid
        withState { cells in
            setFields { peak, impulse in
                values.withUnsafeMutableBufferPointer { values in
                    // A row at a time across the CPU's cores, a whole grid's ground being read for a
                    // viewer each frame; each value lands in its own place, so the slice is the same
                    // however the rows are shared out.
                    concurrently(iterations: ny) { j in
                        for i in 0..<nx {
                            let column = Int(first.x) + i + grid.nx * (Int(first.y) + j)
                            let surface = min(Int(terrain?[column] ?? 0), grid.nz - 1)
                            let cell = grid.index(Int(first.x) + i, Int(first.y) + j, surface)
                            guard mask[cell] == 0 else { continue }
                            let n = 3 * (i + nx * j)
                            values[n] =
                                Self.primitive(of: cells[cell], gamma: gamma, airModel: airModel).pressure
                                - ambient
                            values[n + 1] = peak[cell]
                            values[n + 2] = impulse[cell]
                        }
                    }
                }
            }
        }
        return GroundSlice(
            time: time, cellSize: h, grid: SIMD3(Int32(grid.nx), Int32(grid.ny), Int32(grid.nz)),
            first: first,
            counts: counts, values: values, ambientDensity: ambientDensity, ambientPressure: ambient,
            gamma: gamma)
    }
}
