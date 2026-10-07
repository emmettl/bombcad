import BlastCore
import Foundation
import Testing
import simd

@testable import BombCAD

@Suite("IFC native import")
struct IFCImportTests {
    private var fixture: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(
                "Samples/Importer/Buildings/building-architecture.ifc")
    }
    @Test(
        "Whole-building IFC conversion preserves named physical elements and project sources",
        .enabled(
            if: IFCImporter.converterURL != nil, "Prepare the pinned IFC converter before integration tests"))
    func building() async throws {
        let source = try await IFCImporter.convert(Data(contentsOf: fixture))
        #expect(source.parts.count == 7)
        #expect(source.parts.filter { $0.ifcClass == "IfcWall" }.count == 4)
        #expect(source.parts.filter { $0.ifcClass == "IfcSlab" }.count == 3)
        #expect(source.parts.allSatisfy { $0.ifcGlobalID?.count == 22 })
        #expect(source.parts.contains { $0.name == "floor" && $0.storey == "00 groundfloor" })
        #expect(source.buildingOrigin != nil)
        #expect(source.bounds.min == .zero)
        #expect(source.bounds.size.x > 6 && source.bounds.size.z > 5)
        #expect(source.buildingSourceData == (try Data(contentsOf: fixture)))
        let medium = try source.preview(cellSize: 0.25, domain: SIMD3(repeating: 16))
        #expect(medium.occupiedCells > 0)
        let origin = try #require(source.buildingOrigin)
        func local(_ world: SIMD3<Double>) -> SIMD3<Float> { SIMD3<Float>(world - origin) }
        // The source floor has an entrance recess; neither it nor the interior air is filled.
        #expect(!medium.boxes.contains { $0.contains(local(SIMD3(6.3, 3.1, -0.125))) })
        #expect(!medium.boxes.contains { $0.contains(local(SIMD3(6.2, 6.2, 1))) })
        #expect(medium.boxes.contains { $0.contains(local(SIMD3(3.5, 4, -0.125))) })
        #expect(Set(medium.boxPartIDs ?? []).isSubset(of: Set(source.parts.map(\.id))))
        var scene = Scenario(
            name: "IFC house", domainSize: SIMD3(repeating: 16), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(14, 14, 1)))
        let imported = ImportedModel(
            name: "IFC house", source: source, scale: 1, yUp: false, corner: .zero, behavior: .rigid,
            preview: medium)
        try scene.installImport(imported, material: .plainConcrete, fixedBase: false)
        var document = ProjectDocument(scenario: scene)
        document.runSettings?.resolution = "medium"
        let archive = try document.makeArchive()
        let restored = try ProjectDocument(archive: archive)
        #expect(restored.scenario == scene)
        #expect(
            restored.scenario.importedModels?.first?.source.buildingSourceData == source.buildingSourceData)
        #expect(restored.scenario.importedModels?.first?.source.parts == source.parts)
        let asset = try #require(archive.manifest.assets.first)
        let savedSource = try JSONDecoder().decode(
            ImportedSceneCodec.SourceMesh.self, from: archive.files[asset.path]!)
        #expect(savedSource.encodingVersion == 2)
        let fine = try restored.scenario.resamplingImports(cellSize: 0.125)
        #expect(fine.importedModels?.first?.source.parts == source.parts)
    }
    @Test("Large world coordinates are rebased before conversion to Float and GUIDs survive")
    func localCoordinates() throws {
        let id = "0OfZwWc8j9QP5uX8xPTxDH"
        let vertices = [
            SIMD3<Double>(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1),
            SIMD3(1, 0, 1), SIMD3(1, 1, 1), SIMD3(0, 1, 1),
        ]
        let faces = [
            [1, 4, 3], [1, 3, 2], [5, 6, 7], [5, 7, 8], [1, 2, 6], [1, 6, 5], [2, 3, 7], [2, 7, 6],
            [3, 4, 8], [3, 8, 7], [4, 1, 5], [4, 5, 8],
        ]
        let offset = SIMD3<Double>(1e9, 2e9, -3e9)
        var text = "g \(id)\n"
        for v in vertices {
            let p = v + offset
            text += "v \(p.x) \(p.y) \(p.z)\n"
        }
        for f in faces { text += "f " + f.map(String.init).joined(separator: " ") + "\n" }
        let result = try IFCImporter.decodeOBJ(
            Data(text.utf8),
            metadata: [id: .init(id: id, name: "Wall", ifcClass: "IfcWall", storey: "Ground")])
        #expect(result.origin == offset)
        #expect(result.elements.first?.mesh.bounds.size == SIMD3(repeating: 1))
        let source = try ImportedMesh(buildingElements: result.elements, origin: result.origin)
        #expect(source.parts.first?.ifcGlobalID == id)
        #expect(source.parts.first?.storey == "Ground")
    }
    @Test("An actually open IFC surface is rejected; boundary segmentation never fills a missing face")
    func openSurface() {
        let id = "0OfZwWc8j9QP5uX8xPTxDH"
        let obj = "g \(id)\nv 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n"
        #expect(throws: ImportedMesh.ImportError.self) {
            try IFCImporter.decodeOBJ(
                Data(obj.utf8),
                metadata: [id: .init(id: id, name: "Open wall", ifcClass: "IfcWall", storey: "Ground")])
        }
    }
    @Test("Malformed converter geometry fails without losing identity")
    func malformed() {
        #expect(throws: ImportedMesh.ImportError.self) {
            try IFCImporter.decodeOBJ(Data("g unknown\nv 0 0 0\nf 1 2 3".utf8), metadata: [:])
        }
    }
    @Test("Cancellation and unavailable converter never yield an importable source")
    func cancellation() async {
        do {
            _ = try await IFCImporter.convert(Data(), converter: nil)
            Issue.record("Missing helper was accepted")
        } catch { #expect(error.localizedDescription.contains("unavailable")) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await IFCImporter.convert(Data("invalid IFC".utf8))
        }
        do {
            _ = try await task.value
            Issue.record("Cancelled conversion returned geometry")
        } catch { #expect(error is CancellationError || error is ImportedMesh.ImportError) }
    }
    @MainActor
    @Test(
        "IFC files use the same cancellable file-loader presentation path",
        .enabled(
            if: IFCImporter.converterURL != nil, "Prepare the pinned IFC converter before integration tests"))
    func fileLoader() async throws {
        let loader = ImportFileLoader()
        loader.load(fixture)
        let deadline = ContinuousClock.now + .seconds(20)
        while loader.isLoading {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(loader.error == nil)
        #expect(loader.result?.inspection.validatedMesh?.buildingElements?.count == 7)
        loader.load(fixture)
        loader.cancel()
        try await Task.sleep(for: .milliseconds(300))
        #expect(!loader.isLoading && loader.result == nil)
    }

}
