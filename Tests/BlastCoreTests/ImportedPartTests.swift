import Foundation
import Metal
import Testing
import simd

@testable import BlastCore
@testable import BlastModel

@Suite("Imported parts and materials", .gpuThreads)
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
}
