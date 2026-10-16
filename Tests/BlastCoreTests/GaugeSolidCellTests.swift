import Foundation
import Metal
import Testing

@testable import BlastCore

@Suite("Gauges beside solid cells", .serialized, .gpuThreads)
struct GaugeSolidCellTests {
    @Test("A gauge whose cell is solid reads the fluid cell beside it nearest its point, not the stale state")
    func readsNearestFluidNeighbour() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var config = SolverConfiguration()
        config.skipStillAir = false
        config.reflectiveFaces = .all
        let solver = try BlastSolver(
            device: device, grid: Grid(nx: 6, ny: 6, nz: 6, cellSize: 0.5), configuration: config)
        let ambient: Float = 101_325
        // The gauge's cell holds a stale 500 kPa and is solid; the cell beside it towards the
        // gauge's point is 20 kPa over ambient, the one on the other side 40 kPa.
        solver.mutateState { cells in
            for k in 0..<6 {
                for j in 0..<6 {
                    for i in 0..<6 {
                        let over: Float =
                            (i, j, k) == (2, 2, 2)
                            ? 500_000
                            : (i, j, k) == (3, 2, 2)
                                ? 20_000
                                : (i, j, k) == (1, 2, 2) ? 40_000 : 0
                        cells[solver.grid.index(i, j, k)] = CellState(
                            Primitive(density: 1.225, pressure: ambient + over), gamma: 1.4)
                    }
                }
            }
        }
        solver.mutateMask { $0[solver.grid.index(2, 2, 2)] = 1 }
        solver.restart()
        let centre = solver.grid.cellCentre(2, 2, 2)
        solver.setGauges(
            cells: [(2, 2, 2), (4, 4, 4)],
            points: [centre + SIMD3(0.2, 0, 0), solver.grid.cellCentre(4, 4, 4)])
        solver.advance(steps: 1)
        let first = try #require(solver.gaugeHistories[0].first).pressure - ambient
        #expect(abs(first - 20_000) < 2_000, "read \(first) Pa over ambient")
        let open = try #require(solver.gaugeHistories[1].first).pressure - ambient
        #expect(abs(open) < 100, "a gauge in still fluid reads \(open) Pa")
    }
}
