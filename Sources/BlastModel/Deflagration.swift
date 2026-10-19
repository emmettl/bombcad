import Foundation
import simd

/// A flammable gas that can fill part of a scene as a premixed cloud (see `Deflagration`).
///
/// The numbers are for the gas mixed with air at 1 atm and room temperature. Laminar burning
/// velocities follow Gülder's correlation, S_L = W φ^η exp(−ξ (φ − 1.075)²) (Gülder 1984, SAE
/// 841000), which gives 0.41 m/s for stoichiometric methane and 0.43 m/s for propane, against
/// NFPA 68's fundamental burning velocities of 0.40 and 0.46 m/s. Hydrogen and town gas, whose
/// curves that form cannot follow, take measured burning velocities (`burningVelocityTable`).
///
/// Town gas is the manufactured gas British homes had until the 1970s, as Cubbage and Marshall
/// (1972) give a British town gas (corrected and tabulated by Lautkaski, *Duct venting of gas
/// explosions*, VTT-R-02755-11, 2011, Table 25): H₂ 51.6%, CH₄ 31.6%, C₂H₆ 0.7%, CO 1.6%, CO₂ 1.5%,
/// O₂ 0.3%, N₂ 12.7% by volume, 11.1 g/mol. Its properties here are per mole of that mixture, inert
/// gases included; its lower heating value is the components' (H₂ 241.8, CH₄ 802.3, C₂H₆ 1428.6 and
/// CO 283.0 kJ/mol). Town gases varied with their works and decade (hydrogen 40–55%).
public enum FlammableGas: String, Sendable, Hashable, Codable, CaseIterable {
    case methane
    case propane
    case hydrogen
    case townGas

    /// Molar mass, kg/mol.
    public var molarMass: Double {
        switch self {
        case .methane: 16.043e-3
        case .propane: 44.097e-3
        case .hydrogen: 2.016e-3
        case .townGas: 11.082e-3
        }
    }

    /// Moles of oxygen one mole burns completely (CH4 + 2 O2 → CO2 + 2 H2O;
    /// C3H8 + 5 O2 → 3 CO2 + 4 H2O; H2 + ½ O2 → H2O; town gas's components in their shares, less the
    /// oxygen it carries).
    public var oxygenPerMole: Double {
        switch self {
        case .methane: 2
        case .propane: 5
        case .hydrogen: 0.5
        case .townGas: 0.9195
        }
    }

    /// Lower heating value (water as vapour), J/kg.
    public var heatOfCombustion: Double {
        switch self {
        case .methane: 50.0e6
        case .propane: 46.35e6
        case .hydrogen: 119.96e6
        case .townGas: 35.45e6
        }
    }

    /// Flammability limits in air, as volume fractions: hydrogen's 4–75% (Zabetakis, USBM Bulletin
    /// 627, 1965, Table 21), town gas's 5.0–31.5% (Lautkaski 2011, by Le Chatelier's rule; Coward and
    /// Jones, USBM Bulletin 503, 1952, measured 5.35% and 30.9% for town and coal gases).
    public var flammableRange: ClosedRange<Float> {
        switch self {
        case .methane: 0.050...0.150
        case .propane: 0.021...0.095
        case .hydrogen: 0.040...0.750
        case .townGas: 0.050...0.315
        }
    }

    /// The flame radius at which a spherical flame of the mixture at volume fraction `fraction` turns
    /// cellular, m, at 1 atm and room temperature: Bauwens, Bergthorson and Dorofeev's (2015, Table 1)
    /// measurements on flames up to 2 m across in FM Global's 64 m³ chamber, interpolated in the
    /// equivalence ratio and held at the ends of their range (φ 0.81–1.22). None for propane, whose
    /// measurements (Bauwens et al. 2015, Proceedings of the Combustion Institute 35) were not found.
    /// Lean hydrogen's, by its thermodiffusive instability, from Bauwens, Bergthorson and Dorofeev
    /// (ICHS 2015, paper 202, Table 1) in the same chamber: 18–30 mm over φ 0.33–0.57, held below
    /// it, none richer than φ 0.6 (not measured); none for town gas.
    public func criticalRadius(fraction: Float) -> Float? {
        if self == .hydrogen {
            let lean: [(phi: Float, radius: Float)] = [
                (0.33, 0.018), (0.35, 0.018), (0.37, 0.019), (0.40, 0.019), (0.42, 0.022), (0.46, 0.023),
                (0.49, 0.025), (0.51, 0.022), (0.52, 0.026), (0.54, 0.025), (0.55, 0.026), (0.57, 0.030),
            ]
            let phi = equivalenceRatio(fraction: fraction)
            guard phi <= 0.6 else { return nil }
            guard phi > lean[0].phi else { return lean[0].radius }
            for (a, b) in zip(lean, lean.dropFirst()) where phi <= b.phi {
                return a.radius + (b.radius - a.radius) * (phi - a.phi) / (b.phi - a.phi)
            }
            return lean[lean.count - 1].radius
        }
        guard self == .methane else { return nil }
        let table: [(phi: Float, radius: Float)] = [
            (0.81, 0.204), (0.83, 0.209), (0.885, 0.2135), (0.89, 0.216), (0.925, 0.2175), (0.99, 0.220),
            (1.00, 0.225), (1.04, 0.233), (1.07, 0.238), (1.12, 0.267), (1.14, 0.294), (1.17, 0.334),
            (1.19, 0.315), (1.22, 0.324),
        ]
        let phi = equivalenceRatio(fraction: fraction)
        guard phi > table[0].phi else { return table[0].radius }
        for (a, b) in zip(table, table.dropFirst()) where phi <= b.phi {
            return a.radius + (b.radius - a.radius) * (phi - a.phi) / (b.phi - a.phi)
        }
        return table[table.count - 1].radius
    }

    /// The unburnt mixture's Lewis number at volume fraction `fraction`, that of its deficient
    /// reactant, Le = α / D (α the mixture's thermal diffusivity, D the reactant's mixture-averaged
    /// diffusivity), where it is below one; nil otherwise and for a gas without one here. Hydrogen's,
    /// lean (φ ≤ 1, hydrogen deficient), from Cantera 3.1's mixture-averaged transport (its H₂/O₂
    /// mechanism, 296 K, 1 atm): 0.34 at 8%, 0.36 at 12%, 0.39 at 18%, 0.41 at 24%, 0.43
    /// stoichiometric; richer, oxygen is deficient and its Lewis number above one (1.86 at 32%).
    public func lewisNumber(fraction: Float) -> Float? {
        guard self == .hydrogen, fraction <= stoichiometricFraction + 1e-4 else { return nil }
        let table: [SIMD2<Float>] = [
            SIMD2(0.08, 0.338), SIMD2(0.10, 0.349), SIMD2(0.12, 0.360), SIMD2(0.14, 0.371),
            SIMD2(0.16, 0.380),
            SIMD2(0.18, 0.389), SIMD2(0.20, 0.397), SIMD2(0.22, 0.405), SIMD2(0.24, 0.412),
            SIMD2(0.26, 0.419),
            SIMD2(0.28, 0.424), SIMD2(0.296, 0.428),
        ]
        guard fraction > table[0].x else { return table[0].y }
        for (a, b) in zip(table, table.dropFirst()) where fraction <= b.x {
            return a.y + (b.y - a.y) * (fraction - a.x) / (b.x - a.x)
        }
        return table[table.count - 1].y
    }

    /// The unburnt mixture's Markstein number at volume fraction `fraction`, Ma = L S_L / ν (L the
    /// Markstein length relative to the unburnt gas, ν its kinematic viscosity, as Bradley uses it),
    /// where measured; nil for a gas without one here. Hydrogen's from Taylor's Markstein lengths
    /// (PhD thesis, Leeds, 1991, appendix), with his burning velocities and Cantera's viscosities at
    /// 296 K: negative (thermodiffusively unstable) leaner than φ 0.85, −4.9 at φ 0.51, +2.7
    /// stoichiometric; linear in φ between his mixtures and held at their ends.
    public func marksteinNumber(fraction: Float) -> Float? {
        guard self == .hydrogen else { return nil }
        let table: [SIMD2<Float>] = [
            SIMD2(0.23, -1.93), SIMD2(0.32, -3.22), SIMD2(0.41, -4.41), SIMD2(0.51, -4.85),
            SIMD2(0.62, -4.68),
            SIMD2(0.74, -3.09), SIMD2(0.86, 0.17), SIMD2(1.00, 2.73), SIMD2(1.15, 3.20), SIMD2(1.31, 4.74),
            SIMD2(1.49, 6.64), SIMD2(1.68, 8.73), SIMD2(1.90, 8.42), SIMD2(2.41, 9.22), SIMD2(3.45, 10.07),
            SIMD2(5.07, 15.08),
        ]
        let phi = equivalenceRatio(fraction: fraction)
        guard phi > table[0].x else { return table[0].y }
        for (a, b) in zip(table, table.dropFirst()) where phi <= b.x {
            return a.y + (phi - a.x) / (b.x - a.x) * (b.y - a.y)
        }
        return table[table.count - 1].y
    }

    /// How a cellular flame of this gas accelerates beyond its onset radius `onset` (m), where it
    /// was measured otherwise than methane's: the burning velocity growing as (r / onset)^power up
    /// to `limit` onset radii. nil takes the methane form (`DeflagrationStage.wrinklingPower` and
    /// `wrinklingLimit`). Lean hydrogen's grew as (R/R₀)^0.243 ± 0.005 over every mixture from φ
    /// 0.33 to 0.57 (Bauwens, Bergthorson and Dorofeev, ICHS 2015, paper 202), measured out to
    /// about a metre: held there.
    public func instabilityGrowth(onset: Float) -> (power: Float, limit: Float)? {
        guard self == .hydrogen, onset > 0 else { return nil }
        return (0.243, max(4, 1 / onset))
    }

    /// Measured laminar burning velocities as (equivalence ratio, m/s) points, for a gas whose
    /// curve Gülder's form cannot follow; nil for methane and propane, which take his fit.
    ///
    /// Hydrogen: S. C. Taylor's expanding spherical flames extrapolated to zero stretch (PhD
    /// thesis, Leeds, 1991, appendix p. 307; Dowdy et al. 1990), 16 of his 21 mixtures, peaking at
    /// 2.85 m/s at φ 1.68 (NACA RM E57D24 recommends 3.10 m/s at φ 1.8; the OECD/NEA's review of
    /// 18 studies, CSNI/R(2000)7, ranges 2.67–3.56).
    /// Town gas: Lautkaski's (2011, Table 38) burning velocities from Cubbage and Simmonds's vented
    /// oven flame speeds, scaled to a peak of 1.0 m/s at 25% gas in air; British sources give 0.7–1.2
    /// m/s at the peak (Rasbash, FRN 759, 1969: 1.2 m/s), and GRI-Mech 3.0 computes 0.66 m/s at
    /// 20% (its hydrogen-rich chemistry untested).
    public var burningVelocityTable: [SIMD2<Float>]? {
        switch self {
        case .methane, .propane: nil
        case .hydrogen:
            [
                SIMD2(0.23, 0.084), SIMD2(0.32, 0.188), SIMD2(0.41, 0.340), SIMD2(0.51, 0.644),
                SIMD2(0.62, 0.980), SIMD2(0.74, 1.387), SIMD2(0.86, 1.778), SIMD2(1.00, 2.130),
                SIMD2(1.15, 2.416), SIMD2(1.31, 2.624), SIMD2(1.49, 2.793), SIMD2(1.68, 2.850),
                SIMD2(1.90, 2.790), SIMD2(2.41, 2.535), SIMD2(3.45, 1.895), SIMD2(5.07, 1.098),
            ]
        case .townGas:
            [
                SIMD2(0.488, 0.09), SIMD2(0.599, 0.15), SIMD2(0.714, 0.24), SIMD2(0.836, 0.36),
                SIMD2(0.963, 0.51), SIMD2(1.097, 0.64), SIMD2(1.238, 0.80), SIMD2(1.463, 1.00),
                SIMD2(1.881, 0.70),
            ]
        }
    }

    /// Gülder's W (m/s), η and ξ.
    package var burningVelocityFit: (scale: Float, power: Float, width: Float) {
        switch self {
        case .methane: (0.422, 0.15, 5.18)
        case .propane: (0.446, 0.12, 4.95)
        case .hydrogen, .townGas: (0, 0, 0)  // tabulated instead
        }
    }

    /// The adiabatic isochoric complete combustion (AICC) pressure of the stoichiometric mixture,
    /// as a multiple of its initial pressure (from equilibrium calculations; see
    /// docs/deflagration.md; hydrogen's and town gas's from Cantera 3.1's equilibrium with GRI-Mech
    /// 3.0's thermodynamics, which gives methane 8.81 and propane 9.34). The model's heat release
    /// is set so that its gas reaches this (see `Deflagration.heatPerKilogram`).
    public var stoichiometricAICCRatio: Double {
        switch self {
        case .methane: 8.9
        case .propane: 9.4
        case .hydrogen: 8.01
        case .townGas: 8.44
        }
    }

    /// Measured maximum explosion pressure (bar gauge) and deflagration index K_G (bar m/s) in
    /// standard closed vessels, as tabulated by NFPA 68 and EN 15967. Hydrogen's K_G is the 550 of
    /// Bartknecht's era (Blanchard and Schildberg, CET 31, 2013, for one), its P_max SAFEKINEX's
    /// highest measured ratio, 7.91 (Deliverable 8, Table 16); EN 13673's K_G is about 850, and it
    /// grows with the vessel (SAFEKINEX, 500–990 bar m/s from 2.8 to 1,250 dm³). Town gas's (7.1,
    /// 140) are Bartknecht's for a 60% hydrogen, 40% methane stand-in (via Lautkaski 2011, Table 115).
    public var measuredClosedVessel: (maximumPressure: Double, deflagrationIndex: Double) {
        switch self {
        case .methane: (7.1, 55)
        case .propane: (7.9, 100)
        case .hydrogen: (6.9, 550)
        case .townGas: (7.1, 140)
        }
    }

    /// The numbers the venting correlations take for the stoichiometric mixture: NFPA 68's
    /// fundamental burning velocity (m/s, the editions before 2023), and Bradley and Mitcheson's
    /// (1978) expansion ratio and unburnt ratio of specific heats. Hydrogen's burning velocity is
    /// NACA's recommended maximum (RM E57D24, 1957), town gas's Lautkaski's peak; their expansion
    /// ratios and ratios of specific heats are Cantera's for the stoichiometric mixture.
    public var ventingProperties: (burningVelocity: Double, expansionRatio: Double, gamma: Double) {
        switch self {
        case .methane: (0.40, 7.52, 1.38)
        case .propane: (0.46, 7.98, 1.365)
        case .hydrogen: (3.10, 6.88, 1.402)
        case .townGas: (1.0, 7.21, 1.393)
        }
    }

    /// NFPA 68's (2002) venting constant for low-strength enclosures, bar^(1/2); none for a gas
    /// that burns faster than 1.3 times propane, which that edition does not cover.
    public var nfpa68Constant: Double? {
        switch self {
        case .methane: 0.037
        case .propane: 0.045
        case .hydrogen, .townGas: nil
        }
    }

    /// Fuel volume fraction of the stoichiometric mixture with air (oxygen 20.95% by volume).
    public var stoichiometricFraction: Float {
        Float(1 / (1 + oxygenPerMole / 0.2095))
    }

    /// Equivalence ratio of a mixture holding fuel volume fraction `fraction`.
    public func equivalenceRatio(fraction: Float) -> Float {
        let stoichiometric = stoichiometricFraction
        return (fraction / (1 - fraction)) / (stoichiometric / (1 - stoichiometric))
    }

    /// Laminar burning velocity of the mixture at volume fraction `fraction`, m/s; zero outside
    /// the flammable range. From `burningVelocityTable` where the gas has one (linear in the
    /// equivalence ratio between its points, held at its ends), else Gülder's fit.
    public func laminarBurningVelocity(fraction: Float) -> Float {
        guard flammableRange.contains(fraction) else { return 0 }
        let phi = equivalenceRatio(fraction: fraction)
        if let table = burningVelocityTable, let first = table.first, let last = table.last {
            if phi <= first.x { return first.y }
            for (a, b) in zip(table, table.dropFirst()) where phi <= b.x {
                return a.y + (phi - a.x) / max(b.x - a.x, 1e-6) * (b.y - a.y)
            }
            return last.y
        }
        let fit = burningVelocityFit
        return fit.scale * pow(phi, fit.power) * exp(-fit.width * (phi - 1.075) * (phi - 1.075))
    }

    /// Heat the mixture at volume fraction `fraction` releases by burning completely, per cubic
    /// metre at `pressure` and `temperature`: all of the fuel when lean, as much as the oxygen
    /// allows when rich.
    public func heatPerVolume(fraction: Float, pressure: Float, temperature: Float) -> Double {
        let moles = Double(pressure) / (8.314_46 * Double(temperature))
        let x = Double(fraction)
        let burnt = min(x, (1 - x) * 0.2095 / oxygenPerMole)
        return moles * max(burnt, 0) * molarMass * heatOfCombustion
    }

    /// Volume fraction of fuel in the mixture with the given equivalence ratio.
    public func fraction(equivalenceRatio phi: Float) -> Float {
        let stoichiometric = stoichiometricFraction
        let ratio = phi * stoichiometric / (1 - stoichiometric)
        return ratio / (1 + ratio)
    }

    public var displayName: String {
        switch self {
        case .methane: "Methane"
        case .propane: "Propane"
        case .hydrogen: "Hydrogen"
        case .townGas: "Town gas"
        }
    }
}

/// How the flame's burning velocity grows beyond the laminar value: S_T = f Ξ_r Ξ_t S_L. See
/// docs/deflagration.md for what each part stands for.
public struct FlameAcceleration: Sendable, Hashable, Codable {
    /// A constant multiple of the burning velocity: the venting literature's turbulence factor
    /// (Bradley and Mitcheson's β, Molkov's χ), for turbulence and instabilities not otherwise
    /// represented. 1 leaves it as the other parts make it.
    public var factor: Float = 1
    /// Wrinkling by the flame's own cellular (Darrieus–Landau) instability as it grows: the burning
    /// velocity rises as (r / r₀)^(1/3) beyond the critical radius r₀ from the ignition point
    /// (Gostintsev et al. 1988's self-similar regime). nil for none.
    public var instability: FlameInstability? = .measured
    /// Wrinkling by the turbulence the grid cannot resolve, Ξ_t, from the air's sub-grid mixing
    /// (see `FlameTurbulence`). nil for none.
    public var turbulence: FlameTurbulence? = FlameTurbulence()
    /// A further multiple of the burning velocity outside the cloud's region, for the external
    /// explosion: the anisotropic turbulence of the vortex a vented cloud rolls up into, which
    /// Molkov and Makarov (2004) found isotropic sub-grid models miss, and took as a factor of 2 on
    /// the flame's wrinkling outside the enclosure. nil for none.
    public var externalFactor: Float?
    /// The flame's thermodiffusive response, for a mixture whose deficient reactant diffuses faster
    /// than heat (Lewis number below one, as lean hydrogen's): its burning velocity times 1/Le
    /// (`FlammableGas.lewisNumber`), as Bauwens, Chao and Dorofeev (ICHS 2011) took 0.9/Le for lean
    /// hydrogen's vented flames. nil for none, as in files saved before 17 October 2026.
    public var thermodiffusive: ThermodiffusiveResponse? = .inverseLewis

    public init(
        factor: Float = 1, instability: FlameInstability? = .measured,
        turbulence: FlameTurbulence? = FlameTurbulence(),
        thermodiffusive: ThermodiffusiveResponse? = .inverseLewis
    ) {
        self.factor = factor
        self.instability = instability
        self.turbulence = turbulence
        self.thermodiffusive = thermodiffusive
    }

    /// A laminar flame: no factor, wrinkling, sub-grid turbulence or thermodiffusive response.
    public static let laminar = FlameAcceleration(
        factor: 1, instability: nil, turbulence: nil, thermodiffusive: nil)

    /// The burning velocity's multiple for the thermodiffusive response of a cloud of `gas` at
    /// fuel fraction `fraction`: 1/Le where the gas's Lewis number is below one, else one.
    public func thermodiffusiveFactor(gas: FlammableGas, fraction: Float) -> Float {
        guard thermodiffusive != nil, let lewis = gas.lewisNumber(fraction: fraction), lewis > 0, lewis < 1
        else {
            return 1
        }
        return 1 / lewis
    }
}

/// How a flame's burning velocity responds to its Lewis number (`FlameAcceleration.thermodiffusive`).
public enum ThermodiffusiveResponse: String, Sendable, Hashable, Codable {
    /// Times 1/Le: the leading edges of a thermodiffusively unstable flame burn faster as the
    /// deficient reactant diffuses into them ahead of the heat they lose.
    case inverseLewis
}

/// Where a flame's cellular instability sets in (see `FlameAcceleration.instability`).
public enum FlameInstability: Sendable, Hashable, Codable {
    /// At the critical radius Bauwens, Bergthorson and Dorofeev (2015) measured for the gas and
    /// mixture (`FlammableGas.criticalRadius`); none for a gas without a measurement.
    case measured
    /// At this radius, m.
    case onset(Float)

    /// The onset radius for a cloud of `gas` at fuel fraction `fraction`, m, or nil.
    public func radius(gas: FlammableGas, fraction: Float) -> Float? {
        switch self {
        case .measured: gas.criticalRadius(fraction: fraction)
        case .onset(let radius): radius > 0 ? radius : nil
        }
    }
}

/// The flame's wrinkling by sub-grid turbulence, as Bauwens, Chaffee and Dorofeev (2008, eq. 5)
/// modelled FM Global's vented chamber: Ξ_t = max(1, 1.48 a (u′/S_L)^(1/2) (Δ/δ)^(1/6)), Bradley,
/// Lau and Lawes's (1992) turbulent burning velocity scaled by a, with the grid's cell Δ as the
/// turbulence's length scale and δ = ν/S_L the laminar flame's thickness.
///
/// u′ is the air's sub-grid velocity, from the same eddy viscosity ν_t that its sub-grid mixing
/// (`SubgridMixing`) diffuses momentum, heat and the mixture with: the turbulent kinetic energy of a
/// one-equation model, k = (ν_t / (C_k Δ))² with C_k = 0.094 (Yoshizawa; Fureby et al. 1997, the
/// sub-grid model Bauwens et al. used), and u′ = √(2k/3) as OpenFOAM's XiFoam takes it. A
/// deflagration with flame turbulence therefore turns the air's sub-grid mixing on.
public struct FlameTurbulence: Sendable, Hashable, Codable {
    /// Bauwens et al.'s scaling a on Bradley's correlation: 0.7, which they fitted to the initial
    /// flame speed in FM Global's chamber; 1 is Bradley's own.
    public var scale: Float = 0.7

    public init(scale: Float = 0.7) {
        self.scale = scale
    }

    /// Bradley, Lau and Lawes's coefficient (as Bauwens et al. give it).
    public static let bradleyCoefficient: Float = 1.48
    /// The one-equation sub-grid model's C_k, relating ν_t = C_k Δ √k.
    public static let energyCoefficient: Float = 0.094
    /// The unburnt mixture's kinematic viscosity at 1 atm and room temperature, m²/s (as air's,
    /// which a methane or propane mixture's is within a few percent of); under compression it
    /// falls as the density rises.
    public static let kinematicViscosity: Float = 1.5e-5
}

/// A premixed cloud of flammable gas and air filling a box, ignited at a point: the second kind
/// of source beside a high-explosive charge.
///
/// A flame front spreads from the ignition point at the mixture's burning velocity (see
/// `FlameAcceleration`) relative to the gas, carried by the gas as it moves, and the mixture it
/// passes burns, releasing its heat (see docs/deflagration.md).
public struct Deflagration: Sendable, Hashable, Codable {
    public var gas: FlammableGas
    /// Fuel volume fraction of the mixture (0.095 is stoichiometric methane).
    public var concentration: Float
    /// The region the mixture fills; the rest of the air is air.
    public var region: Box
    public var ignition: SIMD3<Float>
    public var acceleration: FlameAcceleration

    public init(
        gas: FlammableGas = .methane, concentration: Float? = nil, region: Box, ignition: SIMD3<Float>,
        acceleration: FlameAcceleration = FlameAcceleration()
    ) {
        self.gas = gas
        self.concentration = concentration ?? gas.stoichiometricFraction
        self.region = region
        self.ignition = ignition
        self.acceleration = acceleration
    }

    public var equivalenceRatio: Float { gas.equivalenceRatio(fraction: concentration) }
    public var laminarBurningVelocity: Float { gas.laminarBurningVelocity(fraction: concentration) }

    /// The share of the mixture's heat of combustion the solver's gas must take to reach the
    /// stoichiometric mixture's AICC pressure in a closed volume, by the given gas model.
    ///
    /// The solver treats burnt and unburnt gas alike as air. Released in full, the heat of
    /// combustion would raise an ideal gas with γ = 1.4 to 13.7 bar, not the 8.9 bar that
    /// equilibrium gives for methane, whose products have larger heat capacities and partly
    /// dissociate. The share is fitted once, at stoichiometric, and applied to every
    /// concentration.
    public static func heatShare(
        gas: FlammableGas, atmosphere: Atmosphere, airModel: AirModel, gamma: Float
    ) -> Double {
        let density = atmosphere.density
        let pressure = atmosphere.pressure
        let temperature = pressure / (density * AirModel.gasConstant)
        let full = gas.heatPerVolume(
            fraction: gas.stoichiometricFraction, pressure: pressure, temperature: temperature)
        let target = Float(gas.stoichiometricAICCRatio) * pressure
        let needed =
            Double(airModel.internalEnergy(density: density, pressure: target, gamma: gamma))
            - Double(airModel.internalEnergy(density: density, pressure: pressure, gamma: gamma))
        return needed / full
    }

    /// Heat released per kilogram of the cloud's gas as it burns, J/kg, for the solver's gas model.
    public func heatPerKilogram(atmosphere: Atmosphere, airModel: AirModel, gamma: Float) -> Float {
        let temperature = atmosphere.pressure / (atmosphere.density * AirModel.gasConstant)
        let perVolume = gas.heatPerVolume(
            fraction: concentration, pressure: atmosphere.pressure, temperature: temperature)
        let share = Self.heatShare(gas: gas, atmosphere: atmosphere, airModel: airModel, gamma: gamma)
        return Float(share * perVolume / Double(atmosphere.density))
    }

    /// The model's own AICC pressure for this mixture (absolute, Pa): the pressure its gas reaches
    /// when the whole of a closed volume of it has burnt.
    public func modelAICCPressure(atmosphere: Atmosphere, airModel: AirModel, gamma: Float) -> Float {
        let energy =
            airModel.internalEnergy(density: atmosphere.density, pressure: atmosphere.pressure, gamma: gamma)
            + atmosphere.density * heatPerKilogram(atmosphere: atmosphere, airModel: airModel, gamma: gamma)
        return airModel.pressure(density: atmosphere.density, internalEnergy: energy, gamma: gamma)
    }

    /// The model's expansion ratio: the burnt gas's volume over the unburnt's, burning at constant
    /// pressure.
    public func modelExpansionRatio(atmosphere: Atmosphere, airModel: AirModel, gamma: Float) -> Float {
        let q = heatPerKilogram(atmosphere: atmosphere, airModel: airModel, gamma: gamma)
        let p = atmosphere.pressure
        // Enthalpy per kilogram h = e + p / rho; find the density at which it has risen by q.
        let h0 =
            airModel.internalEnergy(density: atmosphere.density, pressure: p, gamma: gamma)
            / atmosphere.density
            + p / atmosphere.density
        var low = atmosphere.density / 30
        var high = atmosphere.density
        for _ in 0..<60 {
            let middle = 0.5 * (low + high)
            let h = airModel.internalEnergy(density: middle, pressure: p, gamma: gamma) / middle + p / middle
            if h - h0 > q { low = middle } else { high = middle }
        }
        return atmosphere.density / (0.5 * (low + high))
    }
}

/// A panel closing an opening, held until the overpressure beside it reaches `releasePressure`,
/// when it is removed at once (it has no mass: an idealised vent cover). A panel with a release
/// pressure of zero or less is an open vent: it is never solid.
public struct VentPanel: Sendable, Hashable, Codable {
    public var box: Box
    /// Static activation overpressure (P_stat), Pa.
    public var releasePressure: Float

    public init(box: Box, releasePressure: Float) {
        self.box = box
        self.releasePressure = releasePressure
    }

    /// The area of the opening: the panel's two largest dimensions.
    public var area: Float {
        let size = box.size
        let sorted = [size.x, size.y, size.z].sorted()
        return sorted[1] * sorted[2]
    }
}
