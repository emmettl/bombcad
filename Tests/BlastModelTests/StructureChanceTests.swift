import Foundation
import Testing
import simd

@testable import BlastModel

/// Each building's chances that its walls and roof are damaged (`structureProbabilities`), on a row
/// of glazed concrete blocks at 20, 50, 90 and 160 m from a charge.
@Suite("Walls' and roofs' chances")
struct StructureChanceTests {
    func chances(mass: Float, walls: EnvelopeConstruction.Kind = .reinforcedConcrete) throws
        -> [FacadeLoadSurrogate.StructureChance]
    {
        var scene = try FacadeGlassProbabilityTests.row()
        scene.charge.mass = mass
        for object in scene.envelopeObjects {
            var construction = scene.envelopeConstruction(for: object.id)
            construction.walls = walls
            scene.setEnvelopeConstruction(construction)
        }
        let estimate = FacadeLoadSurrogate.estimate(scene: scene, cellSize: 2)
        var uncertainty = FacadeLoadSurrogate.Uncertainty()
        uncertainty.samples = 12
        let byOwner = Dictionary(
            uniqueKeysWithValues: FacadeLoadSurrogate.structureProbabilities(
                estimate, mass: Double(mass), cellSize: 2,
                constructions: { scene.envelopeConstruction(for: $0) },
                uncertainty: uncertainty
            ).chances.map { ($0.owner, $0) })
        return try scene.envelopeObjects.map { try #require(byOwner[$0.id]) }
    }

    @Test(
        "Chances lie between nothing and certainty, fall with distance, and heavy is never likelier than moderate"
    )
    func ordered() throws {
        let row = try chances(mass: 2_000)
        for c in row {
            for p in [c.wallsModerate, c.wallsHeavy, c.roofModerate] { #expect((0...1).contains(p)) }
            #expect(c.wallsHeavy <= c.wallsModerate)
        }
        #expect(row[0].wallsModerate > 0.5)
        for (near, far) in zip(row, row.dropFirst()) { #expect(far.wallsModerate <= near.wallsModerate) }
        // A firecracker damages nothing, and nothing is drawn for it.
        #expect(try chances(mass: 0.01).allSatisfy { $0 == .init(owner: $0.owner) })
    }

    @Test("The calibration follows what the walls are built of")
    func calibration() throws {
        let concrete = FacadeLoadSurrogate.structureCalibration(walls: .reinforcedConcrete)
        let stone = FacadeLoadSurrogate.structureCalibration(walls: .unreinforcedMasonry)
        #expect(concrete.walls.scatter == 1.0 && stone.walls.scatter == 0.5 && concrete.roof == stone.roof)
        // Concrete's walls' peak ×1.15 since the refit of 23 October 2026 (emmettl/bombcad-work#56), their
        // impulse ×0.95 since 25 October 2026 (emmettl/bombcad-work#102); roofs ×1.3.
        #expect(concrete.roof.peak == 1.3 && concrete.walls.peak == 1.15 && concrete.walls.impulse == 0.95)
        #expect(stone.walls.peak == 1.0)
        // With the learned field model's peaks, concrete's walls take the same: peak ×1.15, impulse ×0.95.
        let learned = FacadeLoadSurrogate.structureCalibration(walls: .reinforcedConcrete, learned: true)
        #expect(learned.walls.peak == 1.15 && learned.walls.impulse == 0.95 && learned.roof == concrete.roof)
        let learnedStone = FacadeLoadSurrogate.structureCalibration(
            walls: .unreinforcedMasonry, learned: true)
        #expect(learnedStone.walls == stone.walls && learnedStone.roof == stone.roof)
        // Masonry has no level between none and heavy: its walls' chances are one.
        for c in try chances(mass: 2_000, walls: .unreinforcedMasonry) {
            #expect(c.wallsHeavy == c.wallsModerate)
        }
    }
}
