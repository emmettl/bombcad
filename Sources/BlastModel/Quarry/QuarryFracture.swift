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

    /// The offsets (along `normal`) of family `f`'s planes between `low` and `high`.
    public static func planes(_ f: Family, low: Float, high: Float) -> [(index: Int, offset: Float)] {
        let first = Int(ceil(coordinate(low, f)))
        let last = Int(floor(coordinate(high, f)))
        guard first <= last else { return [] }
        return (first...last).map { k in
            var a = low
            var b = high
            for _ in 0..<14 {
                let m = (a + b) / 2
                if coordinate(m, f) < Float(k) { a = m } else { b = m }
            }
            return (k, (a + b) / 2)
        }
    }

    private static func hash(_ a: Int, _ b: Int) -> Float {
        var h = UInt32(truncatingIfNeeded: a &* 73_856_093 ^ b &* 19_349_663)
        h ^= h >> 13
        h = h &* 0x4F37_F8A5
        h ^= h >> 16
        return Float(h & 0xFFFFFF) / Float(0xFFFFFF)
    }

    /// Cuts a cell by the planes that are present around it. `intensity` (0...1): how fractured
    /// the rock is here, from whole large blocks to fines.
    public static func fracture(_ cell: QuarryPolyhedron, intensity: Float, minimumVolume: Float)
        -> [QuarryPolyhedron]
    {
        var pieces = [cell]
        for (j, family) in families.enumerated() {
            var next: [QuarryPolyhedron] = []
            next.reserveCapacity(pieces.count * 2)
            for piece in pieces {
                var parts = [piece]
                let (low, high) = piece.extent(along: family.normal)
                let chance = family.persistence * (0.22 + 1.05 * intensity)
                let centre = piece.volumeAndCentroid.centroid
                for (k, offset) in planes(family, low: low + 0.02, high: high - 0.02) {
                    // The plane is present in patches, and more where the rock is more broken.
                    let patch = QuarryNoise.value(centre * 0.16 + SIMD3(Float(j) * 3.1, Float(k) * 1.7, 2.3))
                    let present = (patch * 0.5 + 0.5) * (0.65 + 0.7 * hash(j, k))
                    guard present < chance else { continue }
                    var split: [QuarryPolyhedron] = []
                    for part in parts {
                        let (a, b) = part.extent(along: family.normal)
                        guard offset > a + 0.02, offset < b - 0.02 else {
                            split.append(part)
                            continue
                        }
                        var below = part
                        below.clip(normal: family.normal, offset: offset, kind: 3)
                        var above = part
                        above.clip(normal: -family.normal, offset: -offset, kind: 3)
                        if below.volumeAndCentroid.volume > minimumVolume,
                            above.volumeAndCentroid.volume > minimumVolume
                        {
                            split.append(below)
                            split.append(above)
                        } else {
                            split.append(part)
                        }
                    }
                    parts = split
                }
                next.append(contentsOf: parts)
            }
            pieces = next
        }
        return pieces
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
