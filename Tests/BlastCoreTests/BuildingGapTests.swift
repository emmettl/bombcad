import Foundation
import Testing
import simd

@testable import BlastCore

@Suite("IFC gaps between independent products")
struct BuildingGapTests {
    private func cube(_ n: Int, corner: SIMD3<Float> = .zero) throws -> ImportedMesh.BuildingElement {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let mesh = try ImportedMesh(
            data: Data(contentsOf: root.appendingPathComponent("Samples/Importer/unit-cube.obj")),
            fileExtension: "obj"
        )
        .transformed(scale: 1, yUp: false, corner: corner)
        return .init(
            globalID: String(format: "%022d", n), name: "Wall \(n)", ifcClass: "IfcWall", storey: "Ground",
            mesh: mesh)
    }
    @Test("Sub-cell openings between separate elements warn in all axes and recover on a finer grid")
    func closingGaps() throws {
        for axis in 0..<3 {
            var corner = SIMD3<Float>.zero
            corner[axis] = 1.05
            let a = try cube(1)
            let b = try cube(2, corner: corner)
            let mesh = try ImportedMesh(buildingElements: [b, a])
            let coarse = try mesh.preview(cellSize: 0.25, domain: SIMD3(repeating: 4))
            let gap = try #require(coarse.diagnostics.first { $0.betweenElements == true })
            #expect(gap.axis == axis && gap.partIDs == [a.partID, b.partID].sorted())
            #expect(abs((gap.minimumSize ?? 0) - 0.05) < 0.00001)
            #expect((coarse.crossElementGapSamples ?? 0) > 0)
            #expect(coarse.crossElementChecksIncomplete == false)
            var opening = SIMD3<Float>(repeating: 0.5)
            opening[axis] = 1.025
            #expect(coarse.boxes.contains { $0.contains(opening) })
            let fine = try mesh.preview(cellSize: 0.02, domain: SIMD3(repeating: 4))
            #expect(fine.crossElementGapSamples == 0)
            #expect(!fine.boxes.contains { $0.contains(opening) })
            let restored = try JSONDecoder().decode(
                ImportedMesh.Preview.self, from: JSONEncoder().encode(coarse))
            #expect(restored.diagnostics.contains { $0.betweenElements == true && $0.partIDs == gap.partIDs })
            #expect(restored.crossElementGapSamples == coarse.crossElementGapSamples)
        }
    }
    @Test("Touching, overlapping and intervening solids do not produce invented clearances")
    func solidUnion() throws {
        for separation: Float in [1, 0.75] {
            let mesh = try ImportedMesh(buildingElements: [cube(1), cube(2, corner: SIMD3(separation, 0, 0))])
            #expect(try mesh.preview(cellSize: 0.25, domain: SIMD3(repeating: 4)).crossElementGapSamples == 0)
        }
        let walls = try [cube(1), cube(2, corner: SIMD3(1.25, 0, 0))]
        #expect(
            try ImportedMesh(buildingElements: walls).preview(cellSize: 0.25, domain: SIMD3(repeating: 4))
                .crossElementGapSamples! > 0)
        let filled = try ImportedMesh(buildingElements: walls + [cube(3, corner: SIMD3(1, 0, 0))])
        #expect(try filled.preview(cellSize: 0.25, domain: SIMD3(repeating: 4)).crossElementGapSamples == 0)
        let diagonal = try ImportedMesh(buildingElements: [cube(1), cube(2, corner: SIMD3(1.05, 1.05, 0))])
        #expect(try diagonal.preview(cellSize: 0.25, domain: SIMD3(repeating: 4)).crossElementGapSamples == 0)
    }
    @Test("An incomplete interval inventory never invents a gap from missing intervening solids")
    func budget() throws {
        var scan = BuildingGapScan(intervalLimit: 1)
        scan.record(axis: 0, j: 0, k: 0, spans: [SIMD2(0, 1)], owner: 1)
        scan.record(axis: 0, j: 0, k: 0, spans: [SIMD2(1.1, 2)], owner: 2)
        #expect(scan.incomplete)
        let result = try scan.diagnostics(cellSize: 0.25)
        #expect(result.samples == 0 && result.issues.isEmpty)
    }
    @Test("Placement survives subset changes at large IFC coordinate origins and reverses exactly")
    func placement() throws {
        let a = try cube(1)
        let b = try cube(2, corner: SIMD3(2, 0, 0))
        let origin = SIMD3<Double>(1e9, -2e9, 3e9)
        let full = try ImportedMesh(buildingElements: [a, b], origin: origin)
        var localB = b
        localB.mesh = try b.mesh.transformed(scale: 1, yUp: false, corner: .zero)
        let subset = try ImportedMesh(buildingElements: [localB], origin: origin + SIMD3(2, 0, 0))
        let corner = SIMD3<Double>(10, 3, 1)
        let moved = try ImportedMesh.preservingBuildingPlacement(from: full, to: subset, corner: corner)
        #expect(moved == SIMD3(12, 3, 1))
        let before = try full.transformed(scale: 1, yUp: false, corner: SIMD3<Float>(corner))
        let after = try subset.transformed(scale: 1, yUp: false, corner: SIMD3<Float>(moved))
        #expect(
            before.buildingElements?.first { $0.globalID == b.globalID }?.mesh
                == after.buildingElements?.first?.mesh)
        #expect(try ImportedMesh.preservingBuildingPlacement(from: subset, to: full, corner: moved) == corner)
        let noOrigin = try ImportedMesh(buildingElements: [a, b])
        #expect(
            try ImportedMesh.preservingBuildingPlacement(from: noOrigin, to: subset, corner: corner)
                == moved)
        let disjoint = try ImportedMesh(buildingElements: [cube(3)])
        #expect(throws: ImportedMesh.ImportError.self) {
            try ImportedMesh.preservingBuildingPlacement(from: noOrigin, to: disjoint, corner: corner)
        }
        let restored = try JSONDecoder().decode(ImportedMesh.self, from: JSONEncoder().encode(subset))
        #expect(
            try ImportedMesh.preservingBuildingPlacement(from: full, to: restored, corner: corner) == moved)
        let below = try ImportedMesh(buildingElements: [a], origin: origin - SIMD3(0, 0, 2))
        let staged = try ImportedMesh.preservingBuildingPlacement(
            from: full, to: below, corner: SIMD3(1, 1, 0))
        #expect(staged.z == -2)
        #expect(throws: ImportedMesh.ImportError.self) {
            try below.transformed(scale: 1, yUp: false, corner: SIMD3<Float>(staged))
        }
    }
}
