import Foundation
import Testing
import simd

@testable import BlastModel

/// Refinement toward chosen buildings: corridors from each charge to each.
@Suite("Refinement corridors")
struct RefinementCorridorTests {
    private func covered(_ point: SIMD3<Float>, by regions: [RefinementRegion]) -> Bool {
        regions.contains { all(point .>= $0.low) && all(point .<= $0.high) }
    }

    @Test("A corridor holds the way from the charge to the building and past it, not the air beside it")
    func corridor() {
        let target = Box(min: SIMD3(90, 40, 0), max: SIMD3(110, 60, 20))
        let regions = RefinementRegion.corridors(from: [SIMD3(0, 50, 1)], to: [target], halfWidth: 10)
        // Along the line, over the building, and its width beyond its far side.
        for x in stride(from: Float(0), through: 120, by: 5) {
            #expect(covered(SIMD3(x, 50, 5), by: regions), "\(x) m along")
        }
        #expect(covered(SIMD3(100, 50, 200), by: regions))
        // Off to the side, and well beyond.
        #expect(!covered(SIMD3(50, 75, 5), by: regions))
        #expect(!covered(SIMD3(50, 25, 5), by: regions))
        #expect(!covered(SIMD3(140, 50, 5), by: regions))
        #expect(!covered(SIMD3(-15, 50, 5), by: regions))
    }

    @Test("Toward a scene's buildings: each charge's corridor 1.5 m/kg^(1/3) wide, nil for none")
    func scene() throws {
        var scene = Scenario(
            name: "Corridors", domainSize: SIMD3(200, 200, 40), boxes: [],
            charge: Charge(mass: 1000, position: SIMD3(20, 100, 1)))
        let near = try scene.addEnvelopeObject(
            BuildingEnvelope(solids: [Box(min: SIMD3(150, 95, 0), max: SIMD3(160, 105, 10))]), name: "Near")
        let away = try scene.addEnvelopeObject(
            BuildingEnvelope(solids: [Box(min: SIMD3(100, 170, 0), max: SIMD3(110, 180, 10))]), name: "Away")
        #expect(scene.object(id: near)?.bounds == Box(min: SIMD3(150, 95, 0), max: SIMD3(160, 105, 10)))
        let regions = try #require(scene.refinementCorridors(toward: [near]))
        // 1.5 × 10 = 15 m either side of the line to it.
        #expect(covered(SIMD3(80, 114, 1), by: regions))
        #expect(!covered(SIMD3(80, 117, 1), by: regions))
        // The other building is left on the coarse cells.
        #expect(!covered(SIMD3(105, 175, 5), by: regions))
        let both = try #require(scene.refinementCorridors(toward: [near, away]))
        #expect(covered(SIMD3(105, 175, 5), by: both))
        // A second charge takes its own corridor.
        scene.additionalCharges = [Charge(mass: 1000, position: SIMD3(155, 20, 1))]
        let twice = try #require(scene.refinementCorridors(toward: [near]))
        #expect(covered(SIMD3(155, 50, 1), by: twice) && !covered(SIMD3(155, 50, 1), by: regions))
        // Ids no longer in the scene refine nothing in particular.
        #expect(scene.refinementCorridors(toward: [UUID()]) == nil)
    }
}
