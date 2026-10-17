import Foundation
import Metal
import Testing

@testable import BlastCore

@Suite("Blocks thinner than a cell", .serialized, .gpuThreads)
struct ThinBlockTests {
    @Test(
        "A wall thinner than a cell, between two cell centres, still takes a layer of cells; a thicker one is unchanged"
    )
    func thinWallTakesCells() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        // On 0.5 m cells a 0.2 m wall at x 2.8–3.0 lies between the centres 2.75 and 3.25.
        let thin = Box(min: SIMD3(2.8, 0, 0), max: SIMD3(3.0, 4, 2))
        let thick = Box(min: SIMD3(5.0, 0, 0), max: SIMD3(5.6, 4, 2))
        #expect(thin.holdingCells(of: 0.5) == Box(min: SIMD3(2.5, 0, 0), max: SIMD3(3.0, 4, 2)))
        #expect(thick.holdingCells(of: 0.5) == thick)
        let scenario = Scenario(
            name: "Thin wall", domainSize: SIMD3(8, 4, 3), boxes: [thin, thick],
            charge: Charge(mass: 1, position: SIMD3(1, 2, 1)))
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.5)
        // The thin wall's middle, x = 2.9, lies in cell 5 (2.5–3.0): a whole layer of it is solid.
        #expect((0..<8).allSatisfy { j in (0..<4).allSatisfy { k in solver.isSolid(5, j, k) } })
        #expect(!solver.isSolid(4, 2, 1) && !solver.isSolid(6, 2, 1))
        // The thick wall holds the centres 5.25: cell 10 alone, as before.
        #expect(solver.isSolid(10, 2, 1) && !solver.isSolid(9, 2, 1) && !solver.isSolid(11, 2, 1))
    }
}
