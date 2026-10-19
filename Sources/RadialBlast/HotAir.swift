import Foundation

/// Hot air's own absorption of thermal radiation, as equilibrium air's: Kivel and Bailey's
/// predictions of the radiant energy it emits per unit volume (Avco Research Report 21, 1957), as
/// NASA TN D-1031 (1961, figure 6) correlates them at each temperature, E = 2α(ρ/ρ₀)^τ W/cm³, read
/// as the Planck mean absorption coefficient that emits as much, κ = E / 4σT⁴. Air at ambient density
/// absorbs 0.03/m at 3,000 K, 0.8 at 6,000 K and 3 at 8,000 K, and nearly as the density's power
/// 1.2 to 1.6, so a shock's layer of air at 8,000 K and eight times the ambient density absorbs
/// some 50/m, opaque within centimetres, where the fireball's gas at 2,500 K and a tenth of it
/// absorbs under a thousandth.
public enum HotAir {
    /// The correlation's temperatures (K), and at each its coefficient α (W/cm³, half the
    /// emission at the normal density) and the density's exponent τ.
    static let temperatures: [Double] = [1000, 3000, 6000, 8000, 12000, 18000]
    static let alphas: [Double] = [0.265e-4, 0.258, 1.231e2, 1.490e3, 1.093e5, 7.310e6]
    static let exponents: [Double] = [1.000, 1.228, 1.337, 1.288, 1.356, 1.579]
    /// The normal density the correlation's densities are reckoned from, kg/m³ (air at 0 °C and
    /// one atmosphere).
    public static let normalDensity = 1.293
    static let stefanBoltzmann = 5.670374e-8

    /// The Planck mean absorption coefficient of equilibrium air at `temperature` (K) and
    /// `density` (kg/m³), in 1/m: interpolated between the correlation's temperatures, its
    /// logarithm linearly in the temperature's and the exponent linearly; held at its ends beyond
    /// 1,000 and 18,000 K (cooler gas is never luminous here, hotter is past a chemical blast).
    public static func planckAbsorption(temperature: Float, density: Float) -> Float {
        guard temperature > 0, density > 0, temperature.isFinite, density.isFinite else { return 0 }
        let t = min(max(Double(temperature), temperatures[0]), temperatures[temperatures.count - 1])
        var n = 0
        while n < temperatures.count - 2, t > temperatures[n + 1] { n += 1 }
        let share = log(t / temperatures[n]) / log(temperatures[n + 1] / temperatures[n])
        let atNormal = { (k: Int) -> Double in
            let tk = temperatures[k]
            return log(2e6 * alphas[k] / (4 * stefanBoltzmann * tk * tk * tk * tk))
        }
        let logKappa = atNormal(n) + share * (atNormal(n + 1) - atNormal(n))
        let tau = exponents[n] + share * (exponents[n + 1] - exponents[n])
        return Float(exp(logKappa + tau * log(Double(density) / normalDensity)))
    }
}
