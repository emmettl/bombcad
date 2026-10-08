import Foundation
import simd

/// A solid made of convex polygons facing outwards, combined by binary space partitioning, after Evan
/// Wallace's csg.js (MIT licence): each solid's polygons are clipped by the other's tree of planes. It
/// builds rooms of any shape from simple pieces: the air of a hall as boxes and extruded plans or
/// sections, joined, cut and intersected; a balcony is a slab cut out of the air.
///
/// Every polygon carries the material of the surface it came from, so the room's faces keep the
/// materials of the pieces that make them.
public struct Solid: Sendable {
    public struct Polygon: Sendable {
        public var vertices: [SIMD3<Double>]
        /// Index into the materials of the mesh the solid becomes.
        public var material: Int
        /// An opening to the air outside.
        public var open: Bool
        var normal: SIMD3<Double>
        var offset: Double

        public init(vertices: [SIMD3<Double>], material: Int, open: Bool = false) {
            self.vertices = vertices
            self.material = material
            self.open = open
            normal = simd_normalize(simd_cross(vertices[1] - vertices[0], vertices[2] - vertices[0]))
            offset = simd_dot(normal, vertices[0])
        }

        func flipped() -> Polygon {
            var copy = self
            copy.vertices.reverse()
            copy.normal = -normal
            copy.offset = -offset
            return copy
        }
    }

    public var polygons: [Polygon]

    public init(polygons: [Polygon]) { self.polygons = polygons }

    static let epsilon = 1e-6

    // MARK: - Pieces

    /// The box between two corners, each face with its own material in the order -x, +x, -y, +y, -z, +z.
    public static func box(_ low: SIMD3<Double>, _ high: SIMD3<Double>, materials: [Int]) -> Solid {
        precondition(materials.count == 6)
        let v = (0..<8).map { i in
            SIMD3(i & 1 == 0 ? low.x : high.x, i & 2 == 0 ? low.y : high.y, i & 4 == 0 ? low.z : high.z)
        }
        // Anticlockwise seen from outside.
        let faces = [
            [0, 4, 6, 2], [1, 3, 7, 5], [0, 1, 5, 4], [2, 6, 7, 3], [0, 2, 3, 1], [4, 5, 7, 6],
        ]
        return Solid(
            polygons: faces.enumerated().map {
                Polygon(vertices: $0.element.map { v[$0] }, material: materials[$0.offset])
            })
    }

    /// The box between two corners, all of one material.
    public static func box(_ low: SIMD3<Double>, _ high: SIMD3<Double>, material: Int) -> Solid {
        box(low, high, materials: Array(repeating: material, count: 6))
    }

    /// A polygon in the plane of two axes, extruded along the third from `from` to `to`: a vertical
    /// prism of a floor plan (axis 2), or a horizontal prism of a section, such as a hall's long section
    /// with its raked floor and sloping ceiling extruded across its width (axis 1). The polygon's points
    /// are (y, z) along x, (x, z) along y and (x, y) along z, and it may run either way round and be
    /// concave, but must not cross itself; `sides[i]` is the material of the face along edge i, from
    /// point i to point i + 1, and the ends take `ends`, the lower end first.
    public static func extrusion(
        _ points: [SIMD2<Double>], along axis: Int, from: Double, to: Double, sides: [Int], ends: (Int, Int)
    ) -> Solid {
        precondition(points.count >= 3 && sides.count == points.count && to > from)
        // In the axes (a, b) with a × b along the axis: (z, x) along y, so its points are swapped.
        let polygon = axis == 1 ? points.map { SIMD2($0.y, $0.x) } : points
        let (a, b) = ((axis + 1) % 3, (axis + 2) % 3)
        func point(_ p: SIMD2<Double>, _ c: Double) -> SIMD3<Double> {
            var v = SIMD3<Double>(repeating: 0)
            v[a] = p.x
            v[b] = p.y
            v[axis] = c
            return v
        }
        // Anticlockwise in (a, b) looking down the axis, so the far end faces +axis.
        let area = polygon.indices.reduce(0) { total, i in
            let p = polygon[i]
            let q = polygon[(i + 1) % polygon.count]
            return total + p.x * q.y - q.x * p.y
        }
        let ring: [SIMD2<Double>] = area > 0 ? polygon : Array(polygon.reversed())
        // Reversing the ring turns edge i into edge n - 2 - i.
        let n = polygon.count
        let ringSides = area > 0 ? sides : (0..<n).map { sides[(2 * n - 2 - $0) % n] }
        var polygons: [Polygon] = []
        for i in ring.indices {
            let p = ring[i]
            let q = ring[(i + 1) % ring.count]
            polygons.append(
                Polygon(
                    vertices: [point(p, from), point(q, from), point(q, to), point(p, to)],
                    material: ringSides[i]))
        }
        for triangle in triangulate(ring) {
            polygons.append(Polygon(vertices: triangle.reversed().map { point($0, from) }, material: ends.0))
            polygons.append(Polygon(vertices: triangle.map { point($0, to) }, material: ends.1))
        }
        return Solid(polygons: polygons)
    }

    /// Triangles covering an anticlockwise simple polygon, by ear clipping.
    static func triangulate(_ polygon: [SIMD2<Double>]) -> [[SIMD2<Double>]] {
        var remaining = polygon
        var triangles: [[SIMD2<Double>]] = []
        func cross(_ o: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var guardCount = 0
        while remaining.count > 3, guardCount < 10_000 {
            guardCount += 1
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
                triangles.append([p, q, r])
                remaining.remove(at: i)
                clipped = true
                break
            }
            if !clipped { break }
        }
        if remaining.count == 3 { triangles.append(remaining) }
        return triangles
    }

    // MARK: - Operations

    /// Everything in either solid.
    public func union(_ other: Solid) -> Solid {
        let a = Node(polygons)
        let b = Node(other.polygons)
        a.clip(to: b)
        b.clip(to: a)
        b.invert()
        b.clip(to: a)
        b.invert()
        a.build(b.allPolygons())
        return Solid(polygons: a.allPolygons())
    }

    /// This solid without the other.
    public func subtracting(_ other: Solid) -> Solid {
        let a = Node(polygons)
        let b = Node(other.polygons)
        a.invert()
        a.clip(to: b)
        b.clip(to: a)
        b.invert()
        b.clip(to: a)
        b.invert()
        a.build(b.allPolygons())
        a.invert()
        return Solid(polygons: a.allPolygons())
    }

    /// What lies in both solids.
    public func intersection(_ other: Solid) -> Solid {
        let a = Node(polygons)
        let b = Node(other.polygons)
        a.invert()
        b.clip(to: a)
        b.invert()
        a.clip(to: b)
        b.clip(to: a)
        a.build(b.allPolygons())
        a.invert()
        return Solid(polygons: a.allPolygons())
    }

    /// The room this solid of air makes: its faces turned to face into it, corners shared where they
    /// coincide, with the given materials.
    public func room(materials: [SurfaceMaterial]) -> RoomMesh {
        var vertices: [SIMD3<Double>] = []
        var lookup: [SIMD3<Int64>: Int] = [:]
        func index(_ v: SIMD3<Double>) -> Int {
            let scaled = (v * 1e5).rounded(.toNearestOrAwayFromZero)
            let key = SIMD3<Int64>(Int64(scaled.x), Int64(scaled.y), Int64(scaled.z))
            if let found = lookup[key] { return found }
            lookup[key] = vertices.count
            vertices.append(v)
            return vertices.count - 1
        }
        var faces: [RoomMesh.Face] = []
        for polygon in polygons {
            var corners: [Int] = []
            for v in polygon.vertices.reversed() {
                let i = index(v)
                if corners.last != i { corners.append(i) }
            }
            if corners.count > 1, corners.first == corners.last { corners.removeLast() }
            guard Set(corners).count >= 3 else { continue }
            faces.append(RoomMesh.Face(corners: corners, material: polygon.material, open: polygon.open))
        }
        return RoomMesh(vertices: vertices, faces: faces, materials: materials)
    }

    // MARK: - Binary space partitioning

    final class Node {
        var normal: SIMD3<Double>?
        var offset = 0.0
        var front: Node?
        var back: Node?
        var polygons: [Polygon] = []

        init(_ polygons: [Polygon] = []) { build(polygons) }

        func invert() {
            polygons = polygons.map { $0.flipped() }
            normal = normal.map { -$0 }
            offset = -offset
            front?.invert()
            back?.invert()
            swap(&front, &back)
        }

        func clipPolygons(_ list: [Polygon]) -> [Polygon] {
            guard let normal else { return list }
            var front: [Polygon] = []
            var back: [Polygon] = []
            for polygon in list {
                var coplanarFront: [Polygon] = []
                var coplanarBack: [Polygon] = []
                Solid.split(
                    polygon, normal: normal, offset: offset, coplanarFront: &coplanarFront,
                    coplanarBack: &coplanarBack, front: &front, back: &back)
                front += coplanarFront
                back += coplanarBack
            }
            front = self.front?.clipPolygons(front) ?? front
            back = self.back?.clipPolygons(back) ?? []
            return front + back
        }

        func clip(to node: Node) {
            polygons = node.clipPolygons(polygons)
            front?.clip(to: node)
            back?.clip(to: node)
        }

        func allPolygons() -> [Polygon] {
            polygons + (front?.allPolygons() ?? []) + (back?.allPolygons() ?? [])
        }

        func build(_ list: [Polygon]) {
            guard !list.isEmpty else { return }
            if normal == nil {
                normal = list[0].normal
                offset = list[0].offset
            }
            var frontList: [Polygon] = []
            var backList: [Polygon] = []
            for polygon in list {
                var coplanarFront: [Polygon] = []
                var coplanarBack: [Polygon] = []
                Solid.split(
                    polygon, normal: normal!, offset: offset, coplanarFront: &coplanarFront,
                    coplanarBack: &coplanarBack, front: &frontList, back: &backList)
                polygons += coplanarFront + coplanarBack
            }
            if !frontList.isEmpty {
                if front == nil { front = Node() }
                front!.build(frontList)
            }
            if !backList.isEmpty {
                if back == nil { back = Node() }
                back!.build(backList)
            }
        }
    }

    /// Sorts a polygon against a plane, splitting it where it spans the plane.
    static func split(
        _ polygon: Polygon, normal: SIMD3<Double>, offset: Double, coplanarFront: inout [Polygon],
        coplanarBack: inout [Polygon], front: inout [Polygon], back: inout [Polygon]
    ) {
        let coplanar = 0
        let inFront = 1
        let behind = 2
        var kinds: [Int] = []
        var kind = 0
        for v in polygon.vertices {
            let t = simd_dot(normal, v) - offset
            let k = t < -epsilon ? behind : t > epsilon ? inFront : coplanar
            kind |= k
            kinds.append(k)
        }
        switch kind {
        case coplanar:
            if simd_dot(normal, polygon.normal) > 0 {
                coplanarFront.append(polygon)
            } else {
                coplanarBack.append(polygon)
            }
        case inFront:
            front.append(polygon)
        case behind:
            back.append(polygon)
        default:
            var f: [SIMD3<Double>] = []
            var b: [SIMD3<Double>] = []
            let n = polygon.vertices.count
            for i in 0..<n {
                let j = (i + 1) % n
                let (ti, tj) = (kinds[i], kinds[j])
                let (vi, vj) = (polygon.vertices[i], polygon.vertices[j])
                if ti != behind { f.append(vi) }
                if ti != inFront { b.append(vi) }
                if (ti | tj) == inFront | behind {
                    let t = (offset - simd_dot(normal, vi)) / simd_dot(normal, vj - vi)
                    let v = vi + (vj - vi) * t
                    f.append(v)
                    b.append(v)
                }
            }
            if f.count >= 3 {
                var piece = polygon
                piece.vertices = f
                front.append(piece)
            }
            if b.count >= 3 {
                var piece = polygon
                piece.vertices = b
                back.append(piece)
            }
        }
    }
}
