import Foundation
import Testing
import simd

@testable import BlastCore

@Suite("Mesh robustness")
struct MeshRobustnessTests {
    private func cube(size: Float = 1, corner: SIMD3<Float> = .zero) throws -> ImportedMesh {
        let points: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0),
            SIMD3(0, 0, 1), SIMD3(1, 0, 1), SIMD3(1, 1, 1), SIMD3(0, 1, 1),
        ]
        let source =
            points.map { p in
                let p = p * size + corner
                return "v \(p.x) \(p.y) \(p.z)"
            }.joined(separator: "\n") + "\nf 1 4 3 2\nf 5 6 7 8\nf 1 2 6 5\nf 2 3 7 6\nf 3 4 8 7\nf 4 1 5 8"
        return try ImportedMesh(data: Data(source.utf8), fileExtension: "obj")
    }
    private func stl(_ triangles: [ImportedMesh.Triangle]) throws -> ImportedMesh {
        var source = "solid test\n"
        for t in triangles {
            source += "facet normal 0 0 0\nouter loop\n"
            for p in [t.a, t.b, t.c] { source += "vertex \(p.x) \(p.y) \(p.z)\n" }
            source += "endloop\nendfacet\n"
        }
        source += "endsolid test"
        return try ImportedMesh(data: Data(source.utf8), fileExtension: "stl")
    }
    private func expectIntersection(_ triangles: [ImportedMesh.Triangle]) {
        do {
            _ = try stl(triangles)
            Issue.record("Intersecting mesh was accepted")
        } catch {
            #expect(error.localizedDescription.contains("intersect"))
            #expect(error.localizedDescription.contains("source units"))
            #expect(error.localizedDescription.contains("Boolean-union"))
        }
    }
    @Test("Overlapping closed solids are rejected before parity can create an artificial void")
    func overlaps() throws {
        let a = try cube()
        let b = try cube(corner: SIMD3(0.5, 0.4, 0.3))
        expectIntersection(a.triangles + b.triangles)
    }
    @Test("Intersection validation finds sub-cell and coplanar surface overlaps")
    func subcellAndCoplanar() throws {
        let a = try cube()
        try expectIntersection(a.triangles + cube(corner: SIMD3(0.9999, 0.2, 0.3)).triangles)
        // Coplanar top/bottom faces intersect, with no shared source vertices.
        try expectIntersection(a.triangles + cube(corner: SIMD3(0.5, 0.4, 0)).triangles)
    }
    @Test("A self-intersecting closed shell is rejected, including triangles sharing vertices")
    func selfIntersection() throws {
        let a = try cube()
        let bad = a.triangles.map { t in
            func moved(_ p: SIMD3<Float>) -> SIMD3<Float> {
                p == SIMD3(repeating: 1) ? SIMD3(-0.5, 0.5, 0.5) : p
            }
            return ImportedMesh.Triangle(a: moved(t.a), b: moved(t.b), c: moved(t.c))
        }
        expectIntersection(bad)
    }
    @Test("Point and edge contacts between separate shells require repair")
    func contacts() throws {
        let a = try cube()
        do {
            _ = try stl(a.triangles + cube(corner: SIMD3(repeating: 1)).triangles)
            Issue.record("Pinched vertex was accepted")
        } catch { #expect(error.localizedDescription.contains("non-manifold vertex")) }
        #expect(throws: ImportedMesh.ImportError.self) {
            try stl(a.triangles + cube(corner: SIMD3(1, 1, 0)).triangles)
        }
        // Face contact without matching tessellation must also be detected.
        try expectIntersection(a.triangles + cube(size: 0.5, corner: SIMD3(1, 0.2, 0.3)).triangles)
    }
    @Test("Disjoint shells with overlapping bounding boxes are accepted")
    func overlappingBounds() throws {
        // Two thin diagonal tetrahedra can overlap in bounds without touching.
        let source = "v 0 0 0\nv 2 2 0\nv 2 2 0.1\nv 2 1.9 0\nf 1 3 2\nf 1 2 4\nf 1 4 3\nf 2 3 4"
        let a = try ImportedMesh(data: Data(source.utf8), fileExtension: "obj")
        let b = try a.transformed(scale: 1, yUp: false, corner: SIMD3(0, 0.2, 0))
        let combined = try stl(a.triangles + b.triangles)
        #expect(combined.triangles.count == 8)
    }
    @Test("Nested shells preserve cavities and an island within a cavity")
    func nestedShells() throws {
        let outer = try cube(size: 3)
        let inner = try cube(size: 2, corner: SIMD3(repeating: 0.5))
        let island = try cube(corner: SIMD3(repeating: 1))
        let combined = try stl(outer.triangles + inner.triangles + island.triangles)
        let preview = try combined.preview(cellSize: 0.25, domain: SIMD3(repeating: 4))
        #expect(preview.occupiedCells == 1728 - 512 + 64)
        #expect(!preview.boxes.contains { $0.contains(SIMD3(repeating: 0.75)) })
        #expect(preview.boxes.contains { $0.contains(SIMD3(repeating: 1.5)) })
    }
    @Test("Inconsistent face winding is normalized for sampling without rewriting source geometry")
    func mixedWinding() throws {
        let original = try cube()
        let triangles = original.triangles.enumerated().map { n, t in
            n % 3 == 0 ? ImportedMesh.Triangle(a: t.a, b: t.c, c: t.b) : t
        }
        let mixed = try stl(triangles)
        #expect(mixed.triangles == triangles)
        #expect(try mixed.preview(cellSize: 0.25, domain: SIMD3(repeating: 2)).occupiedCells == 64)
    }
    @Test("Scanlines through tetrahedron edges and vertices do not invent odd crossings")
    func edgeScanlines() throws {
        // Grid-centre rays pass exactly through the apex and silhouette edges.
        let source =
            "v 0.25 0.25 0.25\nv 2.25 0.25 0.25\nv 0.25 2.25 0.25\nv 0.25 0.25 2.25\nf 1 3 2\nf 1 2 4\nf 1 4 3\nf 2 3 4"
        let mesh = try ImportedMesh(data: Data(source.utf8), fileExtension: "obj")
        let result = try mesh.preview(cellSize: 0.5, domain: SIMD3(repeating: 3))
        #expect(result.occupiedCells > 0)
        // No interior point can be absent, including rays on a triangulation edge.
        for x in 1...3 {
            for y in 1...3 {
                for z in 1...3 where x + y + z < 4 {
                    #expect(
                        result.boxes.contains {
                            $0.contains(
                                SIMD3(
                                    Float(x) * 0.5 + 0.25,
                                    Float(y) * 0.5 + 0.25, Float(z) * 0.5 + 0.25))
                        })
                }
            }
        }
    }
    @Test("Tangent rays on an octahedron are cancelled rather than counted as a solid crossing")
    func tangency() throws {
        let source =
            "v 0.25 1.25 1.25\nv 2.25 1.25 1.25\nv 1.25 0.25 1.25\nv 1.25 2.25 1.25\nv 1.25 1.25 0.25\nv 1.25 1.25 2.25\nf 1 3 5\nf 3 2 5\nf 2 4 5\nf 4 1 5\nf 3 1 6\nf 2 3 6\nf 4 2 6\nf 1 4 6"
        let mesh = try ImportedMesh(data: Data(source.utf8), fileExtension: "obj")
        let result = try mesh.preview(cellSize: 0.5, domain: SIMD3(repeating: 3))
        #expect(result.boxes.contains { $0.contains(SIMD3(repeating: 1.25)) })
        #expect(!result.boxes.contains { $0.contains(SIMD3(0.25, 0.25, 0.25)) })
    }
    @Test("A curved shell with a through-hole validates and keeps its central opening")
    func torus() throws {
        let around = 24
        let section = 12
        var points: [SIMD3<Float>] = []
        for i in 0..<around {
            for j in 0..<section {
                let u = Double(i) * 2 * .pi / Double(around)
                let v = Double(j) * 2 * .pi / Double(section)
                let r = 1 + 0.3 * cos(v)
                points.append(
                    SIMD3(Float(1.5 + r * cos(u)), Float(1.5 + r * sin(u)), Float(0.5 + 0.3 * sin(v))))
            }
        }
        func point(_ i: Int, _ j: Int) -> SIMD3<Float> { points[(i % around) * section + (j % section)] }
        var triangles: [ImportedMesh.Triangle] = []
        for i in 0..<around {
            for j in 0..<section {
                let a = point(i, j)
                let b = point(i + 1, j)
                let c = point(i + 1, j + 1)
                let d = point(i, j + 1)
                triangles.append(.init(a: a, b: b, c: c))
                triangles.append(.init(a: a, b: c, c: d))
            }
        }
        let mesh = try stl(triangles)
        let preview = try mesh.preview(cellSize: 0.125, domain: SIMD3(repeating: 3))
        #expect(preview.occupiedCells > 0)
        #expect(!preview.boxes.contains { $0.contains(SIMD3(1.5, 1.5, 0.5)) })
    }
    @Test("Transforms that collapse surface coordinates are rejected before sampling")
    func collapsedTransform() throws {
        let mesh = try cube()
        #expect(throws: ImportedMesh.ImportError.self) {
            try mesh.transformed(scale: 1e-6, yUp: false, corner: SIMD3(repeating: 100))
        }
    }
    @Test("Saved source meshes receive the same intersection validation as new files")
    func savedSources() throws {
        struct SavedMesh: Encodable { var triangles: [ImportedMesh.Triangle] }
        let triangles = try cube().triangles + cube(corner: SIMD3(0.5, 0.4, 0.3)).triangles
        let data = try JSONEncoder().encode(SavedMesh(triangles: triangles))
        #expect(throws: ImportedMesh.ImportError.self) {
            try JSONDecoder().decode(ImportedMesh.self, from: data)
        }
    }
    @Test("Validation work is bounded and cancellation stops it")
    func boundedAndCancelled() async throws {
        let a = try cube()
        #expect(throws: ImportedMesh.ImportError.self) {
            try MeshValidation.validate(a.triangles, pairLimit: 0)
        }
        #expect(throws: ImportedMesh.ImportError.self) {
            try MeshValidation.validate(a.triangles, nodeLimit: 0)
        }
        let task = Task.detached { () -> Result<Void, Error> in
            while !Task.isCancelled { await Task.yield() }
            return Result { try MeshValidation.validate(a.triangles) }
        }
        task.cancel()
        switch await task.value {
        case .failure(let error): #expect(error is CancellationError)
        case .success: Issue.record("Cancelled validation succeeded")
        }
    }
}
