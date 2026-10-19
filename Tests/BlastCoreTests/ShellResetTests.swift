import Foundation
import Metal
import Testing

@testable import BlastCore

/// `ShellSolver.reset()` puts the structure back as built, its connections' state too: their
/// yielding and release live in the load table, which only the solver's construction wrote.
@Suite("A shell structure reset", .gpuThreads)
struct ShellResetTests {
    @Test("A spring support pulled off its edge is whole again after a reset, and pulls off again")
    func springSupportReset() throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "This test needs a Metal device")
        let elastic = StructureMaterial.elastic(density: 7850, youngsModulus: 210e9, poissonRatio: 0.3)
        var model = StructureModel(
            solids: [Box(min: SIMD3(0, -0.01, 0), max: SIMD3(1, 0.01, 1))], material: elastic,
            elementSize: 0.1, fixedBase: false)
        model.elementKind = .shell
        model.shellLayers = 4
        // Its foot held along and turning, but across by a spring that gives way to nothing at
        // 100 N per metre, and then lets the edge go.
        let stiff = SpringLaw(stiffness: 1e10)
        let weak = SpringLaw(stiffness: 1e6, yield: 100, hardening: -1e6)
        model.springSupports = [
            SpringSupport(
                region: Box(min: SIMD3(-0.01, -0.02, -0.005), max: SIMD3(1.01, 0.02, 0.005)), edge: 0,
                along: 2, pull: stiff, across: weak, turnPositive: stiff, turnNegative: stiff,
                releases: true)
        ]
        let solver = try ShellSolver(device: device, model: model)
        solver.groundContact = false
        solver.gravity = 0
        // 1 kPa across the plate, 1 kN on its foot's 1 m: ten times what the spring holds.
        func push() {
            solver.appliedLoad = PressureLoad(
                axis: 1, positiveSide: true, history: [SIMD2(0, 1000), SIMD2(100, 1000)])
            while solver.releasedSpringShare() < 1, solver.time < 0.2 {
                solver.advance(steps: 200)
            }
        }
        push()
        #expect(solver.releasedSpringShare() == 1)
        solver.reset()
        #expect(solver.releasedSpringShare() == 0)
        push()
        #expect(solver.releasedSpringShare() == 1)
    }
}
