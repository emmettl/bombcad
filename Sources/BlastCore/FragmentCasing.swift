import Foundation

/// A casing's metal, as a fragment description's mass distribution and density give it: the two
/// for which the evidence says how the casing breaks (docs/fragments.md#against-coopers-data).
public enum CasingMetal: String, CaseIterable, Sendable {
    /// Ductile steel: Mott's distribution, exponent ½, as fitted to steel shells; 7,850 kg/m³.
    case steel
    /// Brittle cast iron: Grady's exponential, exponent 1, which fits Cooper's counted cast-iron
    /// bomb within a factor of 1.12 where Mott's is within 1.36; 7,200 kg/m³, a handbook value for
    /// grey iron.
    case castIron

    public var title: String { self == .steel ? "Steel" : "Cast iron" }
    public var massExponent: Float { self == .steel ? 0.5 : 1 }
    public var density: Float { self == .steel ? 7850 : 7200 }
}

extension FragmentSpec {
    /// The casing's metal, where the description's mass exponent and density are one of
    /// `CasingMetal`'s; nil for any other pair.
    public var metal: CasingMetal? {
        get {
            CasingMetal.allCases.first { $0.massExponent == massExponent && $0.density == fragmentDensity }
        }
        set {
            guard let newValue else { return }
            massExponent = newValue.massExponent
            fragmentDensity = newValue.density
        }
    }

    /// A casing's wall thickness and inside diameter, metres, that hold `chargeMass` kg of TNT at
    /// 1,600 kg/m³ (as the air's charge) and weigh this description's `casingMass` as a thin wall
    /// of its metal: for a cylinder twice as long as it is wide, the wall round its side; for a
    /// sphere, round all of it. A starting point for a casing whose dimensions are not known.
    public func casingDimensions(chargeMass: Float) -> (thickness: Float, diameter: Float)? {
        guard chargeMass > 0, casingMass > 0, fragmentDensity > 0 else { return nil }
        let volume = chargeMass / 1600
        switch casing {
        case .cylinder:
            // π d² (2d) / 4 = V, and the wall π d (2d) t.
            let diameter = cbrt(2 * volume / .pi)
            return (casingMass / (fragmentDensity * .pi * 2 * diameter * diameter), diameter)
        case .sphere:
            let diameter = cbrt(6 * volume / .pi)
            return (casingMass / (fragmentDensity * .pi * diameter * diameter), diameter)
        }
    }
}
