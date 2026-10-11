import BlastCore
import Foundation
import Testing
import simd

@testable import BombCAD

@Suite("IFC batch geometry review")
struct IFCBatchReviewTests {
    private func fixture(_ name: String) throws -> Data {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try Data(contentsOf: root.appendingPathComponent("Samples/Importer/Buildings/" + name))
    }
    @Test("All invalid products are reviewed while valid meshes remain unavailable for partial import")
    func multipleFailures() throws {
        let a = "0000000000000000000001"
        let b = "0000000000000000000002"
        let obj = "v 0 0 0\nv 1 0 0\nv 0 1 0\ng \(b)\nf 1 2 3\ng \(a)\nf 1 2 3\n"
        let metadata: [String: IFCImporter.Element] = [
            a: .init(id: a, name: "Open wall", ifcClass: "IfcWall"),
            b: .init(id: b, name: "Open floor", ifcClass: "IfcSlab"),
        ]
        let review = try IFCImporter.inspectOBJ(Data(obj.utf8), metadata: metadata)
        #expect(review.failures.map(\.id) == [a, b])
        #expect(review.elements.isEmpty && review.inspectedElements == 2)
        do {
            _ = try IFCImporter.decodeOBJ(Data(obj.utf8), metadata: metadata)
            Issue.record("Failed geometry yielded an importable result")
        } catch let failure as IFCImporter.ElementFailures {
            #expect(failure.failures.count == 2)
            #expect(failure.report.contains(a) && failure.report.contains(b))
        }
    }
    @Test(
        "Real duplex failures are collected in one pass and explicit exclusions yield validated geometry",
        .enabled(if: IFCImporter.converterURL != nil))
    func duplex() async throws {
        let prepared = try await IFCImporter.prepare(fixture("duplex-apartment.ifc"))
        var failures: IFCImporter.ElementFailures?
        do {
            _ = try await IFCImporter.convert(prepared, includedIDs: prepared.defaultIDs)
            Issue.record("Invalid duplex solids were accepted")
        } catch let review as IFCImporter.ElementFailures { failures = review }
        let review = try #require(failures)
        #expect(review.failures.count > 2)
        #expect(review.failures.contains { $0.id == "1hOSvn6df7F8_7GcBWlRGQ" })
        #expect(review.failures.contains { $0.id == "1hOSvn6df7F8_7GcBWlR72" })
        let ids = prepared.defaultIDs.subtracting(review.failures.map(\.id))
        let source = try await IFCImporter.convert(prepared, includedIDs: ids)
        #expect(Set(source.buildingSelection?.includedIDs ?? []) == ids)
        #expect(source.parts.count == review.inspectedElements - review.failures.count)
        #expect(source.buildingElements?.allSatisfy { ids.contains($0.globalID) } == true)
        #expect(source.buildingSourceData == prepared.data)
    }
    @Test(
        "Surviving real IFC elements keep world placement across selection, save and grid changes",
        .enabled(if: IFCImporter.converterURL != nil))
    func realPlacement() async throws {
        let prepared = try await IFCImporter.prepare(fixture("building-architecture.ifc"))
        let full = try await IFCImporter.convert(prepared, includedIDs: prepared.defaultIDs)
        let chosen = Set(
            prepared.inventory.filter { $0.supported && $0.storey == "00 groundfloor" }.map(\.id))
        let source = try await IFCImporter.convert(prepared, includedIDs: chosen)
        let originalCorner = SIMD3<Double>(4, 5, 1)
        let corner = try ImportedMesh.preservingBuildingPlacement(
            from: full, to: source, corner: originalCorner)
        let oldMesh = try full.transformed(scale: 1, yUp: false, corner: SIMD3<Float>(originalCorner))
        let newMesh = try source.transformed(scale: 1, yUp: false, corner: SIMD3<Float>(corner))
        for e in newMesh.buildingElements! {
            let before = try #require(oldMesh.buildingElements?.first { $0.globalID == e.globalID })
            #expect(simd_length(before.mesh.bounds.min - e.mesh.bounds.min) < 0.00001)
            #expect(simd_length(before.mesh.bounds.max - e.mesh.bounds.max) < 0.00001)
        }
        var scene = Scenario(
            name: "Placed subset", domainSize: SIMD3(repeating: 32), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(24, 24, 1)))
        let preview = try newMesh.preview(cellSize: 0.25, domain: scene.domainSize)
        try scene.installImport(
            .init(
                name: "IFC", source: source, scale: 1, yUp: false, corner: SIMD3<Float>(corner),
                behavior: .rigid, preview: preview), material: .plainConcrete, fixedBase: false)
        var document = ProjectDocument(scenario: scene)
        document.runSettings?.resolution = "medium"
        let reopened = try ProjectDocument(archive: document.makeArchive())
        let fine = try reopened.scenario.resamplingImports(cellSize: 0.125)
        #expect(fine.importedModels?.first?.corner == SIMD3<Float>(corner))
        #expect(fine.importedModels?.first?.source.buildingOrigin == source.buildingOrigin)
    }
    @MainActor
    @Test("Opening a legacy IFC project refreshes gap warnings on the same grid without moving geometry")
    func legacyWarnings() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let cube = try ImportedMesh(
            data: Data(contentsOf: root.appendingPathComponent("Samples/Importer/unit-cube.obj")),
            fileExtension: "obj")
        let source = try ImportedMesh(
            buildingElements: [
                .init(
                    globalID: "0000000000000000000001", name: "A", ifcClass: "IfcWall", storey: nil,
                    mesh: cube),
                .init(
                    globalID: "0000000000000000000002", name: "B", ifcClass: "IfcWall", storey: nil,
                    mesh: cube.transformed(scale: 1, yUp: false, corner: SIMD3(1.05, 0, 0))),
            ], origin: .zero)
        let corner = SIMD3<Float>(1, 1, 0)
        var oldPreview = try source.transformed(scale: 1, yUp: false, corner: corner).preview(
            cellSize: 0.25, domain: SIMD3(repeating: 8))
        oldPreview.smallGaps -= oldPreview.crossElementGapSamples ?? 0
        oldPreview.crossElementGapSamples = nil
        oldPreview.crossElementChecksIncomplete = nil
        oldPreview.diagnostics.removeAll { $0.betweenElements == true }
        let old = ImportedModel(
            name: "Legacy IFC", source: source, scale: 1, yUp: false, corner: corner, behavior: .rigid,
            preview: oldPreview)
        var scene = Scenario(
            name: "Legacy", domainSize: SIMD3(repeating: 8), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(7, 7, 1)))
        try scene.installImport(old, material: .plainConcrete, fixedBase: false)
        var document = ProjectDocument(scenario: scene)
        document.runSettings?.resolution = "medium"
        let restored = try ProjectDocument(archive: document.makeArchive())
        let session = ProjectSession(document: restored)
        let deadline = ContinuousClock.now + .seconds(15)
        while session.model.isLoadingInputs || session.model.isPreparingImports {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(session.model.errorMessage == nil)
        let updated = try #require(session.snapshot.scenario.importedModels?.first)
        #expect((updated.preview.crossElementGapSamples ?? 0) > 0)
        #expect(updated.corner == corner && updated.preview.boxes == oldPreview.boxes)
        #expect(updated.source == source)
        var detached = old
        detached.regenerationEnabled = false
        #expect(!detached.needsSampling(cellSize: 0.25))
        var independent = scene
        independent.importedModels = [detached]
        independent.boxes = oldPreview.boxes
        #expect(try independent.resamplingImports(cellSize: 0.25) == independent)
    }

}
