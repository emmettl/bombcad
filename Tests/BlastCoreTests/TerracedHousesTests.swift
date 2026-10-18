import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

@Suite("Terraced houses", .gpuThreads)
struct TerracedHousesTests {
    @Test("The row meshes with both leaves of its cavity walls apart and its floors as timber shells")
    func meshes() throws {
        let scenario = ScenarioPreset.terracedRow(title: "Terraced row", faceClearance: 0)
        let model = try #require(scenario.structure)
        #expect(model.isAllShells)
        // The preset's domain keeps its open faces clear of the charge and the row.
        #expect(ScenarioPreset.terracedHouses.scenario.tightOpenFaces.isEmpty)
        let mesh = try ShellMesh(model: model)
        // The front wall's two leaves stay two planes, 152.5 mm apart.
        let fronts = Set(mesh.elements.filter { $0.axis == 0 }.map { mesh.positions[Int($0.nodes[0])].x })
            .filter { $0 < 17 }
        #expect(fronts.count == 2, "front planes \(fronts.sorted())")
        // Each leaf of the front shields the other's face across the cavity, and nothing else.
        let shields = mesh.shields()
        let front = mesh.elements.indices.filter {
            mesh.elements[$0].axis == 0 && mesh.positions[Int(mesh.elements[$0].nodes[0])].x < 17
        }
        let outer = front.filter { mesh.positions[Int(mesh.elements[$0].nodes[0])].x < 16.1 }
        let inner = front.filter { mesh.positions[Int(mesh.elements[$0].nodes[0])].x > 16.1 }
        // The outer leaf runs on past the inner one at the corners.
        #expect(outer.allSatisfy { shields[$0].below < 0 })
        #expect(outer.filter { shields[$0].above >= 0 }.count > outer.count * 9 / 10)
        #expect(inner.filter { shields[$0].below >= 0 }.count > inner.count * 9 / 10)
        #expect(inner.allSatisfy { shields[$0].above < 0 })

        let timber = mesh.elements.filter { model.materials[$0.material].model == .timber }
        #expect(timber.count > 0 && timber.allSatisfy { $0.axis == 2 })
        let standing = SceneStanding(
            // Pinned to the balloon until rerun on the mapped start (validation.md, "Still on the balloon start").
            StandingInputs(scenario: scenario, cellSize: 0.25, configuration: .recommended.balloonStart))
        #expect(
            standing.results.contains { result in result.evidence.contains { $0.check.contains("timber") } })
    }

    @Test(
        "The row settles on its seats, covering on roof and walls, ties idle; then a charge loads it, nothing blowing up"
    )
    func settlesAndRuns() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let solver = try BlastSolver(
            device: device, scenario: ScenarioPreset.terracedRow(title: "Terraced row", faceClearance: 0),
            cellSize: 0.5,
            // Pinned to the balloon until rerun on the mapped start (validation.md, "Still on the balloon start").
            configuration: .recommended.balloonStart)
        solver.settleStructures()
        #expect(solver.settlements.allSatisfy { $0.settled })
        let shells = try #require(solver.bodies.first?.shells)
        let model = shells.model
        func weight(_ solid: Int) -> Float {
            let box = model.solids[solid]
            let size = box.max - box.min
            return size.x * size.y * size.z * model.material(of: solid).density * 9.81
        }
        var floors: Float = 0
        var roofs: Float = 0
        var ties: Float = 0
        var covering: Float = 0
        for index in model.supports.indices {
            let law = try #require(model.anchorage(ofSupport: index))
            let force = try #require(shells.pairSummary(support: index)).force
            if law.closingGap != nil {
                ties += simd_length(force)
            } else if law.cohesion == 0 {
                covering += force.z
            } else if index % 4 < 2 {
                floors += force.z  // seats 4 to 15, two per plate, floor then roof
            } else {
                roofs += force.z
            }
        }
        let floorWeight = (0..<3).reduce(Float(0)) { $0 + weight(10 + 2 * $1) }
        let roofWeight = (0..<3).reduce(Float(0)) { $0 + weight(11 + 2 * $1) }
        #expect(abs(floors / floorWeight - 1) < 0.03, "floors carry \(floors) N of \(floorWeight)")
        #expect(abs(covering / weight(16) - 1) < 0.03, "covering rests with \(covering) N of \(weight(16))")
        #expect(roofs > roofWeight + 0.5 * weight(16), "roofs carry \(roofs) N, themselves \(roofWeight)")
        #expect(ties < 1e3, "ties carry \(ties) N at rest")
        var rest: [SIMD3<Float>] = []
        shells.mutateNodes { nodes in rest = nodes.map(\.displacement) }
        #expect(TerracedRowDamage(shells: shells, rest: rest).houses.allSatisfy { $0.category == .none })

        let result = solver.advance(until: 0.04)
        #expect(result.isStable)
        let summary = shells.summary()
        #expect(!summary.hasBlownUp)
        #expect(summary.maxDisplacement > 0.001, "front wall moved \(summary.maxDisplacement * 1000) mm")
    }
}
