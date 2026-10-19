import Foundation

/// Cross-laminated timber in the one-way damage model of envelopes (docs/building-envelopes.md):
/// a panel spanning one way on its strong axis, elastic–perfectly plastic as the Tyndall tests'
/// single-degree-of-freedom analyses take it, graded by the displacement ductility limits WoodWorks
/// TR-18-06.2 (§6.3) recommends from those tests for CLT in bending without axial load.
extension EnvelopePanel {
    /// The panel's lamellae for its thickness: odd, of about 35 mm, at least three.
    static func crossLaminatedLamellae(thickness: Double) -> Int {
        let count = max(3, Int((thickness / 0.035).rounded()))
        return count % 2 == 1 ? count : count + 1
    }

    /// CLT of C24 lamellae (`TimberProperties.crossLaminatedPanel`) spanning `span` one way on its
    /// outer lamellae's grain, simply supported, or as a cantilever from its foot:
    /// - its bending stiffness EI from the lamellae (E₀ along, E₉₀ across) and its shear stiffness GA
    ///   by the shear analogy (EN 1995-1-1:2025), deflecting as 5 r L⁴ / 384 EI + r L² / 8 GA
    ///   (L⁴ / 8 EI + L² / 2 GA for a cantilever);
    /// - its ultimate resistance 8 M / L² (2 M / L²), M the bending strength's mean times the
    ///   dynamic increase of 1.28 (Poulin et al.) times EI / (E₀ t / 2);
    /// - the load–mass factors of a uniformly loaded beam, 0.78 elastic and 0.66 plastic simply
    ///   supported, 0.65 and 0.66 as a cantilever (Biggs).
    public static func crossLaminatedOneWay(thickness: Double, span: Double, cantilever: Bool = false)
        -> SDOFSystem
    {
        let count = crossLaminatedLamellae(thickness: thickness)
        let timber = TimberProperties.crossLaminatedPanel(count)
        let t = thickness / Double(count)
        let along = Double(timber.alongGrain)
        var stiffness = 0.0
        var compliance = 0.0
        for l in 0..<count {
            let centre = (Double(l) + 0.5) * t - thickness / 2
            let crossed = l % 2 == 1
            stiffness +=
                (crossed ? Double(timber.acrossGrain) : along) * (t * t * t / 12 + t * centre * centre)
            let shear = crossed ? Double(timber.rollingShearModulus) : Double(timber.shearModulus)
            compliance += (l == 0 || l == count - 1 ? 0.5 : 1) * t / shear
        }
        let lever = thickness - t
        let shearStiffness = lever * lever / compliance
        let moment =
            Double(timber.tensionAlong * timber.strengthFactor) * stiffness / (along * thickness / 2)
        let resistance = (cantilever ? 2 : 8) * moment / (span * span)
        let flexibility =
            cantilever
            ? pow(span, 4) / (8 * stiffness) + span * span / (2 * shearStiffness)
            : 5 * pow(span, 4) / (384 * stiffness) + span * span / (8 * shearStiffness)
        return SDOFSystem(
            massPerArea: Double(TimberGrade.c24.density) * thickness,
            loadMassElastic: cantilever ? 0.65 : 0.78,
            loadMassPlastic: 0.66, backbone: [SIMD2(resistance * flexibility, resistance)], span: span)
    }
}

extension EnvelopeDamageLevel {
    /// CLT in bending without axial load (WoodWorks TR-18-06.2 §6.3, from the Tyndall tests):
    /// superficial to ductility 1, moderate to 1.5, heavy to 1.75, hazardous to 2, blown out past.
    public static func crossLaminated(ductility: Double) -> Self {
        if ductility < 1 { return .none }
        if ductility < 1.5 { return .moderate }
        if ductility < 1.75 { return .heavy }
        if ductility < 2 { return .hazardous }
        return .failed
    }
}

extension EnvelopeDamageAssessment {
    /// A CLT wall's or roof's damage: one way over `span` (its short span, or its height as a
    /// freestanding cantilever), graded by WoodWorks' limits; failed, blown out, past ductility 2.
    static func crossLaminated(
        _ load: EnvelopeComponentLoad, construction: EnvelopeConstruction, roof: Bool, span: Double,
        cantilever: Bool = false, pressures: [Double], peak: Double, turned: Double = 1
    ) -> EnvelopeComponentDamage {
        let thickness = Double(roof ? construction.roofThicknessM : construction.wallThicknessM)
        let system = EnvelopePanel.crossLaminatedOneWay(
            thickness: thickness, span: span, cantilever: cantilever)
        let response = system.response(
            pressures: pressures, step: load.binS, watch: 2 * system.equivalentElasticDeflection)
        let level = EnvelopeDamageLevel.crossLaminated(ductility: response.ductility)
        let rotation =
            cantilever
            ? atan(max(response.peakDeflection, -response.reboundDeflection) / span) * 180 / .pi
            : Self.rotation(response, span: span)
        var result = EnvelopeComponentDamage(
            id: load.id, owner: load.owner, kind: load.kind, material: .crossLaminatedTimber,
            shortSpanM: span,
            peakNetPa: peak, rotationDeg: rotation...rotation, levels: level...level,
            failedAtS: level == .failed ? response.peakTime : nil, cantilever: cantilever ? true : nil)
        // Blown out as it passes ductility 2, at its speed then.
        result.launch =
            level == .failed
            ? Self.launch(
                time: response.passedAt, speed: response.velocityPassing.map { $0 * turned }, system: system,
                material: .crossLaminatedTimber, thickness: thickness, span: span,
                rotation: atan(2 * system.equivalentElasticDeflection / (cantilever ? span : span / 2))) : nil
        return result
    }
}
