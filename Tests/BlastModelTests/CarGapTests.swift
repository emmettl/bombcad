import Foundation
import Testing
import simd

@testable import BlastModel

/// A car's gap to the ground against the cells Compute Motion gives it: on cell faces on flat open
/// ground, off them beside a structure, on a slope, tilted or with another clearance, where the
/// standing and the motion's section warn that the overturning may differ on finer cells.
@Suite("Cars' gaps against the motion's cells")
struct CarGapTests {
    private func open(_ car: RigidCarDefinition) -> Scenario {
        var scenario = Scenario(
            name: "Open", domainSize: SIMD3(30, 20, 10), boxes: [],
            charge: Charge(mass: 10, position: SIMD3(8, 10, 0.5)))
        scenario.rigidCars = [car]
        return scenario
    }

    @Test("On flat open ground the saloon's 0.15 m gap lies on the cells' faces; nothing is said")
    func flatOpenGround() throws {
        let scenario = open(try .saloon(position: SIMD3(12, 10, 0)))
        #expect(FreestandingMotion.unresolvedGaps(scenario: scenario).isEmpty)
        #expect(
            SceneStanding(StandingInputs(scenario: scenario, cellSize: 0.25))[.freestandingMotion]?.resolution
                .isEmpty == true)
    }

    @Test("Beside a structure the uniform 0.1 m cells put its underside on their centres: warned")
    func besideStructure() throws {
        var scenario = ScenarioPreset.blastWall.scenario
        scenario.rigidCars = [try .saloon(position: SIMD3(2, 2, 0))]
        let gaps = FreestandingMotion.unresolvedGaps(scenario: scenario)
        #expect(gaps.count == 1 && gaps.first?.reason == "between cell faces")
        #expect(abs((gaps.first?.cell ?? 0) - 0.1) < 1e-6)
        let note = try #require(
            SceneStanding(StandingInputs(scenario: scenario, cellSize: 0.25))[.freestandingMotion]?.resolution
                .first)
        #expect(note.contains("may differ on finer cells"), "\(note)")
        // On the patches the open-ground run would give it, 0.05 m, the same gap is resolved.
        #expect(FreestandingMotion.unresolvedGaps(scenario: scenario, cellSize: 0.2, refinement: 4).isEmpty)
        // Uniform 0.075 m cells would resolve it too, at about 3.2 times the time, but the blast wall's
        // crop then spans 3.7 million of them, over the 3 million allowed.
        let finer = try #require(FreestandingMotion.finerCells(scenario: scenario))
        #expect(abs(finer.cellSize - 0.075) < 1e-6 && abs(finer.time - 3.16) < 0.01)
        #expect(!finer.fits && finer.cells > FreestandingMotion.maximumCells, "\(finer)")
        #expect(FreestandingMotion.finerCells(scenario: open(try .saloon(position: SIMD3(12, 10, 0)))) == nil)
    }

    @Test("On a slope, tilted, or with a clearance the cells do not divide: warned, each with its reason")
    func otherCauses() throws {
        var slope = open(try .saloon(position: SIMD3(12, 10, 0)))
        let terrain = Terrain.sampled(domain: slope.domainSize, spacing: 0.5) { max(0, ($0.x - 5) * 0.1) }
        slope.terrain = terrain
        slope.rigidCars = [try slope.resting(try .saloon(position: SIMD3(12, 10, 0)))]
        #expect(FreestandingMotion.unresolvedGaps(scenario: slope).first?.reason == "on a slope")
        let tilt = simd_quatd(angle: 0.2, axis: SIMD3(1, 0, 0)).vector
        let tilted = open(try .saloon(position: SIMD3(12, 10, 1), orientation: tilt))
        #expect(FreestandingMotion.unresolvedGaps(scenario: tilted).first?.reason == "tilted")
        let saloon = try RigidCarDefinition.saloon()
        let low = open(
            try RigidCarDefinition(
                name: "Low", position: SIMD3(12, 10, 0), mass: saloon.mass, wheelbase: saloon.wheelbase,
                track: saloon.track, centreOfMass: saloon.centreOfMass, inertia: saloon.inertia,
                shellSize: saloon.shellSize, groundClearance: 0.12))
        #expect(FreestandingMotion.unresolvedGaps(scenario: low).first?.reason == "between cell faces")
    }
}
