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
