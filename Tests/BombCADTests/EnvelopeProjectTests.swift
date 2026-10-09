import BlastCore
import DocumentKit
import Foundation
import Testing

@testable import BombCAD

@Suite("Envelope project ownership", .serialized)
struct EnvelopeProjectTests {
    @Test("Mixed envelopes and structures require version five and round trip")
    func package() throws {
        var scene = try StreetInteractionStudy.make(.pair)
        let owner = scene.structuralObjects[0]
        try scene.useEnvelope(id: owner.id)
        let archive = try ProjectDocument(scenario: scene).makeArchive()
        let payload = try JSONDecoder().decode(
            ImportedSceneCodec.ScenePayload.self,
            from: archive.files["scene.json"]!)
        #expect(payload.encodingVersion == 5)
        #expect(try ProjectDocument(archive: archive).scenario == scene)
        var old = archive
        var json = try #require(
            try JSONSerialization.jsonObject(with: old.files["scene.json"]!) as? [String: Any])
        json["encodingVersion"] = 4
        old.files["scene.json"] = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: (any Error).self) { try ProjectDocument(archive: old) }
    }

    @MainActor
    @Test("Conversion can be undone, redone and saved without losing the original structure")
    func undo() throws {
        let model = SimulationModel()
        model.settings.scenario = try StreetInteractionStudy.make(.isolated)
        model.recordEdit()
        let before = model.settings.scenario
        let owner = try #require(before.structuralObject)
        model.selectStructure(id: owner.id)
        model.useEditedEnvelope()
        model.recordEdit()
        #expect(model.settings.scenario.envelopeObjects.first?.id == owner.id)
        #expect(model.settings.scenario.structure == nil)
        model.undo()
        #expect(model.settings.scenario == before)
        model.redo()
        #expect(model.settings.scenario.envelopeObjects.first?.id == owner.id)
        let archive = try ProjectDocument(model: model).makeArchive()
        #expect(try ProjectDocument(archive: archive).scenario == model.settings.scenario)
    }
}
