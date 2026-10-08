import Foundation
import simd

/// A room of any shape: a closed polyhedron of flat faces, each with a material. Sloping ceilings, raked
/// seating, stages and balconies are faces like any other.
///
/// Each face's corners run anticlockwise seen from inside the room, so its normal (Newell's) points into
/// the room. The faces must close the room, so their areas, as vectors along their normals, sum to zero;
/// faces may meet at T-junctions, as `Solid` leaves them. Corners lie within `[0, size]` of the room that
/// holds the mesh.
public struct RoomMesh: Codable, Equatable, Sendable {
    public struct Face: Codable, Equatable, Sendable {
        /// Indices into `vertices`, anticlockwise seen from inside.
        public var corners: [Int]
        /// Index into `materials`.
        public var material: Int
        /// An open area, such as a doorway or an opening to another space, through which sound leaves:
        /// air, absorbing everything, whatever its material.
        public var open: Bool

        public init(corners: [Int], material: Int, open: Bool = false) {
            self.corners = corners
            self.material = material
            self.open = open
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            corners = try container.decode([Int].self, forKey: .corners)
            material = try container.decode(Int.self, forKey: .material)
            open = try container.decodeIfPresent(Bool.self, forKey: .open) ?? false
        }
    }

    public var vertices: [SIMD3<Double>]
    public var faces: [Face]
    /// Materials the faces refer to: one per kind of surface, such as "seating" or "plaster".
    public var materials: [SurfaceMaterial]
    /// What each material covers, such as "Audience" or "Stage walls", for showing; nil for none.
    public var labels: [String]?

    public init(
        vertices: [SIMD3<Double>], faces: [Face], materials: [SurfaceMaterial], labels: [String]? = nil
    ) {
        self.vertices = vertices
        self.faces = faces
        self.materials = materials
        self.labels = labels
    }

    /// The area each material covers.
    public var materialAreas: [Double] {
        var areas = [Double](repeating: 0, count: materials.count)
        for face in faces.indices where !faces[face].open {
            areas[faces[face].material] += normalAndArea(face).area
        }
        return areas
    }

    /// Unit normal into the room, by Newell's method, and the face's area.
    public func normalAndArea(_ face: Int) -> (normal: SIMD3<Double>, area: Double) {
        let corners = faces[face].corners.map { vertices[$0] }
        var n = SIMD3<Double>(repeating: 0)
        for i in corners.indices {
            let a = corners[i]
            let b = corners[(i + 1) % corners.count]
            n += SIMD3((a.y - b.y) * (a.z + b.z), (a.z - b.z) * (a.x + b.x), (a.x - b.x) * (a.y + b.y))
        }
        let length = simd_length(n)
        return (length > 0 ? n / length : n, length / 2)
    }

    /// Each face cut into triangles, as corner indices wound so their normals point into the room like
    /// the face's, by ear clipping in the face's own plane. Faces may be concave, as an L-shaped floor
    /// is.
    public func triangles() -> [(corners: SIMD3<Int>, face: Int)] {
        var result: [(corners: SIMD3<Int>, face: Int)] = []
        for face in faces.indices {
            let corners = faces[face].corners
            guard corners.count >= 3 else { continue }
            let normal = normalAndArea(face).normal
            // Axes in the plane with (u, v, normal) right-handed, so the face runs anticlockwise in them.
            let helper: SIMD3<Double> = abs(normal.z) < 0.9 ? [0, 0, 1] : [1, 0, 0]
            let u = simd_normalize(simd_cross(helper, normal))
            let v = simd_cross(normal, u)
            let flat = corners.map { SIMD2(simd_dot(vertices[$0], u), simd_dot(vertices[$0], v)) }
            func cross(_ o: Int, _ a: Int, _ b: Int) -> Double {
                (flat[a].x - flat[o].x) * (flat[b].y - flat[o].y) - (flat[a].y - flat[o].y)
                    * (flat[b].x - flat[o].x)
            }
            var remaining = Array(corners.indices)
            while remaining.count > 3 {
                var clipped = false
                for i in remaining.indices {
                    let p = remaining[(i + remaining.count - 1) % remaining.count]
                    let q = remaining[i]
                    let r = remaining[(i + 1) % remaining.count]
                    guard cross(p, q, r) > 1e-12 else { continue }
                    let blocked = remaining.contains { s in
                        s != p && s != q && s != r && cross(p, q, s) >= 0 && cross(q, r, s) >= 0
                            && cross(r, p, s) >= 0
                    }
                    guard !blocked else { continue }
                    result.append((SIMD3(corners[p], corners[q], corners[r]), face))
                    remaining.remove(at: i)
                    clipped = true
                    break
                }
                // A degenerate remainder, such as collinear corners, is left out.
                if !clipped { break }
            }
            if remaining.count == 3 {
                result.append(
                    (SIMD3(corners[remaining[0]], corners[remaining[1]], corners[remaining[2]]), face))
            }
        }
        return result
    }

    /// The material a face presents: its own, or air for an open face.
    public func material(of face: Int) -> SurfaceMaterial {
        faces[face].open ? .anechoic : materials[faces[face].material]
    }

    /// The edges that outline the room for drawing: those of each flat surface's outline, leaving out
    /// the edges between pieces of the same surface.
    public func outlineEdges() -> [(SIMD3<Double>, SIMD3<Double>)] {
        let geometry = MeshGeometry.of(self)
        var edges: [(SIMD3<Double>, SIMD3<Double>)] = []
        for plane in geometry.planes {
            var count: [SIMD2<Int>: Int] = [:]
            for face in plane.faces {
                let corners = faces[face].corners
                for i in corners.indices {
                    let a = corners[i]
                    let b = corners[(i + 1) % corners.count]
                    count[SIMD2(min(a, b), max(a, b)), default: 0] += 1
                }
            }
            for (edge, n) in count where n == 1 { edges.append((vertices[edge.x], vertices[edge.y])) }
        }
        return edges
    }

    public var bounds: (min: SIMD3<Double>, max: SIMD3<Double>) {
        (
            vertices.reduce(vertices[0]) { simd_min($0, $1) },
            vertices.reduce(vertices[0]) { simd_max($0, $1) }
        )
    }

    /// The enclosed volume, by the divergence theorem; negative if the faces point outwards.
    public var signedVolume: Double {
        faces.indices.reduce(0) { total, face in
            let (normal, area) = normalAndArea(face)
            // Faces point inwards, so the outward flux of x is minus this.
            return total - area * simd_dot(normal, vertices[faces[face].corners[0]]) / 3
        }
    }

    public var volume: Double { abs(signedVolume) }

    func validate() throws {
        guard faces.count >= 4, vertices.count >= 4, !materials.isEmpty else {
            throw AcousticError.invalid("A room's mesh needs at least four faces and one material.")
        }
        guard vertices.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else {
            throw AcousticError.invalid("The room's mesh has a corner that is not a finite point.")
        }
        var flux = SIMD3<Double>(repeating: 0)
        var total = 0.0
        for (index, face) in faces.enumerated() {
            let name = "Face \(index + 1) of the room's mesh"
            guard face.corners.count >= 3, face.corners.allSatisfy(vertices.indices.contains),
                Set(face.corners).count == face.corners.count
            else { throw AcousticError.invalid("\(name) needs three or more distinct corners.") }
            guard materials.indices.contains(face.material) else {
                throw AcousticError.invalid("\(name) refers to a material the mesh does not have.")
            }
            let (normal, area) = normalAndArea(index)
            guard area > 1e-10 else { throw AcousticError.invalid("\(name) has no area.") }
            let origin = vertices[face.corners[0]]
            let flatness = face.corners.map { abs(simd_dot(vertices[$0] - origin, normal)) }.max() ?? 0
            guard flatness < 0.02 else {
                throw AcousticError.invalid(
                    "\(name) is not flat: a corner is \(Int(flatness * 100)) cm off its plane.")
            }
            flux += normal * area
            total += area
        }
        guard simd_length(flux) < 1e-6 * total else {
            throw AcousticError.invalid(
                "The room's mesh is not closed: its faces leave a gap of about "
                    + "\(String(format: "%.2g", simd_length(flux))) m².")
        }
        guard signedVolume > 0.25 else {
            throw AcousticError.invalid(
                "The room's mesh must enclose at least 0.25 m³ with its faces turned inwards.")
        }
        for material in materials { try material.validate() }
    }

    // MARK: - Shapes

    /// A box filling `[0, size]`, its faces in the order of `Surface.allCases`.
    public static func box(_ size: SIMD3<Double>, materials: [Surface: SurfaceMaterial]) -> RoomMesh {
        let v: [SIMD3<Double>] = (0..<8).map { i in
            SIMD3(i & 1 == 0 ? 0 : size.x, i & 2 == 0 ? 0 : size.y, i & 4 == 0 ? 0 : size.z)
        }
        // Anticlockwise seen from inside.
        let corners: [Surface: [Int]] = [
            .west: [0, 2, 6, 4], .east: [1, 5, 7, 3], .south: [0, 4, 5, 1], .north: [2, 3, 7, 6],
            .floor: [0, 1, 3, 2], .ceiling: [4, 6, 7, 5],
        ]
        let surfaces = Surface.allCases
        return RoomMesh(
            vertices: v,
            faces: surfaces.enumerated().map { Face(corners: corners[$0.element]!, material: $0.offset) },
            materials: surfaces.map { materials[$0]! })
    }

    /// A floor plan's walls extruded from the floor (z = 0) to `height`, with the plan's wall materials,
    /// then the floor and the ceiling.
    public static func extruding(
        _ plan: FloorPlan, height: Double, floor: SurfaceMaterial, ceiling: SurfaceMaterial
    ) -> RoomMesh {
        let n = plan.count
        let vertices =
            plan.corners.map { SIMD3($0.x, $0.y, 0) } + plan.corners.map { SIMD3($0.x, $0.y, height) }
        // Up from each corner, along the top and down: anticlockwise seen from inside, since the room
        // lies to the left of each wall.
        var faces = (0..<n).map { i in Face(corners: [i, n + i, n + (i + 1) % n, (i + 1) % n], material: i) }
        // The plan runs anticlockwise from above: seen from inside, the floor runs the same way and the
        // ceiling the other.
        faces.append(Face(corners: Array(0..<n), material: n))
        faces.append(Face(corners: (0..<n).reversed().map { n + $0 }, material: n + 1))
        return RoomMesh(vertices: vertices, faces: faces, materials: plan.walls + [floor, ceiling])
    }
}

/// A mesh prepared for queries: each face's plane, its corners projected onto the plane's two longest
/// axes, and a bounding-volume hierarchy over the faces.
final class MeshGeometry: @unchecked Sendable {
    struct Face {
        var normal: SIMD3<Double>
        /// normal · x for every point x on the plane.
        var offset: Double
        var area: Double
        /// The two axes the face is projected onto, and its corners projected.
        var axes: (Int, Int)
        var polygon: [SIMD2<Double>]
        var corners: [SIMD3<Double>]
        var low: SIMD3<Double>
        var high: SIMD3<Double>
        var open: Bool
        var material: Int
    }

    struct Node {
        var low: SIMD3<Double>
        var high: SIMD3<Double>
        /// Children, or for a leaf the range of `order` it holds.
        var left = -1
        var right = -1
        var first = 0
        var count = 0
    }

    let mesh: RoomMesh
    let faces: [Face]
    /// Faces grouped by the plane they lie in, and each face's group: a wall cut into pieces is one plane
    /// for the image sources.
    private(set) var planes: [(normal: SIMD3<Double>, offset: Double, faces: [Int])] = []
    private(set) var planeOfFace: [Int] = []
    private(set) var nodes: [Node] = []
    private var order: [Int] = []

    private static let lock = NSLock()
    nonisolated(unsafe) private static var recent: [MeshGeometry] = []

    /// The prepared geometry of a mesh, built once and kept for the few meshes used most recently.
    static func of(_ mesh: RoomMesh) -> MeshGeometry {
        lock.lock()
        defer { lock.unlock() }
        if let index = recent.firstIndex(where: { $0.mesh == mesh }) {
            let found = recent.remove(at: index)
            recent.append(found)
            return found
        }
        let made = MeshGeometry(mesh)
        recent.append(made)
        if recent.count > 4 { recent.removeFirst() }
        return made
    }

    init(_ mesh: RoomMesh) {
        self.mesh = mesh
        faces = mesh.faces.indices.map { index in
            let (normal, area) = mesh.normalAndArea(index)
            let corners = mesh.faces[index].corners.map { mesh.vertices[$0] }
            let dominant = (0..<3).max { abs(normal[$0]) < abs(normal[$1]) }!
            let axes = ((dominant + 1) % 3, (dominant + 2) % 3)
            return Face(
                normal: normal, offset: simd_dot(normal, corners[0]), area: area, axes: axes,
                polygon: corners.map { SIMD2($0[axes.0], $0[axes.1]) }, corners: corners,
                low: corners.reduce(corners[0]) { simd_min($0, $1) },
                high: corners.reduce(corners[0]) { simd_max($0, $1) }, open: mesh.faces[index].open,
                material: mesh.faces[index].material)
        }
        order = Array(faces.indices)
        nodes.reserveCapacity(2 * faces.count)
        _ = build(0, faces.count)
        for (index, face) in faces.enumerated() {
            if let group = planes.firstIndex(where: {
                simd_dot($0.normal, face.normal) > 1 - 1e-9 && abs($0.offset - face.offset) < 1e-5
            }) {
                planes[group].faces.append(index)
                planeOfFace.append(group)
            } else {
                planes.append((face.normal, face.offset, [index]))
                planeOfFace.append(planes.count - 1)
            }
        }
    }

    private func build(_ first: Int, _ count: Int) -> Int {
        var low = SIMD3<Double>(repeating: .infinity)
        var high = SIMD3<Double>(repeating: -.infinity)
        for i in first..<(first + count) {
            low = simd_min(low, faces[order[i]].low)
            high = simd_max(high, faces[order[i]].high)
        }
        let index = nodes.count
        nodes.append(Node(low: low, high: high))
        if count <= 4 {
            nodes[index].first = first
            nodes[index].count = count
            return index
        }
        // Split at the median along the longest side of the box of face centres.
        let centres = (first..<(first + count)).map { (faces[order[$0]].low + faces[order[$0]].high) / 2 }
        let span =
            centres.reduce(centres[0]) { simd_max($0, $1) } - centres.reduce(centres[0]) { simd_min($0, $1) }
        let axis = (0..<3).max { span[$0] < span[$1] }!
        let sorted = order[first..<(first + count)].sorted {
            faces[$0].low[axis] + faces[$0].high[axis] < faces[$1].low[axis] + faces[$1].high[axis]
        }
        order.replaceSubrange(first..<(first + count), with: sorted)
        let half = count / 2
        let left = build(first, half)
        let right = build(first + half, count - half)
        nodes[index].left = left
        nodes[index].right = right
        return index
    }

    /// Whether a point on a face's plane lies within the face, by crossings in its projection.
    func faceContains(_ face: Int, _ point: SIMD3<Double>) -> Bool {
        let f = faces[face]
        let p = SIMD2(point[f.axes.0], point[f.axes.1])
        var inside = false
        let polygon = f.polygon
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i]
            let b = polygon[j]
            if (a.y > p.y) != (b.y > p.y) {
                let x = a.x + (p.y - a.y) / (b.y - a.y) * (b.x - a.x)
                if p.x < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    /// Parameter t > 0 at which `origin + t direction` crosses a face, if it does.
    func intersect(_ face: Int, origin: SIMD3<Double>, direction: SIMD3<Double>) -> Double? {
        let f = faces[face]
        let denominator = simd_dot(f.normal, direction)
        guard abs(denominator) > 1e-12 else { return nil }
        let t = (f.offset - simd_dot(f.normal, origin)) / denominator
        guard t > 1e-9 else { return nil }
        return faceContains(face, origin + direction * t) ? t : nil
    }

    private func boxHit(
        _ node: Node, origin: SIMD3<Double>, inverse: SIMD3<Double>, limit: Double
    ) -> Bool {
        let t1 = (node.low - origin) * inverse
        let t2 = (node.high - origin) * inverse
        let near = simd_reduce_max(simd_min(t1, t2))
        let far = simd_reduce_min(simd_max(t1, t2))
        return far >= max(near, 0) && near <= limit
    }

    private func inverse(_ direction: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(
            direction.x != 0 ? 1 / direction.x : .infinity, direction.y != 0 ? 1 / direction.y : .infinity,
            direction.z != 0 ? 1 / direction.z : .infinity)
    }

    /// The nearest face the ray meets before `limit`, other than `excluded`.
    func nearestHit(
        origin: SIMD3<Double>, direction: SIMD3<Double>, excluding excluded: Int = -1,
        limit: Double = .infinity
    ) -> (t: Double, face: Int)? {
        let inv = inverse(direction)
        var best: (t: Double, face: Int)?
        var stack = [0]
        while let index = stack.popLast() {
            let node = nodes[index]
            guard boxHit(node, origin: origin, inverse: inv, limit: best?.t ?? limit) else { continue }
            if node.left < 0 {
                for i in node.first..<(node.first + node.count) {
                    let face = order[i]
                    guard face != excluded,
                        let t = intersect(face, origin: origin, direction: direction), t < (best?.t ?? limit)
                    else { continue }
                    best = (t, face)
                }
            } else {
                stack.append(node.left)
                stack.append(node.right)
            }
        }
        return best
    }

    /// Whether the segment from a to b crosses no face other than those excluded.
    func unobstructed(_ a: SIMD3<Double>, _ b: SIMD3<Double>, excluding excluded: [Int]) -> Bool {
        let direction = b - a
        let inv = inverse(direction)
        var stack = [0]
        while let index = stack.popLast() {
            let node = nodes[index]
            guard boxHit(node, origin: a, inverse: inv, limit: 1) else { continue }
            if node.left < 0 {
                for i in node.first..<(node.first + node.count) {
                    let face = order[i]
                    guard !excluded.contains(face) else { continue }
                    if let t = intersect(face, origin: a, direction: direction), t < 1 - 1e-9 { return false }
                }
            } else {
                stack.append(node.left)
                stack.append(node.right)
            }
        }
        return true
    }

    /// Heights at which a vertical line through (x, y) crosses the mesh, sorted.
    func verticalCrossings(x: Double, y: Double) -> [Double] {
        let origin = SIMD3(x, y, mesh.bounds.min.z - 1)
        let direction = SIMD3<Double>(0, 0, 1)
        let inv = inverse(direction)
        var heights: [Double] = []
        var stack = [0]
        while let index = stack.popLast() {
            let node = nodes[index]
            guard boxHit(node, origin: origin, inverse: inv, limit: .infinity) else { continue }
            if node.left < 0 {
                for i in node.first..<(node.first + node.count) {
                    if let t = intersect(order[i], origin: origin, direction: direction) {
                        heights.append(origin.z + t)
                    }
                }
            } else {
                stack.append(node.left)
                stack.append(node.right)
            }
        }
        return heights.sorted()
    }

    /// Whether a point lies inside: an odd number of crossings along a ray in a direction no wall of a
    /// building is likely to lie along.
    func contains(_ point: SIMD3<Double>) -> Bool {
        let direction = simd_normalize(SIMD3(0.5773, 0.5779, 0.5767))
        let inv = inverse(direction)
        var crossings = 0
        var stack = [0]
        while let index = stack.popLast() {
            let node = nodes[index]
            guard boxHit(node, origin: point, inverse: inv, limit: .infinity) else { continue }
            if node.left < 0 {
                for i in node.first..<(node.first + node.count)
                where intersect(order[i], origin: point, direction: direction) != nil {
                    crossings += 1
                }
            } else {
                stack.append(node.left)
                stack.append(node.right)
            }
        }
        return crossings % 2 == 1
    }

    /// Distance from a point to a face.
    func distance(_ point: SIMD3<Double>, toFace face: Int) -> Double {
        let f = faces[face]
        let height = simd_dot(f.normal, point) - f.offset
        let foot = point - f.normal * height
        if faceContains(face, foot) { return abs(height) }
        var best = Double.infinity
        for i in f.corners.indices {
            let a = f.corners[i]
            let b = f.corners[(i + 1) % f.corners.count]
            let ab = b - a
            let t = min(max(simd_dot(point - a, ab) / simd_length_squared(ab), 0), 1)
            best = min(best, simd_distance(point, a + ab * t))
        }
        return best
    }

    /// The face nearest a point, by brute force over the faces whose boxes could hold a nearer one.
    func nearestFace(_ point: SIMD3<Double>) -> Int {
        var best = (distance: Double.infinity, face: 0)
        for face in faces.indices {
            let f = faces[face]
            let gap = simd_length(simd_max(simd_max(f.low - point, point - f.high), SIMD3(repeating: 0)))
            guard gap < best.distance else { continue }
            let d = distance(point, toFace: face)
            if d < best.distance { best = (d, face) }
        }
        return best.face
    }

    /// Shortest distance from a point to any face.
    func clearance(_ point: SIMD3<Double>) -> Double {
        distance(point, toFace: nearestFace(point))
    }
}
