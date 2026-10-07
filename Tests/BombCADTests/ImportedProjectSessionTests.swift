import BlastCore
import Foundation
import Testing

@testable import BombCAD

@MainActor
@Suite("Imported document sessions", .serialized)
struct ImportedProjectSessionTests {
    private func document(behavior: ImportedModel.Behavior = .deformable) throws -> ProjectDocument {
        let samples = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
                "Samples/Importer")
        let source = try ImportedMesh(
            data: Data(contentsOf: samples.appendingPathComponent("named-parts.obj")), fileExtension: "obj")
        let column = try #require(source.parts.first { $0.name == "Steel column" }).id
        let panel = try #require(source.parts.first { $0.name == "Thin panel" }).id
        let corner = SIMD3<Float>(1, 1, 0)
        let transformed = try source.transformed(scale: 1, yUp: false, corner: corner)
        let imported = ImportedModel(
            name: "Named parts", source: source, scale: 1, yUp: false, corner: corner,
            behavior: behavior,
            preview: try transformed.preview(cellSize: 0.25, domain: SIMD3(repeating: 8)),
            partMaterials: [column: .structuralSteel, panel: .annealedGlass])
        var scene = Scenario(
            name: "Imported session", domainSize: SIMD3(repeating: 8), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(7, 7, 2)))
        try scene.installImport(imported, material: .plainConcrete, fixedBase: true)
        var document = ProjectDocument(scenario: scene)
        document.runSettings?.resolution = "medium"
        document.runSettings?.solidElementSize = 0.25
        return document
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while !condition() {
            try #require(ContinuousClock.now < deadline, "Timed out waiting for import regeneration")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // Exercise the snapshot and atomic package writer used by the document/autosave path.
    private func save(_ session: ProjectSession, to url: URL) throws -> ProjectDocument {
        try session.snapshot.makeArchive().fileWrapper().write(
            to: url, options: .atomic, originalContentsURL: nil)
        return try ProjectDocument.read(from: url)
    }

    @Test(
        "Repeated document saves preserve imported warnings and material edits without reloading undo",
        arguments: [ImportedModel.Behavior.rigid, .deformable])
    func autosaveMaterials(behavior: ImportedModel.Behavior) throws {
        let initial = try ProjectDocument(archive: document(behavior: behavior).makeArchive())
        let session = ProjectSession(document: initial)
        let source = try #require(initial.scenario.importedModels?.first)
        #expect(!source.preview.diagnostics.isEmpty)
        #expect(session.snapshot == initial)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("autosaved.bombcad")
        let first = try save(session, to: url)

        var edited = source
        let column = try #require(source.source.parts.first { $0.name == "Steel column" }).id
        edited.partMaterials?[column] = .masonry
        try session.model.settings.scenario.installImport(
            edited, material: .plainConcrete, fixedBase: true)
        session.model.recordEdit()
        let changed = session.snapshot
        #expect(changed != initial)
        #expect(session.model.canUndo)
        session.receive(changed)
        #expect(session.model.canUndo)
        let saved = try save(session, to: url)
        #expect(saved.documentID == first.documentID)
        #expect(saved.archive?.manifest.assets == first.archive?.manifest.assets)
        #expect(saved.scenario == changed.scenario)
        let restored = ProjectSession(document: saved)
        let imported = try #require(restored.model.settings.scenario.importedModels?.first)
        #expect(imported.id == source.id && imported.source == source.source)
        #expect(imported.partMaterials == edited.partMaterials)
        #expect(imported.preview.diagnostics == source.preview.diagnostics)
        #expect(imported.preview.warnings == source.preview.warnings)
        #expect(restored.snapshot == saved)
        #expect(!restored.model.canUndo)
        if behavior == .deformable {
            #expect(restored.model.settings.scenario.structure?.fixedBase == true)
            #expect(restored.model.settings.scenario.structure?.supports == edited.supports(fixedBase: true))
            let n = try #require(imported.preview.boxPartIDs?.firstIndex(of: column))
            #expect(restored.model.settings.scenario.structure?.material(of: n) == .masonry)
        }
    }

    @Test(
        "Reopening an autosave made during a grid change regenerates retained sources",
        arguments: [ImportedModel.Behavior.rigid, .deformable])
    func pendingGridAutosave(behavior: ImportedModel.Behavior) async throws {
        let initial = try ProjectDocument(archive: document(behavior: behavior).makeArchive())
        let session = ProjectSession(document: initial)
        session.model.settings.resolution = .fine
        session.model.settingsChanged()
        #expect(session.model.isPreparingImports)
        // Snapshot immediately, while the previous preview still belongs to Medium.
        let pending = try ProjectDocument(archive: session.snapshot.makeArchive())
        #expect(pending.runSettings?.resolution == "fine")
        #expect(pending.scenario.importedModels?.first?.preview.cellSize == 0.25)
        let reopened = ProjectSession(document: pending)
        try #require(reopened.model.isPreparingImports)
        reopened.model.run()
        #expect(!reopened.model.isRunning)
        try await waitUntil {
            reopened.model.grid?.cellSize == 0.125 && !reopened.model.isPreparingImports
        }
        #expect(reopened.model.errorMessage == nil)
        let imported = try #require(reopened.model.settings.scenario.importedModels?.first)
        let previous = try #require(initial.scenario.importedModels?.first)
        #expect(imported.preview.occupiedCells == 1088)
        #expect(imported.source == previous.source && imported.partMaterials == previous.partMaterials)
        let panel = try #require(imported.source.parts.first { $0.name == "Thin panel" }).id
        #expect(imported.preview.thinSpans > 0)
        #expect(imported.preview.boxPartIDs?.contains(panel) == true)
        if behavior == .deformable {
            let n = try #require(imported.preview.boxPartIDs?.firstIndex(of: panel))
            #expect(reopened.model.settings.scenario.structure?.material(of: n) == .annealedGlass)
            #expect(
                reopened.model.settings.scenario.structure?.supports == imported.supports(fixedBase: true))
        }
        let nextSave = try reopened.snapshot.makeArchive()
        #expect(nextSave.manifest.assets == initial.archive?.manifest.assets)
        #expect(try ProjectDocument(archive: nextSave).scenario == reopened.model.settings.scenario)
        try await waitUntil { !session.model.isPreparingImports }
    }
}
