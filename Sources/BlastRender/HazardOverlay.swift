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
        /// A safety standard's K-factor distance (`KFactorDistance`), and the minimum safe distance.
        case kFactor = 7
        /// Where the eardrum criteria begin, and the lung's (`InjuryField`).
        case eardrum = 8
        case lung = 9
    }

    /// A circle of `radius` round `centre` on the ground, as lines of `kind`.
    public static func ring(
        centre: SIMD2<Float>, radius: Float, kind: Kind, ground: (SIMD2<Float>) -> Float = { _ in 0 },
        lift: Float = 0.3
    ) -> [SIMD4<Float>] {
        let pieces = max(48, min(Int(2 * .pi * radius / 1.5), 2_048))
        var lines: [SIMD4<Float>] = []
        let code = Float(kind.rawValue)
        func at(_ n: Int) -> SIMD2<Float> {
            let angle: Float = 2 * Float.pi * Float(n) / Float(pieces)
            return centre + radius * SIMD2<Float>(cos(angle), sin(angle))
        }
        for n in 0..<pieces {
            let p = at(n)
            let q = at(n + 1)
            lines.append(SIMD4<Float>(p.x, p.y, ground(p) + lift, code))
            lines.append(SIMD4<Float>(q.x, q.y, ground(q) + lift, 0))
        }
        return lines
    }

    /// The edges between the probes that meet `level` and those read that do not, on the ground:
    /// the injury's contour at the probes' spacing, as lines of `kind`.
    public static func contour(
        _ field: InjuryField, level: BlastInjury.Level, stance: BlastInjury.Stance = .open, kind: Kind,
        ground: (SIMD2<Float>) -> Float = { _ in 0 }, lift: Float = 0.35
    ) -> [SIMD4<Float>] {
        let levels = stance == .open ? field.open : field.againstWall
        let target = Int8(level.rawValue)
        func meets(_ i: Int, _ j: Int) -> Bool? {
            guard i >= 0, j >= 0, i < field.nx, j < field.ny else { return nil }
            let value = levels[i + field.nx * j]
            return value < 0 ? nil : value >= target
        }
        let h = field.spacingM
        func point(_ x: Float, _ y: Float) -> SIMD4<Float> {
            SIMD4(x, y, ground(SIMD2(x, y)) + lift, Float(kind.rawValue))
        }
        var lines: [SIMD4<Float>] = []
        for j in 0..<field.ny {
            for i in 0..<field.nx {
                guard let here = meets(i, j) else { continue }
                // The edge to the east and to the north, where one side meets and the other not.
                if let east = meets(i + 1, j), east != here {
                    let x = Float(i + 1) * h
                    var a = point(x, Float(j) * h)
                    var b = point(x, Float(j + 1) * h)
                    b.w = 0
                    a.w = Float(kind.rawValue)
                    lines += [a, b]
                }
                if let north = meets(i, j + 1), north != here {
                    let y = Float(j + 1) * h
                    var a = point(Float(i) * h, y)
                    var b = point(Float(i + 1) * h, y)
                    b.w = 0
                    a.w = Float(kind.rawValue)
                    lines += [a, b]
                }
            }
        }
        return lines
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
