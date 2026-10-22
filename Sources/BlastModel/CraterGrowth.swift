import Foundation

/// How a crater grows to its final shape after its charge fires, for drawing it as it forms: in
/// the app's replay of a run and in the USD export. Standing: illustrative. Nothing here acts on
/// the blast or changes the final crater, which is `CraterEstimate`'s.
///
/// - **When it has formed.** Holsapple's gravity-regime formation time, T = 0.8 √(V^(1/3) / g),
///   with V the crater's volume (K. A. Holsapple, "Theory and equations for 'Craters from Impacts
///   and Explosions'", equation 8, after Schmidt and Housen, 1987, and Holsapple, 1993, figure 12).
///   Here V is the apparent crater's bowl, π R² D / 2: about 0.33 s for 100 kg of TNT on alluvium,
///   1.3 s for 500 short tons.
/// - **How the bowl grows.** Under point-source scaling a crater's growth is set by one coupling
///   parameter, C = a U^μ δ^ν (Holsapple's equation 3), of dimension L^(1+μ) T^(−μ), so a length
///   in the growing flow goes as t^(μ/(1+μ)). The radius and the depth both grow as
///   (t / T)^(μ/(1+μ)) to their final values at T: μ is 0.41 for dry soil and 0.55 for wet soil
///   and rock (Holsapple's table), so the exponent is 0.29 or 0.35. The bowl keeps its shape as it
///   grows, so each point in it only deepens.
/// - **The lip rises last.** Its height rises over the second half of the formation time, eased
///   (a smoothstep), to its final height at T, and its crest and the ejecta's reach stand out from
///   the bowl's rim as it rises, so no earth lies beyond the rim before then. That choice is
///   BombCAD's own, for the ejecta are still in flight as the bowl opens; no source gives the
///   lip's growth.
extension CraterEstimate {
    /// Standard gravity, m/s².
    public static let gravity: Float = 9.806_65

    /// The apparent crater's volume below the original ground, m³: its paraboloid bowl's,
    /// π R² D / 2.
    public var bowlVolume: Float { .pi / 2 * apparentRadius * apparentRadius * apparentDepth }

    /// How long it takes to form after its charge fires, seconds: 0.8 √(V^(1/3) / g)
    /// (Holsapple, equation 8).
    public var formationTime: Float { 0.8 * (cbrt(bowlVolume) / Self.gravity).squareRoot() }

    /// When it has finished forming, seconds after the run's start.
    public var formedAt: Float { (delay ?? 0) + formationTime }

    /// The point-source coupling exponent μ of its ground (Holsapple's table): 0.55 for wet soil
    /// and rock, 0.41 for dry soil. The clays count as wet, as does any ground over a shallow
    /// water table; the sorting is BombCAD's.
    public var couplingExponent: Float {
        if waterTable != nil { return 0.55 }
        switch ground {
        case .rigid, .rock, .clay, .glacialSoil, .clayShale, .saturated: return 0.55
        case .soilOverSandstone, .playa, .alluvium: return 0.41
        }
    }

    /// The share of their final size the bowl (its radius and depth) and the lip's height have
    /// reached at `time`, seconds after the run's start: both 0 until the charge fires, both 1 from
    /// `formedAt`, and never falling in between.
    public func growth(atTime time: Float) -> (bowl: Float, lip: Float) {
        let since = time - (delay ?? 0)
        guard since > 0 else { return (0, 0) }
        guard formationTime > 0, since < formationTime else { return (1, 1) }
        let progress = since / formationTime
        let mu = couplingExponent
        let lip = min(max(2 * progress - 1, 0), 1)
        return (pow(progress, mu / (1 + mu)), lip * lip * (3 - 2 * lip))
    }

    /// The crater as dug by `time`, seconds after the run's start: nil until its charge fires, the
    /// crater itself from `formedAt`, and in between its bowl and lip grown by `growth(atTime:)`.
    /// Only the shape grows; its ranges stay the final crater's.
    public func grown(atTime time: Float) -> CraterEstimate? {
        let (bowl, lip) = growth(atTime: time)
        return grown(bowl: bowl, lip: lip)
    }

    /// The crater with its bowl grown to the share `bowl` of its size and its lip to `lip` of its
    /// height: nil for no bowl, the crater itself for both whole. The lip's crest and the ejecta's
    /// reach stand out from the bowl's rim as the lip rises, in proportion to the bowl's size, so
    /// that no ejecta lie beyond the rim before the lip has begun to rise.
    public func grown(bowl: Float, lip: Float) -> CraterEstimate? {
        guard bowl > 0 else { return nil }
        guard bowl < 1 || lip < 1 else { return self }
        var grown = self
        grown.apparentRadius *= bowl
        grown.apparentDepth *= bowl
        grown.lipCrestRadius = grown.apparentRadius + (lipCrestRadius - apparentRadius) * bowl * lip
        grown.lipRadius = grown.apparentRadius + (lipRadius - apparentRadius) * bowl * lip
        grown.lipHeight *= lip
        return grown
    }
}
