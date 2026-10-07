import Foundation

/// Bars that slip in their concrete, in place of perfect bond (`StructureModel.bondSlip`).
///
/// Each node carries, for each lattice axis its bars run along, the slip of the bars there
/// relative to the concrete. An element's bars are strained by the concrete's stretch along the
/// axis plus the change in slip across the element, and the bond between bar and concrete
/// resists slip with the stress of the fib Model Code 2010's bond–slip law (§6.1.1, good bond):
/// τ = τ_max (s / s₁)^α up to s₁, held to s₂, falling linearly to τ_f at s₃, starting linearly
/// at a fiftieth of s₁ so that its stiffness is finite, and unloading at that stiffness. The bond
/// acts over the bars' surface, 4 ρ / d per unit volume for a ratio ρ of bars of diameter d.
///
/// So the concrete between two cracks can shed its tension to the bars, as it does in a real
/// member, and cracks can localise on any mesh: a crack crossed by bars softens over its own
/// element, as one in plain concrete does, instead of over the crack spacing, and a bar's
/// rupture is judged in its own element, its strain spread along it by the slip.
///
/// Bars are far lighter than their concrete, too light for the time step, so the slip does not
/// follow their inertia: it relaxes towards equilibrium each step with a mass scaled to the time
/// step and close to critical damping, and so lags the load by some tens of steps. Inclined bars
/// stay perfectly bonded.
public struct BondSlip: Sendable, Hashable, Codable {
    /// The Model Code's bond conditions.
    public enum Condition: String, Sendable, Hashable, Codable, CaseIterable {
        /// Bars well confined, which pull out by shearing the concrete between their ribs:
        /// τ_max = 2.5 √f_c, s₁ = 1 mm, s₂ = 2 mm, s₃ the clear rib spacing, τ_f = 0.4 τ_max.
        case pullOut
        /// Bars in unconfined concrete, as without stirrups, which split their cover:
        /// τ_max = 7 (f_c / 25)^0.25 MPa at the slip the pull-out curve gives it, falling to
        /// nothing by 1.2 times that slip.
        case splitting
        /// Bars that split their cover but are held by stirrups: τ_max = 8 (f_c / 25)^0.25 MPa,
        /// falling to 0.4 τ_max by half the clear rib spacing.
        case confinedSplitting
    }

    public var condition: Condition
    /// The bars' diameter in metres.
    public var barDiameter: Float
    /// The clear distance between the bars' ribs, in metres.
    public var ribSpacing: Float

    public init(condition: Condition = .pullOut, barDiameter: Float = 0.016, ribSpacing: Float = 0.01) {
        self.condition = condition
        self.barDiameter = barDiameter
        self.ribSpacing = ribSpacing
    }

    /// The bond–slip curve's points for concrete of mean compressive strength `strength` (Pa):
    /// the peak bond stress τ_max and residual τ_f (Pa), the slips s₁, s₂ and s₃ (m), and α.
    public func law(compressiveStrength strength: Float) -> (
        peak: Float, residual: Float, s1: Float, s2: Float, s3: Float, alpha: Float
    ) {
        let fc = strength / 1e6
        let pullOut = 2.5 * fc.squareRoot() * 1e6
        let alpha: Float = 0.4
        // The slip at which the pull-out curve's rising branch reaches `stress`.
        func slip(at stress: Float) -> Float { 1e-3 * pow(min(stress / pullOut, 1), 1 / alpha) }
        switch condition {
        case .pullOut:
            return (pullOut, 0.4 * pullOut, 1e-3, 2e-3, max(ribSpacing, 2.1e-3), alpha)
        case .splitting:
            let peak = 7 * pow(fc / 25, 0.25) * 1e6
            let s1 = slip(at: peak)
            return (peak, 0, s1, s1, 1.2 * s1, alpha)
        case .confinedSplitting:
            let peak = 8 * pow(fc / 25, 0.25) * 1e6
            let s1 = slip(at: peak)
            return (peak, 0.4 * peak, s1, s1, max(0.5 * ribSpacing, 1.2 * s1), alpha)
        }
    }
}
