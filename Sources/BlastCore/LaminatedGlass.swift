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

    /// The cracked laminate's stress on the interlayer (Pa) against its plastic strain, at strain
    /// rate `rate` (1/s), for an interlayer `thickness` (m) thick, as at most eight points to its
    /// failure strain, and its modulus: Hooper's Johnson–Cook fit to randomly cracked 7.52 mm
    /// laminate with 1.52 mm of PVB, the law of his post-crack shell model (thesis, §7.2.2 and
    /// Table 7.3), σ = (6.72 + 10.6 ε_p^0.303)(1 + 0.248 ln(ε̇ / 1 s⁻¹)) MPa on a modulus of
    /// 0.55 GPa, scaled to other thicknesses as their plateau stresses are (`plateauStress`).
    /// Ionoplast's, without a cracked-laminate test, is its plateau held to its failure strain on a
    /// modulus that reaches it at the plateau strain of 1.2%.
    public func crackedLaminateCurve(thickness: Double, rate: Double) -> (
        modulus: Double, curve: [SIMD2<Double>]
    ) {
        let failure = failureStrain(thickness: thickness)
        switch self {
        case .sgp:
            let plateau = plateauStress(thickness: thickness, rate: rate)
            let modulus = plateau / LaminatedGlass.plateauStrain
            return (modulus, [SIMD2(0, plateau), SIMD2(max(failure - plateau / modulus, 1e-3), plateau)])
        case .pvb:
            let modulus = 0.55e9
            let scale =
                plateauStress(thickness: thickness, rate: rate)
                / plateauStress(thickness: 1.52e-3, rate: rate)
            let factor = 1 + 0.248 * log(max(rate, 1e-3))
            func stress(_ plastic: Double) -> Double {
                scale * factor * (6.72e6 + 10.6e6 * pow(plastic, 0.303))
            }
            // The plastic strain at which the total, plastic and elastic, reaches the failure strain.
            var last = failure
            for _ in 0..<8 { last = max(failure - stress(last) / modulus, 2e-3) }
            let strains = [0, 0.02, 0.05, 0.1, 0.2, 0.4, 0.8].filter { $0 < last } + [last]
            return (modulus, strains.map { SIMD2($0, stress($0)) })
        }
    }

    /// The cracked laminate's failure strain at blast rates for an interlayer `thickness` (m)
    /// thick: Hooper's for cracked PVB laminate (thesis, pp. 130–135: about 150% for 1.52 and 2.28
    /// mm sheets at every rate, 20% for 0.76 mm and 10% for 0.38 mm at 10 m/s), ionoplast's 120%
    /// (Elkilani et al., at 20 s⁻¹).
    public func failureStrain(thickness: Double) -> Double {
        switch self {
        case .sgp: return 1.2
        case .pvb:
            let table: [(t: Double, e: Double)] = [
                (0.38e-3, 0.10), (0.76e-3, 0.20), (1.52e-3, 1.5), (2.28e-3, 1.5),
            ]
            if thickness <= table[0].t { return table[0].e }
            if thickness >= table.last!.t { return table.last!.e }
            for (a, b) in zip(table, table.dropFirst()) where thickness <= b.t {
                return a.e + (thickness - a.t) / (b.t - a.t) * (b.e - a.e)
            }
            return table[0].e
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
    /// membrane strain, (8/3)(x/a)², reaches its failure strain at blast rates
    /// (`Interlayer.failureStrain`). A cracked pane tears at its edges first, where the strain
    /// gathers: Zhang, Hao and Wang saw 1.52 mm PVB start to tear at 0.23 (*IJIE* 78, 2015,
    /// §3.2.2) and Osnes et al.'s held at 0.4.
    public func tearRatio() -> Double {
        (3 * interlayer.failureStrain(thickness: interlayerThickness) / 8).squareRoot()
    }
    /// Deflection over the shorter span at which the cracked laminate reaches its plateau
    /// tension: 0.067, an average membrane strain (8/3)(x/a)² of 1.2%, the yield strain of Hooper's
    /// fit to cracked laminate (thesis, Table 7.3: A 6.72 MPa, E 0.55 GPa).
    public static let plateauRatio = 0.067
    /// The cracked laminate's strain at its plateau tension, the same datum: 1.2%.
    public static let plateauStrain = 0.012

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

extension StructureMaterial {
    /// A laminated pane a × b (m) meshed as one shell `laminate.thickness` thick, with the laws
    /// and data the envelope's pane uses (`EnvelopePanel.laminatedGlass`):
    /// - **Uncracked:** monolithic `glass`, its stiffness scaled so that the shell deflects as
    ///   the Wölfel–Bennison deflection thickness does over the shorter span, and its tensile
    ///   strength so that it cracks when the more stressed ply would (the stress thickness); its
    ///   mass the plies' and the interlayer's. The plies crack at the stress a load rising over
    ///   `LaminatedGlass.loadDuration` breaks them at by E1300's flaw model and glass's static
    ///   fatigue (`GlassStrength`: Brown's integral of a ramp, σ₆₀ (60 (n + 1) / t)^(1/n)), from
    ///   the pane's 60 s strength, E1300's median for its area unless given.
    /// - **Cracked:** the glass's layers crack and carry only compression, the fragments bearing
    ///   on one another; the interlayer, a layer at the midsurface both ways
    ///   (`interlayerThickness`), carries the load as an isotropic membrane in plane stress (von
    ///   Mises, Poisson's ratio 0.45) by the cracked laminate's stress against strain at 10 s⁻¹
    ///   (`Interlayer.crackedLaminateCurve`, Hooper's), until its equivalent plastic strain
    ///   passes the curve's end, at its failure strain (`Interlayer.failureStrain`), and it
    ///   tears. The curve hardens: a membrane held at a flat plateau, as the envelope's single
    ///   degree of freedom takes it, gathers its stretch into a band.
    /// - **Fragmenting:** once any of a pane's glass cracks open through a layer, the whole
    ///   pane's is in fragments, which keep their mass but carry nothing, the interlayer holding
    ///   them: Hooper's post-crack model (thesis, §7.2.2), which takes the cracks to spread at once
    ///   across the pane and the glass's modulus to nothing. Left to bear on one another in
    ///   compression, the fragments' stiff bands gathered the interlayer's stretch between them
    ///   and it tore through.
    public static func laminatedGlass(
        _ laminate: LaminatedGlass, a: Double, b: Double, glass: StructureMaterial = .annealedGlass,
        sixtySecondStrength: Double? = nil
    ) -> StructureMaterial {
        let effective = laminate.effectiveThicknesses(span: min(a, b), modulus: Double(glass.youngsModulus))
        let n = GlassStrength.fatigueExponent
        let strength =
            (sixtySecondStrength ?? GlassStrength.sixtySecond(area: a * b))
            * pow(60 * (n + 1) / LaminatedGlass.loadDuration, 1 / n)
        let h = laminate.thickness
        var material = glass
        material.name = String(
            format: "Laminated glass (%.1f/%.2f %@/%.1f mm)", laminate.plies[0] * 1e3,
            laminate.interlayerThickness * 1e3, laminate.interlayer.label, laminate.plies[1] * 1e3)
        material.youngsModulus = glass.youngsModulus * Float(pow(effective.deflection / h, 3))
        material.tensileStrength = Float(strength * pow(effective.stress / h, 2))
        material.density = Float(
            (Double(glass.density) * laminate.plies.reduce(0, +)
                + laminate.interlayer.density * laminate.interlayerThickness) / h)
        let cracked = laminate.interlayer.crackedLaminateCurve(
            thickness: laminate.interlayerThickness, rate: LaminatedGlass.strainRate)
        let last = cracked.curve.last!
        var interlayer = SteelProperties(
            yieldStress: Float(cracked.curve[0].y), ultimateStress: Float(last.y),
            ultimateStrain: Float(last.x),
            ruptureStrain: Float(last.x))
        interlayer.youngsModulus = Float(cracked.modulus)
        interlayer.measuredCurve = cracked.curve.map { SIMD2(Float($0.x), Float($0.y)) }
        material.steel = interlayer
        material.interlayerThickness = Float(laminate.interlayerThickness)
        return material
    }
}
