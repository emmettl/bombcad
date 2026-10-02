import Foundation

/// Empirical free-air blast curve for chemical explosions from Kinney & Graham,
/// "Explosive Shocks in Air" (1985). Used only as an independent reference for validation.
public enum KinneyGraham {
    /// Peak overpressure divided by ambient pressure at scaled distance `z` (m / kg^(1/3)).
    public static func peakOverpressureRatio(scaledDistance z: Double) -> Double {
        let numerator = 808 * (1 + (z / 4.5) * (z / 4.5))
        let denominator =
            (1 + (z / 0.048) * (z / 0.048)).squareRoot()
            * (1 + (z / 0.32) * (z / 0.32)).squareRoot()
            * (1 + (z / 1.35) * (z / 1.35)).squareRoot()
        return numerator / denominator
    }

    /// Peak overpressure in pascals at `range` metres from a free-air burst of `mass` kg of TNT.
    public static func peakOverpressure(mass: Double, range: Double, ambientPressure: Double = 101_325)
        -> Double
    {
        ambientPressure * peakOverpressureRatio(scaledDistance: range / cbrt(mass))
    }

    /// Positive-phase impulse per unit area in pascal-seconds at `range` metres from a free-air
    /// burst of `mass` kg of TNT.
    public static func positiveImpulse(mass: Double, range: Double) -> Double {
        let scale = cbrt(mass)
        let z = range / scale
        let barMilliseconds =
            0.067 * (1 + pow(z / 0.23, 4)).squareRoot() / (z * z * cbrt(1 + pow(z / 1.55, 3)))
        return barMilliseconds * scale * 100
    }
}
