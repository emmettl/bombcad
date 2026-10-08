import Foundation
import simd

/// Turns polygons from a model file into a room: the closed surface of the air inside it.
///
/// The model is scaled to metres and, if it was drawn with y up, turned so z is up. Corners closer
/// than 0.1 mm are welded, polygons that collapse are dropped, and polygons that are not flat within
/// a millimetre are cut into triangles. If the faces point out of the room, as they do on a solid
/// modelled as the room's air, they are turned to point in. Faces take one material per name in the
/// file (the OBJ material, else its group, else its object), each starting as `material`.
///
/// The result must be one closed surface. A building modelled with thick walls has an inside and an
/// outside surface; only the room's own inside surface, as one closed shell, is a room.
public enum RoomImport {
    public struct Polygon: Sendable {
        public var corners: [SIMD3<Double>]
        public var name: String?

        public init(corners: [SIMD3<Double>], name: String?) {
            self.corners = corners
            self.name = name
        }
    }

    /// Faces beyond this are refused: the ray tracer and image sources slow down with every face.
    public static let faceLimit = 50_000
    static let weld = 1e-4
    static let flatness = 1e-3

    /// The room, its mesh starting at the origin, and notes on what was changed on the way.
    public static func room(
        from polygons: [Polygon], scale: Double, yUp: Bool, material: SurfaceMaterial
    ) throws -> (room: ShoeboxRoom, notes: [String]) {
        guard scale.isFinite, scale > 0 else { throw AcousticError.invalid("The scale must be positive.") }
        guard !polygons.isEmpty else { throw AcousticError.invalid("The model has no faces.") }
        guard polygons.count <= faceLimit else {
            throw AcousticError.invalid(
                "The model has \(polygons.count) faces; RoomCAD takes at most \(faceLimit). Simplify it first."
            )
        }
        var notes: [String] = []
        var vertices: [SIMD3<Double>] = []
        var index: [SIMD3<Int64>: Int] = [:]
        func vertex(_ p: SIMD3<Double>) -> Int {
            let q = (yUp ? SIMD3(p.x, -p.z, p.y) : p) * scale
            let key = SIMD3<Int64>((q / weld).rounded(.toNearestOrEven))
            if let existing = index[key] { return existing }
            vertices.append(q)
            index[key] = vertices.count - 1
            return vertices.count - 1
        }
        var names: [String] = []
        var faces: [RoomMesh.Face] = []
        var dropped = 0
        var split = 0
        for polygon in polygons {
            guard polygon.corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else {
                throw AcousticError.invalid("The model has corners that are not finite numbers.")
            }
            var corners = polygon.corners.map(vertex)
            // Welding can merge neighbouring corners.
            corners = corners.enumerated().filter { $0.element != corners[($0.offset + 1) % corners.count] }
                .map(\.element)
            let name = polygon.name ?? "Imported"
            let material = names.firstIndex(of: name) ?? names.count
            if material == names.count { names.append(name) }
            guard corners.count >= 3, Set(corners).count == corners.count else {
                dropped += 1
                continue
            }
            let face = RoomMesh.Face(corners: corners, material: material)
            let single = RoomMesh(vertices: vertices, faces: [face], materials: [.rigid])
            let (normal, area) = single.normalAndArea(0)
            guard area > 1e-8 else {
                dropped += 1
                continue
            }
            let offset = simd_dot(normal, vertices[corners[0]])
            if corners.count > 3,
                corners.contains(where: { abs(simd_dot(normal, vertices[$0]) - offset) > flatness })
            {
                split += 1
                for (triangle, _) in single.triangles() {
                    faces.append(
                        RoomMesh.Face(corners: [triangle.x, triangle.y, triangle.z], material: material))
                }
            } else {
                faces.append(face)
            }
        }
        if dropped > 0 { notes.append("\(dropped) faces that collapsed to lines or points were left out.") }
        if split > 0 { notes.append("\(split) faces that were not flat were cut into triangles.") }
        guard !faces.isEmpty else { throw AcousticError.invalid("Every face of the model collapsed.") }

        // Edges used once leave the surface open; used more than twice, it is not one surface.
        var uses: [SIMD2<Int>: Int] = [:]
        for face in faces {
            for i in face.corners.indices {
                let a = face.corners[i]
                let b = face.corners[(i + 1) % face.corners.count]
                uses[SIMD2(min(a, b), max(a, b)), default: 0] += 1
            }
        }
        let open = uses.values.filter { $0 == 1 }.count
        let shared = uses.values.filter { $0 > 2 }.count
        guard open == 0, shared == 0 else {
            var reasons: [String] = []
            if open > 0 { reasons.append("\(open) edges belong to only one face, so the surface has gaps") }
            if shared > 0 { reasons.append("\(shared) edges belong to more than two faces") }
            throw AcousticError.invalid(
                "The model must be one closed surface around the room's air: "
                    + reasons.joined(separator: ", and ")
                    + ". Close the gaps, and keep only the room's inside "
                    + "surface.")
        }

        var mesh = RoomMesh(
            vertices: vertices, faces: faces,
            materials: names.map { name in
                var named = material
                named.name = name
                return named
            })
        mesh.labels = names
        if mesh.signedVolume < 0 {
            mesh.faces = mesh.faces.map {
                RoomMesh.Face(corners: $0.corners.reversed(), material: $0.material, open: $0.open)
            }
            notes.append("The faces pointed out of the room and were turned to point in.")
        }
        var room = ShoeboxRoom(size: [1, 1, 1], material: material)
        room.mesh = mesh
        room = room.fittingMesh()
        try room.validate()
        return (room, notes)
    }
}
