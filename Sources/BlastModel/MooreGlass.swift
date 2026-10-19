import Foundation

/// A glass pane's large-deflection response after D. M. Moore, *Proposed method for determining
/// the thickness of glass in solar collector panels*, JPL Publication 80-34 (1980), as UFC
/// 3-340-02 (Change 2, 2014) gives it in §6-29 and figures 6-52 and 6-53: a rectangular plate
/// simply supported on all four edges, free to move in its plane there, ν = 0.22, its stresses and
/// deflection from the von Kármán equations, so that membrane action stiffens it and keeps its
/// bending stress down once it deflects more than about a third of its thickness, when the
/// largest stress moves from the centre towards the corners.
public enum MooreGlassCurves {
    package struct Curves {
        var aspect: Double
        package var deflection: [SIMD2<Double>]
        var centreStress: [SIMD2<Double>]
        var cornerStress: [SIMD2<Double>]
    }

    /// The centre's deflection over the thickness, and the largest principal stress anywhere
    /// as σ b² / (E′ t²), at the nondimensional load L = q b⁴ / (E′ t⁴), E′ = E / 12(1 − ν²),
    /// b the short span; for aspect ratios a/b from 1 to 4 (longer panes as 4, as UFC says).
    public static func response(load: Double, aspect: Double) -> (deflection: Double, stress: Double) {
        let ratio = min(max(aspect, 1), 4)
        let upper = curves.firstIndex { $0.aspect >= ratio }!
        let lower = max(upper - 1, 0)
        let (a, b) = (curves[lower], curves[upper])
        let w = upper == lower ? 0 : (ratio - a.aspect) / (b.aspect - a.aspect)
        func blend(_ value: (Curves) -> Double) -> Double { (1 - w) * value(a) + w * value(b) }
        return (blend { value($0.deflection, load) }, blend { stress($0, load) })
    }

    /// The larger of the centre's and the corners' stress where each is given.
    package static func stress(_ c: Curves, _ load: Double) -> Double {
        var largest = 0.0
        if load <= c.centreStress.last!.x { largest = value(c.centreStress, load) }
        if load >= c.cornerStress.first!.x { largest = max(largest, value(c.cornerStress, load)) }
        return largest
    }

    /// Log-log interpolation; below the curve's first load, in proportion to the load (the
    /// curves begin where the plate is still nearly linear), and beyond its last, along its last
    /// segment.
    package static func value(_ curve: [SIMD2<Double>], _ load: Double) -> Double {
        guard load > curve[0].x else { return curve[0].y * load / curve[0].x }
        let i = curve.firstIndex { $0.x >= load } ?? curve.count - 1
        let (p, q) = (curve[max(i - 1, 0)], curve[max(i, 1)])
        let f = log(load / p.x) / log(q.x / p.x)
        return exp(log(p.y) + f * log(q.y / p.y))
    }
}

/// Annealed glass's strength by the glass failure prediction model of W. L. Beason and J. R. Morgan
/// (1984), as ASTM E1300 (2016) Annex A2 uses it: the probability of breakage is
/// 1 − exp(−k ∫ (c σ_e)^m dA), σ_e a surface stress equivalent to one held for 60 s, with k =
/// 2.86 × 10⁻⁵³ N⁻⁷ m¹² and m = 7 for annealed glass, and the static fatigue of glass, exponent
/// n = 16, setting how a stress held for a time t_d compares with one held for 60 s, σ (t_d / 60 s)^(1/n)
/// (as transcribed by S. M. Soules, S. M. Morse and H. S. Norville, *The glass failure prediction
/// model*, Facade Tectonics Institute). Here the whole pane is taken to bear its largest principal
/// stress and c = 1 (an equibiaxial stress's), the most stressed a pane could be, so the strength
/// is the lowest the model allows: a real pane's largest stress covers a part of it.
public enum GlassStrength {
    public static let flawConstant = 2.86e-53
    public static let weibullModulus = 7.0
    public static let fatigueExponent = 16.0
    /// The duration the equivalent stress refers to, s.
    public static let referenceDuration = 60.0

    /// The stress held for 60 s that breaks a pane of `area` (m²) with `probability`, Pa.
    public static func sixtySecond(area: Double, probability: Double = 0.5) -> Double {
        pow(-log(1 - probability) / (flawConstant * area), 1 / weibullModulus)
    }
}

extension EnvelopePanel {
    /// A glass pane on Moore's large-deflection plate (`MooreGlassCurves`): simply supported, its
    /// resistance stiffening with deflection, elastic both ways, breaking when its largest
    /// principal stress, accumulated over time as glass's static fatigue weighs it (Brown's
    /// integral ∫ (σ/σ₆₀)ⁿ dt reaching 60 s, n = 16), reaches its 60 s strength (`GlassStrength`,
    /// the median for the pane's area unless given), or when it deflects ten times its thickness
    /// (UFC §6-29.3: the edges let go). The load–mass factor is UFC's for glass,
    /// 0.63 + 0.16 (a/b − 1) up to 0.79 (eq 6-45).
    public static func largeDeflectionGlass(
        thickness: Double, material: StructureMaterial, a: Double, b: Double,
        sixtySecondStrength: Double? = nil
    ) -> SDOFSystem {
        let short = min(a, b)
        let aspect = max(a, b) / short
        let poisson = Double(material.poissonRatio)
        let modulus = Double(material.youngsModulus) / (12 * (1 - poisson * poisson))
        let loadScale = modulus * pow(thickness / short, 4)
        let stressScale = modulus * pow(thickness / short, 2)
        // Loads evenly spaced in their log, from a small-deflection one to the edges letting go.
        var backbone: [SIMD2<Double>] = []
        var stress: [SIMD2<Double>] = []
        var load = 0.1
        while true {
            let r = MooreGlassCurves.response(load: load, aspect: aspect)
            let x = r.deflection * thickness
            if r.deflection >= 10 {
                // The last step, cut back to ten thicknesses along its line.
                if let p = backbone.last, let s = stress.last {
                    let f = (10 * thickness - p.x) / (x - p.x)
                    backbone.append(SIMD2(10 * thickness, p.y + f * (load * loadScale - p.y)))
                    stress.append(SIMD2(10 * thickness, s.y + f * (r.stress * stressScale - s.y)))
                }
                break
            }
            backbone.append(SIMD2(x, load * loadScale))
            stress.append(SIMD2(x, r.stress * stressScale))
            load *= 1.15
        }
        backbone.append(SIMD2(backbone.last!.x * (1 + 1e-6), 0))
        let loadMass = min(0.63 + 0.16 * (aspect - 1), 0.79)
        return SDOFSystem(
            massPerArea: Double(material.density) * thickness, loadMassElastic: loadMass,
            loadMassPlastic: loadMass,
            backbone: backbone, reboundFactor: 1, span: short,
            brittle: SDOFSystem.Brittle(
                stress: stress,
                strength: sixtySecondStrength ?? GlassStrength.sixtySecond(area: a * b),
                referenceDuration: GlassStrength.referenceDuration,
                fatigueExponent: GlassStrength.fatigueExponent))
    }
}
