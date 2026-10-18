import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

/// Structures brought to rest under their own weight before the blast
/// (`BlastSolver.settleStructures()`).
@Suite("Settling under own weight", .gpuThreads)
struct SettleTests {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    /// A 1.5 m cantilever, 100 mm thick, clamped at its root; no charge.
    private func scenario() -> Scenario {
        var model = StructureModel(
            solids: [Box(min: SIMD3(0.25, 0.5, 1.0), max: SIMD3(2.0, 0.6, 1.1))],
            material: .elastic(density: 2400, youngsModulus: 20e9, poissonRatio: 0.2), elementSize: 0.05,
            fixedBase: false)
        model.supports = [Box(min: SIMD3(0.2, 0.4, 0.9), max: SIMD3(0.5, 0.7, 1.2))]
        return Scenario(
            name: "Cantilever", domainSize: SIMD3(2.5, 1.0, 2.0), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(2.2, 0.5, 0.5)), structure: model)
    }

    /// The tip's vertical displacement at the free end's middle node.
    private func tip(_ structure: StructureSolver) -> Float {
        structure.displacement(structure.ex, structure.ey / 2, structure.ez / 2).z
    }

    /// The farthest the tip goes from `rest` over 30 ms of the coupled run.
    private func swing(_ solver: BlastSolver, from rest: Float) throws -> Float {
        let structure = try #require(solver.structure)
        var furthest: Float = 0
        while solver.time < 0.03 {
            #expect(solver.advance(steps: 4, timeLimit: 0.03).isStable)
            furthest = max(furthest, abs(tip(structure) - rest))
        }
        return furthest
    }

    @Test("Settled, a cantilever stays at rest until loaded; from rest it swings about its sag")
    func settledCantilever() throws {
        let scenario = scenario()
        let settled = try BlastSolver(device: device, scenario: scenario, cellSize: 0.25)
        let structure = try #require(settled.structure)
        settled.settleStructures()
        let settlement = try #require(settled.settlements.first)
        #expect(settled.settlements.count == 1 && settlement.settled)
        #expect(settled.time == 0 && structure.time == 0)
        var fastest: Float = 0
        structure.mutateNodes { nodes in fastest = nodes.map { simd_length($0.velocity) }.max() ?? 0 }
        #expect(fastest == 0)
        let rest = tip(structure)
        #expect(rest < -0.0003, "sag \(rest * 1000) mm")
        // Deflection is measured from the settled shape, reading zero before the blast; the sag is
        // reported on its own, and as the settlement's displacement.
        let summary = structure.summary()
        #expect(summary.maxDisplacement == 0)
        #expect(summary.selfWeightSag >= abs(rest) && settlement.displacement == summary.selfWeightSag)
        let still = try swing(settled, from: rest)
        #expect(still < 0.1 * abs(rest), "settled: \(still * 1000) mm off rest, sag \(rest * 1000) mm")

        var configuration = SolverConfiguration()
        configuration.settlesStructures = false
        let fromRest = try BlastSolver(
            device: device, scenario: scenario, cellSize: 0.25, configuration: configuration)
        let unsettled = try #require(fromRest.structure)
        fromRest.settleStructures()
        #expect(fromRest.settlements.isEmpty && !fromRest.structuresSettled)
        #expect(unsettled.summary().maxDisplacement == 0 && unsettled.summary().selfWeightSag == 0)
        let swinging = try swing(fromRest, from: rest)
        #expect(
            swinging > 0.5 * abs(rest), "from rest: \(swinging * 1000) mm off rest, sag \(rest * 1000) mm")
    }

    @Test("A body without gravity is not settled, and a falling one starts undeformed")
    func leftAlone() throws {
        var scenario = scenario()
        let weightless = try BlastSolver(device: device, scenario: scenario, cellSize: 0.25)
        try #require(weightless.structure).gravity = 0
        weightless.settleStructures()
        #expect(weightless.settlements.isEmpty && weightless.structuresSettled)

        // Unsupported, the cantilever falls; it is put back as it was.
        scenario.structure?.supports = []
        let falling = try BlastSolver(device: device, scenario: scenario, cellSize: 0.25)
        falling.settleStructures()
        let settlement = try #require(falling.settlements.first)
        #expect(!settlement.settled)
        #expect(try #require(falling.structure).summary().maxDisplacement == 0)
    }
}
