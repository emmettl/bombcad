import Foundation
import Metal
import Testing
import simd

@testable import BlastCore
@testable import BlastModel

@Suite("Ground shock", .gpuThreads)
struct GroundShockTests {
    @Test("A ground slice gives back the solver's ground, solid cells left out")
    func slice() throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
        let scenario = Scenario(
            name: "Ground", domainSize: SIMD3(8, 8, 4), boxes: [Box(x: 4...6, y: 4...6, height: 2)],
            charge: Charge(mass: 0, position: SIMD3(1, 1, 1)))
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.5)
        // Pressure rising along x on the ground; peak and impulse rising along y.
        solver.mutateState { cells in
            for j in 0..<16 {
                for i in 0..<16 {
                    cells[solver.grid.index(i, j, 0)] = CellState(
                        Primitive(density: 1.225, pressure: 101_325 + Float(i) * 1000), gamma: 1.4)
                }
            }
        }
        solver.setFields { peak, impulse in
            for j in 0..<16 {
                for i in 0..<16 {
                    peak[solver.grid.index(i, j, 0)] = 5000 + Float(j) * 100
                    impulse[solver.grid.index(i, j, 0)] = 10 + Float(j)
                }
            }
        }
        let slice = solver.groundSlice(low: SIMD2(1, 1), high: SIMD2(7, 7))
        #expect(slice.first == SIMD2(2, 2) && slice.counts == SIMD2(13, 13))
        // Halfway between cells 3 and 4 along x (centres 1.75 and 2.25 m), on cell 5 along y.
        let open = try #require(slice.sample(SIMD2(2, 2.75)))
        #expect(abs(open.overpressure - 3500) < 1 && open.peak == 5500 && open.impulse == 15)
        #expect(slice.sample(SIMD2(5, 5)) == nil, "Under the block there is no open ground.")
        // Beside the block, its open neighbours alone.
        let edge = try #require(slice.sample(SIMD2(4, 5)))
        #expect(abs(edge.overpressure - 7000) < 1)
        // Beyond the slice but within the grid: unknown.
        #expect(slice.sample(SIMD2(0.2, 3)) == nil)
        let restored = try GroundSlice(header: slice.header, payload: slice.payload)
        #expect(restored.header == slice.header)
        #expect(zip(restored.values, slice.values).allSatisfy { $0 == $1 || ($0.isNaN && $1.isNaN) })
        #expect(throws: CocoaError.self) {
            try GroundSlice(header: slice.header, payload: slice.payload.dropLast(4))
        }
    }
}
