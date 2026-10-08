import SceneModel
import simd

/// What a `MeshRenderer` draws: lit triangles, translucent triangles and lines, in metres with z up.
///
/// Solid triangles are drawn only from the side their normal faces, so a room whose faces point into
/// it shows its far walls and floor from outside, with the near walls left out: a cutaway. Each
/// solid triangle may carry a pick number, non-negative, that `pick` returns and the renderer can
/// highlight.
public struct SceneGeometry: Sendable, Equatable {
    /// Layout matches `SceneVertex` in `Scene.metal`: position and pick number, normal, colour.
    public struct Vertex: Sendable, Equatable {
        public var position: SIMD4<Float>
        public var normal: SIMD4<Float>
        public var colour: SIMD4<Float>

        public init(_ position: SIMD3<Float>, normal: SIMD3<Float>, colour: SIMD4<Float>, pick: Int32) {
            self.position = SIMD4(position, Float(pick))
            self.normal = SIMD4(normal, 0)
            self.colour = colour
        }

        public var point: SIMD3<Float> { SIMD3(position.x, position.y, position.z) }
        public var pick: Int32 { Int32(position.w) }
    }

    public var solid: [Vertex] = []
    public var translucent: [Vertex] = []
    /// Pairs of vertices, one line each; their normals are unused.
    public var lines: [Vertex] = []

    public init() {}

    /// A triangle facing the side from which a, b, c run anticlockwise.
    public mutating func addTriangle(
        _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, colour: SIMD4<Float>, pick: Int32 = -1,
        translucent: Bool = false
    ) {
        let cross = simd_cross(b - a, c - a)
        let length = simd_length(cross)
        guard length > 0 else { return }
        let normal = cross / length
        let vertices = [a, b, c].map { Vertex($0, normal: normal, colour: colour, pick: pick) }
        if translucent { self.translucent += vertices } else { solid += vertices }
    }

    /// A convex polygon, as a fan of triangles facing the side from which its corners run anticlockwise.
    public mutating func addPolygon(
        _ corners: [SIMD3<Float>], colour: SIMD4<Float>, pick: Int32 = -1, translucent: Bool = false
    ) {
        guard corners.count >= 3 else { return }
        for i in 1..<(corners.count - 1) {
            addTriangle(
                corners[0], corners[i], corners[i + 1], colour: colour, pick: pick, translucent: translucent)
        }
    }

    public mutating func addLine(_ a: SIMD3<Float>, _ b: SIMD3<Float>, colour: SIMD4<Float>) {
        lines += [
            Vertex(a, normal: .zero, colour: colour, pick: -1),
            Vertex(b, normal: .zero, colour: colour, pick: -1),
        ]
    }

    /// The eight corners of a box, x fastest.
    static func corners(_ low: SIMD3<Float>, _ high: SIMD3<Float>) -> [SIMD3<Float>] {
        (0..<8).map { i in
            SIMD3(i & 1 == 0 ? low.x : high.x, i & 2 == 0 ? low.y : high.y, i & 4 == 0 ? low.z : high.z)
        }
    }

    /// A box's six faces, facing out.
    public mutating func addBox(
        _ low: SIMD3<Float>, _ high: SIMD3<Float>, colour: SIMD4<Float>, pick: Int32 = -1,
        translucent: Bool = false
    ) {
        let v = Self.corners(low, high)
        // Anticlockwise seen from outside.
        for face in [
            [0, 4, 6, 2], [1, 3, 7, 5], [0, 1, 5, 4], [2, 6, 7, 3], [0, 2, 3, 1], [4, 5, 7, 6],
        ] {
            addPolygon(face.map { v[$0] }, colour: colour, pick: pick, translucent: translucent)
        }
    }

    /// A box's twelve edges.
    public mutating func addBoxEdges(_ low: SIMD3<Float>, _ high: SIMD3<Float>, colour: SIMD4<Float>) {
        let v = Self.corners(low, high)
        for (a, b) in [
            (0, 1), (2, 3), (4, 5), (6, 7), (0, 2), (1, 3), (4, 6), (5, 7), (0, 4), (1, 5), (2, 6), (3, 7),
        ] {
            addLine(v[a], v[b], colour: colour)
        }
    }

    /// A sphere of `rings` bands of latitude, facing out.
    public mutating func addSphere(
        centre: SIMD3<Float>, radius: Float, colour: SIMD4<Float>, pick: Int32 = -1, rings: Int = 10
    ) {
        let segments = 2 * rings
        func point(_ ring: Int, _ segment: Int) -> SIMD3<Float> {
            let polar = Float.pi * Float(ring) / Float(rings)
            let azimuth = 2 * Float.pi * Float(segment) / Float(segments)
            return centre + radius * SIMD3(sin(polar) * cos(azimuth), sin(polar) * sin(azimuth), cos(polar))
        }
        for ring in 0..<rings {
            for segment in 0..<segments {
                let a = point(ring, segment)
                let b = point(ring + 1, segment)
                let c = point(ring + 1, segment + 1)
                let d = point(ring, segment + 1)
                // Anticlockwise seen from outside. At the poles a quad is a triangle.
                if ring < rings - 1 { addTriangle(a, b, c, colour: colour, pick: pick) }
                if ring > 0 { addTriangle(a, c, d, colour: colour, pick: pick) }
            }
        }
    }

    /// Bounds of everything in the scene, or nil if it is empty.
    public var bounds: Box? {
        let points = (solid + translucent + lines).map(\.point)
        guard let first = points.first else { return nil }
        return Box(
            min: points.reduce(first) { simd_min($0, $1) }, max: points.reduce(first) { simd_max($0, $1) })
    }

    /// The pick number of the nearest triangle with one that a ray meets, if any: what a click there
    /// selects. Solid triangles count only from their drawn side, since from behind they are not
    /// drawn; translucent ones count from either side.
    public func pick(origin: SIMD3<Float>, direction: SIMD3<Float>) -> Int32? {
        var nearest = Float.infinity
        var found: Int32?
        for (triangles, oneSided) in [(solid, true), (translucent, false)] {
            var index = 0
            while index + 2 < triangles.count {
                defer { index += 3 }
                let a = triangles[index]
                guard a.pick >= 0, !oneSided || simd_dot(a.normal.xyz, direction) < 0 else { continue }
                if let t = Self.intersect(
                    origin, direction, a.point, triangles[index + 1].point, triangles[index + 2].point),
                    t < nearest
                {
                    nearest = t
                    found = a.pick
                }
            }
        }
        return found
    }

    /// How far along a ray it meets a triangle, if it does (Möller–Trumbore).
    static func intersect(
        _ origin: SIMD3<Float>, _ direction: SIMD3<Float>, _ p0: SIMD3<Float>, _ p1: SIMD3<Float>,
        _ p2: SIMD3<Float>
    ) -> Float? {
        let e1 = p1 - p0
        let e2 = p2 - p0
        let h = simd_cross(direction, e2)
        let det = simd_dot(e1, h)
        guard abs(det) > 1e-12 else { return nil }
        let s = origin - p0
        let u = simd_dot(s, h) / det
        guard u >= 0, u <= 1 else { return nil }
        let q = simd_cross(s, e1)
        let v = simd_dot(direction, q) / det
        guard v >= 0, u + v <= 1 else { return nil }
        let t = simd_dot(e2, q) / det
        return t > 0 ? t : nil
    }
}

extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
