import BlastCore
import BlastRender
import DocumentKit
import Foundation
import Metal
import Testing

@testable import BombCAD

enum MultiBodyFixture {
    static func scene() throws -> Scenario {
        var scene = Scenario(
            name: "Independent walls", domainSize: SIMD3(12, 8, 6), boxes: [],
            charge: Charge(mass: 0.02, position: SIMD3(5, 3, 1)),
            gauges: [Gauge("Pressure", at: SIMD3(6, 3, 1))],
            structure: StructureModel(
                solids: [Box(x: 2...2.5, y: 2...4, height: 2)],
                material: .plainConcrete, elementSize: 0.25))
        try scene.addStructureObject(
            StructureModel(
                solids: [Box(x: 8...8.5, y: 2...4, height: 2)],
                material: .structuralSteel, elementSize: 0.5), name: "Steel wall")
        return scene
    }

    static func imports() throws -> Scenario {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let mesh = try ImportedMesh(
            data: Data(contentsOf: root.appendingPathComponent("Samples/Importer/unit-cube.obj")),
            fileExtension: "obj")
        var scene = Scenario(
            name: "Two imports", domainSize: SIMD3(repeating: 8), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(7, 6, 1)))
        for x: Float in [1, 5] {
            let corner = SIMD3<Float>(x, 1, 0)
            let transformed = try mesh.transformed(scale: 1, yUp: false, corner: corner)
            let imported = ImportedModel(
                name: "Cube \(x)", source: mesh, scale: 1, yUp: false, corner: corner,
                behavior: .deformable,
                preview: try transformed.preview(cellSize: 0.5, domain: scene.domainSize))
            try scene.installImport(imported, material: .plainConcrete, fixedBase: true)
        }
        return scene
    }
}

@Suite("Multiple structure projects")
struct MultiBodyProjectTests {
    @Test("The renderer draws every body's geometry")
    func rendering() throws {
        let scene = try MultiBodyFixture.scene()
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let solver = try BlastSolver(device: device, scenario: scene, cellSize: 0.5)
        let renderer = try SceneRenderer(device: device)
        renderer.setScene(scene, solver: solver)
        let camera = OrbitCamera.framing(scene)
        let both = try #require(
            renderer.snapshot(commandQueue: queue, width: 320, height: 200, camera: camera))
        var single = scene
        try single.updateStructureObject(id: scene.structuralObjects[1].id, model: nil)
        let oneSolver = try BlastSolver(device: device, scenario: single, cellSize: 0.5)
        renderer.setScene(single, solver: oneSolver)
        let one = try #require(
            renderer.snapshot(commandQueue: queue, width: 320, height: 200, camera: camera))
        let bothPixels = try #require(both.image.dataProvider?.data)
        let onePixels = try #require(one.image.dataProvider?.data)
        #expect(bothPixels as Data != onePixels as Data)
    }

    @Test("Multiple owners round-trip in version 4 and older encodings reject extra structures")
    func persistence() throws {
        var scene = try MultiBodyFixture.scene()
        try scene.reorderObjects(scene.objects.map(\.id).reversed())
        let original = ProjectDocument(scenario: scene)
        var archive = try original.makeArchive()
        let payload = try JSONDecoder().decode(
            ImportedSceneCodec.ScenePayload.self, from: archive.files["scene.json"]!)
        #expect(payload.encodingVersion == 4)
        let restored = try ProjectDocument(archive: archive)
        #expect(restored.scenario == scene)
        #expect(restored.scenario.structuralObjects.map { $0.structure!.elementSize } == [0.5, 0.25])
        #expect(try restored.makeArchive().files["scene.json"] == archive.files["scene.json"])
        var raw = try #require(
            try JSONSerialization.jsonObject(with: archive.files["scene.json"]!) as? [String: Any])
        raw["encodingVersion"] = 3
        archive.files["scene.json"] = try JSONSerialization.data(withJSONObject: raw)
        #expect(throws: ProjectFileError.self) { try ProjectDocument(archive: archive) }
    }

    @Test("Import edits, replacement, detachment and regeneration target their own bodies")
    func imports() throws {
        let scene = try MultiBodyFixture.imports()
        let models = try #require(scene.importedModels)
        #expect(scene.structuralObjects.count == 2)
        let a = try #require(scene.structuralObject(sourceID: models[0].id))
        let b = try #require(scene.structuralObject(sourceID: models[1].id))
        let part = try #require(StructureEditing.parts(in: scene).first { $0.id.modelID == models[1].id })
        let assigned = try StructureEditing.settingMaterial(.structuralSteel, for: part.id, in: scene)
        #expect(assigned.object(id: a.id) == a)
        #expect(assigned.object(id: b.id)?.structure?.material(of: 0) == .structuralSteel)
        let fine = try assigned.resamplingImports(cellSize: 0.25)
        #expect(fine.structuralObject(sourceID: models[0].id)?.id == a.id)
        #expect(fine.structuralObject(sourceID: models[1].id)?.id == b.id)
        #expect(fine.object(id: b.id)?.structure?.material(of: 0) == .structuralSteel)
        let local = try StructureEditing.changing(fine, objectID: b.id) { body in
            body.openings.append(Box(min: SIMD3(5, 1, 0.25), max: SIMD3(6, 1.5, 0.75)))
        }
        #expect(local.importedModels?.first(where: { $0.id == models[0].id })?.isAttached == true)
        #expect(local.importedModels?.first(where: { $0.id == models[1].id })?.isAttached == false)
        #expect(local.object(id: a.id) == fine.object(id: a.id))
        let finer = try local.resamplingImports(cellSize: 0.125)
        #expect(finer.object(id: b.id) == local.object(id: b.id))
        let archive = try ProjectDocument(scenario: finer).makeArchive()
        #expect(archive.manifest.assets.count == 1)
        #expect(try ProjectDocument(archive: archive).scenario == finer)
    }

    @Test("Replacing a linked import preserves the other body and the replaced owner's ID")
    func replacement() throws {
        var scene = try MultiBodyFixture.imports()
        let original = scene.structuralObjects[0]
        var imported = try #require(scene.importedModels?.last)
        let owner = try #require(scene.structuralObject(sourceID: imported.id))
        imported.corner.x += 0.5
        imported = try imported.sampled(cellSize: 0.5, domain: scene.domainSize)
        try scene.installImport(imported, material: .structuralSteel, fixedBase: true)
        #expect(scene.object(id: original.id) == original)
        #expect(scene.structuralObject(sourceID: imported.id)?.id == owner.id)
        #expect(scene.structuralObject(sourceID: imported.id)?.structure?.bounds.min.x == 5.5)
    }

    @Test("Overlapping owners cannot be saved as a supported run")
    func overlap() throws {
        var scene = try MultiBodyFixture.scene()
        try scene.updateStructureObject(id: scene.structuralObjects[1].id, model: scene.structure!)
        #expect(throws: SceneObjectError.self) { try ProjectDocument(scenario: scene).makeArchive() }
    }
}

@MainActor
@Suite("Multiple structure editor", .serialized)
struct MultiBodyEditorTests {
    @Test("Switching owners scopes component edits, material settings and undo")
    func scopedEditing() throws {
        let scene = try MultiBodyFixture.scene()
        let model = SimulationModel(document: ProjectDocument(scenario: scene))
        let first = scene.structuralObjects[0]
        let second = scene.structuralObjects[1]
        model.selectStructure(id: second.id)
        #expect(model.editedStructure == second.structure)
        model.setStructureMaterial(.masonry)
        model.recordEdit()
        #expect(model.settings.scenario.object(id: first.id) == first)
        #expect(model.settings.scenario.object(id: second.id)?.structure?.material == .masonry)
        let reference = first.references(.solid)[0]
        model.editComponent(reference) { $0.setMaterial(.structuralSteel, of: $1) }
        #expect(model.settings.scenario.object(id: second.id)?.structure?.material == .masonry)
        #expect(model.settings.scenario.object(id: first.id)?.structure?.material(of: 0) == .structuralSteel)
        model.undo()
        #expect(model.settings.scenario.object(id: first.id) == first)
        #expect(model.settings.scenario.object(id: second.id)?.structure?.material == .masonry)
        model.undo()
        #expect(model.settings.scenario == scene)
        model.selectStructure(id: first.id)
        model.setElementKind(.shell, ofSolid: 0)
        model.selectStructure(id: second.id)
        model.setElementKind(.shell, ofSolid: 0)
        model.setElementKind(.solid, ofSolid: 0)
        #expect(model.editedStructure?.elementSize == 0.5)
        model.selectStructure(id: first.id)
        model.setElementKind(.solid, ofSolid: 0)
        #expect(model.editedStructure?.elementSize == 0.25)
    }

    @Test("A completed shared-air run retains both response histories and provenance")
    func capture() async throws {
        let scene = try MultiBodyFixture.scene()
        var document = ProjectDocument(scenario: scene)
        document.runSettings?.resolution = "coarse"
        document.runSettings?.duration = 0.01
        let model = SimulationModel(document: document)
        model.run()
        let deadline = ContinuousClock.now + .seconds(30)
        while !model.canKeepRun {
            try #require(model.errorMessage == nil)
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(5))
            if !model.isRunning && model.time == 0 { model.run() }
        }
        #expect(Set(model.bodyHistories.keys) == Set(scene.structuralObjects.map(\.id)))
        #expect(model.bodyHistories.values.allSatisfy { $0.count >= 2 })
        try model.keepRun(named: "Two bodies")
        let run = try #require(model.savedRuns.first)
        #expect(run.solverVersion == SavedSimulationRun.multiBodySolverVersion)
        #expect(run.bodyResponses?.count == 2)
        #expect(run.bodyResponses?.allSatisfy({ $0.response.peak > 0 }) == true)
        let archive = try ProjectDocument(model: model).makeArchive()
        let reopened = try ProjectDocument(archive: archive)
        #expect(reopened.savedRuns == model.savedRuns)
        var historical = run
        historical.solverVersion = SavedSimulationRun.previousMultiBodySolverVersion
        var historicalDocument = ProjectDocument(scenario: scene)
        historicalDocument.savedRuns = [historical]
        let historicalRoundTrip = try ProjectDocument(archive: historicalDocument.makeArchive())
        #expect(historicalRoundTrip.savedRuns[0].solverVersion == "blast-solver-3")
        for object in scene.structuralObjects {
            #expect(run.csv().contains(object.id.uuidString))
            #expect(model.resultsCSV().contains(object.id.uuidString))
        }
        var invalid = run
        let duplicateID = invalid.bodyResponses![0].id
        invalid.bodyResponses?[1].id = duplicateID
        #expect(throws: ProjectFileError.self) { try invalid.validate() }
        invalid = run
        invalid.bodyResponses = nil
        #expect(throws: ProjectFileError.self) { try invalid.validate() }
    }
}
