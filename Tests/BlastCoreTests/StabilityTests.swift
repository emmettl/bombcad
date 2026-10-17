import Foundation
import Metal
import Testing

@testable import BlastCore

@Suite("Stability")
struct StabilityTests {
    @Test("A NaN in the air makes the batch unstable, though its step reaches the time limit")
    func nanStops() throws {
        let scene = Scenario(
            name: "Open", domainSize: SIMD3(8, 8, 4), boxes: [],
            charge: Charge(mass: 0.05, position: SIMD3(4, 4, 0)))
        let solver = try BlastSolver(
            device: #require(MTLCreateSystemDefaultDevice()), scenario: scene, cellSize: 0.25)
        #expect(solver.advance(steps: 4).isStable)
        let index = solver.grid.index(20, 20, 2)
        solver.mutateState { $0[index].energy = .nan }
        // The wave speed is NaN, so the step runs to the limit: only the overpressure says so.
        #expect(!solver.advance(until: 0.05).isStable)
    }
}
