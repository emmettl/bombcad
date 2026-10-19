import Foundation
import Metal
import Testing
import simd

@testable import BlastCore
@testable import BlastModel

@Suite("Fragments and air slices", .gpuThreads)
struct FragmentCloudTests {
    @Test("A slice of the solver's air gives back its state, every cell or every second")
    func slice() throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
        let scenario = Scenario(
            name: "Slice", domainSize: SIMD3(8, 8, 8), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(1, 1, 1)))
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.5)
        // Density rising along x, a wind along y.
        solver.mutateState { cells in
            for k in 0..<16 {
                for j in 0..<16 {
                    for i in 0..<16 {
                        cells[solver.grid.index(i, j, k)] = CellState(
                            Primitive(density: 1 + Float(i) * 0.1, velocity: SIMD3(0, 20, 0), pressure: 2e5),
                            gamma: 1.4)
                    }
                }
            }
        }
        for stride in [1, 2] {
            let slice = solver.airSlice(region: Box(min: SIMD3(1, 1, 1), max: SIMD3(6, 6, 6)), stride: stride)
            // Cell 5's centre is at 2.75 m: halfway to cell 6, 0.15 below cell 6's density.
            let air = try #require(slice.sample(SIMD3(3.0, 3, 3)))
            #expect(abs(air.density - 1.55) < 0.01)
            #expect(abs(air.velocity.y - 20) < 0.05 && abs(air.pressure - 2e5) < 200)
            // Outside the slice but inside the domain: unknown. Outside the domain: still air.
            #expect(slice.sample(SIMD3(7.8, 3, 3)) == nil)
            #expect(slice.sample(SIMD3(-1, 3, 3)) == slice.ambient)
        }
    }
}
