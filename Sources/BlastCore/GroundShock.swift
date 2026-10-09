import Foundation
import simd

/// The soil under the ground points: one uniform layer, as deep as it needs to be.
public struct GroundSoil: Codable, Sendable, Equatable {
    /// Bulk density, kg/m³.
    public var density: Float = 1600
    /// The speed of a compression wave loading the soil (its seismic, or loading, wave speed), m/s.
    public var waveSpeed: Float = 300

    public init(density: Float = 1600, waveSpeed: Float = 300) {
        self.density = density
        self.waveSpeed = waveSpeed
    }

    /// The soil's acoustic impedance ρc, Pa·s/m: the stress that moves it at a metre a second.
    public var impedance: Float { density * waveSpeed }
}

/// Where to estimate the ground's shaking under the blast, and in what soil. An illustrative
/// model, not a validated one: the one-dimensional air-induced ground shock of the protective
/// design manuals, driven by the overpressure the run records on the ground.
public struct GroundShockSpec: Codable, Sendable, Equatable {
    /// Points along a straight line on the ground, ends included.
    public struct Line: Codable, Sendable, Equatable {
        public var from: SIMD2<Float>
        public var to: SIMD2<Float>
        public var count: Int

        public init(from: SIMD2<Float>, to: SIMD2<Float>, count: Int) {
            self.from = from
            self.to = to
            self.count = count
        }
    }

    public var soil = GroundSoil()
    /// Ground points, (x, y) in metres.
    public var points: [SIMD2<Float>] = []
    public var line: Line?
    /// Depths below each point at which to give the response, metres.
    public var depths: [Float] = [0, 1, 3]
    /// The overpressure, Pa, whose first passing marks the blast's arrival at a point.
    public var arrivalThreshold: Float = 1000

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case soil, points, line, depths, arrivalThreshold
    }

    /// Any field left out takes its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GroundShockSpec()
        soil = try c.decodeIfPresent(GroundSoil.self, forKey: .soil) ?? d.soil
        points = try c.decodeIfPresent([SIMD2<Float>].self, forKey: .points) ?? d.points
        line = try c.decodeIfPresent(Line.self, forKey: .line)
        depths = try c.decodeIfPresent([Float].self, forKey: .depths) ?? d.depths
        arrivalThreshold = try c.decodeIfPresent(Float.self, forKey: .arrivalThreshold) ?? d.arrivalThreshold
    }

    /// The points given, then the line's.
    public var allPoints: [SIMD2<Float>] {
        guard let line else { return points }
        return points
            + (0..<line.count).map { n in
                line.from + (line.to - line.from) * Float(n) / Float(max(line.count - 1, 1))
            }
    }

    /// Soil, points and depths a run can handle; with `domain`, points within its ground.
    public func validate(domain: SIMD3<Float>? = nil) throws {
        let all = allPoints
        func finite(_ point: SIMD2<Float>) -> Bool { point.x.isFinite && point.y.isFinite }
        guard soil.density > 0, soil.density.isFinite, soil.waveSpeed > 0, soil.waveSpeed.isFinite,
            (1...10_000).contains(all.count), all.allSatisfy(finite),
            line.map({ (2...10_000).contains($0.count) }) ?? true,
            (1...32).contains(depths.count), depths.allSatisfy({ $0 >= 0 && $0 <= 1000 }),
            arrivalThreshold > 0, arrivalThreshold.isFinite
        else {
            throw CocoaError(
                .coderInvalidValue,
                userInfo: [
                    NSLocalizedDescriptionKey: "The ground shock description is out of range or incomplete."
                ])
        }
        if let domain,
            !all.allSatisfy({ $0.x >= 0 && $0.y >= 0 && $0.x <= domain.x && $0.y <= domain.y })
        {
            throw CocoaError(
                .coderInvalidValue,
                userInfo: [NSLocalizedDescriptionKey: "A ground shock point lies outside the domain."])
        }
    }
}

/// The ground's peak response at one depth below a point.
public struct GroundResponse: Codable, Sendable, Equatable {
    public var depth: Float
    /// Peak vertical stress, Pa.
    public var stress: Float
    /// Peak vertical particle velocity, m/s, downwards.
    public var verticalVelocity: Float
    /// Peak vertical displacement, m, downwards.
    public var verticalDisplacement: Float
    /// Peak horizontal particle velocity, m/s, away from the blast; nil where the ground's wave
    /// outruns the air's, which the model does not cover.
    public var horizontalVelocity: Float?
    /// When the stress wave reaches this depth, s; nil if the blast never reached the point.
    public var arrival: Double?

    public init(
        depth: Float, stress: Float, verticalVelocity: Float, verticalDisplacement: Float,
        horizontalVelocity: Float?, arrival: Double?
    ) {
        self.depth = depth
        self.stress = stress
        self.verticalVelocity = verticalVelocity
        self.verticalDisplacement = verticalDisplacement
        self.horizontalVelocity = horizontalVelocity
        self.arrival = arrival
    }
}

/// Air-induced ground shock as the protective design manuals estimate it, away from the charge
/// where the soil is driven only by the air pressing on it. Each point is a column of soil
/// loaded by a plane wave: a compression wave runs down at the soil's wave speed c carrying the
/// surface stress, so the particles move at σ/(ρc), and the column's top sinks by the impulse
/// over ρc. Real soil gives way more on unloading than on loading, which shaves the peak as the
/// wave goes down; the manuals' factor 1/(1 + z/(c t_d)) stands in for that. Where the air's
/// front sweeps over the ground faster than c, the soil's wave trails behind it at an angle and
/// the particles also move outwards.
public enum AirInducedGroundShock {
    /// The duration, s, of the triangular pulse with the same peak and impulse: 2I/P.
    public static func duration(peak: Float, impulse: Float) -> Float {
        peak > 0 ? 2 * impulse / peak : 0
    }

    /// How much of the surface's peak stress reaches `depth` for a pulse lasting `duration`:
    /// 1/(1 + z/L), L = c t_d the pulse's length in the soil.
    public static func attenuation(depth: Float, soil: GroundSoil, duration: Float) -> Float {
        let length = soil.waveSpeed * duration
        guard depth > 0 else { return 1 }
        return length > 0 ? 1 / (1 + depth / length) : 0
    }

    /// The speed, m/s, of an air shock of `overpressure` (Pa) running into still air, by the
    /// Rankine–Hugoniot relations: c₀ √(1 + (γ+1)/(2γ) · P/p₀).
    public static func frontSpeed(
        overpressure: Float, ambientPressure: Float, ambientDensity: Float, gamma: Float
    ) -> Float {
        let sound = sqrt(gamma * ambientPressure / ambientDensity)
        return sound * sqrt(1 + (gamma + 1) / (2 * gamma) * max(overpressure, 0) / ambientPressure)
    }

    /// The response at `depth` to a surface overpressure with this peak (Pa), positive impulse
    /// (Pa·s) and arrival (s), its front sweeping over the ground at `frontSpeed` (m/s).
    public static func response(
        peak: Float, impulse: Float, arrival: Double?, depth: Float, soil: GroundSoil, frontSpeed: Float
    ) -> GroundResponse {
        guard peak > 0 else {
            return GroundResponse(
                depth: depth, stress: 0, verticalVelocity: 0, verticalDisplacement: 0,
                horizontalVelocity: 0, arrival: nil)
        }
        let alpha = attenuation(depth: depth, soil: soil, duration: duration(peak: peak, impulse: impulse))
        let stress = alpha * peak
        let vertical = stress / soil.impedance
        // Superseismic: the soil's wave front trails at θ to the ground, sin θ = c/U, and its
        // particles move square to the front.
        var horizontal: Float?
        if frontSpeed > soil.waveSpeed {
            let sine = soil.waveSpeed / frontSpeed
            horizontal = vertical * sine / sqrt(1 - sine * sine)
        }
        return GroundResponse(
            depth: depth, stress: stress, verticalVelocity: vertical,
            // An elastic column's top sinks by I/(ρc) at every depth: the unloading that shaves
            // the peak is left out here, so this is an upper value.
            verticalDisplacement: impulse / soil.impedance, horizontalVelocity: horizontal,
            arrival: arrival.map { $0 + Double(depth / soil.waveSpeed) })
    }
}
