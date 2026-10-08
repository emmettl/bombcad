import BlastCore
import CryptoKit
import DocumentKit
import Foundation
import Testing

@testable import BombCAD

@Suite("Scene ownership projects")
struct SceneOwnershipProjectTests {
    @Test("Old scene packages migrate once and persist ownership", arguments: [1, 2])
    func legacyPackage(version: Int) throws {
        var scene = try StructureEditingTests().layout()
        scene.boxes = [Box(min: SIMD3(4, 1, 0), max: SIMD3(5, 2, 1))]
        var archive = try ProjectDocument(scenario: scene).makeArchive()
        var payload = try #require(
            try JSONSerialization.jsonObject(with: archive.files["scene.json"]!) as? [String: Any])
        var raw = try #require(payload["scenario"] as? [String: Any])
        raw.removeValue(forKey: "objectOwnership")
        payload["scenario"] = raw
        payload["encodingVersion"] = version
        archive.files["scene.json"] = try JSONSerialization.data(withJSONObject: payload)
        let migrated = try ProjectDocument(archive: archive)
        #expect(migrated.scenario.boxes == scene.boxes)
        #expect(migrated.scenario.structure == scene.structure)
        #expect(migrated.scenario.structuralObject?.sourceModelID == scene.importedModels?.first?.id)
        let saved = try migrated.makeArchive()
        let header = try JSONDecoder().decode(
            ImportedSceneCodec.ScenePayload.self, from: saved.files["scene.json"]!)
        #expect(header.encodingVersion == 3)
        #expect(try ProjectDocument(archive: saved).scenario == migrated.scenario)
        #expect(
            try ProjectDocument(archive: saved).makeArchive().files["scene.json"] == saved.files["scene.json"]
        )
    }

    @Test("Imported regeneration and source edits preserve their owner and independent objects")
    func importOwnership() throws {
        var scene = try StructureEditingTests().layout()
        let independent = scene.addFixedObject(Box(min: SIMD3(4, 1, 0), max: SIMD3(5, 2, 1)))
        let originalObject = try #require(scene.structuralObject)
        let originalFixed = try #require(scene.object(id: independent))
        let fine = try scene.resamplingImports(cellSize: 0.25)
        #expect(fine.structuralObject?.id == originalObject.id)
        #expect(fine.structuralObject?.sourceModelID == originalObject.sourceModelID)
        #expect(fine.object(id: independent) == originalFixed)
        let part = try #require(StructureEditing.parts(in: fine).first)
        let edited = try StructureEditing.settingMaterial(.structuralSteel, for: part.id, in: fine)
        #expect(edited.structuralObject?.id == originalObject.id)
        #expect(edited.object(id: independent) == originalFixed)
        #expect(
            try ProjectDocument(archive: ProjectDocument(scenario: edited).makeArchive()).scenario == edited)
    }

    @Test("Historical fingerprints retain the old numerical encoding")
    func fingerprintCompatibility() throws {
        let run = try SavedRunTests().fixture()
        // A separately declared legacy schema is the fingerprint oracle.
        struct LegacyScenario: Encodable {
            var name: String
            var domainSize: SIMD3<Float>
            var boxes: [Box]
            var rigidObjects: [RigidObjectDefinition]?
            var importNotes: [String]?
            var importedModels: [ImportedModel]?
            var charge: Charge
            var additionalCharges: [Charge]?
            var gauges: [Gauge]
            var structure: StructureModel?
            var atmosphere: Atmosphere
            var reflectiveFaces: BoundaryFaces
        }
        struct LegacyInputs: Encodable {
            var scenario: LegacyScenario
            var settings: ProjectRunSettings
        }
        let scene = run.scenario
        let legacyScene = LegacyScenario(
            name: scene.name, domainSize: scene.domainSize, boxes: scene.boxes,
            rigidObjects: scene.rigidObjects, importNotes: scene.importNotes,
            importedModels: scene.importedModels, charge: scene.charge,
            additionalCharges: scene.additionalCharges, gauges: scene.gauges,
            structure: scene.structure, atmosphere: scene.atmosphere,
            reflectiveFaces: scene.reflectiveFaces)
        let legacyBytes = try ProjectArchive.encodeJSON(
            LegacyInputs(scenario: legacyScene, settings: run.settings))
        let legacyHash = SHA256.hash(data: legacyBytes).map { String(format: "%02x", $0) }.joined()
        #expect(try SavedSimulationRun.fingerprint(run.scenario, settings: run.settings) == legacyHash)
        var legacyRun = run
        legacyRun.inputSHA256 = legacyHash
        try legacyRun.validate()
        var changed = run.scenario
        let first = changed.addFixedObject(Box(min: SIMD3(4, 1, 0), max: SIMD3(5, 2, 1)))
        let hash = try SavedSimulationRun.fingerprint(changed, settings: run.settings)
        try changed.removeObject(id: first)
        _ = changed.addFixedObject(Box(min: SIMD3(4, 1, 0), max: SIMD3(5, 2, 1)))
        #expect(try SavedSimulationRun.fingerprint(changed, settings: run.settings) == hash)
        changed.charge.mass += 1
        #expect(try SavedSimulationRun.fingerprint(changed, settings: run.settings) != hash)
    }

    @Test("Missing ownership in new packages and missing source references are rejected")
    func invalidNewPackage() throws {
        var archive = try ProjectDocument(scenario: StructureEditingTests().layout()).makeArchive()
        var payload = try #require(
            try JSONSerialization.jsonObject(with: archive.files["scene.json"]!) as? [String: Any])
        var raw = try #require(payload["scenario"] as? [String: Any])
        var ownership = try #require(raw["objectOwnership"] as? [String: Any])
        var body = try #require(ownership["structure"] as? [String: Any])
        body["sourceModelID"] = UUID().uuidString
        ownership["structure"] = body
        raw["objectOwnership"] = ownership
        payload["scenario"] = raw
        archive.files["scene.json"] = try JSONSerialization.data(withJSONObject: payload)
        #expect(throws: (any Error).self) { try ProjectDocument(archive: archive) }
        raw.removeValue(forKey: "objectOwnership")
        payload["scenario"] = raw
        archive.files["scene.json"] = try JSONSerialization.data(withJSONObject: payload)
        #expect(throws: (any Error).self) { try ProjectDocument(archive: archive) }
    }

    @Test("Historical run packages migrate without changing fingerprints or solver provenance")
    func historicalRunMigration() throws {
        let run = try SavedRunTests().fixture()
        var document = ProjectDocument(scenario: run.scenario)
        document.savedRuns = [run]
        var archive = try document.makeArchive()
        let path = try #require(archive.files.keys.first { $0.hasPrefix("results/runs/") })
        var record = try #require(
            try JSONSerialization.jsonObject(with: archive.files[path]!) as? [String: Any])
        var scene = try #require(record["scene"] as? [String: Any])
        var scenario = try #require(scene["scenario"] as? [String: Any])
        scenario.removeValue(forKey: "objectOwnership")
        scene["scenario"] = scenario
        scene["encodingVersion"] = 1
        record["scene"] = scene
        var result = try #require(record["result"] as? [String: Any])
        var resultScenario = try #require(result["scenario"] as? [String: Any])
        resultScenario.removeValue(forKey: "objectOwnership")
        result["scenario"] = resultScenario
        record["result"] = result
        archive.files[path] = try JSONSerialization.data(withJSONObject: record)
        let reopened = try ProjectDocument(archive: archive)
        #expect(reopened.savedRuns[0].inputSHA256 == run.inputSHA256)
        #expect(reopened.savedRuns[0].solverVersion == run.solverVersion)
        #expect(reopened.savedRuns[0].scenario.structure == run.scenario.structure)
        try reopened.savedRuns[0].validate()
        let saved = try reopened.makeArchive()
        #expect(try ProjectDocument(archive: saved).savedRuns == reopened.savedRuns)
    }
}

@MainActor
@Suite("Scene ownership editing", .serialized)
struct SceneOwnershipEditingTests {
    @Test("Duplication, edits and undo restore exact object identities")
    func fixedUndo() throws {
        let scene = Scenario(
            name: "Object editing", domainSize: SIMD3(repeating: 6), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(5, 5, 1)))
        let model = SimulationModel(document: ProjectDocument(scenario: scene))
        model.addBlock()
        model.recordEdit()
        let first = try #require(model.settings.scenario.fixedObjects.first)
        model.duplicateBlock(id: first.id)
        model.recordEdit()
        let duplicate = try #require(model.settings.scenario.fixedObjects.last)
        #expect(first.id != duplicate.id)
        let afterDuplicate = model.settings.scenario
        model.removeBlock(id: first.id)
        model.recordEdit()
        model.updateBlock(id: first.id, box: Box(min: .zero, max: SIMD3(repeating: 1)))
        #expect(model.settings.scenario.fixedObjects == [duplicate])
        model.undo()
        #expect(model.settings.scenario == afterDuplicate)
        model.undo()
        #expect(model.settings.scenario.fixedObjects == [first])
        model.redo()
        #expect(model.settings.scenario == afterDuplicate)
    }

    @Test("Stale component references cannot change a surviving equal region")
    func staleComponent() throws {
        let box = Box(min: SIMD3(1, 1, 0), max: SIMD3(2, 2, 1))
        let scene = Scenario(
            name: "Equal regions", domainSize: SIMD3(repeating: 6), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(5, 5, 1)),
            structure: StructureModel(solids: [box, box], elementSize: 0.5))
        let model = SimulationModel(document: ProjectDocument(scenario: scene))
        let references = scene.componentReferences(.solid)
        model.removeComponent(references[0])
        #expect(model.settings.scenario.componentIndex(references[1]) == 0)
        let after = model.settings.scenario
        model.editComponent(references[0]) { body, index in body.setMaterial(.structuralSteel, of: index) }
        model.removeComponent(references[0])
        #expect(model.settings.scenario == after)
        model.editComponent(references[1]) { body, index in
            body.solids[index] = Box(min: SIMD3(2, 2, 0), max: SIMD3(3, 3, 1))
        }
        #expect(model.settings.scenario.componentIndex(references[1]) == 0)
        #expect(model.settings.scenario.structure?.solids[0].min == SIMD3(2, 2, 0))
    }
}
