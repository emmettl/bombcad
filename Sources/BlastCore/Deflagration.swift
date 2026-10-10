import Foundation
import simd

/// A flammable gas that can fill part of a scene as a premixed cloud (see `Deflagration`).
///
/// The numbers are for the gas mixed with air at 1 atm and room temperature. Laminar burning
/// velocities follow Gülder's correlation, S_L = W φ^η exp(−ξ (φ − 1.075)²) (Gülder 1984, SAE
/// 841000), which gives 0.41 m/s for stoichiometric methane and 0.43 m/s for propane, against
/// NFPA 68's fundamental burning velocities of 0.40 and 0.46 m/s.
public enum FlammableGas: String, Sendable, Hashable, Codable, CaseIterable {
    case methane
    case propane

    /// Molar mass, kg/mol.
    public var molarMass: Double {
        switch self {
        case .methane: 16.043e-3
        case .propane: 44.097e-3
        }
    }

    /// Moles of oxygen one mole burns completely (CH4 + 2 O2 → CO2 + 2 H2O;
    /// C3H8 + 5 O2 → 3 CO2 + 4 H2O).
    public var oxygenPerMole: Double {
        switch self {
        case .methane: 2
        case .propane: 5
        }
    }

    /// Lower heating value (water as vapour), J/kg.
    public var heatOfCombustion: Double {
        switch self {
        case .methane: 50.0e6
        case .propane: 46.35e6
        }
    }

    /// Flammability limits in air, as volume fractions.
    public var flammableRange: ClosedRange<Float> {
        switch self {
        case .methane: 0.050...0.150
        case .propane: 0.021...0.095
        }
    }

    /// Gülder's W (m/s), η and ξ.
    var burningVelocityFit: (scale: Float, power: Float, width: Float) {
        switch self {
        case .methane: (0.422, 0.15, 5.18)
        case .propane: (0.446, 0.12, 4.95)
        }
    }

    /// The adiabatic isochoric complete combustion (AICC) pressure of the stoichiometric mixture,
    /// as a multiple of its initial pressure (from equilibrium calculations; see
    /// docs/deflagration.md). The model's heat release is set so that its gas reaches this
    /// (see `Deflagration.heatPerKilogram`).
    public var stoichiometricAICCRatio: Double {
        switch self {
        case .methane: 8.9
        case .propane: 9.4
        }
    }

    /// Measured maximum explosion pressure (bar gauge) and deflagration index K_G (bar m/s) in
    /// standard closed vessels, as tabulated by NFPA 68 and EN 15967.
    public var measuredClosedVessel: (maximumPressure: Double, deflagrationIndex: Double) {
        switch self {
        case .methane: (7.1, 55)
        case .propane: (7.9, 100)
        }
    }

    /// The numbers the venting correlations take for the stoichiometric mixture: NFPA 68's
    /// fundamental burning velocity (m/s, the editions before 2023), and Bradley and Mitcheson's
    /// (1978) expansion ratio and unburnt ratio of specific heats.
    public var ventingProperties: (burningVelocity: Double, expansionRatio: Double, gamma: Double) {
        switch self {
        case .methane: (0.40, 7.52, 1.38)
        case .propane: (0.46, 7.98, 1.365)
        }
    }

    /// NFPA 68's (2002) venting constant for low-strength enclosures, bar^(1/2).
    public var nfpa68Constant: Double {
        switch self {
        case .methane: 0.037
        case .propane: 0.045
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
    /// the flammable range.
    public func laminarBurningVelocity(fraction: Float) -> Float {
        guard flammableRange.contains(fraction) else { return 0 }
        let phi = equivalenceRatio(fraction: fraction)
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
        }
    }
}

/// How the flame's burning velocity grows beyond the laminar value. None of this is resolved
/// by the grid; see docs/deflagration.md for what each part stands for.
public struct FlameAcceleration: Sendable, Hashable, Codable {
    /// A constant multiple of the burning velocity: the venting literature's turbulence factor
    /// (Bradley and Mitcheson's β, Molkov's χ), for turbulence and instabilities not otherwise
    /// represented. 1 leaves it laminar.
    public var factor: Float = 1
    /// Wrinkling by the flame's own instabilities as it grows: the burning velocity rises as
    /// (r / r₀)^(1/3) beyond `wrinklingRadius` from the ignition point (Gostintsev et al. 1988's
    /// self-similar regime, as used by Molkov's fractal model). nil for none.
    public var wrinklingRadius: Float? = 1
    /// Turbulence the grid cannot resolve, estimated from the resolved flow's vorticity: u′ =
    /// C Δ |ω|, adding u′ to the burning velocity (Peters' corrugated-flamelet limit, S_T − S_L ≈
    /// b₃ u′ with b₃ = 1). nil for none. Shear behind obstacles and through openings raises it.
    public var subgridCoefficient: Float? = 0.2

    public init(factor: Float = 1, wrinklingRadius: Float? = 1, subgridCoefficient: Float? = 0.2) {
        self.factor = factor
        self.wrinklingRadius = wrinklingRadius
        self.subgridCoefficient = subgridCoefficient
    }

    /// A laminar flame: no factor, wrinkling or sub-grid turbulence.
    public static let laminar = FlameAcceleration(factor: 1, wrinklingRadius: nil, subgridCoefficient: nil)
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
