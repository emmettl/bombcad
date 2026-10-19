import Foundation

/// Reference curves from UFC 3-340-02, *Structures to Resist the Effects of Accidental
/// Explosions* (US Department of Defense, 2008).
public enum UFC340 {
    /// Figure 2-152: peak gas pressure from a TNT detonation in a partially contained chamber
    /// (vent area up to 0.022 V^(2/3)), an experimental fit, read off the chart (W/V in lb/ft³,
    /// pressure in psi; the reading is good to about 10%).
    private static let gasPressureChart: [(chargePerVolume: Double, pressure: Double)] = [
        (0.001, 17), (0.002, 27), (0.005, 50), (0.01, 85), (0.02, 160), (0.03, 210), (0.05, 270), (0.1, 430),
        (0.2, 720), (0.5, 1450), (1, 2500), (2, 4500), (4, 8000),
    ]

    /// Peak gas (quasi-static) overpressure in pascals for `chargePerVolume` kg of TNT per cubic
    /// metre of free volume, or nil outside the chart (0.016 to 64 kg/m³).
    public static func peakGasPressure(chargePerVolume: Double) -> Double? {
        let poundsPerCubicFoot = chargePerVolume / 16.0185
        let chart = gasPressureChart
        guard let first = chart.first, let last = chart.last,
            poundsPerCubicFoot >= first.chargePerVolume, poundsPerCubicFoot <= last.chargePerVolume
        else { return nil }
        for (a, b) in zip(chart, chart.dropFirst()) where poundsPerCubicFoot <= b.chargePerVolume {
            // Straight lines on the chart's log-log axes.
            let t = log(poundsPerCubicFoot / a.chargePerVolume) / log(b.chargePerVolume / a.chargePerVolume)
            return exp(log(a.pressure) + t * log(b.pressure / a.pressure)) * 6894.76
        }
        return nil
    }
}
