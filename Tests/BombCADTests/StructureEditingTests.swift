import BlastCore
import DocumentKit
import Foundation
import Testing

@testable import BombCAD

@Suite("Structural part editing")
struct StructureEditingTests {
    func layout() throws -> Scenario {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let mesh = try ImportedMesh(
            data: Data(contentsOf: root.appendingPathComponent("Samples/Importer/named-parts.obj")),
            fileExtension: "obj")
        let imported = ImportedModel(
            name: "Named structure", source: mesh, scale: 1, yUp: false, corner: .zero,
            behavior: .deformable, preview: try mesh.preview(cellSize: 0.5, domain: SIMD3(repeating: 6)))
        var scenario = Scenario(
            name: "Part edits", domainSize: SIMD3(repeating: 6), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(5, 5, 1)))
        try scenario.installImport(imported, material: .plainConcrete, fixedBase: false)
        return scenario
    }

    @Test("A vanished part retains material choices and gains owned regions after refinement")
    func namedPartRefinement() throws {
        let scene = try layout()
        let parts = StructureEditing.parts(in: scene)
        #expect(parts.map(\.name) == ["Concrete block", "Steel column", "Thin panel"])
        let thin = try #require(parts.last)
        #expect(thin.regions.isEmpty)
        let edited = try StructureEditing.settingMaterial(.structuralSteel, for: thin.id, in: scene)
        #expect(edited.importedModels?.first?.isAttached == true)
        let fine = try edited.resamplingImports(cellSize: 0.125)
        let recovered = try #require(StructureEditing.parts(in: fine).last)
        #expect(!recovered.regions.isEmpty)
        #expect(recovered.id == thin.id)
        #expect(recovered.regions.allSatisfy { fine.structure?.material(of: $0) == .structuralSteel })
        let restored = try ProjectDocument(archive: ProjectDocument(scenario: fine).makeArchive())
        #expect(restored.scenario == fine)
        #expect(StructureEditing.parts(in: restored.scenario).last?.regions == recovered.regions)
    }

    @Test("Detached part ownership follows deletion; material edits affect only surviving owned regions")
    func detachedOwnership() throws {
        let scene = try layout()
        let parts = StructureEditing.parts(in: scene)
        let first = try #require(parts.first)
        let steel = parts[1]
        let changed = try StructureEditing.changing(scene) { body in
            body.removeSolid(at: first.regions[0])
            body.solids.append(Box(min: SIMD3(4, 4, 0), max: SIMD3(5, 5, 1)))
        }
        #expect(changed.importedModels?.first?.isAttached == false)
        #expect(changed.structure?.solidSourceParts.last == .some(nil))
        let edited = try StructureEditing.settingMaterial(.masonry, for: steel.id, in: changed)
        let regions = try #require(StructureEditing.parts(in: edited).first { $0.id == steel.id }).regions
        #expect(!regions.isEmpty)
        #expect(regions.allSatisfy { edited.structure?.material(of: $0) == .masonry })
        #expect(edited.structure?.material(of: edited.structure!.solids.count - 1) == .plainConcrete)
        #expect(edited.importedModels == changed.importedModels)
        #expect(try edited.resamplingImports(cellSize: 0.125) == edited)
        #expect(
            try ProjectDocument(archive: ProjectDocument(scenario: edited).makeArchive()).scenario == edited)
    }

    @Test("An unedited import without stored ownership derives it before a local edit")
    func derivedOwnership() throws {
        var scene = try layout()
        scene.structure?.solidSourceParts = []
        let parts = StructureEditing.parts(in: scene)
        #expect(parts[0].regions == [0])
        #expect(parts[1].regions == [1])
        let changed = try StructureEditing.changing(scene) { body in
            body.openings.append(Box(min: SIMD3(0, 0.25, 0.25), max: SIMD3(1, 0.75, 0.75)))
        }
        #expect(changed.importedModels?.first?.isAttached == false)
        #expect(changed.structure?.solidSourceParts == changed.importedModels?.first?.regionSourceParts)
        #expect(StructureEditing.parts(in: changed).map(\.regions) == parts.map(\.regions))
    }

    @Test("Reinforcement and support edits detach while retaining source and explicit reinforcement layers")
    func authoritativeEdits() throws {
        let scene = try layout()
        let first = try #require(StructureEditing.parts(in: scene).first)
        let spec = Reinforcement.column(longitudinal: 0.025, ties: 0.005)
        let reinforced = try StructureEditing.changing(scene) { body in
            for index in first.regions { body.setReinforcement(spec, of: index) }
        }
        #expect(reinforced.importedModels?.first?.isAttached == false)
        #expect(first.regions.allSatisfy { reinforced.structure?.reinforcement(of: $0) == spec })
        var explicit = reinforced
        let extra = ReinforcementLayer(region: explicit.structure!.bounds, ratio: SIMD3(0.003, 0, 0))
        explicit.structure?.reinforcement.append(extra)
        let supported = try StructureEditing.changing(explicit) { body in
            body.supports.append(Box(min: .zero, max: SIMD3(1, 1, 0.1)))
        }
        #expect(supported.structure?.reinforcement.contains(extra) == true)
        #expect(supported.structure?.reinforcement.count == explicit.structure?.reinforcement.count)
        #expect(supported.importedModels == reinforced.importedModels)
        #expect(
            try ProjectDocument(archive: ProjectDocument(scenario: supported).makeArchive()).scenario
                == supported)
    }

    @Test(
        "No-op edits keep the source attached; unsupported materials and bad references fail transactionally")
    func transactionalValidation() throws {
        let scene = try layout()
        #expect(try StructureEditing.changing(scene) { _ in } == scene)
        var crowded = scene
        crowded.detachImport(id: crowded.importedModels![0].id)
        // The body default plus seven unique region materials fills the eight-material budget.
        let region = crowded.structure!.solids[0]
        crowded.structure!.solids = Array(repeating: region, count: 8)
        let first = try #require(StructureEditing.parts(in: scene).first).id
        crowded.structure!.solidSourceParts = Array(repeating: nil, count: 8)
        crowded.structure!.solidSourceParts[0] = first
        crowded.structure!.solidMaterial = (0..<8).map { n in
            guard n > 0 else { return nil }
            var material = StructureMaterial.plainConcrete
            material.name = "Material \(n)"
            return material
        }
        #expect(throws: ImportedMesh.ImportError.self) {
            try StructureEditing.settingMaterial(.structuralSteel, for: first, in: crowded)
        }
        #expect(crowded.structure!.solidMaterial[0] == nil)
        #expect(throws: ImportedMesh.ImportError.self) {
            try StructureEditing.settingMaterial(
                .masonry,
                for: .init(modelID: first.modelID, partID: 9999), in: scene)
        }
        #expect(throws: ImportedMesh.ImportError.self) {
            try StructureEditing.changing(scene) { $0.supports.append(Box(min: .zero, max: .zero)) }
        }
        var invalid = scene
        invalid.structure?.solidSourceParts[0] = .init(modelID: UUID(), partID: 0)
        #expect(throws: ProjectFileError.self) { try ProjectDocument(scenario: invalid).makeArchive() }
    }
}

@MainActor @Suite("Structural editor workflow", .serialized)
struct StructuralEditorWorkflowTests {
    private func model() throws -> SimulationModel {
        var document = ProjectDocument(scenario: try StructureEditingTests().layout())
        document.runSettings?.resolution = "coarse"
        return SimulationModel(document: document)
    }

    @Test("Part edits, opening placement and detachment undo together and reopen without losing ownership")
    func openingUndo() throws {
        let model = try model()
        let part = try #require(model.structuralParts.first { $0.name == "Steel column" })
        model.selection = .part(part.id)
        model.setPartMaterial(.structuralSteel, for: part.id)
        model.recordEdit()
        #expect(model.settings.scenario.importedModels?.first?.isAttached == true)
        let before = model.settings.scenario
        let bounds = try #require(model.highlightedBox)
        model.addOpening()
        let edited = model.settings.scenario
        let opening = try #require(edited.structure?.openings.first)
        #expect(opening.contains((bounds.min + bounds.max) / 2))
        #expect(edited.importedModels?.first?.isAttached == false)
        model.undo()
        #expect(model.settings.scenario == before)
        model.redo()
        #expect(model.settings.scenario == edited)
        #expect(try ProjectDocument(archive: ProjectDocument(model: model).makeArchive()).scenario == edited)
    }

    @Test("Custom base connections stay linked, regenerate and undo; region laws persist after detachment")
    func connectionEditing() throws {
        let model = try model()
        model.setFixedBase(true)
        model.recordEdit()
        let clamped = model.settings.scenario
        var joint = Anchorage.constructionJoint
        joint.normalStiffness = 2e9
        joint.friction = 0.4
        model.setBaseAnchorage(joint)
        let linked = model.settings.scenario
        #expect(linked.importedModels?.first?.isAttached == true)
        #expect(linked.structure?.baseAnchorage == joint)
        #expect(linked.structure?.anchorage(ofSupport: 0) == joint)
        let fine = try linked.resamplingImports(cellSize: 0.125)
        #expect(fine.structure?.baseAnchorage == joint)
        #expect(fine.structure?.anchorage(ofSupport: 0) == joint)
        model.undo()
        #expect(model.settings.scenario == clamped)
        model.redo()
        #expect(model.settings.scenario == linked)
        model.addSupport()
        model.setSupportAnchorage(.resting(friction: 0.25), at: 1)
        #expect(model.settings.scenario.importedModels?.first?.isAttached == false)
        let detached = model.settings.scenario
        #expect(try detached.resamplingImports(cellSize: 0.125) == detached)
        let archive = try ProjectDocument(model: model).makeArchive()
        let payload = try JSONDecoder().decode(
            ImportedSceneCodec.ScenePayload.self, from: #require(archive.files["scene.json"]))
        #expect(payload.encodingVersion == 2)
        let oldArchive = try ProjectDocument(scenario: clamped).makeArchive()
        let oldPayload = try JSONDecoder().decode(
            ImportedSceneCodec.ScenePayload.self, from: #require(oldArchive.files["scene.json"]))
        #expect(oldPayload.encodingVersion == 1)
        let restored = try ProjectDocument(archive: archive)
        #expect(restored.scenario == detached)
        model.removeSupport(at: 0)
        #expect(model.settings.scenario.structure?.anchorage(ofSupport: 0) == .resting(friction: 0.25))
        let beforeInvalid = model.settings.scenario
        var invalid = joint
        invalid.friction = -1
        model.setSupportAnchorage(invalid, at: 0)
        #expect(model.settings.scenario == beforeInvalid)
    }

    @Test("Ground restraint can stay source-managed; custom support and part reinforcement detach")
    func supportAndReinforcement() throws {
        let model = try model()
        model.setFixedBase(true)
        #expect(model.settings.scenario.importedModels?.first?.isAttached == true)
        #expect(!model.settings.scenario.structure!.supports.isEmpty)
        let part = try #require(model.structuralParts.first)
        model.selection = .part(part.id)
        model.addSupport()
        #expect(model.settings.scenario.importedModels?.first?.isAttached == false)
        #expect(model.settings.scenario.structure?.supports.count == 2)
        if case .support(let index) = model.selection {
            #expect(model.highlightedBox == model.settings.scenario.structure?.supports[index])
            model.removeSupport(at: index)
        } else {
            Issue.record("Add Support must select its new region")
        }
        model.setPartReinforcement(.column(longitudinal: 0.03, ties: 0.005), for: part.id)
        #expect(
            part.regions.allSatisfy {
                model.settings.scenario.structure?.reinforcement(of: $0)
                    == .column(longitudinal: 0.03, ties: 0.005)
            })
        let id = try #require(model.settings.scenario.importedModels?.first?.id)
        model.removeImport(id: id)
        #expect(model.structuralParts.isEmpty)
        #expect(model.settings.scenario.structure?.solidSourceParts.allSatisfy { $0 == nil } == true)
        _ = try ProjectDocument(model: model).makeArchive()
    }
}
