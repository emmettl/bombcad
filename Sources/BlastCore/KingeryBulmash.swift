import Foundation

/// Reference values of the Kingery-Bulmash blast parameters for a hemispherical surface burst of
/// TNT, the standard used in design practice (and in ConWep).
///
/// `point(at:)` evaluates the curves at any scaled distance, from Swisdak's simplified
/// polynomials. `hemisphericalSurfaceBurst` holds three worked examples tabulated independently
/// in the United Nations' International Ammunition Technical Guidelines, IATG 01.80 (3rd ed.,
/// 2021), Table 5, for 1,000, 10,000 and 100,000 kg at 50 m, reduced to scaled form by
/// cube-root scaling so that they apply to any charge mass.
public enum KingeryBulmash {
    public struct Point: Sendable {
        /// Scaled distance in m / kg^(1/3).
        public var scaledDistance: Double
        /// Peak incident (side-on) overpressure in Pa.
        public var incidentPressure: Double
        /// Positive incident impulse per kg^(1/3), in Pa s.
        public var scaledIncidentImpulse: Double
        /// Peak overpressure on a rigid wall facing the charge, in Pa.
        public var reflectedPressure: Double
        /// Positive impulse on that wall per kg^(1/3), in Pa s.
        public var scaledReflectedImpulse: Double
        /// Arrival time of the shock per kg^(1/3), in seconds.
        public var scaledArrival: Double

        /// Range in metres at which a charge of `mass` kg has this scaled distance.
        public func range(mass: Double) -> Double { scaledDistance * cbrt(mass) }

        public func incidentImpulse(mass: Double) -> Double { scaledIncidentImpulse * cbrt(mass) }

        public func reflectedImpulse(mass: Double) -> Double { scaledReflectedImpulse * cbrt(mass) }

        public func arrival(mass: Double) -> Double { scaledArrival * cbrt(mass) }
    }

    /// Builds a point from a row of the source table: mass in kg at 50 m, pressures in bar,
    /// impulses in bar ms and arrival in ms.
    private static func point(
        mass: Double, incident: Double, incidentImpulse: Double, reflected: Double, reflectedImpulse: Double,
        arrival: Double
    ) -> Point {
        let scale = cbrt(mass)
        return Point(
            scaledDistance: 50 / scale, incidentPressure: incident * 1e5,
            scaledIncidentImpulse: incidentImpulse * 100 / scale, reflectedPressure: reflected * 1e5,
            scaledReflectedImpulse: reflectedImpulse * 100 / scale, scaledArrival: arrival * 1e-3 / scale)
    }

    /// The three tabulated cases, nearest the charge first (scaled distances 1.08, 2.32 and 5).
    public static let hemisphericalSurfaceBurst: [Point] = [
        point(
            mass: 100_000, incident: 11.5, incidentImpulse: 106, reflected: 66.5, reflectedImpulse: 372,
            arrival: 24.8),
        point(
            mass: 10_000, incident: 2.02, incidentImpulse: 25.2, reflected: 6.8, reflectedImpulse: 65.5,
            arrival: 48.1),
        point(
            mass: 1_000, incident: 0.43, incidentImpulse: 5.9, reflected: 1.01, reflectedImpulse: 12.6,
            arrival: 82.4),
    ]

    // MARK: - The curves

    /// One piece of a fitted curve: the value is exp(sum of c_i (ln Z)^i) over `range` of scaled
    /// distance Z (m / kg^(1/3)).
    private struct Fit {
        var range: ClosedRange<Double>
        var coefficients: [Double]
    }

    private static func evaluate(_ fits: [Fit], at z: Double) -> Double? {
        guard let fit = fits.first(where: { $0.range.contains(z) }) else { return nil }
        let u = log(z)
        var power = 1.0
        var sum = 0.0
        for c in fit.coefficients {
            sum += c * power
            power *= u
        }
        return exp(sum)
    }

    // M. M. Swisdak, "Simplified Kingery Airblast Calculations", Naval Surface Warfare Center,
    // Proceedings of the 26th DoD Explosives Safety Seminar, 1994, Table 1 (metric): polynomial
    // fits to the 1984 Kingery-Bulmash hemispherical TNT surface-burst curves, within 1% of them
    // on average. Units as in the source: ms, kPa and kPa ms, per kg^(1/3) where scaled.
    private static let arrivalFits = [
        Fit(range: 0.06...1.50, coefficients: [-0.7604, 1.8058, 0.1257, -0.0437, -0.0310, -0.00669]),
        Fit(range: 1.50...40, coefficients: [-0.7137, 1.5732, 0.5561, -0.4213, 0.1054, -0.00929]),
    ]
    private static let incidentPressureFits = [
        Fit(range: 0.2...2.9, coefficients: [7.2106, -2.1069, -0.3229, 0.1117, 0.0685]),
        Fit(range: 2.9...23.8, coefficients: [7.5938, -3.0523, 0.40977, 0.0261, -0.01267]),
        Fit(range: 23.8...198.5, coefficients: [6.0536, -1.4066]),
    ]
    private static let reflectedPressureFits = [
        Fit(range: 0.06...2.00, coefficients: [9.006, -2.6893, -0.6295, 0.1011, 0.29255, 0.13505, 0.019736]),
        Fit(range: 2.00...40, coefficients: [8.8396, -1.733, -2.64, 2.293, -0.8232, 0.14247, -0.0099]),
    ]
    private static let durationFits = [
        Fit(range: 0.2...1.02, coefficients: [0.5426, 3.2299, -1.5931, -5.9667, -4.0815, -0.9149]),
        Fit(range: 1.02...2.80, coefficients: [0.5440, 2.7082, -9.7354, 14.3425, -9.7791, 2.8535]),
        Fit(range: 2.80...40, coefficients: [-2.4608, 7.1639, -5.6215, 2.2711, -0.44994, 0.03486]),
    ]
    private static let incidentImpulseFits = [
        Fit(range: 0.2...0.96, coefficients: [5.522, 1.117, 0.6, -0.292, -0.087]),
        Fit(range: 0.96...2.38, coefficients: [5.465, -0.308, -1.464, 1.362, -0.432]),
        Fit(range: 2.38...33.7, coefficients: [5.2749, -0.4677, -0.2499, 0.0588, -0.00554]),
        Fit(range: 33.7...158.7, coefficients: [5.9825, -1.062]),
    ]
    private static let reflectedImpulseFits = [
        Fit(range: 0.06...40, coefficients: [6.7853, -1.3466, 0.101, -0.01123])
    ]
    private static let shockVelocityFits = [
        Fit(range: 0.06...1.50, coefficients: [0.1794, -0.956, -0.0866, 0.109, 0.0699, 0.01218]),
        Fit(range: 1.50...40, coefficients: [0.2597, -1.326, 0.3767, 0.0396, -0.0351, 0.00432]),
    ]

    /// The blast parameters at scaled distance `z` (m / kg^(1/3)), from the Kingery-Bulmash
    /// curves, or nil outside the range they all cover (0.2 to 40).
    public static func point(at z: Double) -> Point? {
        guard let arrival = evaluate(arrivalFits, at: z),
            let incident = evaluate(incidentPressureFits, at: z),
            let reflected = evaluate(reflectedPressureFits, at: z),
            let incidentImpulse = evaluate(incidentImpulseFits, at: z),
            let reflectedImpulse = evaluate(reflectedImpulseFits, at: z)
        else { return nil }
        // kPa to Pa; kPa ms to Pa s needs no factor; ms to s.
        return Point(
            scaledDistance: z, incidentPressure: incident * 1000, scaledIncidentImpulse: incidentImpulse,
            reflectedPressure: reflected * 1000, scaledReflectedImpulse: reflectedImpulse,
            scaledArrival: arrival * 1e-3)
    }

    /// Positive phase duration of the incident wave per kg^(1/3), in seconds.
    public static func scaledDuration(at z: Double) -> Double? {
        evaluate(durationFits, at: z).map { $0 * 1e-3 }
    }

    /// Speed of the shock front, in m/s.
    public static func shockVelocity(at z: Double) -> Double? {
        evaluate(shockVelocityFits, at: z).map { $0 * 1000 }
    }
}
