import Foundation
import Testing

@testable import BlastModel

/// The quick estimate's chances are the same for the same scene however often it is laid out:
/// its draws are keyed by each building's geometry (`SceneObject.drawKey`), not by the identifiers a
/// map's buildings are given anew each time.
@Suite("The quick estimate reproduced")
struct EstimateReproducibilityTests {
    @Test("A district laid out twice, its buildings' identifiers new, gives the same chances to the bit")
    func sameSceneSameChances() throws {
        func laidOut() throws -> Scenario {
            var layout = try DistrictLayoutTests.layout()
            layout.mass = 2_000
            return try layout.scene(halfSide: layout.halfSide(radius: 60, cellSize: 4), cellSize: 4).0
        }
        let (first, second) = (try laidOut(), try laidOut())
        #expect(first.envelopeObjects.map(\.id) != second.envelopeObjects.map(\.id))
        #expect(first.envelopeObjects.map(\.drawKey) == second.envelopeObjects.map(\.drawKey))
        // Results by the building's place in the layout, with what was judged.
        func chances(_ scene: Scenario) -> (glass: [String], walls: [String]) {
            let place = Dictionary(
                uniqueKeysWithValues: scene.envelopeObjects.enumerated().map { ($1.id, $0) })
            var uncertainty = FacadeLoadSurrogate.Uncertainty(yieldLogSD: log(1.5) / 1.645, samples: 4)
            uncertainty.stratified = true
            let glass = FacadeLoadSurrogate.glassProbabilities(
                scene: scene, cellSize: 4, uncertainty: uncertainty
            )
            .sides.map {
                "\(place[$0.owner]!) \($0.axis) \($0.outward) \($0.someBroken) \($0.blownOut) \($0.thrownPast3b)"
            }
            let estimate = FacadeLoadSurrogate.estimate(scene: scene, cellSize: 4)
            let walls = FacadeLoadSurrogate.structureProbabilities(
                estimate, mass: Double(scene.charge.mass), cellSize: 4,
                constructions: { scene.envelopeConstruction(for: $0) }, uncertainty: uncertainty
            ).0.map { "\(place[$0.owner]!) \($0.wallsModerate) \($0.wallsHeavy) \($0.roofModerate)" }.sorted()
            return (glass, walls)
        }
        let (a, b) = (chances(first), chances(second))
        #expect(!a.glass.isEmpty && !a.walls.isEmpty)
        #expect(a.glass == b.glass)
        #expect(a.walls == b.walls)
    }
}
