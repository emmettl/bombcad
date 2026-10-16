import Foundation
import Testing

@testable import BlastCore

/// What envelope buildings are built of: from map tags, IFC layers, the editor, or assumed.
@Suite("Envelope constructions")
struct EnvelopeConstructionTests {
    @Test("A map building's material tag gives concrete or masonry; anything else says nothing")
    func map() {
        let id = UUID()
        #expect(
            EnvelopeConstruction.fromMap(objectID: id, material: "concrete")?.walls == .reinforcedConcrete)
        let brick = EnvelopeConstruction.fromMap(objectID: id, material: "brick")
        #expect(
            brick?.walls == .unreinforcedMasonry && brick?.wallThicknessM == 0.215 && brick?.source == .map)
        #expect(EnvelopeConstruction.fromMap(objectID: id, material: "wood") == nil)
        #expect(EnvelopeConstruction.fromMap(objectID: id, material: nil) == nil)
    }

    @Test("IFC layers give the larger class of element, at its median structural thickness")
    func ifc() {
        let id = UUID()
        let wall = [
            IFCStructure.Layer(name: "Plaster", thickness: 0.015),
            IFCStructure.Layer(name: "Brick, common", thickness: 0.24),
        ]
        let slab = [IFCStructure.Layer(name: "Concrete C30/37", thickness: 0.2)]
        let construction = EnvelopeConstruction.fromIFC(
            objectID: id, elementLayers: [wall, wall, wall, slab])
        #expect(construction?.walls == .unreinforcedMasonry && construction?.source == .ifc)
        #expect(abs((construction?.wallThicknessM ?? 0) - 0.24) < 1e-6)
        #expect(EnvelopeConstruction.fromIFC(objectID: id, elementLayers: [[]]) == nil)
    }

    @Test("An envelope with none takes the assumed default; one set is saved and reopened")
    func persistence() throws {
        var scene = Scenario(
            name: "Envelopes", domainSize: SIMD3(20, 20, 10), boxes: [],
            charge: Charge(mass: 1, position: SIMD3(1, 1, 0)))
        let id = try scene.addEnvelopeObject(
            BuildingEnvelope(solids: [Box(min: SIMD3(5, 5, 0), max: SIMD3(8, 8, 3))]))
        #expect(scene.envelopeConstruction(for: id).source == .assumed)
        scene.setEnvelopeConstruction(
            EnvelopeConstruction(objectID: id, walls: .unreinforcedMasonry, source: .user, detail: "chosen"))
        let data = try JSONEncoder().encode(scene)
        let reopened = try JSONDecoder().decode(Scenario.self, from: data)
        #expect(reopened.envelopeConstruction(for: id).walls == .unreinforcedMasonry)
        #expect(reopened.envelopeConstruction(for: id).source == .user)
        // Setting it again replaces it, and constructions of envelopes no longer present go.
        var edited = reopened
        edited.setEnvelopeConstruction(.assumed(objectID: id))
        edited.setEnvelopeConstruction(.assumed(objectID: UUID()))
        #expect(edited.envelopeConstructions?.count == 1)
    }
}
