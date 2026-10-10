import Foundation

/// Sub-grid turbulent mixing in the air (see `mixingFlux` in Solver.metal, `eddyViscosity` in
/// Mixing.metal and docs/air-blast-model.md#sub-grid-mixing): an eddy viscosity after Smagorinsky,
/// (C Δ)² |S|, switched off in shocks by the sensor of Ducros and others, carries momentum, heat
/// and the products and oxygen across the cells' faces as the turbulence the grid cannot resolve
/// would. Off by default (nil in `SolverConfiguration`).
public struct SubgridMixing: Sendable, Hashable, Codable {
    /// Smagorinsky's coefficient C: 0.17 from Lilly's estimate for the inertial range; smaller
    /// values are often used where the scheme itself dissipates.
    public var coefficient: Float = 0.17
    /// The turbulent Prandtl and Schmidt numbers, the ratio of the eddy viscosity to the eddy
    /// diffusivities of heat and of the products and oxygen.
    public var prandtl: Float = 0.7

    public init(coefficient: Float = 0.17, prandtl: Float = 0.7) {
        self.coefficient = coefficient
        self.prandtl = prandtl
    }
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
