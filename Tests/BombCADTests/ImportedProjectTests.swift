import BlastCore
import DocumentKit
import Foundation
import Testing

@testable import BombCAD

@Suite("Imported project assets")
struct ImportedProjectTests {
    private var samples: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Samples/Importer")
    }

    private func mesh(_ name: String) throws -> ImportedMesh {
        try ImportedMesh(data: Data(contentsOf: samples.appendingPathComponent(name)), fileExtension: "obj")
    }

    private func model(
        _ name: String = "named-parts.obj", scale: Float = 1, yUp: Bool = false,
        corner: SIMD3<Float> = SIMD3(1, 1, 0), behavior: ImportedModel.Behavior = .rigid
    ) throws -> ImportedModel {
        let source = try mesh(name)
        let transformed = try source.transformed(scale: scale, yUp: yUp, corner: corner)
        var assignments: [Int: StructureMaterial] = [source.parts[0].id: .plainConcrete]
        if let last = source.parts.last, last.id != source.parts[0].id {
            assignments[last.id] = .structuralSteel
        }
        return ImportedModel(
            name: name, source: source, scale: scale, yUp: yUp, corner: corner, behavior: behavior,
            preview: try transformed.preview(cellSize: 0.25, domain: SIMD3(repeating: 8)),
            partMaterials: assignments)
    }

    private func document(_ models: [ImportedModel]) -> ProjectDocument {
        var scenario = Scenario(
            name: "Asset test", domainSize: SIMD3(repeating: 8), boxes: [],
            charge: Charge(mass: 1, position: SIMD3(7, 7, 1)))
        scenario.importedModels = models
        return ProjectDocument(scenario: scenario)
    }

    private func payload(_ archive: ProjectArchive) throws -> ImportedSceneCodec.ScenePayload {
        try JSONDecoder().decode(ImportedSceneCodec.ScenePayload.self, from: archive.files["scene.json"]!)
    }

    @Test("Source meshes move into assets; identical sources share one stable asset across autosaves")
    func sharedSources() throws {
        let first = try model()
        let second = try model(corner: SIMD3(2, 1, 0))
        let original = document([first, second])
        let saved = try original.makeArchive()
        let repeated = try original.makeArchive()
        #expect(saved.manifest.assets.count == 1)
        #expect(saved.manifest.assets == repeated.manifest.assets)
        let scene = try payload(saved)
        #expect(scene.scenario.importedModels == nil)
        #expect(scene.imports?.count == 2)
        #expect(scene.imports?[0].sourceAssetID == scene.imports?[1].sourceAssetID)
        #expect(!String(decoding: saved.files["scene.json"]!, as: UTF8.self).contains("\"triangles\""))
        let restored = try ProjectDocument(archive: saved)
        #expect(restored.scenario == original.scenario)
        #expect(try restored.makeArchive().manifest.assets == saved.manifest.assets)
        #expect(restored.scenario.importedModels?[0].source.parts == first.source.parts)
        #expect(restored.scenario.importedModels?[0].partMaterials == first.partMaterials)
    }

    @Test("Source coordinates remain unscaled; millimetres and Y-up conversion apply exactly once")
    func sourceCoordinates() throws {
        let imported = try model("millimetres-y-up.obj", scale: 0.001, yUp: true, corner: SIMD3(2, 3, 1))
        let saved = try document([imported]).makeArchive()
        let asset = try #require(saved.manifest.assets.first)
        let source = try JSONDecoder().decode(
            ImportedSceneCodec.SourceMesh.self, from: saved.files[asset.path]!)
        #expect(source.coordinateSpace == "source")
        #expect(source.mesh == imported.source)
        #expect(source.mesh.bounds.size != imported.preview.bounds.size)
        let reopened = try #require(ProjectDocument(archive: saved).scenario.importedModels?.first)
        #expect(try reopened.transformedSource() == imported.transformedSource())
        #expect(reopened.scale == 0.001 && reopened.yUp)
        #expect(reopened.corner == SIMD3<Float>(2, 3, 1))
        #expect(reopened.preview == imported.preview)
    }

    @Test("Detached structural edits and rigid geometry survive without regeneration")
    func detachedEdits() throws {
        let deformable = try model(behavior: .deformable)
        var original = document([])
        try original.scenario.installImport(deformable, material: .plainConcrete, fixedBase: true)
        original.scenario.detachImport(id: deformable.id)
        original.scenario.structure?.solids[0].max.z += 0.125
        original.scenario.structure?.openings = [Box(min: SIMD3(1.2, 1.2, 0.2), max: SIMD3(1.4, 1.4, 0.4))]
        original.scenario.structure?.supports = [Box(min: SIMD3(1, 1, 0), max: SIMD3(2, 2, 0.1))]
        original.scenario.structure?.fixedBase = false
        let reinforcementRegion = try #require(original.scenario.structure?.bounds)
        original.scenario.structure?.reinforcement = [
            .init(region: reinforcementRegion, ratio: SIMD3(0.01, 0, 0))
        ]
        let saved = try original.makeArchive()
        let restored = try ProjectDocument(archive: saved)
        #expect(restored.scenario == original.scenario)
        #expect(restored.scenario.importedModels?.first?.isAttached == false)
        #expect(try restored.scenario.resamplingImports(cellSize: 0.5) == restored.scenario)

        let rigid = try model("unit-cube.obj")
        var rigidDocument = document([])
        try rigidDocument.scenario.installImport(rigid, material: .plainConcrete, fixedBase: false)
        rigidDocument.scenario.detachImport(id: rigid.id)
        rigidDocument.scenario.boxes[0].min.x += 0.1
        let rigidRestored = try ProjectDocument(archive: rigidDocument.makeArchive())
        #expect(rigidRestored.scenario == rigidDocument.scenario)
        #expect(try rigidRestored.scenario.resamplingImports(cellSize: 0.5) == rigidRestored.scenario)
    }

    @Test("Managed imports can resample after reopening while keeping part material assignments")
    func resample() throws {
        let imported = try model(behavior: .deformable)
        var original = document([])
        try original.scenario.installImport(imported, material: .plainConcrete, fixedBase: false)
        let restored = try ProjectDocument(archive: original.makeArchive())
        let resampled = try restored.scenario.resamplingImports(cellSize: 0.125)
        #expect(resampled.importedModels?.first?.partMaterials == imported.partMaterials)
        #expect(resampled.importedModels?.first?.source.parts == imported.source.parts)
        var edited = restored
        edited.scenario = resampled
        edited.runSettings?.resolution = "fine"
        #expect(try ProjectDocument(archive: edited.makeArchive()).scenario == resampled)
    }

    @Test("A moved project reopens after the original import file has been removed")
    func portableProject() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sourceURL = folder.appendingPathComponent("source.obj")
        try Data(contentsOf: samples.appendingPathComponent("unit-cube.obj")).write(to: sourceURL)
        let source = try ImportedMesh(data: Data(contentsOf: sourceURL), fileExtension: "obj")
        let imported = ImportedModel(
            name: "Portable", source: source, scale: 1, yUp: false, corner: .zero, behavior: .rigid,
            preview: try source.preview(cellSize: 0.25, domain: SIMD3(repeating: 8)))
        let projectURL = folder.appendingPathComponent("original.bombcad")
        let movedURL = folder.appendingPathComponent("moved.bombcad")
        let original = document([imported])
        try original.makeArchive().fileWrapper().write(
            to: projectURL, options: .atomic, originalContentsURL: nil)
        try FileManager.default.moveItem(at: projectURL, to: movedURL)
        try FileManager.default.removeItem(at: sourceURL)
        #expect(try ProjectDocument.read(from: movedURL).scenario == original.scenario)
    }

    @Test("Missing references, changed part IDs, cache mismatches and unsupported mesh versions fail clearly")
    func invalidReferences() throws {
        let original = try document([model()]).makeArchive()
        var saved = original
        var scene = try payload(saved)
        scene.imports?[0].sourceAssetID = UUID()
        saved.files["scene.json"] = try ProjectArchive.encodeJSON(scene)
        #expect(throws: (any Error).self) { try ProjectDocument(archive: saved) }
        scene = try payload(original)
        scene.imports?[0].previewKey.scale *= 2
        saved.files["scene.json"] = try ProjectArchive.encodeJSON(scene)
        #expect(throws: (any Error).self) { try ProjectDocument(archive: saved) }
        scene = try payload(original)
        scene.imports?[0].partMaterials = [99999: .masonry]
        saved.files["scene.json"] = try ProjectArchive.encodeJSON(scene)
        #expect(throws: (any Error).self) { try ProjectDocument(archive: saved) }

        saved = original
        let asset = saved.manifest.assets[0]
        var source = try JSONDecoder().decode(
            ImportedSceneCodec.SourceMesh.self, from: saved.files[asset.path]!)
        source.parts[0].id += 1
        var data = try ProjectArchive.encodeJSON(source)
        saved.files[asset.path] = data
        saved.manifest.assets[0] = ProjectManifest.Asset(id: asset.id, path: asset.path, data: data)
        #expect(throws: (any Error).self) { try ProjectDocument(archive: saved) }
        source.parts[0].id -= 1
        source.encodingVersion = 99
        data = try ProjectArchive.encodeJSON(source)
        saved.files[asset.path] = data
        saved.manifest.assets[0] = ProjectManifest.Asset(id: asset.id, path: asset.path, data: data)
        #expect(throws: (any Error).self) { try ProjectDocument(archive: saved) }
    }
}
