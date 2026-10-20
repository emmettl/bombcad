import Foundation
import Testing
import simd

@testable import BlastModel

@Suite("Terraced houses")
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
        #expect(timber.count > 0 && timber.allSatisfy { $0.axis == 2 || $0.axis == 3 })
        // The roof: two slopes at 40° meeting at the ridge, the gables and party walls cut to them.
        let slopes = model.solids.indices.filter { model.inclination(of: $0)?.trimsWalls == true }
        #expect(slopes.count == 2)
        let ridge = model.solids[slopes[0]].max.z
        let shared = Set(
            mesh.elements.filter { $0.solid == slopes[0] }.flatMap { e in (0..<4).map { e.nodes[$0] } }
        )
        .intersection(
            mesh.elements.filter { $0.solid == slopes[1] }.flatMap { e in (0..<4).map { e.nodes[$0] } })
        #expect(shared.count == 121 && shared.allSatisfy { abs(mesh.positions[Int($0)].z - ridge) < 1e-3 })
        // The tiles and the slope under them shield each other's faces, as a cavity wall's leaves
        // do, so that the air between them, unresolved, does not load both.
        let tiles = mesh.elements.indices.filter {
            TerracedRowDamage.isCovering(in: model)(mesh.elements[$0].solid)
        }
        #expect(!tiles.isEmpty)
        #expect(
            tiles.allSatisfy {
                let below = shields[$0].below
                return below >= 0 && slopes.contains(mesh.elements[Int(below)].solid)
                    && shields[Int(below)].above == $0
            })
        let top = model.solids[slopes[0]].min.z
        let x0 = model.solids[slopes[0]].min.x
        let half = model.solids[slopes[0]].max.x - x0
        for element in mesh.elements where element.axis == 1 {
            let centre = (0..<4).reduce(SIMD3<Float>.zero) { $0 + mesh.positions[Int(element.nodes[$1])] } / 4
            let roof = top + (ridge - top) * (1 - abs(centre.x - x0 - half) / half)
            #expect(centre.z <= roof + 1e-3, "\(centre)")
        }
        let layout = TerracedRowDamage.Layout(model)
        #expect(layout.externalLeaves == 0..<8 && layout.frontLeaves == 0..<2 && layout.partyWalls == 8..<10)
        #expect(layout.firstSeat == 4)
        let standing = SceneStanding(
            // Pinned to the balloon until rerun on the mapped start (validation.md, "Still on the balloon start").
            StandingInputs(scenario: scenario, cellSize: 0.25, configuration: .recommended.balloonStart))
        #expect(
            standing.results.contains { result in result.evidence.contains { $0.check.contains("timber") } })
    }

    @Test(
        "The solid-walled row has one brick-thick plane at the front, joined to the party walls, and no ties")
    func solidWalls() throws {
        let scenario = ScenarioPreset.terracedRow(
            title: "Terraced row", faceClearance: 0, walls: .solidOneBrick)
        let model = try #require(scenario.structure)
        let mesh = try ShellMesh(model: model)
        let x0 = model.solids[0].min.x
        let front = mesh.elements.filter { $0.solid == 0 }
        #expect(!front.isEmpty && front.allSatisfy { $0.axis == 0 && abs($0.thickness - 0.215) < 1e-4 })
        let planes = Set(mesh.elements.filter { $0.axis == 0 }.map { mesh.positions[Int($0.nodes[0])].x })
            .filter { $0 < x0 + 1 }
        #expect(planes.count == 1, "front planes \(planes.sorted())")
        // No ties: nothing across a cavity, and the grader's seats start at the first support.
        #expect(model.supports.indices.allSatisfy { model.anchorage(ofSupport: $0)?.closingGap == nil })
        let layout = TerracedRowDamage.Layout(model)
        #expect(layout.externalLeaves == 0..<4 && layout.frontLeaves == 0..<1 && layout.partyWalls == 4..<6)
        #expect(layout.firstSeat == 0)
        // The party walls end on the front wall's midsurface and share its nodes: bonded in.
        let frontNodes = Set(front.flatMap { e in (0..<4).map { e.nodes[$0] } })
        let partyNodes = Set(
            mesh.elements.filter { layout.partyWalls.contains($0.solid) }.flatMap { e in
                (0..<4).map { e.nodes[$0] }
            })
        #expect(!frontNodes.intersection(partyNodes).isEmpty)
    }

    @Test("The app's terraced sample is the solid row, the 1930s cavity row the second")
    func samples() throws {
        let solid = try #require(ScenarioPreset.terracedHouses.scenario.structure)
        let cavity = try #require(ScenarioPreset.terracedHousesCavity.scenario.structure)
        #expect(TerracedRowDamage.Layout(solid).externalLeaves == 0..<4)
        #expect(abs(solid.solids[0].size.x - 0.215) < 1e-5)
        #expect(TerracedRowDamage.Layout(cavity).externalLeaves == 0..<8)
        #expect(ScenarioPreset.terracedHousesCavity.scenario.tightOpenFaces.isEmpty)
    }
}
