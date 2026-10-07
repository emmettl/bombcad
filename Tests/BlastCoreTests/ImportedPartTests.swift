import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

@Suite("Imported parts and materials")
struct ImportedPartTests {
    private func cube(
        _ name: String, size: SIMD3<Float> = SIMD3(repeating: 1),
        corner: SIMD3<Float> = .zero, index: Int = 0, group: String? = nil
    ) -> String {
        let points: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0),
            SIMD3(0, 0, 1), SIMD3(1, 0, 1), SIMD3(1, 1, 1), SIMD3(0, 1, 1),
        ]
        let faces = [
            [1, 4, 3, 2], [5, 6, 7, 8], [1, 2, 6, 5], [2, 3, 7, 6], [3, 4, 8, 7], [4, 1, 5, 8],
        ]
        return "o \(name)\ng \(group ?? "off")\n"
            + points.map { p in
                let p = p * size + corner
                return "v \(p.x) \(p.y) \(p.z)"
            }.joined(separator: "\n") + "\n"
            + faces.map { f in
                "f " + f.map { String($0 + index) }.joined(separator: " ")
            }.joined(separator: "\n") + "\n"
    }
    private func source(_ text: String) throws -> ImportedMesh {
        try ImportedMesh(data: Data(text.utf8), fileExtension: "obj")
    }
    private func record(
        _ mesh: ImportedMesh, h: Float = 0.5,
        assignments: [Int: StructureMaterial] = [:]
    ) throws -> ImportedModel {
        ImportedModel(
            name: "Parts", source: mesh, scale: 1, yUp: false, corner: .zero,
            behavior: .deformable, preview: try mesh.preview(cellSize: h, domain: SIMD3(repeating: 32)),
            partMaterials: assignments.isEmpty ? nil : assignments)
    }
    private func layout(_ model: ImportedModel) throws -> Scenario {
        var scene = Scenario(
            name: "Parts", domainSize: SIMD3(repeating: 32), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(5, 5, 5)))
        try scene.installImport(model, material: .plainConcrete, fixedBase: false)
        return scene
    }
    private func material(_ scene: Scenario, at point: SIMD3<Float>) throws -> StructureMaterial {
        let body = try #require(scene.structure)
        let n = try #require(body.solids.lastIndex { $0.contains(point) })
        return body.material(of: n)
    }
    @Test("OBJ objects and groups name complete closed parts with stable source IDs")
    func objNames() throws {
        let mesh = try source(
            cube("Wall", group: "North face") + cube("Column", corner: SIMD3(2, 0, 0), index: 8))
        #expect(mesh.parts.map(\.name) == ["Wall / North face", "Column"])
        #expect(mesh.parts.map(\.id) == [0, 12])
        #expect(mesh.parts.map { $0.triangleIndices.count } == [12, 12])
        let moved = try mesh.transformed(scale: 0.5, yUp: true, corner: SIMD3(1, 1, 0))
        #expect(moved.parts == mesh.parts)
        let reopened = try JSONDecoder().decode(ImportedMesh.self, from: JSONEncoder().encode(mesh))
        #expect(reopened == mesh)
        #expect(reopened.parts == mesh.parts)
    }
    @Test("Face groups remain one volumetric part and duplicate names are distinguished")
    func faceGroupsAndDuplicateNames() throws {
        let text = cube("Wall", group: "Bottom").replacingOccurrences(
            of: "f 5 6 7 8", with: "g Top\nf 5 6 7 8")
        let mesh = try source(text)
        #expect(mesh.parts.count == 1)
        #expect(mesh.parts[0].name == "Wall")
        #expect(mesh.parts[0].groupName == nil)
        let duplicates = try source(cube("Wall") + cube("Wall", corner: SIMD3(2, 0, 0), index: 8))
        #expect(duplicates.parts.map(\.name) == ["Wall · 1", "Wall · 2"])
    }
    @Test("STL and legacy saved sources discover connected components without names")
    func stlAndLegacy() throws {
        let mesh = try source(cube("A") + cube("B", corner: SIMD3(2, 0, 0), index: 8))
        struct Legacy: Encodable { var triangles: [ImportedMesh.Triangle] }
        let legacy = try JSONDecoder().decode(
            ImportedMesh.self,
            from: JSONEncoder().encode(Legacy(triangles: mesh.triangles)))
        #expect(legacy.parts.map(\.name) == ["Component 1", "Component 2"])
        var text = "solid components\n"
        for t in mesh.triangles {
            text += "facet normal 0 0 0\nouter loop\n"
            for p in [t.a, t.b, t.c] { text += "vertex \(p.x) \(p.y) \(p.z)\n" }
            text += "endloop\nendfacet\n"
        }
        let stl = try ImportedMesh(data: Data((text + "endsolid components").utf8), fileExtension: "stl")
        #expect(stl.parts == legacy.parts)
    }
    @Test("Coalescing never merges distinct part ownership even when a coarse grid closes a gap")
    func ownershipOnAllAxes() throws {
        for axis in 0..<3 {
            var corner = SIMD3<Float>.zero
            corner[axis] = 1.05
            let mesh = try source(cube("A") + cube("B", corner: corner, index: 8))
            let preview = try mesh.preview(cellSize: 0.5, domain: SIMD3(repeating: 4))
            #expect(preview.occupiedCells == 16)
            #expect(preview.boxes.count == 2)
            #expect(preview.boxPartIDs == [0, 12])
        }
    }
    @Test("Cavity boundaries retain the enclosing part's material; solid islands own their material")
    func cavityOwnership() throws {
        let mesh = try source(
            cube("Outer", size: SIMD3(repeating: 3))
                + cube("Cavity", size: SIMD3(repeating: 2), corner: SIMD3(repeating: 0.5), index: 8)
                + cube("Island", corner: SIMD3(repeating: 1), index: 16))
        let imported = try record(
            mesh, h: 0.25, assignments: [0: .masonry, 12: .structuralSteel, 24: .structuralSteel])
        let scene = try layout(imported)
        #expect(!Set(imported.preview.boxPartIDs ?? []).contains(12))
        #expect(try material(scene, at: SIMD3(2.75, 1.5, 1.5)) == .masonry)
        #expect(try material(scene, at: SIMD3(0.25, 1.5, 1.5)) == .masonry)
        #expect(try material(scene, at: SIMD3(repeating: 1.5)) == .structuralSteel)
    }
    @Test("Assignments survive save, default changes, resampling and placement changes")
    func persistenceAndRegeneration() throws {
        let mesh = try source(cube("Concrete") + cube("Steel", corner: SIMD3(2, 0, 0), index: 8))
        var scene = try layout(record(mesh, assignments: [12: .structuralSteel]))
        scene = try JSONDecoder().decode(Scenario.self, from: JSONEncoder().encode(scene))
        scene.structure?.material = .masonry
        let fine = try scene.resamplingImports(cellSize: 0.125)
        #expect(fine.importedModels?.first?.partMaterials == [12: .structuralSteel])
        #expect(try material(fine, at: SIMD3(repeating: 0.5)) == .masonry)
        #expect(try material(fine, at: SIMD3(2.5, 0.5, 0.5)) == .structuralSteel)
        var moved = try #require(fine.importedModels?.first)
        moved.corner = SIMD3(1, 1, 0)
        moved = try moved.sampled(cellSize: 0.25, domain: scene.domainSize)
        var replaced = fine
        try replaced.installImport(moved, material: .masonry, fixedBase: false)
        #expect(try material(replaced, at: SIMD3(3.5, 1.5, 0.5)) == .structuralSteel)
        #expect(moved.canRegenerate(replaced.structure))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let solver = try StructureSolver(device: device, model: #require(replaced.structure))
        #expect(solver.materials == [.masonry, .structuralSteel])
        #expect(solver.elementCount == 128)
    }
    @Test("An absent coarse-grid part recovers its saved material when refinement restores it")
    func recoveredPart() throws {
        let mesh = try source(
            cube("Large") + cube("Thin", size: SIMD3(0.1, 1, 1), corner: SIMD3(2, 0, 0), index: 8))
        let coarse = try layout(record(mesh, assignments: [12: .structuralSteel]))
        #expect(coarse.structure?.materials == [.plainConcrete])
        let fine = try coarse.resamplingImports(cellSize: 0.125)
        #expect(try material(fine, at: SIMD3(2.0625, 0.5, 0.5)) == .structuralSteel)
        #expect(fine.importedModels?.first?.partMaterials == [12: .structuralSteel])
    }
    @Test("Source assignment edits are allowed; unrelated generated-region edits still block resampling")
    func localEdits() throws {
        let mesh = try source(cube("A") + cube("B", corner: SIMD3(2, 0, 0), index: 8))
        var scene = try layout(record(mesh, assignments: [12: .structuralSteel]))
        var imported = try #require(scene.importedModels?.first)
        imported.partMaterials = [0: .masonry]
        try scene.installImport(imported, material: .plainConcrete, fixedBase: false)
        #expect(imported.canRegenerate(scene.structure))
        scene.structure?.setMaterial(.structuralSteel, of: 0)
        #expect(!imported.canRegenerate(scene.structure))
        #expect(throws: ImportedMesh.ImportError.self) { try scene.resamplingImports(cellSize: 0.125) }
        let edited = scene.structure
        scene.detachImport(id: imported.id)
        #expect(try scene.resamplingImports(cellSize: 0.125).structure == edited)
    }
    @Test(
        "Invalid ownership or assignment IDs fail transactionally; legacy previews without assignments still work"
    )
    func invalidAndLegacyPreview() throws {
        let mesh = try source(cube("A"))
        var imported = try record(mesh)
        imported.preview.boxPartIDs = nil
        _ = try layout(imported)
        imported.partMaterials = [0: .structuralSteel]
        #expect(throws: ImportedMesh.ImportError.self) { try layout(imported) }
        imported = try record(mesh, assignments: [999: .structuralSteel])
        #expect(throws: ImportedMesh.ImportError.self) { try layout(imported) }
        imported = try record(mesh)
        imported.preview.boxPartIDs = [999]
        #expect(throws: ImportedMesh.ImportError.self) { try layout(imported) }
    }
    @Test("Refinement that restores too many distinct materials leaves the coarse layout unchanged")
    func recoveredMaterialLimit() throws {
        var text = cube("Main")
        for n in 1...8 {
            text += cube("Thin \(n)", size: SIMD3(0.1, 1, 1), corner: SIMD3(Float(n) * 2, 0, 0), index: n * 8)
        }
        let mesh = try source(text)
        let assignments = Dictionary(
            uniqueKeysWithValues: mesh.parts.dropFirst().enumerated().map { n, part in
                var material = StructureMaterial.structuralSteel
                material.name = "Steel \(n)"
                return (part.id, material)
            })
        let coarse = try layout(record(mesh, assignments: assignments))
        #expect(coarse.structure?.materials.count == 1)
        #expect(throws: ImportedMesh.ImportError.self) { try coarse.resamplingImports(cellSize: 0.125) }
        #expect(coarse.importedModels?.first?.preview.cellSize == 0.5)
        #expect(coarse.structure?.materials.count == 1)
    }
    @Test("The solver material limit is checked before modifying the layout")
    func materialLimit() throws {
        var text = ""
        for n in 0..<9 { text += cube("Part \(n)", corner: SIMD3(Float(n) * 2, 0, 0), index: n * 8) }
        let mesh = try source(text)
        let assignments = Dictionary(
            uniqueKeysWithValues: mesh.parts.enumerated().map { n, part in
                var material = StructureMaterial.structuralSteel
                material.name = "Steel \(n)"
                return (part.id, material)
            })
        let imported = try record(mesh, assignments: assignments)
        var scene = Scenario(
            name: "Empty", domainSize: SIMD3(repeating: 32), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(5, 5, 5)))
        let before = scene
        #expect(throws: ImportedMesh.ImportError.self) {
            try scene.installImport(imported, material: .plainConcrete, fixedBase: false)
        }
        #expect(scene == before)
    }
}
