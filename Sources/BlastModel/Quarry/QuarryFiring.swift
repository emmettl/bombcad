import Foundation
import simd

/// A row of firings, stylised for the eye: even along the face, staggered in time so a ripple runs
/// along it. No charge masses or designs of any kind; each firing only imparts a velocity by the
/// scaled law in `QuarryLaunch`. This is a picture, not a blast-design aid: it says nothing about real
/// fragmentation, flyrock reach or safe distances.
public struct QuarryFiring: Sendable {
    public var position: SIMD3<Float>
    public var time: Float

    public init(position: SIMD3<Float>, time: Float) {
        self.position = position
        self.time = time
    }
}

/// The order the ripple runs along the row. Stylised, for the eye.
public enum QuarryFiringOrder: String, CaseIterable, Sendable {
    case leftToRight = "Left to right"
    case rightToLeft = "Right to left"
    case centreOut = "Centre out"
    case edgesIn = "Edges in"
    case scattered = "Scattered"
}

public enum QuarryFiringPattern {
    public static func row(
        face hillside: QuarryFace, count: Int = 16, first: Float = 1.8, stagger: Float = 0.1,
        order: QuarryFiringOrder = .leftToRight
    ) -> [QuarryFiring] {
        let length = hillside.length
        // Each firing's place in the order (0 first), by the distance that matters to that order.
        let positions = (0..<count).map { Float($0) - Float(max(count - 1, 1)) * 0.5 }
        var ranked: [Int]
        switch order {
        case .leftToRight: ranked = Array(0..<count)
        case .rightToLeft: ranked = Array((0..<count).reversed())
        case .centreOut: ranked = (0..<count).sorted { abs(positions[$0]) < abs(positions[$1]) }
        case .edgesIn: ranked = (0..<count).sorted { abs(positions[$0]) > abs(positions[$1]) }
        case .scattered:
            var r = QuarryRandom(seed: 41)
            ranked = (0..<count).map { ($0, r.float()) }.sorted { $0.1 < $1.1 }.map(\.0)
        }
        var rank = [Int](repeating: 0, count: count)
        for (place, firing) in ranked.enumerated() { rank[firing] = place }
        return (0..<count).map { n in
            let x = 12 + (length - 24) * Float(n) / Float(max(count - 1, 1))
            let y = hillside.faceLine(x) + hillside.depth * 0.45
            let floor = hillside.floorHeight(x)
            let z = floor + (hillside.height(hillside.original, x, y) - floor) * 0.55
            return QuarryFiring(position: SIMD3(x, y, z), time: first + stagger * Float(rank[n]))
        }
    }
}

/// Per-block launch state from the firings: when it lets go and how fast.
public struct QuarryLaunch: Sendable {
    /// Scaled law, stated: the speed at distance r from the nearest firing is
    /// `speed0 (r0 / max(r, r0))^exponent`; illustrative, chosen by eye.
    public var speed0: Float = 15
    public var r0: Float = 3
    public var exponent: Float = 1.0
    /// The face swells before it lets go, coherently and by eye: a smooth drift out and up over
    /// `rise` seconds, up to `swellAmplitude` metres near a firing, fading with distance.
    public var rise: Float = 0.8
    public var swellAmplitude: Float = 3.4
    public var swellReach: Float = 20
    /// Share of a block's launch that is up.
    public var lift: Float = 0.55
    /// Speed of the break through the rock, for each block's release (m/s). Visual only.
    public var front: Float = 200

    public init() {}

    public func apply(to blocks: inout [QuarryFace.Block], firings: [QuarryFiring], face hillside: QuarryFace)
        -> (
            fire: [Float], velocity: [SIMD3<Float>], spin: [SIMD3<Float>], swell: [SIMD4<Float>]
        )
    {
        var random = QuarryRandom(seed: 77)
        var fire = [Float](repeating: 0, count: blocks.count)
        var velocity = [SIMD3<Float>](repeating: .zero, count: blocks.count)
        var spin = velocity
        var swell = [SIMD4<Float>](repeating: .zero, count: blocks.count)
        for (n, block) in blocks.enumerated() {
            let c = block.centre
            var best: Float = .infinity
            var nearest = firings[0]
            for firing in firings {
                let d = simd_distance_squared(c, firing.position)
                if d < best {
                    best = d
                    nearest = firing
                }
            }
            let r = sqrt(best)
            // The last skin of blocks against the new face stays put, so the face is left rough.
            let across =
                c.y - hillside.faceLine(c.x) - hillside.depth
                * QuarryFace.mask(c.x, length: hillside.length)
            // The strip's end is ragged: the last blocks to hold back come and go along it.
            let raggedness = QuarryNoise.fbm(c * SIMD3<Float>(0.05, 0.05, 0.03) + 19, octaves: 3)
            let unbroken =
                hillside.height(hillside.original, c.x, c.y)
                - hillside.height(hillside.terrain.heights, c.x, c.y)
                < 0.3
            if block.skin || unbroken || across > -2.6 + 9 * raggedness {
                fire[n] = .greatestFiniteMagnitude
                velocity[n] = .zero
                spin[n] = .zero
                continue
            }
            let speed = speed0 * pow(r0 / max(r, r0), exponent)
            let radial = simd_normalize(c - nearest.position + SIMD3<Float>(0, 0, 0.5))
            let outward = SIMD3<Float>(0, -1, 0)
            var direction = simd_normalize(0.55 * radial + 0.45 * outward)
            direction.z += lift * (0.6 + 0.4 * random.float())
            direction = simd_normalize(direction + 0.18 * random.unit())
            fire[n] = nearest.time + r / front
            // Coherent: no jitter, so the face rises as a whole before it opens.
            let reach = r / swellReach
            let amplitude = swellAmplitude * exp(-reach * reach) + 0.2
            let thisRise = rise + 0.45 * min(1, r / 25)
            let swellDirection = simd_normalize(0.6 * outward + SIMD3<Float>(0, 0, 0.55) + 0.25 * radial)
            swell[n] = SIMD4(swellDirection * amplitude / (0.5 * thisRise), thisRise)
            velocity[n] = direction * max(0.25, speed * random.float(0.7, 1.2))
            spin[n] =
                random.unit()
                * min(9, simd_length(velocity[n]) * random.float(0.3, 1.5) / max(block.size, 0.3))
        }
        return (fire, velocity, spin, swell)
    }
}
