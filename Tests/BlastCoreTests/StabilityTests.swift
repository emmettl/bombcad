import Foundation
import Metal
import Testing

@testable import BlastCore
@testable import BlastModel

@Suite("Stability")
struct StabilityTests {
    @Test("A NaN in the air stops the batch where it is, unstable, not at the time limit")
    func nanStops() throws {
        let scene = Scenario(
            name: "Open", domainSize: SIMD3(8, 8, 4), boxes: [],
            charge: Charge(mass: 0.05, position: SIMD3(4, 4, 0)))
        let solver = try BlastSolver(
            device: #require(MTLCreateSystemDefaultDevice()), scenario: scene, cellSize: 0.25)
        #expect(solver.advance(steps: 4).isStable)
        let index = solver.grid.index(20, 20, 2)
        solver.mutateState { $0[index].energy = .nan }
        let before = solver.time
        // The NaN wave speed outranks every real one, and the step it would set reaches the time
        // limit: the batch stops at the step after the NaN, which does nothing.
        #expect(!solver.advance(until: 0.05).isStable)
        #expect(solver.time < before + 0.001, "\(solver.time) s")
    }
}
