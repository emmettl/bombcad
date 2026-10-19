import Foundation

/// Profiled steel sheeting in the one-way damage model of envelopes (docs/profiled-sheeting.md):
/// UFC 3-340-02 §5-34's design of cold-formed steel panels, graded by PDC-TR 06-08's limits, and
/// its fixings checked against EN 1993-1-3's resistances of self-drilling screws.
extension EnvelopePanel {
    /// UFC 3-340-02 eq. 5-26: the dynamic design stress of a cold-formed panel, its nominal yield
    /// times an average strength increase of 1.21 and a dynamic increase of 1.1, whatever the
    /// strain rate.
    public static let coldFormedStrengthIncrease = 1.21 * 1.1

    /// A profiled sheet spanning `span` (its rails' or purlins' spacing) one way: elastic–perfectly
    /// plastic, the ultimate resistance r_u = 7.2 M / L² for a single span or 3.6 (M⁻ + 2 M⁺) / L²
    /// for the first span of a continuous sheet (UFC eqs. 5-29 and 5-30), M the profile's
    /// strength modulus at the dynamic design stress (the profile's yield times `strengthIncrease`,
    /// by default UFC's 1.21 × 1.1 for a nominal yield); its equivalent elastic deflection
    /// X_E = β r_u L⁴ / (E I), β 0.0130 or 0.0062 (eq. 5-31); load–mass factor 0.74 (§5-34.4).
    public static func profiledSheetOneWay(
        profile: SheetProfile, span: Double, continuous: Bool,
        strengthIncrease: Double = coldFormedStrengthIncrease
    ) -> SDOFSystem {
        let (area, secondMoment, _) = profile.perWidth
        // Crests out: pushed in, the span's middle bends its crests into compression, a continuous
        // sheet's supports its troughs.
        let stress = Double(profile.yieldStress) * strengthIncrease
        let positive = stress * Double(profile.designModulus(crestCompressed: true))
        let negative = stress * Double(profile.designModulus(crestCompressed: false))
        let resistance = (continuous ? 3.6 * (negative + 2 * positive) : 7.2 * positive) / (span * span)
        let deflection =
            (continuous ? 0.0062 : 0.0130) * resistance * pow(span, 4)
            / (Double(StructureMaterial.structuralSteel.youngsModulus) * Double(secondMoment))
        return SDOFSystem(
            massPerArea: 7850 * Double(area), loadMassElastic: 0.74, loadMassPlastic: 0.74,
            backbone: [SIMD2(deflection, resistance)], span: span)
    }

    /// The tension one self-drilling screw of `diameter` (m) can hold before it pulls out of a
    /// support `supportThickness` thick of ultimate strength `supportStrength`, or pulls through
    /// the sheet under its washer of `washer` diameter (EN 1993-1-3 Table 8.2: F_o = 0.45 d t_sup
    /// f_u,sup and F_p = d_w t f_u, without partial factors), N.
    public static func screwTension(
        profile: SheetProfile, diameter: Double = 0.0055, washer: Double = 0.016, supportThickness: Double,
        supportStrength: Double = 420e6, sheetStrength: Double = 420e6
    ) -> Double {
        let pullOut = 0.45 * diameter * supportThickness * supportStrength
        let pullThrough = washer * Double(profile.thickness) * sheetStrength
        return min(pullOut, pullThrough)
    }

    /// The largest reaction per metre of support pulling a sheet off its screws (N/m), on a span
    /// `span`: pushed in, it bears on its supports, and only coming back out does it pull on its
    /// screws. UFC Table 3-9's dynamic reaction of a uniformly loaded span, 0.39 R + 0.11 F, R the
    /// resistance at its furthest outward deflection (at most the rebound's share of the ultimate)
    /// and F the largest suction, per metre width.
    public static func sheetPullOff(
        _ system: SDOFSystem, response: SDOFResponse, suction: Double, span: Double
    )
        -> Double
    {
        let outward = -min(response.reboundDeflection, 0)
        let resistance = min(system.stiffness * outward, system.reboundFactor * system.ultimateResistance)
        return (0.39 * resistance + 0.11 * max(suction, 0)) * span
    }
}

extension EnvelopeDamageLevel {
    /// One-way corrugated metal deck with limited tensile membrane capacity, limited by its
    /// connectors (PDC-TR 06-08 Table 4-6): superficial to ductility 1, moderate to 1.8 or 1.3°,
    /// heavy to 3 or 2°, hazardous to 6 or 4°, whichever the response reaches first.
    public static func profiledSheet(ductility: Double, rotationDeg: Double) -> Self {
        if ductility <= 1 { return .none }
        if ductility <= 1.8 && rotationDeg <= 1.3 { return .moderate }
        if ductility <= 3 && rotationDeg <= 2 { return .heavy }
        if ductility <= 6 && rotationDeg <= 4 { return .hazardous }
        return .failed
    }
}

extension EnvelopeDamageAssessment {
    /// A sheeted wall's or roof's damage: one way between its rails or purlins, whatever the
    /// component's own span, from a single span to the first span of a continuous sheet, graded
    /// by PDC-TR 06-08, under the load on the middle third across its span (`EnvelopeComponentLoad
    /// .strip`); failed, blown off, if the reaction pulling it off its screws, as it comes back out
    /// or is sucked, passed what they hold.
    static func profiledSheet(
        _ load: EnvelopeComponentLoad, construction: EnvelopeConstruction, roof: Bool, pressures: [Double],
        peak: Double
    ) -> EnvelopeComponentDamage {
        // Its ribs span on their own: the load on the middle third across the span, where recorded.
        let pressures = load.stripPa == nil ? pressures : load.strip.netPa
        let profile = construction.sheet(roof: roof)
        let span = Double(construction.sheetSpanM ?? 1.8)
        let continuous = construction.sheetContinuous ?? true
        let screws = Double(construction.screwsPerM ?? 3)
        let holding =
            screws
            * EnvelopePanel.screwTension(
                profile: profile, supportThickness: Double(construction.railThicknessM ?? 0.002))
        var rotations: [Double] = []
        var levels: [EnvelopeDamageLevel] = []
        var failedAt: Double?
        var launch: DebrisLaunch?
        for single in [false, true] where single || continuous {
            let system = EnvelopePanel.profiledSheetOneWay(profile: profile, span: span, continuous: !single)
            let response = system.response(pressures: pressures, step: load.binS)
            let rotation = rotation(response, span: span)
            var level = EnvelopeDamageLevel.profiledSheet(
                ductility: response.ductility, rotationDeg: rotation)
            let suction = -(pressures.min() ?? 0)
            if EnvelopePanel.sheetPullOff(system, response: response, suction: suction, span: span) > holding
            {
                level = .failed
                let at = response.reboundTime ?? response.peakTime
                if at < failedAt ?? .infinity {
                    failedAt = at
                    // Off its screws at the furthest of its rebound, at rest, the suction to carry it.
                    launch = Self.launch(
                        time: at, speed: 0, system: system, material: .profiledSteel,
                        thickness: Double(profile.thickness), span: span,
                        rotation: atan(-response.reboundDeflection / (span / 2)))
                }
            }
            rotations.append(rotation)
            levels.append(level)
        }
        var result = EnvelopeComponentDamage(
            id: load.id, owner: load.owner, kind: load.kind, material: .profiledSteel, shortSpanM: span,
            peakNetPa: peak, rotationDeg: rotations.min()!...rotations.max()!,
            levels: levels.min()!...levels.max()!,
            failedAtS: failedAt)
        result.launch = launch
        return result
    }
}
