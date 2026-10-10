import Foundation

/// Reference results for gas deflagrations in closed vessels: the thin-flame model of a flame
/// spreading from the centre of a sphere.
public enum DeflagrationReference {
    /// The pressure history of a laminar flame spreading from the centre of a closed sphere of
    /// radius `radius`, by the thin-flame model (Lewis and von Elbe; Dahoe et al. 1996): the
    /// pressure rises in proportion to the mass burnt, p = p₀ + (p_max − p₀) x, the unburnt gas
    /// is compressed adiabatically with ratio of specific heats `gamma`, and the flame, a sphere,
    /// burns it at `burningVelocity`:
    ///
    ///   dx/dt = 3 r_f² S_u (p / p₀)^(1/γ) / R³,  r_f³ = R³ [1 − (1 − x) (p₀ / p)^(1/γ)].
    ///
    /// The flame starts at radius `start`. The linear rise is exact for one ideal gas burning to
    /// another with the same γ, as the solver's ideal gas does.
    public static func closedSphere(
        radius: Double, initialPressure p0: Double, maximumPressure pm: Double, gamma: Double,
        burningVelocity s: Double, start: Double = 0
    ) -> ClosedVesselHistory {
        let r3 = radius * radius * radius
        func flameRadius(_ x: Double) -> Double {
            let p = p0 + (pm - p0) * x
            return cbrt(max(r3 * (1 - (1 - x) * pow(p0 / p, 1 / gamma)), 0))
        }
        func rate(_ x: Double) -> Double {
            let p = p0 + (pm - p0) * x
            let rf = flameRadius(x)
            return 3 * rf * rf * s * pow(p / p0, 1 / gamma) / r3
        }
        // Start with the burnt mass of a sphere of radius `start` at the initial pressure, or a
        // small seed.
        let seed = max(start / radius, 1e-3)
        var x = seed * seed * seed
        var t = 0.0
        // Steps of a hundredth of a percent of the time the flame takes to cross at its
        // initial speed.
        let pm0 = pm / p0
        let dt = radius / (pow(pm0, 1 / gamma) * s) / 20_000
        var times = [t]
        var pressures = [p0 + (pm - p0) * x]
        var peakRate = 0.0
        while x < 1, t < 1e3 * radius / s {
            let k1 = rate(x)
            let k2 = rate(min(x + 0.5 * dt * k1, 1))
            let k3 = rate(min(x + 0.5 * dt * k2, 1))
            let k4 = rate(min(x + dt * k3, 1))
            x = min(x + dt / 6 * (k1 + 2 * k2 + 2 * k3 + k4), 1)
            t += dt
            peakRate = max(peakRate, (pm - p0) * k4)
            times.append(t)
            pressures.append(p0 + (pm - p0) * x)
        }
        return ClosedVesselHistory(times: times, pressures: pressures, peakRate: peakRate, completion: t)
    }

    /// The thin-flame model's deflagration index, (dp/dt)_max V^(1/3), when the flame reaches the
    /// wall of a sphere: (36π)^(1/3) (p_max − p₀) (p_max / p₀)^(1/γ) S_u (Dahoe et al. 1996), in
    /// Pa m/s.
    public static func deflagrationIndex(
        initialPressure p0: Double, maximumPressure pm: Double, gamma: Double, burningVelocity s: Double
    ) -> Double {
        cbrt(36 * Double.pi) * (pm - p0) * pow(pm / p0, 1 / gamma) * s
    }
}

/// The vented-explosion correlations of EN 14994 and NFPA 68, each giving the reduced
/// overpressure P_red (the peak in the enclosure) for a compact enclosure, a vent and a gas.
/// See docs/deflagration.md for their sources and ranges.
public struct VentCorrelations: Sendable {
    /// Enclosure volume (m³), internal surface area (m², vent included), vent area (m²).
    public var volume: Double
    public var surfaceArea: Double
    public var ventArea: Double
    /// Vent release overpressure, Pa (0 for an open vent), and the initial pressure, Pa.
    public var releasePressure: Double
    public var initialPressure: Double = 101_325
    public var gas: FlammableGas

    public init(
        volume: Double, surfaceArea: Double, ventArea: Double, releasePressure: Double, gas: FlammableGas,
        initialPressure: Double = 101_325
    ) {
        self.volume = volume
        self.surfaceArea = surfaceArea
        self.ventArea = ventArea
        self.releasePressure = releasePressure
        self.gas = gas
        self.initialPressure = initialPressure
    }

    /// Bartknecht's equation (EN 14994 §6 and NFPA 68 for strong enclosures, as Lautkaski 2011
    /// gives it): A = [(0.1265 log10 K_G − 0.0567) P_red^−0.5817 + 0.1754 P_red^−0.5722 (P_stat − 0.1)]
    /// V^(2/3), bar and bar m/s, P_stat taken as at least 0.1 bar. Valid for P_red from 0.1 to 2 bar
    /// (gauge), K_G 50 to 550 bar m/s, V up to 1000 m³; nil when P_red would fall outside it.
    public var bartknecht: Double? {
        let kg = gas.measuredClosedVessel.deflagrationIndex
        let stat = max(releasePressure / 1e5, 0.1)
        func area(_ p: Double) -> Double {
            ((0.1265 * log10(kg) - 0.0567) * pow(p, -0.5817) + 0.1754 * pow(p, -0.5722) * (stat - 0.1))
                * pow(volume, 2.0 / 3)
        }
        // The area falls as P_red rises; bisect in log P_red.
        var low = log(0.01)
        var high = log(5.0)
        guard area(exp(high)) < ventArea, area(exp(low)) > ventArea else { return nil }
        for _ in 0..<80 {
            let middle = 0.5 * (low + high)
            if area(exp(middle)) > ventArea { low = middle } else { high = middle }
        }
        let p = exp(0.5 * (low + high))
        return p >= 0.1 && p <= 2 ? p * 1e5 : nil
    }

    /// NFPA 68 (2002) for low-strength enclosures: A_v = C A_s / sqrt(P_red), C for the gas.
    public var nfpa68: Double {
        let ratio = gas.nfpa68Constant * surfaceArea / ventArea
        return ratio * ratio * 1e5
    }

    /// Molkov's universal correlation for vented gas deflagrations (Molkov 2001, IChemE Hazards
    /// XVI, eqs. 3–4; the low-strength method of EN 14994 is of this kind): the Bradley number
    /// Br = (A_v / V^(2/3)) c_u / (S_u (E − 1)), its turbulent form Br_t = sqrt(E / γ_u) Br /
    /// ((36π)^(1/3) χ/μ) with the deflagration–outflow interaction number χ/μ = 1.75 [(1 + 10
    /// V^(1/3)) (1 + 0.5 Br^0.5) / (1 + π_v)]^0.4 π_i^0.6, and π_red = Br_t^−2.4 (Br_t ≥ 1) or
    /// 7 − 6 Br_t^0.5. A best fit, not an envelope.
    public var molkov: Double {
        let properties = gas.ventingProperties
        let e = properties.expansionRatio
        let soundSpeed = (properties.gamma * initialPressure / 1.2).squareRoot()
        let br =
            ventArea / pow(volume, 2.0 / 3) * soundSpeed / (properties.burningVelocity * (e - 1))
        let piV = (releasePressure + initialPressure) / initialPressure
        let piI = initialPressure / 1e5
        let interaction =
            1.75 * pow((1 + 10 * cbrt(volume)) * (1 + 0.5 * br.squareRoot()) / (1 + piV), 0.4) * pow(piI, 0.6)
        let brt = (e / properties.gamma).squareRoot() * br / (cbrt(36 * Double.pi) * interaction)
        let piRed = brt >= 1 ? pow(brt, -2.4) : 7 - 6 * brt.squareRoot()
        return piRed * initialPressure
    }
}

/// A closed vessel's pressure over time, with its largest rate of rise and when it is done.
public struct ClosedVesselHistory: Sendable {
    public var times: [Double]
    public var pressures: [Double]
    /// Largest dp/dt, Pa/s.
    public var peakRate: Double
    /// When the pressure reaches its maximum, s.
    public var completion: Double
}
