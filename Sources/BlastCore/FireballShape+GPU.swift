import BlastModel
import Foundation
import simd

extension BlastSolver {
    /// The luminous gas in blocks of two cells a side, read from the state on the CPU as the GPU's
    /// `extractFireballBlocks` sums it, spread across the CPU's cores.
    func cpuLuminousBlocks(luminousTemperature: Float) -> [LuminousBlock] {
        let (nx, ny, nz) = (grid.nx, grid.ny, grid.nz)
        let dims = LuminousBlock.dimensions(grid)
        let gamma = configuration.gamma
        let airModel = configuration.airModel
        let mask = maskContents.bindMemory(to: UInt8.self, capacity: grid.cellCount)
        var planes = [[LuminousBlock]](repeating: [], count: dims.z)
        withState { cells in
            planes.withUnsafeMutableBufferPointer { planes in
                concurrently(iterations: dims.z) { bk in
                    var plane: [LuminousBlock] = []
                    for bj in 0..<dims.y {
                        for bi in 0..<dims.x {
                            var block = LuminousBlock(
                                index: bi + dims.x * (bj + dims.y * bk), cells: 0, fourth: 0, hottest: 0,
                                position: .zero, air: 0)
                            for k in 2 * bk..<min(2 * bk + 2, nz) {
                                for j in 2 * bj..<min(2 * bj + 2, ny) {
                                    for i in 2 * bi..<min(2 * bi + 2, nx) {
                                        let index = grid.index(i, j, k)
                                        guard mask[index] == 0 else { continue }
                                        block.air += 1
                                        let air = Self.primitive(
                                            of: cells[index], gamma: gamma, airModel: airModel)
                                        // Dissociating air is never hotter than this, so it bounds
                                        // the search.
                                        let bound = air.pressure / (air.density * AirModel.gasConstant)
                                        guard bound >= luminousTemperature else { continue }
                                        let t =
                                            airModel == .dissociating
                                            ? airModel.temperature(
                                                density: air.density, pressure: air.pressure)
                                            : bound
                                        guard t >= luminousTemperature, t.isFinite else { continue }
                                        block.cells += 1
                                        block.position += SIMD3(Float(i), Float(j), Float(k)) + 0.5
                                        let square = t * t
                                        block.fourth += square * square
                                        block.hottest = max(block.hottest, t)
                                    }
                                }
                            }
                            if block.cells > 0 { plane.append(block) }
                        }
                    }
                    planes[bk] = plane
                }
            }
        }
        return planes.flatMap { $0 }
    }
}
