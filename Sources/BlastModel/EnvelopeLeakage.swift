import Foundation

/// UFC 3-340-02 (2008) §2-15.5's filling pressure, an independent reference for
/// `EnvelopeDamageAssessment.fill`: the mean pressure inside a structure rises as
/// δPi = CL (Ao / Vo) δt (equation 2-31), with the leakage pressure coefficient CL read from
/// Figure 2-235 on the difference P − Pi across the openings (taken negative when it is), for
/// small area-volume ratios and applied pressures under 150 psi.
extension EnvelopeDamageAssessment {
    /// Figure 2-235, CL (psi ft/ms) at P − Pi = 0, 1.25, 2.5 … 125 psi: the curve behind the
    /// figure as the UFC's own DPlot data hold it (ufc_3_340_02_dplot_v2.zip, Plots/02_235.grf).
    static let leakageCoefficientPsiFtPerMs: [Double] = [
        0, 3.625, 6.759, 9.449, 11.78, 13.83, 15.66, 17.30, 18.80, 20.18,
        21.47, 22.69, 23.84, 24.94, 25.99, 27.01, 27.99, 28.93, 29.85, 30.74,
        31.60, 32.44, 33.25, 34.05, 34.82, 35.57, 36.31, 37.04, 37.75, 38.45,
        39.14, 39.83, 40.50, 41.17, 41.84, 42.50, 43.16, 43.81, 44.47, 45.12,
        45.77, 46.41, 47.05, 47.69, 48.33, 48.96, 49.59, 50.21, 50.83, 51.44,
        52.05, 52.65, 53.24, 53.83, 54.42, 55.00, 55.57, 56.14, 56.71, 57.27,
        57.83, 58.39, 58.95, 59.51, 60.06, 60.62, 61.17, 61.73, 62.28, 62.84,
        63.40, 63.95, 64.51, 65.06, 65.61, 66.15, 66.70, 67.24, 67.77, 68.30,
        68.82, 69.34, 69.86, 70.37, 70.88, 71.39, 71.90, 72.42, 72.94, 73.47,
        74.01, 74.57, 75.14, 75.72, 76.32, 76.91, 77.51, 78.08, 78.61, 79.07,
        79.43,
    ]

    static let psi = 6_894.757

    /// CL in Pa m/s at a difference of `difference` Pa, signed as it is; held at the figure's end
    /// past 125 psi.
    public static func leakageCoefficient(difference: Double) -> Double {
        let table = leakageCoefficientPsiFtPerMs
        let x = min(abs(difference) / psi / 1.25, Double(table.count - 1))
        let low = min(Int(x), table.count - 2)
        let value = table[low] + (table[low + 1] - table[low]) * (x - Double(low))
        // psi ft/ms to Pa m/s.
        return (difference < 0 ? -1 : 1) * value * psi * 0.3048 * 1_000
    }

    /// The inside overpressure of a room of `volume` m³ filled through `openings` as
    /// `fill(volume:openings:bin:)` takes them, by equation 2-31 instead of an orifice: peak (Pa)
    /// and positive impulse (Pa s), in the same 20 steps a bin.
    public static func leakageFill(
        volume: Double, openings: [(area: Double, opens: Double, outer: [Double])], bin: Double
    )
        -> (peak: Double, impulse: Double)
    {
        guard volume > 0 else { return (0, 0) }
        let count = openings.map(\.outer.count).max() ?? 0
        var inside = 0.0
        var peak = 0.0
        var impulse = 0.0
        let substeps = 20
        let h = bin / Double(substeps)
        for index in 0..<count {
            for sub in 0..<substeps {
                let time = Double(index) * bin + Double(sub) * h
                var rise = 0.0
                for opening in openings where time >= opening.opens && index < opening.outer.count {
                    rise +=
                        leakageCoefficient(difference: opening.outer[index] - inside) * opening.area / volume
                }
                inside += rise * h
                peak = max(peak, inside)
                impulse += max(inside, 0) * h
            }
        }
        return (peak, impulse)
    }
}
