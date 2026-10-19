import Foundation
import Metal
import Testing
import simd

@testable import BlastCore
@testable import BlastModel

@Suite("Model import", .gpuThreads)
struct ModelImportTests {
    private func cube(_ size: SIMD3<Float> = SIMD3(repeating: 1), offset: SIMD3<Float> = .zero) -> String {
        let vertices: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1), SIMD3(1, 0, 1),
            SIMD3(1, 1, 1), SIMD3(0, 1, 1),
        ]
        return vertices.map { p in
            let v = p * size + offset
            return "v \(v.x) \(v.y) \(v.z)"
        }.joined(separator: "\n") + "\nf 1 4 3 2\nf 5 6 7 8\nf 1 2 6 5\nf 2 3 7 6\nf 3 4 8 7\nf 4 1 5 8\n"
    }
    private func mesh(_ source: String) throws -> ImportedMesh {
        try ImportedMesh(data: Data(source.utf8), fileExtension: "obj")
    }
    @Test("Imported deformable solids preserve custom material and support assumptions")
    func deformable() throws {
        let preview = try mesh(cube()).preview(cellSize: 0.25, domain: SIMD3(repeating: 2))
        var material = StructureMaterial.plainConcrete
        material.name = "Imported concrete"
        material.density = 2200
        material.youngsModulus = 18e9
        var body = StructureModel(
            solids: preview.boxes, material: material, elementSize: 0.25, fixedBase: true)
        body.solidReinforcement = Array(repeating: .none, count: body.solids.count)
        body.autoReinforce()
        #expect(body.reinforcement.isEmpty)
        let scenario = Scenario(
            name: "Imported body", domainSize: SIMD3(repeating: 2), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(repeating: 1.5)), structure: body)
        let restored = try JSONDecoder().decode(Scenario.self, from: JSONEncoder().encode(scenario))
        #expect(restored.structure?.material == material)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let solver = try BlastSolver(device: device, scenario: restored, cellSize: 0.25)
        #expect(solver.structure?.elementCount == 64)
        #expect(solver.grid.cellCount - solver.fluidCellCount == 64)
    }
    private func retained(_ source: ImportedMesh, h: Float = 0.5, behavior: ImportedModel.Behavior = .rigid)
        throws -> ImportedModel
    {
        ImportedModel(
            name: "retained.obj", source: source, scale: 1, yUp: false, corner: SIMD3(1, 1, 0),
            behavior: behavior,
            preview: try source.transformed(scale: 1, yUp: false, corner: SIMD3(1, 1, 0)).preview(
                cellSize: h, domain: SIMD3(repeating: 4)))
    }
    @Test("Detaching rigid geometry preserves occupancy and removes source ownership")
    func detachRigid() throws {
        let imported = try retained(mesh(cube()))
        var layout = Scenario(
            name: "Detach", domainSize: SIMD3(repeating: 4), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(1.5, 1.5, 0.5)))
        try layout.installImport(imported, material: .plainConcrete, fixedBase: false)
        #expect(layout.chargeIsBlocked)
        let before = layout.rigidBoxes
        layout.detachImport(id: imported.id)
        #expect(layout.boxes == before)
        #expect(layout.rigidBoxes == before)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let solver = try BlastSolver(device: device, scenario: layout, cellSize: 0.5)
        #expect(solver.grid.cellCount - solver.fluidCellCount == 8)
    }
    @Test("Imported cells reach the air solver and diagnostics survive saving")
    func solverAndSave() throws {
        let result = try mesh(cube()).preview(cellSize: 0.25, domain: SIMD3(repeating: 2))
        var scenario = Scenario(
            name: "Import", domainSize: SIMD3(repeating: 2), boxes: result.boxes,
            charge: Charge(mass: 0, position: SIMD3(repeating: 1.5)))
        scenario.importNotes = result.warnings
        let restored = try JSONDecoder().decode(Scenario.self, from: JSONEncoder().encode(scenario))
        #expect(restored == scenario)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let solver = try BlastSolver(device: device, scenario: restored, cellSize: 0.25)
        #expect(solver.grid.cellCount - solver.fluidCellCount == result.occupiedCells)
        #expect(solver.isSolid(0, 0, 0))
        #expect(!solver.isSolid(5, 5, 5))
    }
}
