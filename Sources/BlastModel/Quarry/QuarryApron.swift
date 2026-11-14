import Foundation
import simd

extension QuarryFace {
    /// A point of the talus apron (`footApron`): its place and normal, and how far up the apron it
    /// lies (0 at its toe on the floor, 1 where it meets the face). Layout matches `ApronVertex` in
    /// `QuarryRender.metal`.
    public struct ApronVertex: Sendable {
        public var x: Float, y: Float, z: Float
        public var nx: Float, ny: Float, nz: Float
        public var up: Float
    }

    /// The talus at a face's foot past the strip's ends (emmettl/bombcad-work#142): render-only, a
    /// continuous apron of fallen grit and stones banked against the face, its top 0.7 to 3 m up the
    /// face, wandering along it, sloping down at about the angle of repose to a lobed toe on the
    /// floor, low toward the strip's ends. Past the strip the face's rock ended at the floor in the
    /// dressing cells' points, which read as teeth (until 13 November 2026). Nothing for a ridge cut,
    /// and nothing over the strip itself, where the broken rock goes. Illustrative, for the eye: not
    /// a solid, not in the solver.
    ///
    /// Since emmettl/bombcad-work#148 its top stands at least about a metre up the face (lower, the
    /// dressing cells' lower ends overhung it in a sawtooth), dropping only over its last few metres
    /// to the strip; where it meets the face is eased along the face (the ground's own steps made a
    /// sawtooth of the line), and runs a little on into the hill under the rock; its toe's normals
    /// are the floor's, so its edge does not show on the floor.
    public func footApron(spacing: Float = 0.5) -> (vertices: [ApronVertex], indices: [UInt32]) {
        guard ridge == nil else { return ([], []) }
        let t = terrain
        // The ground as the dressing lays its rock on it: the excavated grid, the old ground past it.
        func ground(_ x: Float, _ y: Float) -> Float {
            let inside = x > t.origin.x + 1 && x < t.origin.x + Float(t.columns - 2) * t.spacing
            return inside ? height(t.heights, x, y) : oldHeight(x, y)
        }
        let rows = 14
        // Along the face where the dressing is (`buildDressing`), past each end of the strip.
        let ranges: [ClosedRange<Float>] = [(low.x - 60)...(-1), (length + 1)...620]
        var vertices: [ApronVertex] = []
        var indices: [UInt32] = []
        for range in ranges {
            let columns = Int(((range.upperBound - range.lowerBound) / spacing).rounded(.down)) + 1
            guard columns >= 2 else { continue }
            // The face's line and the talus's top and toe along it, then eased along the face.
            var floors = [Float](repeating: 0, count: columns)
            var meets = [Float](repeating: 0, count: columns)
            var tops = [Float](repeating: 0, count: columns)
            var lobes = [Float](repeating: 0, count: columns)
            for i in 0..<columns {
                let x = range.lowerBound + Float(i) * spacing
                // The face's line here: the steepest rise into the hill.
                var line: Float = 0
                var best = -Float.infinity
                var y: Float = -40
                while y <= 40 {
                    let rise = ground(x, y + 1) - ground(x, y - 1)
                    if rise > best {
                        best = rise
                        line = y
                    }
                    y += 0.5
                }
                let floor = ground(x, line - 8)
                // How high the talus stands against the face, wandering along it: at least about a
                // metre, over the dressing's lowest cells, and lower only over its last few metres to
                // the strip's ends.
                let outside = x < 0 ? -x : x - length
                let wander = QuarryNoise.fbm(SIMD3(x / 9, 3.3, 1.7), octaves: 3)
                let small = QuarryNoise.fbm(SIMD3(x / 2.6, 8.1, 0.4), octaves: 2)
                var top = 1.05 + 1.9 * smoothstep(0.25, 0.7, wander) + 0.35 * small
                top *= 0.35 + 0.65 * smoothstep(0, 4, outside)
                // Where the ground reaches the talus's top: the apron meets the face there.
                var meet = line - 8
                while meet < line + 12, ground(x, meet) < floor + top { meet += 0.05 }
                floors[i] = floor
                meets[i] = meet
                tops[i] = ground(x, meet)
                // The toe at about the angle of repose near the face (the profile's mean run is 2 a
                // metre of height), thinning out over the floor in lobes.
                lobes[i] = 0.75 + 0.6 * QuarryNoise.fbm(SIMD3(x / 4.5, 1.9, 6.2), octaves: 2)
            }
            // Eased over about two metres along the face.
            func eased(_ v: [Float]) -> [Float] {
                (0..<columns).map { i in
                    var (sum, weight): (Float, Float) = (0, 0)
                    for k in max(0, i - 4)...min(columns - 1, i + 4) {
                        let w = 1 - Float(abs(k - i)) / 5
                        sum += v[k] * w
                        weight += w
                    }
                    return sum / weight
                }
            }
            meets = eased(meets)
            tops = eased(tops)
            // One more row past the meeting line, dipping a little into the hill under the face's rock.
            let all = rows + 1
            var grid = [SIMD3<Float>](repeating: .zero, count: columns * (all + 1))
            var ups = [Float](repeating: 0, count: columns * (all + 1))
            var floorNormals = [SIMD3<Float>](repeating: SIMD3(0, 0, 1), count: columns * (all + 1))
            for i in 0..<columns {
                let x = range.lowerBound + Float(i) * spacing
                let (floor, meet, topZ) = (floors[i], meets[i], max(tops[i], floors[i] + 0.1))
                let toe = meet - (topZ - floor) * 2 * lobes[i] - 0.6
                for r in 0...all {
                    let s = Float(min(r, rows)) / Float(rows)
                    let yr = r == all ? meet + 0.4 : toe + (meet - toe) * s
                    let under = ground(x, yr)
                    // Concave, as talus is: steeper near the face, easing out to the toe, which
                    // dips just under the floor.
                    var z = floor - 0.06 + (topZ - floor + 0.06) * pow(s, 1.6)
                    z =
                        r == all
                        ? topZ - 0.15 : r == rows ? topZ : max(z, r == 0 ? under - 0.06 : under + 0.02)
                    grid[i + columns * r] = SIMD3(x, yr, z)
                    ups[i + columns * r] = s
                    let e: Float = 0.5
                    let gx = (ground(x + e, yr) - ground(x - e, yr)) / (2 * e)
                    let gy = (ground(x, yr + e) - ground(x, yr - e)) / (2 * e)
                    floorNormals[i + columns * r] = simd_normalize(SIMD3(-gx, -gy, 1))
                }
            }
            // Normals from the grid's neighbours.
            let base = UInt32(vertices.count)
            for r in 0...all {
                for i in 0..<columns {
                    let a = grid[max(i - 1, 0) + columns * r]
                    let b = grid[min(i + 1, columns - 1) + columns * r]
                    let c = grid[i + columns * max(r - 1, 0)]
                    let d = grid[i + columns * min(r + 1, all)]
                    var n = simd_cross(b - a, d - c)
                    if n.z < 0 { n = -n }
                    n = simd_length_squared(n) > 1e-12 ? simd_normalize(n) : SIMD3(0, 0, 1)
                    // Toward its toe, the floor's own normal, so it is lit as the floor is.
                    let toward = 1 - smoothstep(0.05, 0.35, ups[i + columns * r])
                    n = simd_normalize(n + (floorNormals[i + columns * r] - n) * toward)
                    let p = grid[i + columns * r]
                    vertices.append(
                        ApronVertex(
                            x: p.x, y: p.y, z: p.z, nx: n.x, ny: n.y, nz: n.z, up: ups[i + columns * r]))
                }
            }
            for r in 0..<all {
                for i in 0..<(columns - 1) {
                    let a = base + UInt32(i + columns * r)
                    let b = a + 1
                    let c = a + UInt32(columns)
                    let d = c + 1
                    indices.append(contentsOf: [a, b, d, a, d, c])
                }
            }
        }
        return (vertices, indices)
    }
}

private func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
    let t = max(0, min(1, (x - a) / (b - a)))
    return t * t * (3 - 2 * t)
}
