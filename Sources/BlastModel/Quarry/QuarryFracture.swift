import Foundation
import simd

/// Procedural bedding and joints for the hillside's rock: plane families at irregular spacing,
/// each plane present only in patches, that cut Voronoi cells into slabs and wedges. Illustrative:
/// for the look of bedded, jointed rock, not a structural model of any real rock mass.
public enum QuarryFracture {
    public struct Family: Sendable {
        public var normal: SIMD3<Float>
        /// Mean spacing (m), with sinusoids in the coordinate along `normal` making it irregular.
        public var spacing: Float
        public var amplitude1: Float
        public var frequency1: Float
        public var phase1: Float
        public var amplitude2: Float
        public var frequency2: Float
        public var phase2: Float
        /// Base chance a plane cuts a given patch.
        public var persistence: Float
    }

    /// Bedding first (the same spacing the shader colours by), then two steep joint sets and a
    /// shallow shear set that makes wedges.
    public static let families: [Family] = [
        Family(
            normal: QuarryFace.beddingNormal, spacing: 1.25, amplitude1: 0.9, frequency1: 0.31, phase1: 1.2,
            amplitude2: 0.5, frequency2: 0.97, phase2: 2.7, persistence: 0.72),
        Family(
            normal: simd_normalize(SIMD3<Float>(0.97, 0.22, 0.05)), spacing: 2.9, amplitude1: 1.5,
            frequency1: 0.17,
            phase1: 0.4, amplitude2: 0.7, frequency2: 0.61, phase2: 3.1, persistence: 0.5),
        Family(
            normal: simd_normalize(SIMD3<Float>(-0.2, 0.97, 0.08)), spacing: 3.6, amplitude1: 1.6,
            frequency1: 0.13,
            phase1: 2.2, amplitude2: 0.9, frequency2: 0.47, phase2: 0.9, persistence: 0.42),
        Family(
            normal: simd_normalize(SIMD3<Float>(0.18, -0.62, 0.76)), spacing: 6.5, amplitude1: 2.6,
            frequency1: 0.09,
            phase1: 1.7, amplitude2: 1.1, frequency2: 0.33, phase2: 2.4, persistence: 0.3),
    ]

    private static func coordinate(_ s: Float, _ f: Family) -> Float {
        (s + f.amplitude1 * sin(f.frequency1 * s + f.phase1) + f.amplitude2 * sin(f.frequency2 * s + f.phase2))
            / f.spacing
    }

    /// The bedding's own coordinate at `s` along its normal: bed k lies between k and k + 1.
    public static func bedCoordinate(_ s: Float) -> Float { coordinate(s, families[0]) }

    /// Close steep joints that cut sandstone beds into elongated pieces, nearly parallel to the
    /// first steep set, and a cross set at right angles in plan that makes them blocks and
    /// columns (the cross set and the closer spacing, 1.25 to 0.9 m, from 12 November 2026).
    public static let closeJoints = Family(
        normal: simd_normalize(SIMD3<Float>(0.95, 0.3, 0.02)), spacing: 0.9, amplitude1: 0.3,
        frequency1: 0.7,
        phase1: 0.3, amplitude2: 0.15, frequency2: 1.9, phase2: 1.1, persistence: 0.8)
    public static let crossJoints = Family(
        normal: simd_normalize(SIMD3<Float>(-0.3, 0.95, 0.03)), spacing: 1.4, amplitude1: 0.3,
        frequency1: 0.7,
        phase1: 2.1, amplitude2: 0.15, frequency2: 1.9, phase2: 1.1, persistence: 0.8)

    /// The offset (along `normal`) where family `f`'s coordinate is `value`, between `low` and `high`.
    private static func offset(_ f: Family, value: Float, low: Float, high: Float) -> Float {
        var a = low
        var b = high
        for _ in 0..<14 {
            let m = (a + b) / 2
            if coordinate(m, f) < value { a = m } else { b = m }
        }
        return (a + b) / 2
    }

    /// The offsets (along `normal`) of family `f`'s planes between `low` and `high`.
    public static func planes(_ f: Family, low: Float, high: Float) -> [(index: Int, offset: Float)] {
        let first = Int(ceil(coordinate(low, f)))
        let last = Int(floor(coordinate(high, f)))
        guard first <= last else { return [] }
        return (first...last).map { k in (k, offset(f, value: Float(k), low: low, high: high)) }
    }

    private static func hash(_ a: Int, _ b: Int) -> Float {
        var h = UInt32(truncatingIfNeeded: a &* 73_856_093 ^ b &* 19_349_663)
        h ^= h >> 13
        h = h &* 0x4F37_F8A5
        h ^= h >> 16
        return Float(h & 0xFFFFFF) / Float(0xFFFFFF)
    }

    /// Cuts a cell by the planes that are present around it. `intensity` (0...1): how fractured
    /// the rock is here, from whole large blocks to fines. Each bed's kind of rock
    /// (`QuarryRock`) changes how it breaks: bedding planes between two limestone beds are mostly
    /// closed (massive rock, large blocks), shale beds split along partings into slabs, sandstone
    /// beds take close joints (elongated pieces), and joints cut each kind more or less often.
    /// `beds` false leaves out the partings and close joints, for rock that is never thrown.
    public static func fracture(
        _ cell: QuarryPolyhedron, intensity: Float, minimumVolume: Float, beds: Bool = true
    )
        -> [QuarryPolyhedron]
    {
        let scale = 0.22 + 1.05 * intensity
        func split(_ parts: [QuarryPolyhedron], normal: SIMD3<Float>, offset: Float) -> [QuarryPolyhedron] {
            var split: [QuarryPolyhedron] = []
            for part in parts {
                let (a, b) = part.extent(along: normal)
                guard offset > a + 0.02, offset < b - 0.02 else {
                    split.append(part)
                    continue
                }
                var below = part
                below.clip(normal: normal, offset: offset, kind: 3)
                var above = part
                above.clip(normal: -normal, offset: -offset, kind: 3)
                if below.volumeAndCentroid.volume > minimumVolume,
                    above.volumeAndCentroid.volume > minimumVolume
                {
                    split.append(below)
                    split.append(above)
                } else {
                    split.append(part)
                }
            }
            return split
        }
        var pieces = [cell]
        for (j, family) in families.enumerated() {
            var next: [QuarryPolyhedron] = []
            next.reserveCapacity(pieces.count * 2)
            for piece in pieces {
                var parts = [piece]
                let (low, high) = piece.extent(along: family.normal)
                let centre = piece.volumeAndCentroid.centroid
                let rock = QuarryRock.kind(at: centre)
                for (k, offset) in planes(family, low: low + 0.02, high: high - 0.02) {
                    var chance = family.persistence * scale
                    if j == 0 {
                        // A bedding plane: closed between two limestone beds, open against shale.
                        let (under, over) = (QuarryRock.kind(bed: k - 1), QuarryRock.kind(bed: k))
                        if under == .limestone && over == .limestone {
                            chance *= 0.25
                        } else if under == .shale || over == .shale {
                            chance = max(chance, 0.9)
                        }
                    } else {
                        chance *= QuarryRock.jointFactor(rock)
                    }
                    // The plane is present in patches, and more where the rock is more broken.
                    let patch = QuarryNoise.value(centre * 0.16 + SIMD3(Float(j) * 3.1, Float(k) * 1.7, 2.3))
                    let present = (patch * 0.5 + 0.5) * (0.65 + 0.7 * hash(j, k))
                    guard present < chance else { continue }
                    parts = split(parts, normal: family.normal, offset: offset)
                }
                next.append(contentsOf: parts)
            }
            pieces = next
        }
        // Partings within shale beds and close joints in sandstone ones.
        guard beds else { return pieces }
        let bedding = families[0]
        var next: [QuarryPolyhedron] = []
        next.reserveCapacity(pieces.count * 2)
        for piece in pieces {
            let centre = piece.volumeAndCentroid.centroid
            let s = simd_dot(centre, bedding.normal)
            let k = Int(floor(coordinate(s, bedding)))
            var parts = [piece]
            switch QuarryRock.kind(bed: k) {
            case .shale:
                let bottom = offset(bedding, value: Float(k), low: s - 8, high: s + 8)
                let top = offset(bedding, value: Float(k + 1), low: s - 8, high: s + 8)
                let count = max(1, Int(((top - bottom) / 0.55).rounded()))
                for i in stride(from: 1, to: count, by: 1) {
                    let jitter = (hash(17 + i, k) - 0.5) * 0.3
                    let at = bottom + (top - bottom) * (Float(i) + jitter) / Float(count)
                    let patch = QuarryNoise.value(centre * 0.3 + SIMD3(Float(i) * 2.3, Float(k) * 0.9, 7.7))
                    guard patch * 0.5 + 0.5 < 0.7 * min(1, scale + 0.3) else { continue }
                    parts = split(parts, normal: bedding.normal, offset: at)
                }
            case .sandstone:
                for (setIndex, joints) in [closeJoints, crossJoints].enumerated() {
                    let (low, high) = piece.extent(along: joints.normal)
                    let threshold = joints.persistence * min(1, scale + 0.2)
                    for (m, at) in planes(joints, low: low + 0.02, high: high - 0.02) {
                        let patch = QuarryNoise.value(
                            centre * 0.2 + SIMD3(Float(m) * 1.3, 4.1 + Float(setIndex) * 5.3, Float(k) * 0.7))
                        let present = (patch * 0.5 + 0.5) * (0.7 + 0.6 * hash(31 + setIndex * 7, m))
                        guard present < threshold else { continue }
                        parts = split(parts, normal: joints.normal, offset: at)
                    }
                }
            default: break
            }
            next.append(contentsOf: parts)
        }
        return next
    }

    /// Knocks `count` small corners off a piece, as fresh breaks: edges chipped in the throw. Only
    /// corners inside the rock, not on its weathered outer face, so the face is whole before the
    /// blast.
    public static func chipCorners(
        _ piece: inout QuarryPolyhedron, count: Int, size: Float, random: inout QuarryRandom
    ) {
        guard count > 0 else { return }
        let (volume, centroid) = piece.volumeAndCentroid
        var corners: [SIMD3<Float>] = []
        var outer: [SIMD3<Float>] = []
        for (f, polygon) in piece.faces.enumerated() {
            for v in polygon {
                if piece.kinds[f] == 1 || piece.kinds[f] == 2 { outer.append(v) }
                if !corners.contains(where: { simd_distance_squared($0, v) < 1e-4 }) { corners.append(v) }
            }
        }
        corners.removeAll { v in outer.contains { simd_distance_squared($0, v) < 1e-4 } }
        guard !corners.isEmpty else { return }
        for _ in 0..<count {
            let v = corners[Int(random.float() * Float(corners.count)) % corners.count]
            let out = v - centroid
            let reach = simd_length(out)
            guard reach > 1e-3 else { continue }
            let n = simd_normalize(out / reach + random.unit() * 0.35)
            let depth = size * random.float(0.07, 0.17)
            var chipped = piece
            chipped.clip(normal: n, offset: simd_dot(n, v) - depth, kind: 0)
            if chipped.faces.count >= 4, chipped.volumeAndCentroid.volume > 0.88 * volume { piece = chipped }
        }
    }
}

extension QuarryPolyhedron {
    public func extent(along n: SIMD3<Float>) -> (Float, Float) {
        var low = Float.infinity
        var high = -Float.infinity
        for polygon in faces {
            for v in polygon {
                let s = simd_dot(v, n)
                low = min(low, s)
                high = max(high, s)
            }
        }
        return (low, high)
    }
}
