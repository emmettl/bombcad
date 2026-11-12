import Foundation
import simd

/// The rock's beds and its weathering, for the look of bedded sedimentary rock: each bed of the
/// bedding family (`QuarryFracture.families[0]`) is one of a few stylised kinds of rock, which
/// sets how it breaks, how far its outer face weathers back and its colour; rock near the old
/// surface is weathered, deeper rock fresh. Illustrative, chosen by eye: not a model of any real
/// quarry's geology. `QuarryRender.metal` keeps a copy of `bedHash` and the kinds' shares; change
/// them together.
public enum QuarryRock {
    public enum Kind: Int, Sendable, CaseIterable {
        /// Pale, massive: thick beds that break into large blocks.
        case limestone
        /// Dark, fissile: thin beds that split into slabs and flakes and weather back.
        case shale
        /// Buff: blocky, with close joints that make elongated pieces.
        case sandstone
        /// Red-brown, hard, rare.
        case ironstone
    }

    /// An integer hash of a bed's index, the same in the shader.
    public static func bedHash(_ k: Int) -> UInt32 {
        var h = UInt32(truncatingIfNeeded: k) &* 0x9E37_79B1
        h ^= h >> 15
        h = h &* 0x85EB_CA77
        h ^= h >> 13
        h = h &* 0xC2B2_AE3D
        h ^= h >> 16
        return h
    }

    public static func kind(bed k: Int) -> Kind {
        let u = Float(bedHash(k) >> 8) / Float(1 << 24)
        return u < 0.42 ? .limestone : u < 0.66 ? .shale : u < 0.88 ? .sandstone : .ironstone
    }

    /// The bed a point lies in.
    public static func bed(_ p: SIMD3<Float>) -> Int {
        Int(floor(QuarryFracture.bedCoordinate(simd_dot(p, QuarryFace.beddingNormal))))
    }

    public static func kind(at p: SIMD3<Float>) -> Kind { kind(bed: bed(p)) }

    /// How far a bed's outer face stands back from the old surface where it is exposed (m): shale
    /// weathers back under ledges of the harder beds, so the face is banded in relief as in colour.
    public static func recess(_ kind: Kind) -> Float {
        switch kind {
        case .limestone: 0.1
        case .shale: 0.95
        case .sandstone: 0.4
        case .ironstone: 0.05
        }
    }

    /// How much more (above 1) or less a bed's joints cut it than the families' own persistence.
    /// Since 12 November 2026 limestone is cut less (more large, blocky pieces) and shale too, so
    /// that its partings leave plates rather than blades; sandstone takes close joints of its own.
    public static func jointFactor(_ kind: Kind) -> Float {
        switch kind {
        case .limestone: 0.45
        case .shale: 0.7
        case .sandstone: 1.05
        case .ironstone: 0.85
        }
    }

    /// How much flatter than wide a bed's coarse cells are, along the bedding's normal: the
    /// metric their faces are placed in (`QuarryFace.beddedNormal`). Massive limestone breaks
    /// blockier and shale flatter than the one stretch of 1.7 all beds had before 12 November 2026.
    public static func stretch(_ kind: Kind) -> Float {
        switch kind {
        case .limestone: 1.0
        case .shale: 2.4
        case .sandstone: 1.6
        case .ironstone: 1.3
        }
    }

    /// Depth below the old surface past which the rock is fresh (m).
    public static let weatheredDepth: Float = 7

    /// Weathering at `depth` below the old surface: 1 at the surface, 0 from `weatheredDepth` in.
    public static func weathering(depth: Float) -> Float {
        let t = max(0, min(1, 1 - depth / weatheredDepth))
        return t * t * (3 - 2 * t)
    }

    /// Per-face bits carried in a vertex's `body` above the block's index: five of weathering and
    /// six of a random value, so a face can be told from its neighbours. The index keeps 21 bits.
    public static let bodyBits: UInt32 = 21
    public static let bodyMask: UInt32 = (1 << bodyBits) - 1

    public static func faceTag(weathering w: Float, random r: Float) -> UInt32 {
        let grade = UInt32(max(0, min(31, (w * 31).rounded())))
        let value = UInt32(max(0, min(63, (r * 63).rounded())))
        return (grade << bodyBits) | (value << (bodyBits + 5))
    }

    /// Zingg's four shapes, by a piece's principal lengths a >= b >= c: equant (b/a and c/b both
    /// over 2/3), disc (c/b under), rod (b/a under) and blade (both under).
    public enum Shape: String, CaseIterable, Sendable { case equant, disc, rod, blade }

    public static func shape(_ polyhedron: QuarryPolyhedron) -> Shape { shapeAndRatios(polyhedron).0 }

    /// Zingg's shape and the two ratios it is read from, b/a and c/b.
    public static func shapeAndRatios(_ polyhedron: QuarryPolyhedron) -> (Shape, SIMD2<Float>) {
        var points: [SIMD3<Float>] = []
        for polygon in polyhedron.faces { points.append(contentsOf: polygon) }
        guard points.count >= 4 else { return (.equant, SIMD2(1, 1)) }
        let mean = points.reduce(SIMD3<Float>.zero, +) / Float(points.count)
        var c = simd_float3x3()
        for p in points {
            let d = p - mean
            c += simd_float3x3(columns: (d * d.x, d * d.y, d * d.z))
        }
        let e = eigenvalues(c).map { sqrt(max($0, 0)) }.sorted(by: >)
        let (a, b, cc) = (e[0], e[1], e[2])
        let ratios = SIMD2(b / max(a, 1e-6), cc / max(b, 1e-6))
        let long = ratios.x >= 2.0 / 3
        let flat = ratios.y < 2.0 / 3
        return (long ? (flat ? .disc : .equant) : (flat ? .blade : .rod), ratios)
    }

    /// The eigenvalues of a symmetric 3 x 3 matrix (the trigonometric solution).
    static func eigenvalues(_ m: simd_float3x3) -> [Float] {
        let (a, b, c) = (m.columns.0, m.columns.1, m.columns.2)
        let p1 = b.x * b.x + c.x * c.x + c.y * c.y
        if p1 < 1e-12 { return [a.x, b.y, c.z] }
        let q = (a.x + b.y + c.z) / 3
        let p2 = (a.x - q) * (a.x - q) + (b.y - q) * (b.y - q) + (c.z - q) * (c.z - q) + 2 * p1
        let p = sqrt(p2 / 6)
        let bm = (m - simd_float3x3(diagonal: SIMD3(repeating: q))) * (1 / p)
        let r = max(-1, min(1, simd_determinant(bm) / 2))
        let phi = acos(r) / 3
        let e1 = q + 2 * p * cos(phi)
        let e3 = q + 2 * p * cos(phi + 2 * .pi / 3)
        return [e1, 3 * q - e1 - e3, e3]
    }
}

/// The decorative chips' shapes (the renderer draws each chip as one of them, never as a body):
/// small broken stones of every shape, for the look only.
public enum QuarryChipShapes {
    /// How many shapes there are, and the vertices of each: up to 12 triangles, the hull of at
    /// most 8 points (`chipPosition` in `QuarryRender.metal` reads them so).
    public static let count = 32
    public static let vertices = 36

    /// Small broken stones of every shape: the convex hull of 5 to 8 points in an ellipsoid whose
    /// axes run from equal to slab and rod, each as unindexed triangles padded with degenerate
    /// ones. Until 12 November 2026 every chip was the same icosahedron, which stood out against
    /// the varied blocks (and cost 20 triangles where these take up to 12).
    public static func make() -> [SIMD4<Float>] {
        var r = QuarryRandom(seed: 4_021_977)
        var out: [SIMD4<Float>] = []
        out.reserveCapacity(count * vertices)
        var made = 0
        while made < count {
            // Long, middle and short axes: chunky, slabby, rod-like and flaky by turns.
            let kind = made % 4
            let b: Float = kind == 2 ? r.float(0.3, 0.5) : r.float(0.6, 1)
            let c: Float =
                kind == 1 ? r.float(0.2, 0.4) : kind == 3 ? r.float(0.18, 0.3) : r.float(0.5, 0.9) * b
            let axes = SIMD3<Float>(1, b, c)
            let n = 5 + Int(r.float() * 3.99)
            let points = (0..<n).map { _ in r.unit() * r.float(0.75, 1) * axes }
            let triangles = hull(points)
            guard triangles.count >= 4, triangles.count * 3 <= vertices else { continue }
            let centre = points.reduce(SIMD3<Float>.zero, +) / Float(n)
            for t in triangles {
                for k in [t.0, t.1, t.2] { out.append(SIMD4(points[k] - centre, 0)) }
            }
            let last = out[out.count - 1]
            for _ in 0..<(vertices - triangles.count * 3) { out.append(last) }
            made += 1
        }
        return out
    }

    /// The faces of the convex hull of a few points, outward and wound counter-clockwise, by trying
    /// every triple (no four of them coplanar, as random points are not).
    public static func hull(_ p: [SIMD3<Float>]) -> [(Int, Int, Int)] {
        var faces: [(Int, Int, Int)] = []
        for i in p.indices {
            for j in (i + 1)..<p.count {
                for k in (j + 1)..<p.count {
                    let normal = simd_cross(p[j] - p[i], p[k] - p[i])
                    guard simd_length_squared(normal) > 1e-10 else { continue }
                    var above = 0
                    var below = 0
                    for m in p.indices where m != i && m != j && m != k {
                        let side = simd_dot(normal, p[m] - p[i])
                        if side > 1e-6 { above += 1 } else if side < -1e-6 { below += 1 }
                    }
                    if above == 0 { faces.append((i, j, k)) } else if below == 0 { faces.append((i, k, j)) }
                }
            }
        }
        return faces
    }
}
