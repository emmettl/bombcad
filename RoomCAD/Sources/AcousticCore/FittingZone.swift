import Foundation
import simd

/// A box of the room filled with objects that scatter sound: chairs, pews, desks, pillars, ornament
/// or hanging lights, too many or too small to model as surfaces. After Ondet and Barbry (1989), the
/// objects are described statistically, by how often sound meets one and how much it loses when it
/// does.
///
/// Within the zone, sound travelling `d` metres meets an object with probability `1 - exp(-q d)`,
/// where `q` is the `density`, the same in every band: the objects are taken to be large beside the
/// wavelength, which holds above the wave solver's crossover for most furniture. For objects scattered
/// at random, `q` is their total surface area over four times the zone's volume, since a convex
/// object's mean cross-section over all directions is a quarter of its surface (Cauchy's formula).
/// At an object a fraction `absorption` of the energy is lost, and the rest scatters equally in every
/// direction.
///
/// The image sources keep only the energy that crosses the zones without meeting an object, and the
/// rays carry the rest. The zones add `4 q α V` of absorption area, like air, to the statistical
/// estimates, and so to the wave solver's decay.
public struct FittingZone: Codable, Equatable, Sendable {
    public var name: String
    /// Opposite corners of the zone, in the room's coordinates.
    public var low: SIMD3<Double>
    public var high: SIMD3<Double>
    /// Objects met per metre travelled.
    public var density: Double
    /// Fraction of the energy lost at each object, per octave band.
    public var absorption: [Double]
    /// Where the values come from.
    public var reference: String

    public init(
        name: String, low: SIMD3<Double>, high: SIMD3<Double>, density: Double, absorption: [Double],
        reference: String = ""
    ) {
        self.name = name
        self.low = low
        self.high = high
        self.density = density
        self.absorption = absorption
        self.reference = reference
    }

    /// A zone holding `count` objects, each with surface area `area` in square metres, that lose
    /// `absorption` of the energy at each encounter.
    public static func objects(
        _ name: String, low: SIMD3<Double>, high: SIMD3<Double>, count: Double, area: Double,
        absorption: [Double], reference: String = ""
    ) -> FittingZone {
        let volume = (high - low).x * (high - low).y * (high - low).z
        return FittingZone(
            name: name, low: low, high: high, density: count * area / (4 * volume), absorption: absorption,
            reference: reference)
    }

    public var volume: Double {
        let size = high - low
        return size.x * size.y * size.z
    }

    /// Absorption area the zone adds in each band, in square metres: `4 q α V`.
    public var absorptionArea: [Double] {
        absorption.map { 4 * density * $0 * volume }
    }

    func validate() throws {
        guard [low, high].allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }), all(low .< high)
        else {
            throw AcousticError.invalid(
                "The fitted zone \(name)'s corners must be finite, its low corner below its high one.")
        }
        guard absorption.count == OctaveBands.count else {
            throw AcousticError.invalid("The fitted zone \(name) needs an absorption in every band.")
        }
        guard density.isFinite, density >= 0, density <= 50 else {
            throw AcousticError.invalid(
                "The fitted zone \(name)'s density must be between 0 and 50 per metre.")
        }
        guard absorption.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else {
            throw AcousticError.invalid("The fitted zone \(name)'s absorption must be between 0 and 1.")
        }
    }

    /// The part of the segment `origin + t direction`, `t` in `[0, limit]`, inside the zone, if any.
    func overlap(origin: SIMD3<Double>, direction: SIMD3<Double>, limit: Double) -> ClosedRange<Double>? {
        var enter = 0.0
        var leave = limit
        for a in 0..<3 {
            if direction[a] == 0 {
                guard origin[a] >= low[a], origin[a] <= high[a] else { return nil }
                continue
            }
            var t0 = (low[a] - origin[a]) / direction[a]
            var t1 = (high[a] - origin[a]) / direction[a]
            if t0 > t1 { swap(&t0, &t1) }
            enter = max(enter, t0)
            leave = min(leave, t1)
            if enter >= leave { return nil }
        }
        return enter...leave
    }
}

extension [FittingZone] {
    /// The optical depth, `∫ q dl`, along the straight segment from `a` to `b`.
    func depth(from a: SIMD3<Double>, to b: SIMD3<Double>) -> Double {
        let offset = b - a
        let length = simd_length(offset)
        guard length > 0 else { return 0 }
        let direction = offset / length
        var depth = 0.0
        for zone in self {
            guard let inside = zone.overlap(origin: a, direction: direction, limit: length) else { continue }
            depth += zone.density * (inside.upperBound - inside.lowerBound)
        }
        return depth
    }

    /// The optical depth along a path through the given points.
    func depth(along points: [SIMD3<Double>]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + depth(from: $1.0, to: $1.1) }
    }

    /// Where along a ray, within `limit`, it first meets an object, given the optical depth `budget`
    /// it may cross (an exponential random number). Nil if it crosses the zones within `limit` without
    /// meeting one.
    func encounter(
        origin: SIMD3<Double>, direction: SIMD3<Double>, limit: Double, budget: Double
    ) -> (distance: Double, zone: Int)? {
        // Zones are few, so take their crossings in order by picking the next nearest each time,
        // without sorting into a new array.
        // Zones do not overlap, so their crossings follow one another. They are ordered by where they
        // start, then by zone, so a zone that only touches another still counts.
        var remaining = budget
        var after = (-Double.infinity, -1)
        while true {
            var next: (range: ClosedRange<Double>, zone: Int)?
            for (index, zone) in enumerated() where zone.density > 0 {
                guard let inside = zone.overlap(origin: origin, direction: direction, limit: limit),
                    (inside.lowerBound, index) > after,
                    next.map({ (inside.lowerBound, index) < ($0.range.lowerBound, $0.zone) }) ?? true
                else { continue }
                next = (inside, index)
            }
            guard let (range, index) = next else { return nil }
            let q = self[index].density
            let depth = q * (range.upperBound - range.lowerBound)
            if depth >= remaining { return (range.lowerBound + remaining / q, index) }
            remaining -= depth
            after = (range.lowerBound, index)
        }
    }
}

/// A room's image-source path, unfolded into a straight line, folded back into the room along one
/// axis of length `length`: the coordinate at unfolded position `u`.
func fold(_ u: Double, length: Double) -> Double {
    let period = 2 * length
    var m = u.truncatingRemainder(dividingBy: period)
    if m < 0 { m += period }
    return m > length ? period - m : m
}

/// Parameters in (0, 1) where the unfolded coordinate `from + t (to - from)` crosses a multiple of
/// `length`, where the folded path turns.
func foldBreaks(from: Double, to: Double, length: Double, into breaks: inout [Double]) {
    guard from != to else { return }
    let a = min(from, to) / length
    let b = max(from, to) / length
    var k = a.rounded(.down) + 1
    while k < b {
        breaks.append((k * length - from) / (to - from))
        k += 1
    }
}
