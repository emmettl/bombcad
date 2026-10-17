import Foundation
import Metal
import Testing

@testable import BlastCore

@Suite("Terraced houses", .gpuThreads)
struct TerracedHousesTests {
    @Test("The row meshes with both leaves of its cavity walls apart and its floors as timber shells")
    func meshes() throws {
        let scenario = ScenarioPreset.terracedHouses.scenario
        let model = try #require(scenario.structure)
        #expect(model.isAllShells)
        let mesh = try ShellMesh(model: model)
        // The front wall's two leaves stay two planes, 152.5 mm apart.
        let fronts = Set(mesh.elements.filter { $0.axis == 0 }.map { mesh.positions[Int($0.nodes[0])].x })
            .filter { $0 < 17 }
        #expect(fronts.count == 2, "front planes \(fronts.sorted())")
        let timber = mesh.elements.filter { model.materials[$0.material].model == .timber }
        #expect(timber.count > 0 && timber.allSatisfy { $0.axis == 2 })
        let standing = SceneStanding(
            StandingInputs(scenario: scenario, cellSize: 0.25, configuration: .recommended))
        #expect(
            standing.results.contains { result in result.evidence.contains { $0.check.contains("timber") } })
    }

    @Test("A street charge loads the row without the timber or the masonry blowing up")
    func runs() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let solver = try BlastSolver(
            device: device, scenario: ScenarioPreset.terracedHouses.scenario, cellSize: 0.5,
            configuration: .recommended)
        let result = solver.advance(until: 0.04)
        #expect(result.isStable)
        let summary = try #require(solver.bodies.first?.summary())
        #expect(!summary.hasBlownUp)
        #expect(summary.maxDisplacement > 0.001, "front wall moved \(summary.maxDisplacement * 1000) mm")
    }
}
