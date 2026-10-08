import Foundation
import Testing
import simd

@testable import AcousticCore

@Suite("Importing rooms")
struct RoomImportTests {
    static let plaster = SurfaceMaterial.uniform(0.05, name: "Plaster")

    /// A box's six faces as polygons pointing out, as a solid modelled as the room's air would be,
    /// with the floor named apart.
    static func outwardBox(_ size: SIMD3<Double>, yUp: Bool = false) -> [RoomImport.Polygon] {
        let v: [SIMD3<Double>] = (0..<8).map { i in
            let p = SIMD3(i & 1 == 0 ? 0 : size.x, i & 2 == 0 ? 0 : size.y, i & 4 == 0 ? 0 : size.z)
            // Drawn with y up: the file's y is height and its z runs the other way from RoomCAD's y.
            return yUp ? SIMD3(p.x, p.z, -p.y) : p
        }
        // Anticlockwise seen from outside.
        let faces: [([Int], String)] = [
            ([0, 4, 6, 2], "Walls"), ([1, 3, 7, 5], "Walls"), ([0, 1, 5, 4], "Walls"),
            ([2, 6, 7, 3], "Walls"),
            ([0, 2, 3, 1], "Floor"), ([4, 5, 7, 6], "Ceiling"),
        ]
        return faces.map { RoomImport.Polygon(corners: $0.0.map { v[$0] }, name: $0.1) }
    }

    @Test("A solid drawn in centimetres with y up becomes a room in metres, z up, its faces turned in")
    func box() throws {
        let polygons = Self.outwardBox([500, 400, 300], yUp: true)
        let (room, notes) = try RoomImport.room(
            from: polygons, scale: 0.01, yUp: true, material: Self.plaster)
        #expect(abs(room.volume - 60) < 1e-9)
        #expect(simd_distance(room.size, [5, 4, 3]) < 1e-9)
        #expect(notes.contains { $0.contains("turned to point in") })
        let mesh = try #require(room.mesh)
        #expect(mesh.labels == ["Walls", "Floor", "Ceiling"])
        #expect(mesh.materials.map(\.name) == ["Walls", "Floor", "Ceiling"])
        // The floor is at the bottom and faces up into the room.
        let floor = try #require(mesh.faces.indices.first { mesh.faces[$0].material == 1 })
        #expect(mesh.normalAndArea(floor).normal.z > 0.99)
        #expect(
            mesh.faces.allSatisfy { face in
                face.corners.allSatisfy { mesh.vertices[$0].z >= -1e-12 }
            })
        #expect(room.contains([2.5, 2, 1.5]))
    }

    @Test("Separate triangles are welded into one surface, and a concave floor stays one face")
    func weldingAndConcaveFaces() throws {
        // An L-shaped room from the floor plan, each face given its own copies of its corners, as STL does.
        let plan = FloorPlan.lShape([8, 6], notch: [4, 3], material: Self.plaster)
        let mesh = RoomMesh.extruding(plan, height: 2.6, floor: Self.plaster, ceiling: Self.plaster)
        let polygons = mesh.faces.map { face in
            RoomImport.Polygon(corners: face.corners.map { mesh.vertices[$0] + 1e-6 }, name: nil)
        }
        let (room, notes) = try RoomImport.room(from: polygons, scale: 1, yUp: false, material: Self.plaster)
        #expect(notes.isEmpty)
        #expect(abs(room.volume - (48 - 12) * 2.6) < 1e-6)
        #expect(room.mesh?.faces.count == mesh.faces.count)
        #expect(room.mesh?.labels == ["Imported"])
        // Triangles, as an STL file holds them.
        let triangles = mesh.triangles().map { triangle, _ in
            RoomImport.Polygon(
                corners: [triangle.x, triangle.y, triangle.z].map { mesh.vertices[$0] }, name: nil)
        }
        let fromTriangles = try RoomImport.room(from: triangles, scale: 1, yUp: false, material: Self.plaster)
        #expect(abs(fromTriangles.room.volume - room.volume) < 1e-9)
    }

    @Test("Open or tangled surfaces are refused with what is wrong; warped faces are cut into triangles")
    func faults() throws {
        var open = Self.outwardBox([5, 4, 3])
        open.removeLast()
        #expect {
            try RoomImport.room(from: open, scale: 1, yUp: false, material: Self.plaster)
        } throws: { error in
            error.localizedDescription.contains("4 edges belong to only one face")
        }
        // Two boxes sharing an edge: the shared edge belongs to four faces.
        let other = Self.outwardBox([2, 2, 3]).map { polygon in
            RoomImport.Polygon(corners: polygon.corners.map { $0 + SIMD3(5, 4, 0) }, name: polygon.name)
        }
        #expect {
            try RoomImport.room(
                from: Self.outwardBox([5, 4, 3]) + other, scale: 1, yUp: false, material: Self.plaster)
        } throws: { error in
            error.localizedDescription.contains("more than two faces")
        }
        // The ceiling's corner raised by 5 cm: that face is no longer flat, and the walls meet it there.
        var warped = Self.outwardBox([5, 4, 3])
        let raised = SIMD3<Double>(5, 4, 3)
        warped = warped.map { polygon in
            RoomImport.Polygon(
                corners: polygon.corners.map { $0 == raised ? $0 + [0, 0, 0.05] : $0 }, name: polygon.name)
        }
        let (room, notes) = try RoomImport.room(from: warped, scale: 1, yUp: false, material: Self.plaster)
        #expect(notes.contains { $0.contains("cut into triangles") })
        #expect(room.volume > 60)
        #expect(throws: AcousticError.self) {
            try RoomImport.room(from: [], scale: 1, yUp: false, material: Self.plaster)
        }
    }
}
