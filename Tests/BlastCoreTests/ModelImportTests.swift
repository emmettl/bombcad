import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

@Suite("Model import")
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
    @Test("A closed OBJ becomes the expected cells and coalesces to one box")
    func cubePreview() throws {
        let mesh = try mesh(cube())
        let result = try mesh.preview(cellSize: 0.25, domain: SIMD3(repeating: 4))
        #expect(mesh.triangles.count == 12)
        #expect(result.occupiedCells == 64)
        #expect(result.boxes == [Box(min: .zero, max: SIMD3(repeating: 1))])
        #expect(result.thinSpans == 0)
        #expect(result.missedTriangles == 0)
    }
    @Test("Units and Y-up are applied before placement")
    func transform() throws {
        let mesh = try mesh(cube(SIMD3(100, 200, 300), offset: SIMD3(10, 20, 30)))
        let transformed = try mesh.transformed(scale: 0.01, yUp: true, corner: SIMD3(2, 3, 0))
        #expect(simd_distance(transformed.bounds.min, SIMD3(2, 3, 0)) < 1e-5)
        #expect(simd_distance(transformed.bounds.size, SIMD3(1, 3, 2)) < 1e-5)
    }
    @Test("Open meshes, invalid indices and non-finite coordinates are rejected")
    func invalid() throws {
        #expect(throws: ImportedMesh.ImportError.self) { try mesh("v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3") }
        #expect(throws: ImportedMesh.ImportError.self) { try mesh("v 0 0 0\nf 1 2 3") }
        #expect(throws: ImportedMesh.ImportError.self) {
            try mesh(cube().replacingOccurrences(of: "v 0.0 0.0 0.0", with: "v nan 0 0"))
        }
    }
    @Test("Thin features warn on any axis, and vanished features are rejected")
    func thin() throws {
        for axis in 0..<3 {
            var size = SIMD3<Float>(repeating: 1)
            size[axis] = 0.3
            let preview = try mesh(cube(size)).preview(cellSize: 0.25, domain: SIMD3(repeating: 4))
            #expect(preview.thinSpans > 0)
            #expect(preview.warnings.count >= 2)
            size[axis] = 0.05
            #expect(throws: ImportedMesh.ImportError.self) {
                try mesh(cube(size)).preview(cellSize: 0.25, domain: SIMD3(repeating: 4))
            }
        }
    }
    @Test("Disconnected volumes and internal cavities remain separate")
    func separate() throws {
        let first = cube()
        let second = cube(offset: SIMD3(2, 0, 0)).split(separator: "\n").map { line -> String in
            let fields = line.split(separator: " ")
            if fields.first == "f" {
                return "f " + fields.dropFirst().map { String(Int($0)! + 8) }.joined(separator: " ")
            }
            return String(line)
        }.joined(separator: "\n")
        let result = try mesh(first + "\n" + second).preview(cellSize: 0.25, domain: SIMD3(repeating: 4))
        #expect(result.occupiedCells == 128)
        #expect(result.boxes.count == 2)
        let outer = cube(SIMD3(repeating: 3))
        let inner = cube(offset: SIMD3(repeating: 1)).split(separator: "\n").map { line -> String in
            let fields = line.split(separator: " ")
            if fields.first == "f" {
                return "f " + fields.dropFirst().map { String(Int($0)! + 8) }.joined(separator: " ")
            }
            return String(line)
        }.joined(separator: "\n")
        let hollow = try mesh(outer + "\n" + inner).preview(cellSize: 0.5, domain: SIMD3(repeating: 4))
        #expect(hollow.occupiedCells == 216 - 8)
        #expect(!hollow.boxes.contains { $0.contains(SIMD3(repeating: 1.5)) })
    }
    @Test("Sub-cell gaps are flagged even when voxelisation closes them")
    func gapWarnings() throws {
        let first = cube()
        let second = cube(offset: SIMD3(1.05, 0, 0)).split(separator: "\n").map { line -> String in
            let fields = line.split(separator: " ")
            if fields.first == "f" {
                return "f " + fields.dropFirst().map { String(Int($0)! + 8) }.joined(separator: " ")
            }
            return String(line)
        }.joined(separator: "\n")
        let result = try mesh(first + "\n" + second).preview(cellSize: 0.25, domain: SIMD3(repeating: 4))
        #expect(result.smallGaps > 0)
        #expect(result.warnings.contains { $0.contains("gaps are narrower") })
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
    @Test("ASCII and binary STL agree with OBJ")
    func stl() throws {
        let original = try mesh(cube())
        var ascii = "solid cube\n"
        var binary = Data(repeating: 0, count: 80)
        func append(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { binary.append(contentsOf: $0) }
        }
        append(UInt32(original.triangles.count))
        for t in original.triangles {
            ascii += "facet normal 0 0 0\nouter loop\n"
            for v in [t.a, t.b, t.c] { ascii += "vertex \(v.x) \(v.y) \(v.z)\n" }
            ascii += "endloop\nendfacet\n"
            for _ in 0..<3 { append(0) }
            for v in [t.a, t.b, t.c] { for k in 0..<3 { append(v[k].bitPattern) } }
            binary.append(contentsOf: [0, 0])
        }
        ascii += "endsolid cube"
        for data in [Data(ascii.utf8), binary] {
            let result = try ImportedMesh(data: data, fileExtension: "stl").preview(
                cellSize: 0.25, domain: SIMD3(repeating: 4))
            #expect(result.occupiedCells == 64)
        }
    }
    @Test("Domain and workload limits reject unsafe previews")
    func limits() throws {
        let model = try mesh(cube())
        #expect(throws: ImportedMesh.ImportError.self) {
            try model.preview(cellSize: 0.25, domain: SIMD3(repeating: 0.5))
        }
        #expect(throws: ImportedMesh.ImportError.self) {
            try model.preview(cellSize: 0.001, domain: SIMD3(repeating: 4))
        }
        #expect(throws: ImportedMesh.ImportError.self) {
            try model.transformed(scale: Float.infinity, yUp: false, corner: .zero)
        }
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
