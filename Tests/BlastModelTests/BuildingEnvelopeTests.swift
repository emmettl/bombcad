import Foundation
import Testing
import simd

@testable import BlastModel

@Suite("Stationary building envelopes", .serialized)
struct BuildingEnvelopeTests {
    func scene() throws -> Scenario {
        var scene = Scenario(
            name: "Envelope", domainSize: SIMD3(8, 8, 6), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(1, 1, 1)))
        scene.reflectiveFaces = .all
        try scene.addEnvelopeObject(
            BuildingEnvelope(solids: [
                Box(min: SIMD3(3, 3, 2), max: SIMD3(5, 5, 4))
            ]), name: "Cube")
        return scene
    }

    @Test("Overlapping openings retain the half-open box boundary convention")
    func openings() throws {
        let envelope = try BuildingEnvelope(
            solids: [Box(min: .zero, max: SIMD3(4, 2, 3))],
            openings: [
                Box(min: SIMD3(1, 0, 0), max: SIMD3(2, 2, 2)),
                Box(min: SIMD3(1.5, 0, 1), max: SIMD3(3, 2, 2)),
            ])
        for x in stride(from: Float(0), through: 4, by: 0.25) {
            for z in stride(from: Float(0), through: 3, by: 0.25) {
                let p = SIMD3(x, 1, z)
                #expect(envelope.occupies(p) == envelope.blocks.contains { $0.contains(p) })
            }
        }
        #expect(throws: SceneObjectError.self) {
            try BuildingEnvelope(solids: [Box(min: .zero, max: SIMD3(1, 1, 0))])
        }
        // Openings that cut a solid away between them leave nothing; one that holds it whole leaves
        // it alone, as a pane set in an opening.
        #expect(throws: SceneObjectError.self) {
            try BuildingEnvelope(
                solids: [Box(min: .zero, max: SIMD3(1, 1, 1))],
                openings: [
                    Box(min: SIMD3(-1, -1, -1), max: SIMD3(0.5, 2, 2)),
                    Box(min: SIMD3(0.5, -1, -1), max: SIMD3(2, 2, 2)),
                ])
        }
        #expect(
            try BuildingEnvelope(
                solids: [Box(min: .zero, max: SIMD3(1, 1, 1))],
                openings: [Box(min: .zero, max: SIMD3(1, 1, 1))]
            ).blocks.count == 1)
    }

    @Test("Conversion and encoding preserve owner, openings and physics fingerprint semantics")
    func ownership() throws {
        var scene = try StreetInteractionStudy.make(.pair, clamped: true)
        let original = scene.structuralObjects
        for object in original { try scene.useEnvelope(id: object.id) }
        #expect(scene.structuralObjects.isEmpty)
        #expect(scene.envelopeObjects.map(\.id) == original.map(\.id))
        let reopened = try JSONDecoder().decode(Scenario.self, from: JSONEncoder().encode(scene))
        #expect(reopened == scene)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.userInfo[Scenario.physicsInputEncoding] = true
        let first = try encoder.encode(scene)
        var renamed = scene
        renamed.objects[0].name = "Renamed"
        #expect(try encoder.encode(renamed) == first)
        #expect(!scene.chargeIsBlocked)
        scene.charge.position = SIMD3(16.25, 6.25, 1)
        #expect(scene.chargeIsBlocked)
    }
}
