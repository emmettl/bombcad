import Foundation

/// The interlayer of a laminated pane.
public enum Interlayer: String, Codable, Hashable, Sendable, CaseIterable {
    /// Polyvinyl butyral, the common interlayer.
    case pvb
    /// Ionoplast (SentryGlas), several times stiffer and stronger.
    case sgp

    public var label: String {
        switch self {
        case .pvb: "PVB"
        case .sgp: "Ionoplast (SGP)"
        }
    }

    /// kg/m³.
    public var density: Double {
        switch self {
        case .pvb: 1070
        case .sgp: 950
        }
    }

    /// Shear modulus a load lasting `duration` (s) sees at 20 °C, Pa. PVB's relaxes fast: Hooper's
    /// Prony series (PhD thesis, Imperial College London, 2011, Table 4.2), G₀ 178 MPa, gives
    /// 64 MPa at 1 ms and 16 MPa at 10 ms. Ionoplast's: E 380–470 MPa at 20–45 s⁻¹ (Elkilani et
    /// al., *Polymers* 16, 2024, Table 2), G = E/3 for a rubbery solid, about 140 MPa.
    public func shearModulus(duration: Double) -> Double {
        switch self {
        case .pvb:
            let g0 = 178e6
            let terms: [(g: Double, tau: Double)] = [
                (0.490, 2.45e-5), (0.408, 2.21e-3), (0.0852, 4.98e-2), (0.0139, 0.624), (0.00159, 24.9),
                (0.002, 1000),
            ]
            let relaxed = terms.reduce(0) { $0 + $1.g * (1 - exp(-duration / $1.tau)) }
            return max(g0 * (1 - relaxed), 0.125e6)
        case .sgp:
            return 140e6
        }
    }

    /// The cracked laminate's plateau stress on the interlayer at strain rate `rate` (1/s), Pa:
    /// PVB's from Hooper's tension tests of cracked laminated glass (thesis, Table 5.2, random
    /// cracks), σ_p = m log₁₀ ε̇ + σ₀, m 4.5–4.9 MPa and σ₀ 11.0–14.3 MPa for 0.38–2.28 mm sheets;
    /// ionoplast's taken as its yield at 20–45 s⁻¹, 46–48 MPa (Elkilani et al., Table 2), no
    /// cracked-laminate test having been found.
    public func plateauStress(thickness: Double, rate: Double) -> Double {
        switch self {
        case .pvb:
            let table: [(t: Double, m: Double, s0: Double)] = [
                (0.38e-3, 4.9e6, 14.3e6), (0.76e-3, 4.8e6, 13.6e6), (1.52e-3, 4.9e6, 11.0e6),
                (2.28e-3, 4.5e6, 11.2e6),
            ]
            var row = table[0]
            if thickness >= table.last!.t {
                row = table.last!
            } else if thickness > table[0].t {
                for (a, b) in zip(table, table.dropFirst()) where thickness <= b.t {
                    let f = (thickness - a.t) / (b.t - a.t)
                    row = (thickness, a.m + f * (b.m - a.m), a.s0 + f * (b.s0 - a.s0))
                    break
                }
            }
            return row.m * log10(max(rate, 1e-3)) + row.s0
        case .sgp:
            return 47e6
        }
    }
}

/// A laminated pane: two glass plies bonded by an interlayer, which holds the glass once it has
/// cracked, carrying the load as a membrane until it tears or pulls out of its frame.
public struct LaminatedGlass: Codable, Hashable, Sendable {
    /// The glass plies' thicknesses, m (two).
    public var plies: [Double]
    public var interlayer: Interlayer
    /// m.
    public var interlayerThickness: Double
    /// What the frame holds before the pane pulls out, N per metre of edge: nil for an edge
    /// captured deeply enough not to let go (Osnes et al.'s clamped shock-tube panes). Structural
    /// silicone of 0.7 MPa over a 20 mm bite holds 14 kN/m.
    public var edgeCapacity: Double?

    public init(
        plies: [Double], interlayer: Interlayer, interlayerThickness: Double, edgeCapacity: Double? = nil
    ) {
        precondition(plies.count == 2 && plies.allSatisfy { $0 > 0 } && interlayerThickness > 0)
        self.plies = plies
        self.interlayer = interlayer
        self.interlayerThickness = interlayerThickness
        self.edgeCapacity = edgeCapacity
    }

    /// What a structural silicone joint of `bite` (m) holds per metre of edge, N/m: 1.1 MPa over
    /// the bite, the strength Hooper recommends designing to (thesis, §6.5), his joints' weakest,
    /// pulled at 30° and 0.1 m/s (Table 6.2: up to 2.3 MPa pulled faster or straighter). In his
    /// blast tests the joints, 20 mm bites, let go at 20 ± 5 kN/m (Table 3.11, §8.4).
    public static func siliconeCapacity(bite: Double) -> Double { 1.1e6 * bite }

    /// Glass and interlayer together, m.
    public var thickness: Double { plies.reduce(0, +) + interlayerThickness }

    /// A façade's common laminate, two 6 mm annealed plies on 1.52 mm PVB, held in structural
    /// silicone with a 20 mm bite.
    public static let facade = LaminatedGlass(
        plies: [0.006, 0.006], interlayer: .pvb, interlayerThickness: 0.00152,
        edgeCapacity: siliconeCapacity(bite: 0.02))

    /// The duration of the load the interlayer's shear modulus is taken at: 1 ms, the time to
    /// break the measured panes took (0.4–1.1 ms in Osnes et al.'s shock tube, 1–2.5 ms in Hooper's
    /// and Zhang et al.'s arena tests).
    public static let loadDuration = 1e-3
    /// The strain rate the cracked laminate's tension is taken at: 10 s⁻¹, the low end of the
    /// 10–30 s⁻¹ Hooper measured at the centre of his blast-loaded panes (thesis, Table 3.8).
    public static let strainRate = 10.0
    /// Deflection over the shorter span at which the cracked laminate tears: where its average
    /// membrane strain, (8/3)(x/a)², reaches its failure strain at blast rates, Hooper's for cracked
    /// PVB laminate (thesis, pp. 130–135: about 150% for 1.52 and 2.28 mm sheets at every rate, 20%
    /// for 0.76 mm and 10% for 0.38 mm at 10 m/s), ionoplast's 120% (Elkilani et al., at 20 s⁻¹).
    /// A cracked pane tears at its edges first, where the strain gathers: Zhang, Hao and Wang saw
    /// 1.52 mm PVB start to tear at 0.23 (*IJIE* 78, 2015, §3.2.2) and Osnes et al.'s held at 0.4.
    public func tearRatio() -> Double {
        let strain: Double
        switch interlayer {
        case .sgp: strain = 1.2
        case .pvb:
            let table: [(t: Double, e: Double)] = [
                (0.38e-3, 0.10), (0.76e-3, 0.20), (1.52e-3, 1.5), (2.28e-3, 1.5),
            ]
            let t = interlayerThickness
            if t <= table[0].t {
                strain = table[0].e
            } else if t >= table.last!.t {
                strain = table.last!.e
            } else {
                var value = table[0].e
                for (a, b) in zip(table, table.dropFirst()) where t <= b.t {
                    value = a.e + (t - a.t) / (b.t - a.t) * (b.e - a.e)
                    break
                }
                strain = value
            }
        }
        return (3 * strain / 8).squareRoot()
    }
    /// Deflection over the shorter span at which the cracked laminate reaches its plateau
    /// tension: 0.067, an average membrane strain (8/3)(x/a)² of 1.2%, the yield strain of Hooper's
    /// fit to cracked laminate (thesis, Table 7.3: A 6.72 MPa, E 0.55 GPa).
    public static let plateauRatio = 0.067

    /// Wölfel–Bennison effective thicknesses (ASTM E1300's for laminated glass, after Calderone,
    /// Davies and Bennison 2009) for a pane whose shorter span is `span`: the monolithic thickness
    /// that deflects as much, and the thinner one whose stress matches the more stressed ply's, m.
    public func effectiveThicknesses(span: Double, modulus: Double = 70e9) -> (
        deflection: Double, stress: Double
    ) {
        let h1 = plies[0]
        let h2 = plies[1]
        let hv = interlayerThickness
        let hs = 0.5 * (h1 + h2) + hv
        let hs1 = hs * h1 / (h1 + h2)
        let hs2 = hs * h2 / (h1 + h2)
        let inertia = h1 * hs2 * hs2 + h2 * hs1 * hs1
        let g = interlayer.shearModulus(duration: Self.loadDuration)
        let gamma = 1 / (1 + 9.6 * modulus * inertia * hv / (g * hs * hs * span * span))
        let deflection = cbrt(h1 * h1 * h1 + h2 * h2 * h2 + 12 * gamma * inertia)
        let stress1 = (deflection * deflection * deflection / (h1 + 2 * gamma * hs2)).squareRoot()
        let stress2 = (deflection * deflection * deflection / (h2 + 2 * gamma * hs1)).squareRoot()
        return (deflection, min(stress1, stress2))
    }

    /// p = shape T x / a² for a membrane a × b (a the shorter) under uniform tension T and
    /// pressure p, x its middle's deflection: x = (p a² / 8T) [1 − (32/π³) Σ (−1)^((n−1)/2) /
    /// (n³ cosh(nπb / 2a))], n odd (Poisson's equation; 13.6 square, 8 for a long strip).
    public static func membraneShape(aspect: Double) -> Double {
        var sum = 0.0
        for k in 0..<20 {
            let n = Double(2 * k + 1)
            sum += (k % 2 == 0 ? 1 : -1) / (n * n * n * cosh(n * .pi * aspect / 2))
        }
        return 8 / (1 - 32 / pow(.pi, 3) * sum)
    }
}

extension EnvelopePanel {
    /// A laminated pane a × b (m) on Moore's large-deflection plate and E1300's flaw model, as
    /// `largeDeflectionGlass` is for a monolithic one, at the plies' Wölfel–Bennison effective
    /// thicknesses: deflecting as the thickness that matches its deflection, stressed as the one
    /// that matches its more stressed ply's. When the glass cracks it does not lose its resistance:
    /// the interlayer holds the fragments and carries the load as a membrane at the cracked
    /// laminate's plateau tension (`SDOFSystem.Membrane`), until it tears or pulls out.
    public static func laminatedGlass(
        _ laminate: LaminatedGlass, a: Double, b: Double, sixtySecondStrength: Double? = nil
    ) -> SDOFSystem {
        let short = min(a, b)
        let aspect = max(a, b) / short
        let thickness = laminate.effectiveThicknesses(span: short)
        var system = largeDeflectionGlass(
            thickness: thickness.deflection, material: .annealedGlass, a: a, b: b,
            sixtySecondStrength: sixtySecondStrength)
        // The stress at a deflection goes as the inverse square of the thickness that carries it.
        let scale = pow(thickness.deflection / thickness.stress, 2)
        if var brittle = system.brittle {
            brittle.stress = brittle.stress.map { SIMD2($0.x, $0.y * scale) }
            system.brittle = brittle
        }
        system.massPerArea =
            Double(StructureMaterial.annealedGlass.density) * laminate.plies.reduce(0, +)
            + laminate.interlayer.density * laminate.interlayerThickness
        let tension =
            laminate.interlayer.plateauStress(
                thickness: laminate.interlayerThickness, rate: LaminatedGlass.strainRate)
            * laminate.interlayerThickness
        system.membrane = SDOFSystem.Membrane(
            tension: tension, shape: LaminatedGlass.membraneShape(aspect: aspect), span: short,
            tearRatio: laminate.tearRatio(), plateauDeflection: LaminatedGlass.plateauRatio * short,
            edgeCapacity: laminate.edgeCapacity)
        return system
    }
}
