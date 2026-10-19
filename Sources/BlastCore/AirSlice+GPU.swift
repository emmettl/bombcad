import BlastModel
import Foundation
import simd

extension BlastSolver {
    /// The air now over `region`, every `stride`-th cell. Cut out on the GPU if the batch that
    /// ended now was asked for this region and stride (see `frameRequest`); otherwise read from the
    /// state, so call it only while no batch is in flight.
    public func airSlice(region: Box, stride: Int) -> AirSlice {
        let layout = AirSlice.layout(region: region, stride: stride, grid: grid)
        let values =
            frameExtractor?.airValues(layout, time: time, steps: stepCount) ?? cpuAirValues(layout)
        return AirSlice(
            time: time, cellSize: grid.cellSize,
            grid: SIMD3<Int32>(Int32(grid.nx), Int32(grid.ny), Int32(grid.nz)), first: layout.first,
            counts: layout.counts, stride: layout.stride, values: values,
            ambient: Primitive(density: ambientDensity, pressure: configuration.ambientPressure))
    }

    /// The samples of `layout`, read from the state on the CPU.
    func cpuAirValues(_ layout: AirSlice.Layout) -> [Float16] {
        let (nx, ny, nz) = (Int(layout.counts.x), Int(layout.counts.y), Int(layout.counts.z))
        let (low, stride) = (layout.first, layout.stride)
        var values = [Float16](repeating: 0, count: 5 * nx * ny * nz)
        // A row of samples at a time, spread across the CPU's cores: each lands in its own place,
        // so the slice is the same however the rows are shared out.
        let gamma = configuration.gamma
        let airModel = configuration.airModel
        withState { cells in
            values.withUnsafeMutableBufferPointer { values in
                concurrently(iterations: ny * nz) { row in
                    let (j, k) = (row % ny, row / ny)
                    var n = 5 * nx * row
                    for i in 0..<nx {
                        let cell = low &+ SIMD3<Int32>(Int32(i), Int32(j), Int32(k)) &* stride
                        let state = Self.primitive(
                            of: cells[grid.index(Int(cell.x), Int(cell.y), Int(cell.z))], gamma: gamma,
                            airModel: airModel)
                        values[n] = Float16(state.density)
                        values[n + 1] = Float16(state.velocity.x)
                        values[n + 2] = Float16(state.velocity.y)
                        values[n + 3] = Float16(state.velocity.z)
                        values[n + 4] = Float16(state.pressure / 1e6)
                        n += 5
                    }
                }
            }
        }
        return values
    }
}
