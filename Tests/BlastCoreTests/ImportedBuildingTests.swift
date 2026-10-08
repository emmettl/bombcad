import Foundation
import Testing
import simd

@testable import BlastCore

@Suite("Independent IFC element sampling")
struct ImportedBuildingTests {
    private func cube(size: Float = 1, corner: SIMD3<Float> = .zero) throws -> ImportedMesh {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Samples/Importer/unit-cube.obj")
        return try ImportedMesh(data: Data(contentsOf: url), fileExtension: "obj")
            .transformed(scale: size, yUp: false, corner: corner)
    }
    private func element(_ n: Int, mesh: ImportedMesh) -> ImportedMesh.BuildingElement {
        .init(
            globalID: String(format: "%022d", n), name: "Element \(n)", ifcClass: "IfcWall", storey: "Ground",
            mesh: mesh)
    }
    @Test("Touching and overlapping IFC products form additive occupancy without artificial voids")
    func union() throws {
        for (corner, cells) in [(Float(1), 16), (Float(0.5), 12)] {
            let a = try element(1, mesh: cube())
            let b = try element(2, mesh: cube(corner: SIMD3(corner, 0, 0)))
            let mesh = try ImportedMesh(buildingElements: [b, a])
            let preview = try mesh.preview(cellSize: 0.5, domain: SIMD3(repeating: 4))
            #expect(preview.occupiedCells == cells)
            #expect(preview.boxes.contains { $0.contains(SIMD3(0.75, 0.25, 0.25)) })
            #expect(Set(preview.boxPartIDs ?? []) == Set([a.partID, b.partID]))
            // Generated boxes never overlap, so occupancy counts and picking have one owner.
            for (i, x) in preview.boxes.enumerated() {
                for y in preview.boxes.dropFirst(i + 1) {
                    let extent = simd_min(x.max, y.max) - simd_max(x.min, y.min)
                    #expect(!(extent.x > 0 && extent.y > 0 && extent.z > 0))
                }
            }
        }
    }
    @Test("A contained IFC product is a solid rather than a cavity of another product")
    func containedProduct() throws {
        let mesh = try ImportedMesh(buildingElements: [
            element(1, mesh: cube()), element(2, mesh: cube(size: 0.5, corner: SIMD3(repeating: 0.25))),
        ])
        let preview = try mesh.preview(cellSize: 0.25, domain: SIMD3(repeating: 2))
        #expect(preview.occupiedCells == 64)
        #expect(preview.boxes.contains { $0.contains(SIMD3(repeating: 0.5)) })
    }
    @Test("GUID identity and placement survive reordering, transforms and saved sources")
    func identity() throws {
        let a = try element(1, mesh: cube())
        let b = try element(2, mesh: cube(corner: SIMD3(2, 0, 0)))
        let source = try ImportedMesh(
            buildingElements: [b, a], notes: ["Imported metres"], origin: SIMD3(100, 200, -4),
            sourceData: Data("IFC reference".utf8))
        let moved = try source.transformed(scale: 0.5, yUp: true, corner: SIMD3(2, 3, 1))
        #expect(moved.parts == source.parts)
        #expect(moved.bounds.min == SIMD3(2, 3, 1))
        #expect(moved.buildingSourceData == source.buildingSourceData)
        let restored = try JSONDecoder().decode(ImportedMesh.self, from: JSONEncoder().encode(source))
        #expect(restored == source)
        #expect(restored.parts == source.parts)
        #expect(try ImportedMesh(buildingElements: [a, b]).parts.map(\.id) == source.parts.map(\.id))
    }
    @Test("Sampling reports distinguish vanished thin elements from full and partial overlap")
    func samplingLosses() throws {
        let large = try element(1, mesh: cube())
        let covered = try element(2, mesh: cube(size: 0.5, corner: SIMD3(repeating: 0.25)))
        let partial = try element(3, mesh: cube(corner: SIMD3(0.75, 0, 0)))
        let thin = try element(4, mesh: cube(size: 0.05, corner: SIMD3(2, 0, 0)))
        let source = try ImportedMesh(buildingElements: [thin, covered, partial, large])
        let medium = try source.preview(cellSize: 0.25, domain: SIMD3(repeating: 4))
        let samples = try #require(medium.buildingSampling)
        #expect(samples.first { $0.id == covered.globalID }?.status == "Fully covered by other elements")
        #expect(samples.first { $0.id == partial.globalID }?.status == "Partly overlaps other elements")
        #expect(samples.first { $0.id == thin.globalID }?.status == "No solid cells on this grid")
        #expect(samples.reduce(0) { $0 + $1.assignedCells } == medium.occupiedCells)
        #expect(medium.warnings.contains { $0.contains("sampling losses") })
        let fine = try source.preview(cellSize: 0.025, domain: SIMD3(repeating: 4))
        #expect(fine.buildingSampling?.first { $0.id == thin.globalID }?.sampledCells == 8)
        let restored = try JSONDecoder().decode(ImportedMesh.Preview.self, from: JSONEncoder().encode(medium))
        #expect(restored.buildingSampling == samples)
    }
    @Test("Inconsistent saved selection cannot claim excluded geometry was converted")
    func selectionGuards() throws {
        let a = try element(1, mesh: cube())
        let b = try element(2, mesh: cube())
        let inventory = [a, b].map {
            ImportedMesh.BuildingSourceElement(id: $0.globalID, name: $0.name, ifcClass: $0.ifcClass)
        }
        let selection = ImportedMesh.BuildingSelection(inventory: inventory, includedIDs: [a.globalID])
        #expect(throws: ImportedMesh.ImportError.self) {
            try ImportedMesh(buildingElements: [b], selection: selection)
        }
        let valid = try ImportedMesh(buildingElements: [a], selection: selection)
        #expect(
            try JSONDecoder().decode(ImportedMesh.self, from: JSONEncoder().encode(valid)).buildingSelection
                == selection)
        var invalid = selection
        invalid.inventory.append(inventory[0])
        #expect(throws: ImportedMesh.ImportError.self) {
            try ImportedMesh(buildingElements: [a], selection: invalid)
        }
    }
    @Test("Rigid-only installation, duplicate GUIDs and nested building sources are guarded")
    func guards() throws {
        let a = try element(1, mesh: cube())
        #expect(throws: ImportedMesh.ImportError.self) { try ImportedMesh(buildingElements: [a, a]) }
        let source = try ImportedMesh(buildingElements: [a])
        #expect(throws: ImportedMesh.ImportError.self) {
            try ImportedMesh(buildingElements: [element(2, mesh: source)])
        }
        let record = ImportedModel(
            name: "IFC", source: source, scale: 1, yUp: false, corner: .zero, behavior: .deformable,
            preview: try source.preview(cellSize: 0.5, domain: SIMD3(repeating: 4)))
        var scene = Scenario(
            name: "Test", domainSize: SIMD3(repeating: 4), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(3, 3, 1)))
        #expect(throws: ImportedMesh.ImportError.self) {
            try scene.installImport(record, material: .plainConcrete, fixedBase: false)
        }
        #expect(scene.importedModels == nil && scene.structure == nil)
        #expect(throws: ImportedMesh.ImportError.self) {
            try source.preview(cellSize: .nan, domain: SIMD3(repeating: 4))
        }
        #expect(throws: ImportedMesh.ImportError.self) {
            try source.preview(cellSize: 0.0001, domain: SIMD3(repeating: 4))
        }
    }
}
