import BlastCore
import Foundation
import Testing

@testable import BombCAD

/// The envelope section's "Could finer cells change it": judged from a run's loads once asked
/// for, cleared when the loads change.
@Suite("Envelope doubt in the app")
@MainActor
struct EnvelopeDoubtAppTests {
    @Test("Colouring by doubt judges every building from the loads, and new loads clear it")
    func judged() async throws {
        var scene = try StreetInteractionStudy.make(.pair)
        for object in scene.structuralObjects { try scene.useEnvelope(id: object.id) }
        var document = ProjectDocument(scenario: scene)
        document.runSettings?.resolution = "coarse"
        let model = SimulationModel(document: document)
        // A short pulse on every component: one building failed at any load the band gives, the
        // other's a few kPa.
        func loads(_ peaks: [Double]) -> [EnvelopeComponentLoad] {
            zip(scene.envelopeObjects, peaks).flatMap { object, peak in
                object.envelope!.components(owner: object.id, cellSize: 0.25).map { component in
                    EnvelopeComponentLoad(
                        id: component.id, owner: object.id,
                        kind: EnvelopeComponentLoad.Kind(rawValue: component.kind.rawValue) ?? .wall,
                        region: component.region, axis: component.axis, binS: 1e-4,
                        outerPa: (0..<400).map { bin in bin < 40 ? peak * (1 - Double(bin) / 40) : 0 },
                        innerPa: [])
                }
            }
        }
        model.updateEnvelopeDamage(loads: loads([30e6, 3e3]))
        #expect(model.canJudgeEnvelopeDoubt && model.envelopeDoubt == nil)
        model.envelopeColouring = .couldFlip
        while model.judgingEnvelopeDoubt { try await Task.sleep(for: .milliseconds(10)) }
        let doubt = try #require(model.envelopeDoubt)
        #expect(Set(doubt.buildings.map(\.id)) == Set(scene.envelopeObjects.map(\.id)))
        // Failed whatever the band, or barely loaded: neither is in doubt.
        #expect(doubt.count(.settled) == 2, "\(doubt.buildings)")
        model.updateEnvelopeDamage(loads: loads([30e6, 6e3]))
        #expect(model.envelopeDoubt == nil)
    }
}
