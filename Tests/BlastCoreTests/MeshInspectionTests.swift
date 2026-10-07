import Foundation
import Testing
import simd

@testable import BlastCore

@Suite("Mesh defect inspection")
struct MeshInspectionTests {
    @Test("Open edges can be inspected but never become a validated mesh")
    func openSurface() throws {
        let data = Data("v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3".utf8)
        let result = try ImportedMesh.inspect(data: data, fileExtension: "obj")
        #expect(result.validatedMesh == nil)
        #expect(result.triangles.count == 1)
        #expect(result.issues[0].triangleIndices == [0])
        #expect(result.issues[0].bounds == Box(min: .zero, max: SIMD3(1, 1, 0)))
        #expect(result.issues[0].message.contains("3 open or non-manifold edges"))
        #expect(throws: ImportedMesh.ImportError.self) { try ImportedMesh(data: data, fileExtension: "obj") }
    }
    @Test("Non-finite and collapsed geometry is marked undisplayable and still rejected")
    func invalidVertices() throws {
        for source in ["v nan 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3", "v 0 0 0\nv 1 0 0\nv 2 0 0\nf 1 2 3"] {
            let result = try ImportedMesh.inspect(data: Data(source.utf8), fileExtension: "obj")
            #expect(result.validatedMesh == nil && result.omittedTriangles == 1)
            #expect(!result.issues.isEmpty)
        }
    }
    @Test("OBJ syntax errors identify original line numbers, including CRLF and blank lines")
    func lineNumbers() {
        do {
            _ = try ImportedMesh.inspect(data: Data("v 0 0 0\r\n\r\nf 1 2 3".utf8), fileExtension: "obj")
            Issue.record("Missing vertices were accepted")
        } catch { #expect(error.localizedDescription.contains("line 3")) }
    }
    private func cube(_ name: String, size: Float = 1, corner: SIMD3<Float> = .zero, offset: Int = 0)
        -> String
    {
        let p: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1), SIMD3(1, 0, 1),
            SIMD3(1, 1, 1), SIMD3(0, 1, 1),
        ]
        let faces = [
            [1, 4, 3, 2], [5, 6, 7, 8], [1, 2, 6, 5], [2, 3, 7, 6], [3, 4, 8, 7], [4, 1, 5, 8],
        ]
        return "o \(name)\n"
            + p.map { p in
                let v = p * size + corner
                return "v \(v.x) \(v.y) \(v.z)"
            }.joined(separator: "\n")
            + "\n"
            + faces.map { "f " + $0.map { String($0 + offset) }.joined(separator: " ") }.joined(
                separator: "\n") + "\n"
    }
    @Test("Inspection locates intersecting faces and valid inspection agrees with the strict importer")
    func intersectionsAndValid() throws {
        let source = cube("A")
        let result = try ImportedMesh.inspect(
            data: Data((source + cube("B", corner: SIMD3(0.5, 0.4, 0.3), offset: 8)).utf8),
            fileExtension: "obj")
        #expect(result.validatedMesh == nil)
        #expect(result.issues[0].triangleIndices.count == 2)
        #expect(result.issues[0].bounds != nil)
        let valid = try ImportedMesh.inspect(data: Data(source.utf8), fileExtension: "obj")
        #expect(valid.validatedMesh == (try ImportedMesh(data: Data(source.utf8), fileExtension: "obj")))
        #expect(valid.issues.isEmpty)
    }
    @Test("Narrow gaps and cavity-wall warnings carry both affected source boundary IDs")
    func diagnosticOwners() throws {
        let gap = try ImportedMesh(
            data: Data((cube("A") + cube("B", corner: SIMD3(1.05, 0, 0), offset: 8)).utf8),
            fileExtension: "obj")
        let result = try gap.preview(cellSize: 0.25, domain: SIMD3(repeating: 4))
        #expect(
            result.diagnostics.filter { $0.kind == .gap }.allSatisfy { Set($0.partIDs ?? []) == [0, 12] })
        let cavity = try ImportedMesh(
            data: Data(
                (cube("Outer") + cube("Cavity", size: 0.8, corner: SIMD3(repeating: 0.1), offset: 8)).utf8),
            fileExtension: "obj")
        let shell = try cavity.preview(cellSize: 0.25, domain: SIMD3(repeating: 4), allowEmpty: true)
        #expect(shell.diagnostics.contains { $0.kind == .thin && Set($0.partIDs ?? []) == [0, 12] })
        let saved = try JSONDecoder().decode(ImportedMesh.Preview.self, from: JSONEncoder().encode(shell))
        #expect(saved == shell)
    }
    @Test("Cancelled inspection cannot return even a recovery result")
    func cancellation() async {
        let task = Task.detached { () -> Result<ImportedMesh.Inspection, Error> in
            while !Task.isCancelled { await Task.yield() }
            return Result { try ImportedMesh.inspect(data: Data("v 0 0 0".utf8), fileExtension: "obj") }
        }
        task.cancel()
        switch await task.value {
        case .failure(let error): #expect(error is CancellationError)
        case .success: Issue.record("Cancelled inspection returned geometry")
        }
    }
}
