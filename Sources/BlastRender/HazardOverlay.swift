import BlastCore
import Foundation
import simd

/// The hazardous fragment distance drawn on the ground round the charge, as lines for
/// `SceneRenderer.setLines`.
public enum HazardOverlay {
    public enum Kind: Int, Sendable {
        /// A circle at the hazard distance, the largest of the directions'.
        case distance = 5
        /// Each direction's own distance, an arc across its sector.
        case sector = 6
    }

    /// Lines a little above the ground, whose height under a point `ground` gives.
    public static func lines(
        _ hazard: GroundHazard, ground: (SIMD2<Float>) -> Float = { _ in 0 }, lift: Float = 0.3
    ) -> [SIMD4<Float>] {
        guard let distance = hazard.hazardDistance else { return [] }
        func point(_ radius: Float, _ angle: Float) -> SIMD3<Float> {
            let xy = hazard.centre + radius * SIMD2(cos(angle), sin(angle))
            return SIMD3(xy, ground(xy) + lift)
        }
        func arc(_ radius: Float, from start: Float, to end: Float, kind: Kind) -> [SIMD4<Float>] {
            // Segments of about 3°, and at most a metre and a half on a large circle.
            let pieces = max(2, Int(((end - start) * max(radius / 1.5, 19)).rounded(.up)))
            var lines: [SIMD4<Float>] = []
            for n in 0..<pieces {
                let a = start + (end - start) * Float(n) / Float(pieces)
                let b = start + (end - start) * Float(n + 1) / Float(pieces)
                lines += [SIMD4(point(radius, a), Float(kind.rawValue)), SIMD4(point(radius, b), 0)]
            }
            return lines
        }
        var lines = arc(distance, from: 0, to: 2 * .pi, kind: .distance)
        let width = 2 * Float.pi / Float(hazard.sectors)
        for (sector, reach) in hazard.sectorDistances.enumerated() {
            guard let reach, reach < distance else { continue }
            let centre = Float(sector) * width
            lines += arc(reach, from: centre - width / 2, to: centre + width / 2, kind: .sector)
        }
        return lines
    }
}
