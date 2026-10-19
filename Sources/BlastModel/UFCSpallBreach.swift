import Foundation

/// UFC 3-340-02 (2008, change 2 of 2014) §4-55's threshold spall and breach of concrete slabs under
/// high-explosive bursts: upper bounds to the tests' no-spall, spall and breach points (Figure
/// 4-65a). A slab `h` thick at range `R` from the charge's centre spalls when h/R is under
/// 1 / (a + b Ψ^2.5 + c Ψ^0.5) (equation 4-178) and is breached when under
/// 1 / (a + b Ψ + c Ψ²) (4-179), Ψ the spall parameter of equations 4-180a (standing off) and
/// 4-180b (in contact), on the adjusted charge of 4-181a: Wadj = Bf Cf W, Bf 1 for a burst on
/// the surface and 0.5 in free air, Cf 1 for a charge that is not a long cylinder. Valid for
/// 0.5 ≤ Ψ ≤ 14; past 14 neither, as no test spalled there.
public enum UFCSpallBreach {
    public enum Outcome: String, Codable, Sendable, Comparable {
        case none, spalled, breached

        public static func < (a: Self, b: Self) -> Bool {
            [Self.none, .spalled, .breached].firstIndex(of: a)! < [Self.none, .spalled, .breached].firstIndex(
                of: b)!
        }
    }

    package static let foot = 0.3048
    static let pound = 0.453_592_37
    static let psi = 6_894.757

    /// The spall parameter at `range` m, of concrete of `strength` Pa, under `charge` kg of TNT
    /// adjusted (Wadj) with `casing` kg of steel casing; `contact` for a charge touching the slab.
    public static func spallParameter(
        range: Double, strength: Double, adjusted: Double, casing: Double, contact: Bool
    )
        -> Double
    {
        let r = range / foot
        let fc = strength / psi
        let w = adjusted / pound
        if contact { return 0.527 * pow(r, 0.972) * pow(fc, 0.308) * pow(w, -0.341) }
        let wc = casing / pound
        return pow(r, 0.926) * pow(fc, 0.266) * pow(w, -0.353) * pow(w / (w + wc), 0.333)
    }

    /// h/R at the threshold of spall (4-178) and of breach (4-179) for spall parameter `psi`.
    public static func spallRatio(psi: Double) -> Double {
        1 / (-0.02511 + 0.01004 * pow(psi, 2.5) + 0.13613 * pow(psi, 0.5))
    }

    public static func breachRatio(psi: Double) -> Double {
        1 / (0.028205 + 0.144308 * psi + 0.049265 * psi * psi)
    }

    /// What a slab `thickness` m thick at `range` m from the charge's centre suffers: `charge` kg
    /// of TNT, `casing` kg of steel round it, burst on the surface (`surface`) or in free air;
    /// in `contact` when it touches the slab. Ψ under 0.5 is taken at 0.5.
    public static func outcome(
        thickness: Double, range: Double, strength: Double, charge: Double, casing: Double = 0,
        surface: Bool, contact: Bool
    ) -> Outcome {
        guard thickness > 0, range > 0, charge > 0 else { return .none }
        let adjusted = (surface ? 1 : 0.5) * charge
        let psi = spallParameter(
            range: range, strength: strength, adjusted: adjusted, casing: casing, contact: contact)
        guard psi <= 14 else { return .none }
        let p = max(psi, 0.5)
        let ratio = thickness / range
        if ratio < breachRatio(psi: p) { return .breached }
        if ratio < spallRatio(psi: p) { return .spalled }
        return .none
    }
}
