import BlastCore
import CryptoKit
import Foundation
import Testing
import simd

@testable import BombCAD

@Suite("Selective IFC import and completeness")
struct IFCSelectionTests {
    private func fixture(_ name: String) throws -> Data {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Samples/Importer/Buildings")
        return try Data(contentsOf: root.appendingPathComponent(name))
    }
    @Test("Repository IFC fixture bytes match the pinned provenance manifest")
    func fixtureProvenance() throws {
        struct Entry: Decodable {
            var file: String
            var bytes: Int
            var sha256: String
        }
        struct Manifest: Decodable {
            var files: [Entry]
            var additionalModels: [Entry]
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: fixture("manifest.json"))
        for entry in manifest.files + manifest.additionalModels {
            let data = try fixture(entry.file)
            #expect(data.count == entry.bytes)
            #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == entry.sha256)
        }
    }
    @Test("Spatial scope uses GUIDs, preserves duplicate storey names, and does not leak between buildings")
    func hierarchy() throws {
        func id(_ n: Int) -> String { String(format: "%022d", n) }
        let xml = """
            <ifc><decomposition><IfcProject id="\(id(1))">
            <IfcBuilding id="\(id(2))" Name="West"><IfcBuildingStorey id="\(id(3))" Name="Ground">
            <IfcWall id="\(id(4))" Name="A"/><IfcFurniture id="\(id(5))" Name="Chair"/>
            </IfcBuildingStorey></IfcBuilding>
            <IfcBuilding id="\(id(6))" Name="East"><IfcBuildingStorey id="\(id(7))" Name="Ground">
            <IfcWall id="\(id(8))" Name="B"/>
            </IfcBuildingStorey></IfcBuilding>
            <IfcRoof id="\(id(9))" Name="Outside"><IfcSlab id="\(id(10))"/></IfcRoof>
            </IfcProject></decomposition></ifc>
            """
        let elements = try IFCImporter.decodeMetadata(Data(xml.utf8))
        #expect(elements.count == 5)
        let a = try #require(elements.first { $0.id == id(4) })
        let b = try #require(elements.first { $0.id == id(8) })
        #expect(a.storey == b.storey && a.storeyID != b.storeyID)
        #expect(a.building == "West" && b.building == "East")
        #expect(elements.first { $0.id == id(9) }?.building == nil)
        #expect(elements.first { $0.id == id(9) }?.hasChildren == true)
        #expect(elements.first { $0.id == id(5) }?.supported == false)
        #expect(throws: ImportedMesh.ImportError.self) {
            try IFCImporter.decodeMetadata(
                Data("<ifc><decomposition><IfcWall id='bad'/></decomposition></ifc>".utf8))
        }
        #expect(throws: ImportedMesh.ImportError.self) {
            try IFCImporter.decodeMetadata(
                Data(
                    "<ifc><decomposition><IfcWall id='\(id(4))'/><IfcWall id='\(id(4))'/></decomposition></ifc>"
                        .utf8))
        }
    }
    @Test(
        "A chosen storey converts only its GUIDs and persists choices, exclusions and original IFC",
        .enabled(if: IFCImporter.converterURL != nil))
    func chosenStorey() async throws {
        let data = try fixture("building-architecture.ifc")
        let prepared = try await IFCImporter.prepare(data)
        let selected = Set(
            prepared.inventory.filter { $0.supported && $0.storey == "00 groundfloor" }.map(\.id))
        #expect(selected.count == 5)
        let mesh = try await IFCImporter.convert(prepared, includedIDs: selected)
        #expect(Set(mesh.buildingElements!.map(\.globalID)) == selected)
        #expect(mesh.parts.allSatisfy { $0.storey == "00 groundfloor" })
        #expect(mesh.buildingSourceData == data)
        let preview = try mesh.preview(cellSize: 0.25, domain: SIMD3(repeating: 16))
        let rows = IFCCompleteness.rows(mesh: mesh, preview: preview)
        #expect(rows.filter { $0.status == "Excluded by your choices" }.count == 3)
        #expect(rows.contains { $0.type == "IfcChimney" && $0.status == "Unsupported type, excluded" })
        #expect(rows.filter { $0.sampling != nil }.count == 5)
        var scene = Scenario(
            name: "Subset", domainSize: SIMD3(repeating: 16), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(14, 14, 1)))
        try scene.installImport(
            .init(
                name: "Subset", source: mesh, scale: 1, yUp: false, corner: .zero,
                behavior: .rigid, preview: preview), material: .plainConcrete, fixedBase: false)
        var document = ProjectDocument(scenario: scene)
        document.runSettings?.resolution = "medium"
        let restored = try ProjectDocument(archive: document.makeArchive())
        let saved = try #require(restored.scenario.importedModels?.first?.source)
        #expect(saved.buildingSelection == mesh.buildingSelection)
        #expect(saved.buildingSourceData == data)
        #expect(
            try saved.transformed(scale: 1, yUp: false, corner: SIMD3(2, 2, 0)).buildingSelection
                == mesh.buildingSelection)
        let fine = try restored.scenario.resamplingImports(cellSize: 0.125)
        #expect(fine.importedModels?.first?.source.buildingSelection == mesh.buildingSelection)
        let sourceRows = IFCCompleteness.rows(mesh: saved, preview: nil)
        #expect(!sourceRows.contains { $0.status.contains("grid") && $0.sampling != nil })
    }
    @Test(
        "Excluded, unsupported and unknown GUIDs cannot enter native conversion",
        .enabled(if: IFCImporter.converterURL != nil))
    func guards() async throws {
        let prepared = try await IFCImporter.prepare(fixture("building-architecture.ifc"))
        let unsupported = try #require(prepared.inventory.first { !$0.supported })
        for ids: Set<String> in [[], [unsupported.id], ["0000000000000000000000"]] {
            await #expect(throws: ImportedMesh.ImportError.self) {
                try await IFCImporter.convert(prepared, includedIDs: ids)
            }
        }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await IFCImporter.convert(prepared, includedIDs: prepared.defaultIDs)
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
    }
    @Test(
        "Missing selected geometry remains visible as an omission rather than an exclusion",
        .enabled(if: IFCImporter.converterURL != nil))
    func completeness() async throws {
        let mesh = try await IFCImporter.convert(fixture("building-architecture.ifc"))
        let preview = try mesh.preview(cellSize: 0.25, domain: SIMD3(repeating: 16))
        let roof = try #require(
            IFCCompleteness.rows(mesh: mesh, preview: preview).first { $0.type == "IfcRoof" })
        #expect(roof.issue && roof.status == "No converted geometry; has child elements")
        #expect(roof.sampling == nil)
        #expect(IFCCompleteness.report(mesh: mesh, preview: preview).contains(roof.id))
        #expect(IFCCompleteness.summary(mesh: mesh, preview: preview).contains("1 without geometry"))
    }
    @Test(
        "Real fixtures cover beams, columns, distinct storeys and invalid door/window geometry",
        .enabled(if: IFCImporter.converterURL != nil))
    func broadFixtures() async throws {
        let structural = try await IFCImporter.convert(fixture("building-structural.ifc"))
        #expect(structural.parts.count == 11)
        #expect(structural.parts.filter { $0.ifcClass == "IfcBeam" }.count == 6)
        let column = try await IFCImporter.convert(fixture("column-straight-rectangle.ifc"))
        #expect(column.parts.first?.ifcClass == "IfcColumn")
        #expect(abs(column.bounds.size.z - 3.048) < 0.00001)
        let duplex = try await IFCImporter.prepare(fixture("duplex-apartment.ifc"))
        #expect(duplex.inventory.count == 289 && duplex.defaultIDs.count == 144)
        #expect(Set(duplex.inventory.compactMap(\.storeyID)).count == 4)
        let ids = Set(
            duplex.inventory.filter {
                $0.supported && $0.storey == "Level 1"
                    && ["IfcWallStandardCase", "IfcSlab"].contains($0.ifcClass)
            }.map(\.id))
        let level = try await IFCImporter.convert(duplex, includedIDs: ids)
        #expect(level.parts.count == 31 && Set(level.buildingElements!.map(\.globalID)) == ids)
        #expect(level.bounds.size.x < 10 && level.bounds.size.z < 7)
        let door = try #require(duplex.inventory.first { $0.ifcClass == "IfcDoor" && $0.storey == "Level 1" })
        do {
            _ = try await IFCImporter.convert(duplex, includedIDs: [door.id])
            Issue.record("Open exported door was accepted")
        } catch let failure as IFCImporter.ElementFailure { #expect(failure.id == door.id) }
        let window = try #require(
            duplex.inventory.first { $0.ifcClass == "IfcWindow" && $0.storey == "Level 1" })
        do {
            _ = try await IFCImporter.convert(duplex, includedIDs: [window.id])
            Issue.record("Open exported window was accepted")
        } catch let failure as IFCImporter.ElementFailure { #expect(failure.id == window.id) }

    }
    @Test(
        "An upstream unit-detection failure is blocked before scaled geometry can enter the simulation",
        .enabled(if: IFCImporter.converterURL != nil))
    func unreliableUnits() async throws {
        let prepared = try await IFCImporter.prepare(fixture("wall-with-opening-and-window.ifc"))
        #expect(prepared.defaultIDs.count == 2)
        do {
            _ = try await IFCImporter.convert(prepared, includedIDs: prepared.defaultIDs)
            Issue.record("Undetermined units were accepted")
        } catch { #expect(error.localizedDescription.contains("units could not be determined")) }
    }
}
