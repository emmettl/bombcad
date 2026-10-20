import Foundation

/// Sub-grid turbulent mixing in the air (see `mixingFlux` in Solver.metal, `eddyViscosity` in
/// Mixing.metal and docs/air-blast-model.md#sub-grid-mixing): an eddy viscosity after Smagorinsky,
/// (C Δ)² |S|, switched off in shocks by the sensor of Ducros and others, carries momentum, heat
/// and the products and oxygen across the cells' faces as the turbulence the grid cannot resolve
/// would. Off by default (nil in `SolverConfiguration`).
public struct SubgridMixing: Sendable, Hashable, Codable {
    /// How the eddy viscosity is worked out from the resolved flow.
    public enum Model: String, Sendable, Hashable, Codable {
        /// Smagorinsky's (C Δ)² |S|.
        case smagorinsky
        /// Nicoud et al.'s (2011) σ-model, (C Δ)² σ₃(σ₁ − σ₂)(σ₂ − σ₃)/σ₁² from the velocity
        /// gradient's singular values: zero in one- and two-dimensional, axisymmetric, purely
        /// sheared and rigidly rotating flow, such as the laminar flow round a growing flame.
        case sigma
    }

    /// The model's coefficient C: for Smagorinsky's, 0.17 from Lilly's estimate for the inertial
    /// range (smaller values are often used where the scheme itself dissipates); for the σ-model,
    /// 1.35, which Nicoud et al. found gives the same dissipation in isotropic turbulence.
    public var coefficient: Float = 0.17
    /// The turbulent Prandtl and Schmidt numbers, the ratio of the eddy viscosity to the eddy
    /// diffusivities of heat and of the products and oxygen.
    public var prandtl: Float = 0.7
    /// Smagorinsky's unless set (saves made before the σ-model open unchanged).
    public var model: Model?

    public init(coefficient: Float = 0.17, prandtl: Float = 0.7, model: Model? = nil) {
        self.coefficient = coefficient
        self.prandtl = prandtl
        self.model = model
    }

    /// The σ-model with Nicoud et al.'s coefficient, as a deflagration's turbulent flame uses it.
    public static let sigma = SubgridMixing(coefficient: 1.35, model: .sigma)
}

/// An extinction limit for afterburning (see `afterburntHere` in Solver.metal and
/// docs/air-blast-model.md#an-extinction-limit-for-afterburning): the products burn only where the
/// mixture can keep a flame going, at least `ignitionTemperature` hot and able, by burning all the
/// fuel its oxygen allows, to reach `limitFlameTemperature`. Off by default (nil in
/// `SolverConfiguration`), when they burn wherever they meet oxygen.
public struct AfterburnLimit: Sendable, Hashable, Codable {
    /// K: below it the products' carbon monoxide oxidises more slowly than the gas mixes (Dryer and
    /// Glassman's global rate, for a fireball's mixing times of tens of milliseconds to a second).
    public var ignitionTemperature: Float = 800
    /// K: the flame temperature of mixtures at their flammability limits (Zabetakis), which a
    /// mixture must reach by burning.
    public var limitFlameTemperature: Float = 1500

    public init(ignitionTemperature: Float = 800, limitFlameTemperature: Float = 1500) {
        self.ignitionTemperature = ignitionTemperature
        self.limitFlameTemperature = limitFlameTemperature
    }
}

/// Afterburning limited by the sub-grid turbulence's mixing, an eddy-break-up rate (Spalding 1971;
/// Magnussen and Hjertager 1977): the products burn at min(fuel, oxygen / s) × min(1/τ, C √k / Δ),
/// τ the burning time fitted to the blast's impulse (`SolverConfiguration.afterburnTime`), k the
/// sub-grid kinetic energy from the eddy viscosity of the air's sub-grid mixing as a one-equation
/// model has it, k = (ν_t / (C_k Δ))², C_k = 0.094 (as a deflagration's flame turbulence takes it),
/// and Δ the cell. Where the turbulence is strong, early on, the fitted time governs; as it decays
/// the burning slows to the rate the eddies mix oxygen in (see `afterburntHere` in Solver.metal and
/// docs/thermal-radiation.md, emmettl/bombcad-work#22). Needs sub-grid mixing, which is turned on
/// (Smagorinsky's) if it is not already. Off by default (nil in `SolverConfiguration`). Judged on
/// 20 October 2026 and not adopted: the eddy viscosity is nothing in the expanding fireball, so the
/// limit slows the early burning most, and wherever it lowers Dial Pack's radiated share it costs the
/// open blast's impulse 6% to 20%.
public struct MixedAfterburning: Sendable, Hashable, Codable {
    /// The eddy-break-up coefficient C on √k / Δ.
    public var coefficient: Float = 1

    public init(coefficient: Float = 1) {
        self.coefficient = coefficient
    }

    /// The rate's factor on ν_t / Δ²: C / C_k.
    public var ratePerViscosity: Float { coefficient / FlameTurbulence.energyCoefficient }
}
