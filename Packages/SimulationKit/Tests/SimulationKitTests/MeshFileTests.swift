import Foundation
import GeometryImport
import Testing
import simd

@Suite("Mesh files")
struct MeshFileTests {
    @Test("OBJ polygons keep their corners, with the object, group and material in force")
    func obj() throws {
        let text = """
            # A square and a triangle
            o Room
            v 0 0 0
            v 1 0 0
            v 1 1 0
            v 0 1 0
            g Floor
            usemtl Carpet
            f 1 2 3 4
            g off
            usemtl
            f -4/1/1 -2//2 -1
            """
        let file = try MeshFile(data: Data(text.utf8), fileExtension: "OBJ")
        #expect(file.vertices.count == 4)
        #expect(
            file.faces == [
                .init(corners: [0, 1, 2, 3], object: "Room", group: "Floor", material: "Carpet"),
                .init(corners: [0, 2, 3], object: "Room", group: nil, material: nil),
            ])
    }

    @Test("ASCII and binary STL give each triangle its own three corners")
    func stl() throws {
        let ascii = """
            solid t
            facet normal 0 0 1
            outer loop
            vertex 0 0 0
            vertex 1 0 0
            vertex 0 1 0
            endloop
            endfacet
            endsolid t
            """
        let a = try MeshFile(data: Data(ascii.utf8), fileExtension: "stl")
        #expect(a.vertices == [[0, 0, 0], [1, 0, 0], [0, 1, 0]])
        #expect(a.faces.map(\.corners) == [[0, 1, 2]])
        var binary = Data(count: 80)
        withUnsafeBytes(of: UInt32(1).littleEndian) { binary.append(contentsOf: $0) }
        for value: Float in [0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 2, 0] {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { binary.append(contentsOf: $0) }
        }
        binary.append(contentsOf: [0, 0])
        let b = try MeshFile(data: binary, fileExtension: "stl")
        #expect(b.vertices == [[0, 0, 0], [2, 0, 0], [0, 2, 0]])
    }

    @Test("Malformed files are refused with the line at fault")
    func errors() {
        func message(_ text: String, _ ext: String = "obj") -> String? {
            do {
                _ = try MeshFile(data: Data(text.utf8), fileExtension: ext)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        #expect(message("v 0 0\n") == "Invalid OBJ vertex at line 1.")
        #expect(message("v 0 0 0\nf 1 2\n") == "OBJ face at line 2 needs at least three vertices.")
        #expect(message("v 0 0 0\nf 1 2 3\n") == "OBJ face at line 2 references a missing vertex.")
        #expect(message("v 0 0 0\nf 1 x 3\n") == "Invalid OBJ face index at line 2.")
        #expect(message("", "ply") == "Choose an OBJ or STL file.")
        #expect(message("vertex 0 0 0\n", "stl") == "Incomplete STL triangle.")
    }
}
