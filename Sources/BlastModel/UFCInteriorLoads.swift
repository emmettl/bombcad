import Foundation

/// UFC 3-340-02 (2008) §2-15.4: the peak average pressure that a shock entering a building
/// through openings in its front wall puts on the inside of each wall, for a shock striking the
/// front wall head-on. An independent reference for the air that fills a vented envelope. The
/// charts are the UFC's own DPlot data (ufc_3_340_02_dplot_v2.zip, Plots/02_2xx.grf); pressures
/// in psi as the UFC gives them; `Pso` is the incident pressure at the front wall, `Ao / Aw` the
/// openings' share of the front wall, `L` the depth front to back, `H` the height, `W` the
/// front's width and `Lw` the incident wave's positive length.
public enum UFCInteriorLoads {
    /// Incident pressures (psi) at which the back-wall curves are tabulated.
    static let backWallPressures: [Double] = [2, 4, 8, 16, 32]
    /// `Ao / Aw` of the back-wall curves.
    static let backWallOpenings: [Double] = [1.0 / 8, 3.0 / 16, 1.0 / 4, 3.0 / 8, 1.0 / 2]
    /// P_RIB / Pso by L/H (1, 2, 4, 8: Figures 2-230a, 2-230b, 2-231a, 2-231b), then by
    /// `backWallOpenings`, at `backWallPressures` (each curve read at those pressures, log-linearly).
    static let backWall: [(lengthToHeight: Double, ratios: [[Double]])] = [
        (
            1,
            [
                [0.7599, 0.7677, 0.8014, 0.8901, 1.0455], [0.8883, 0.9006, 0.9453, 1.0580, 1.2204],
                [1.0491, 1.0570, 1.1290, 1.2495, 1.4491], [1.3328, 1.3515, 1.4319, 1.5994, 1.9324],
                [1.7264, 1.7803, 1.8531, 2.0966, 2.5285],
            ]
        ),
        (
            2,
            [
                [0.5419, 0.5404, 0.5536, 0.5760, 0.6315], [0.6559, 0.6575, 0.6825, 0.7151, 0.8050],
                [0.7940, 0.7917, 0.8208, 0.8702, 1.0173], [1.0608, 1.0592, 1.0894, 1.1906, 1.4208],
                [1.3917, 1.3897, 1.4343, 1.6422, 1.9634],
            ]
        ),
        (
            4,
            [
                [0.4420, 0.4407, 0.4521, 0.4663, 0.5071], [0.5811, 0.5855, 0.5991, 0.6169, 0.6990],
                [0.7262, 0.7309, 0.7570, 0.7995, 0.9307], [0.9147, 0.9374, 0.9738, 1.0448, 1.2338],
                [1.1330, 1.1594, 1.2164, 1.3490, 1.5953],
            ]
        ),
        (
            8,
            [
                [0.4204, 0.4249, 0.4333, 0.4419, 0.4788], [0.5159, 0.5175, 0.5257, 0.5516, 0.6024],
                [0.6154, 0.6215, 0.6353, 0.6624, 0.7422], [0.7465, 0.7472, 0.7855, 0.8360, 0.9602],
                [0.9080, 0.9098, 0.9495, 1.0389, 1.2003],
            ]
        ),
    ]

    /// Linear interpolation in `xs` (ascending), extrapolating from the end pairs.
    static func interpolate(_ xs: [Double], _ ys: [Double], at x: Double) -> Double {
        let i = min(max((xs.firstIndex { $0 > x } ?? xs.count) - 1, 0), xs.count - 2)
        return ys[i] + (ys[i + 1] - ys[i]) * (x - xs[i]) / (xs[i + 1] - xs[i])
    }

    /// The back wall's peak average pressure over the incident, P_RIB / Pso (§2-15.4.5): linear in
    /// `Ao / Aw` (extrapolated beyond the charts' 1/8 to 1/2), in log Pso (held at their 2 to 32
    /// psi) and in log L/H (held at 1 to 8).
    public static func backWallRatio(pressurePsi: Double, openingRatio: Double, lengthToHeight: Double)
        -> Double
    {
        let logP = log(min(max(pressurePsi, 2), 32))
        let ps = backWallPressures.map(log)
        func at(_ chart: [[Double]]) -> Double {
            interpolate(backWallOpenings, chart.map { interpolate(ps, $0, at: logP) }, at: openingRatio)
        }
        let logs = backWall.map { log($0.lengthToHeight) }
        let values = backWall.map { at($0.ratios) }
        return interpolate(logs, values, at: log(min(max(lengthToHeight, 1), 8)))
    }

    /// The side walls' (and, turned, the roof's) peak average pressure, psi (equations 2-15 to
    /// 2-21, for 3/2 ≤ W/H ≤ 6).
    public static func sideWallPsi(
        pressurePsi: Double, openingRatio: Double, wavelengthToLength: Double, widthToHeight: Double,
        lengthToHeight: Double
    ) -> Double {
        let a = 0.002 * pow(widthToHeight, 1.4467) - 0.0213
        let b = 2.2075 - 1.902 * pow(widthToHeight, -0.085)
        let c = 1.231 + 0.0008 * pow(widthToHeight, 2.678)
        let d = 2.573 * pow(lengthToHeight, -0.444) - 0.3911
        let e = 0.4221 + 1.241 * pow(openingRatio, 0.367)
        let k = (a + b * pow(wavelengthToLength, c)) * d * e * pow(pressurePsi, 1.025)
        return k / wavelengthToLength
    }

    /// Figure 2-204 (W/H = 3/2): Pmax × Lw/H (psi) at Pso = 1 and 32 psi, straight on its log
    /// axes, by Lw/H (3/8 … 12) and then Ao/Aw (1/8, 1/4, 1/2).
    static let frontWallLengths: [Double] = [3.0 / 8, 3.0 / 4, 3.0 / 2, 3, 6, 12]
    static let frontWallOpenings: [Double] = [1.0 / 8, 1.0 / 4, 1.0 / 2]
    static let frontWall: [[(atOne: Double, atThirtyTwo: Double)]] = [
        [(0.097, 3.590), (0.139, 5.145), (0.225, 8.328)],
        [(0.39, 14.44), (0.53, 19.62), (0.83, 30.72)],
        [(1.39, 51.45), (1.9, 70.33), (2.7, 99.94)],
        [(3.3, 162.9), (5.6, 207.3), (6.7, 248.0)],
        [(10.6, 392.4), (13, 481.2), (14.9, 551.5)],
        [(23.5, 869.8), (28, 1036.4), (30.7, 1136.3)],
    ]

    /// The inside of the front wall's peak average pressure, psi (§2-15.4.3, Figure 2-204, so for
    /// W/H = 3/2): log-log in Pso and Lw/H, linear in Ao/Aw.
    public static func frontWallPsi(pressurePsi: Double, openingRatio: Double, wavelengthToHeight: Double)
        -> Double
    {
        let rows = frontWall.map { row in
            let logs = row.map { pair in
                log(pair.atOne) + (log(pair.atThirtyTwo) - log(pair.atOne)) * log(pressurePsi) / log(32)
            }
            return exp(interpolate(frontWallOpenings, logs, at: openingRatio))
        }
        let scaled = exp(
            interpolate(frontWallLengths.map(log), rows.map(log), at: log(wavelengthToHeight)))
        return scaled / wavelengthToHeight
    }

    /// Figure 2-15's positive wave length of a hemispherical surface burst of TNT, Lw / W^(1/3) in
    /// m/kg^(1/3), at scaled distances in m/kg^(1/3).
    static let wavelengthTable: [(scaledDistance: Double, length: Double)] = [
        (1.5, 0.3504), (2, 0.5238), (2.5, 0.658), (3, 0.7707), (4, 0.9482), (5, 1.0815), (6, 1.1857),
        (8, 1.3401), (10, 1.4508), (12, 1.5353), (15, 1.6312), (20, 1.7421),
    ]

    /// The positive wave length (m) `range` m from `mass` kg of TNT burst on the surface.
    public static func wavelength(mass: Double, range: Double) -> Double {
        let scale = cbrt(mass)
        let z = min(max(range / scale, 1.5), 20)
        let logs = wavelengthTable.map { log($0.scaledDistance) }
        return exp(interpolate(logs, wavelengthTable.map { log($0.length) }, at: log(z))) * scale
    }
}
