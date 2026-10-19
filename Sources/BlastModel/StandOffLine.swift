import Foundation
import simd

/// A stand-off line: a line on the plan that keeps charges back, a fence, a row of bollards or a
/// closed car park's edge. The side it guards is the left of its direction of travel
/// (`guardsLeft`) or the right; charges belong on the other. The air never sees it: it constrains
/// where a threat may be placed (`Scenario.chargesInsideStandOff`, `stopPoint(for:)`).
public struct StandOffLine: Codable, Hashable, Sendable {
    public var name: String
    /// The line's points on the plan, m (two or more).
    public var points: [SIMD2<Float>]
    /// The guarded side is to the left of the line's direction of travel; false for the right.
    public var guardsLeft: Bool

    public init(name: String, points: [SIMD2<Float>], guardsLeft: Bool) {
        self.name = name
        self.points = points
        self.guardsLeft = guardsLeft
    }

    /// How far a charge stopped at the line stands from it, on the unguarded side, m.
    public static let stopClearance: Float = 1

    /// The nearest point of the line to `p`, and the segment it lies on.
    func nearest(_ p: SIMD2<Float>) -> (point: SIMD2<Float>, segment: Int, distance: Float) {
        var best = (point: points[0], segment: 0, distance: Float.infinity)
        for n in 0..<(points.count - 1) {
            let a = points[n]
            let b = points[n + 1]
            let ab = b - a
            let length2 = simd_length_squared(ab)
            let t = length2 > 0 ? simd_clamp(simd_dot(p - a, ab) / length2, 0, 1) : 0
            let q = a + t * ab
            let d = simd_distance(p, q)
            if d < best.distance { best = (q, n, d) }
        }
        return best
    }

    /// The distance from `p` to the line, m.
    public func distance(to p: SIMD2<Float>) -> Float { nearest(p).distance }

    /// The guarded side's direction at segment `n`: its left or right normal.
    func guardedNormal(_ n: Int) -> SIMD2<Float> {
        let d = simd_normalize(points[n + 1] - points[n])
        let left = SIMD2(-d.y, d.x)
        return guardsLeft ? left : -left
    }

    /// Whether `p` lies on the guarded side, by the nearest segment (its ends' lines extended past
    /// the line's ends).
    public func guards(_ p: SIMD2<Float>) -> Bool {
        guard points.count >= 2 else { return false }
        let near = nearest(p)
        let n = near.segment
        let a = points[n]
        return simd_dot(p - a, guardedNormal(n)) > 0
    }

    /// Where a charge at `p` stops: for a place the line guards, the nearest point on the line
    /// moved `stopClearance` to the unguarded side; anywhere else, `p` itself.
    public func stopPoint(for p: SIMD2<Float>) -> SIMD2<Float> {
        guard guards(p) else { return p }
        let near = nearest(p)
        return near.point - Self.stopClearance * guardedNormal(near.segment)
    }

    public func validate() throws {
        guard points.count >= 2, points.allSatisfy({ all($0 .== $0) && $0.x.isFinite && $0.y.isFinite }),
            zip(points, points.dropFirst()).allSatisfy({ simd_distance($0, $1) > 0 })
        else {
            throw ImportedMesh.ImportError.invalid("A stand-off line needs two or more distinct points.")
        }
    }
}
