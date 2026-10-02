import Foundation

/// Reference values of the Kingery-Bulmash blast parameters for a hemispherical surface burst of
/// TNT, the standard used in design practice (and in ConWep).
///
/// The polynomials themselves are not reproduced here. These are the worked examples tabulated
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
}
