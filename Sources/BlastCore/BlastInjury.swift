import Foundation
import simd

/// The US explosives safety standards' blast distances, `D = K W^(1/3)`, K in ft/lb^(1/3) with W
/// the net explosive weight in lb, or in m/kg^(1/3) with W in kg (K × 0.3967): DoD 4145.26-M
/// (2008) §C5.6.2 and §C5.18.6.3, which gives both. Policy distances, not predictions: each is
/// where the standard expects the overpressure it names from a bare charge in the open.
public struct KFactorDistance: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    /// ft/lb^(1/3) and m/kg^(1/3).
    public var k: Float
    public var metric: Float
    /// The overpressure the standard names at it, Pa; nil where it names none.
    public var overpressurePa: Float?
    /// What the standard uses it for.
    public var use: String
    /// The least distance the standard allows whatever the weight, m; nil where it sets none.
    public var minimumM: Float? = nil

    /// The distance for `kilograms` of TNT-equivalent net explosive weight by the K-factor alone, m.
    public func distance(kilograms: Float) -> Float { metric * cbrt(max(kilograms, 0)) }

    /// The distance the standard requires for `kilograms`: the K-factor's, but never under its
    /// minimum, m.
    public func requiredDistance(kilograms: Float) -> Float {
        max(distance(kilograms: kilograms), minimumM ?? 0)
    }

    /// Unbarricaded intraline distance, 3.5 psi (§C5.6.2.4).
    public static let k18 = KFactorDistance(
        name: "K18", k: 18, metric: 7.14, overpressurePa: 24_000, use: "Unbarricaded intraline distance")
    /// Public traffic route distance, 2.3 psi (§C5.6.2.5).
    public static let k24 = KFactorDistance(
        name: "K24", k: 24, metric: 9.52, overpressurePa: 15_800, use: "Public traffic route distance")
    /// Inhabited building distance, 1.2 psi (§C5.6.2.7; up to K50 at 0.9 psi).
    public static let k40 = KFactorDistance(
        name: "K40", k: 40, metric: 15.87, overpressurePa: 8_300, use: "Inhabited building distance")
    /// Non-essential personnel at intentional detonations, not less than 381 m (§C5.18.6.3).
    public static let k328 = KFactorDistance(
        name: "K328", k: 328, metric: 130.1, overpressurePa: nil,
        use: "Non-essential personnel at intentional detonations (not less than 381 m)", minimumM: 381)

    public static let all = [k18, k24, k40, k328]
}

/// The distance an exposure needs from a charge, never shorter than the published distance that
/// applies: the inhabited building distance (K40), and for a cased charge DoD's default hazardous
/// fragment distance for items not tested (DoD 4145.26-M Table AP2.T2, "OPEN"); BombCAD's own
/// hazardous fragment distance is shown beside them as an estimate (0.58–1.02 of DoD's
/// test-derived distances, short with thick walls: fragments.md), and governs only where larger.
public struct MinimumSafeDistance: Codable, Sendable, Equatable {
    public var overpressureM: Float
    /// DoD's default for a cased charge of this weight; nil for a bare charge, whose distance in the
    /// open is K40 (DoD 4145.26-M §C5.8.1.7.1.8).
    public var publishedFragmentM: Float?
    /// BombCAD's estimate, where its fragments were flown.
    public var fragmentM: Float?
    /// BombCAD's hazardous debris distance from the envelope components that failed and were thrown
    /// (`EnvelopeDebris`), an estimate like the fragments'; nil where none was (left out of older
    /// records).
    public var debrisM: Float? = nil
    /// DoD's default for a charge inside a building, whose debris it throws: DESR 6055.09 Table
    /// V3.E3.T2's "Structure" column; nil in the open (left out of older records).
    public var publishedDebrisM: Float? = nil

    public var distanceM: Float {
        max(overpressureM, publishedFragmentM ?? 0, fragmentM ?? 0, debrisM ?? 0, publishedDebrisM ?? 0)
    }

    public var governedBy: String {
        let distance = distanceM
        let others = max(overpressureM, publishedFragmentM ?? 0, fragmentM ?? 0)
        if let publishedDebrisM, publishedDebrisM == distance, publishedDebrisM > others,
            publishedDebrisM >= debrisM ?? 0
        {
            return "DoD's default structure debris distance"
        }
        if let debrisM, debrisM == distance,
            debrisM > max(others, publishedDebrisM ?? 0)
        {
            return "BombCAD's envelope debris distance"
        }
        if let fragmentM, fragmentM == distance, fragmentM > max(overpressureM, publishedFragmentM ?? 0) {
            return "BombCAD's fragment distance"
        }
        if let publishedFragmentM, publishedFragmentM == distance, publishedFragmentM > overpressureM {
            return "DoD's default fragment distance"
        }
        return "overpressure (K40)"
    }

    /// For `kilograms` of TNT-equivalent net explosive weight, cased (fragments flown) or bare,
    /// with any envelope `debris` thrown, and `inStructure` when the charge is inside a building.
    public init(
        kilograms: Float, fragments: GroundHazard?, cased: Bool? = nil, debris: GroundHazard? = nil,
        inStructure: Bool = false
    ) {
        publishedDebrisM = inStructure ? Self.defaultStructureDebrisDistance(kilograms: kilograms) : nil
        overpressureM = KFactorDistance.k40.distance(kilograms: kilograms)
        publishedFragmentM =
            (cased ?? (fragments != nil)) ? Self.defaultFragmentDistance(kilograms: kilograms) : nil
        fragmentM = fragments?.hazardDistance
        debrisM = debris?.hazardDistance
    }

    /// DoD 4145.26-M Table AP2.T2's hazardous fragment distance for HD 1.1 in the open, m:
    /// `107.87 + 24.14 ln Q` under 45.4 kg (not less than 71.9 m), `-251.87 + 118.56 ln Q` to
    /// 204.1 kg, and 381 m above (Equations C9.T2-3 and C9.T2-4).
    public static func defaultFragmentDistance(kilograms q: Float) -> Float {
        guard q > 0 else { return 0 }
        if q > 204.1 { return 381 }
        if q < 45.4 { return max(107.87 + 24.14 * log(q), 71.9) }
        return -251.87 + 118.56 * log(q)
    }

    /// DESR 6055.09 (Edition 1, Change 2) Table V3.E3.T2's hazardous fragment distance for HD 1.1
    /// in a structure that can contribute to the debris hazard, m: 61.0 m to 14.1 kg,
    /// `-251.87 + 118.56 ln Q` to 204.1 kg (EQN V3.E3.T2-10), and 381 m above.
    public static func defaultStructureDebrisDistance(kilograms q: Float) -> Float {
        guard q > 0 else { return 0 }
        if q > 204.1 { return 381 }
        if q <= 14.1 { return 61 }
        return -251.87 + 118.56 * log(q)
    }

    public var summary: String {
        String(
            format: "minimum safe distance %.0f m, %@ governing (K40 %.0f m", distanceM, governedBy,
            overpressureM)
            + (publishedDebrisM.map { String(format: "; DoD's default structure debris distance %.0f m", $0) }
                ?? "")
            + (publishedFragmentM.map { String(format: "; DoD's default fragment distance %.0f m", $0) } ?? "")
            + (fragmentM.map {
                String(
                    format:
                        "; BombCAD's fragment distance %.0f m, an estimate that reads up to two-fifths short",
                    $0)
            } ?? "")
            + (debrisM.map { String(format: "; BombCAD's envelope debris distance %.0f m, an estimate", $0) }
                ?? "")
            + ")"
    }
}

/// Injury to a person from the blast wave itself, by published criteria for an ideal (Friedlander)
/// pulse from animal tests: eardrum rupture (UFC 3-340-02 §1-11), the threshold of lung injury
/// (Bowen et al., 1968) and 50% lethality from lung injury (Bass et al., 2008), the last two as
/// Teland (FFI-rapport 2012/00539) gives their curves. Pressures are overpressures, Pa; durations
/// the positive phase's, s.
public enum BlastInjury {
    public enum Level: Int, Codable, Sendable, CaseIterable, Comparable {
        case none, eardrumThreshold, eardrum50, lungThreshold, lethality50

        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

        public var title: String {
            switch self {
            case .none: "None"
            case .eardrumThreshold: "Eardrum rupture threshold"
            case .eardrum50: "50% eardrum rupture"
            case .lungThreshold: "Lung injury threshold"
            case .lethality50: "50% lethality (lung)"
            }
        }
    }

    public static let ambient: Double = 101_325

    /// Peak dynamic pressure behind a shock of overpressure `p`, `5p² / (2p + 14 p0)`.
    public static func dynamic(_ p: Double, ambient p0: Double = ambient) -> Double {
        5 * p * p / (2 * p + 14 * p0)
    }

    /// Normally reflected overpressure off a rigid wall, `(8p² + 14 p p0) / (p + 7 p0)`.
    public static func reflected(_ p: Double, ambient p0: Double = ambient) -> Double {
        (8 * p * p + 14 * p * p0) / (p + 7 * p0)
    }

    /// The duration as the curves take it, ms: scaled to a 70 kg person and to sea-level pressure
    /// (Bowen's, Teland's Equation 2.1).
    public static func scaledDuration(_ seconds: Double, massKg: Double = 70, ambient p0: Double = ambient)
        -> Double
    {
        seconds * 1000 * cbrt(70 / massKg) * (p0 / 101_325).squareRoot()
    }

    /// Bowen's 50% lethality curve for a person against a wall, on the reflected overpressure:
    /// `423 (1 + 6.76 T^-1.064)` kPa, T in scaled ms.
    public static func bowenLethality50(duration t: Double) -> Double {
        423e3 * (1 + 6.76 * pow(max(t, 1e-3), -1.064))
    }

    /// Bass's 50% lethality curve for durations under 30 ms, on the incident overpressure, the
    /// same against a wall or standing in the open: `89.5 (1 + 6.7 T^-0.83)` kPa.
    public static func bassLethality50(duration t: Double) -> Double {
        89.5e3 * (1 + 6.7 * pow(max(t, 1e-3), -0.83))
    }

    /// UFC 3-340-02's eardrum rupture: its threshold at 5 psi and 50% at 15 psi, of the effective
    /// pressure (the highest of the incident, incident plus dynamic, and reflected).
    public static let eardrumThresholdPa: Double = 34_474
    public static let eardrum50Pa: Double = 103_421

    /// Where a person stands: in the open (eardrum and Bowen's lung dose incident plus dynamic
    /// pressure), or against a wall facing the charge (the reflected pressure); Bass's lethality
    /// takes the incident pressure either way.
    public enum Stance: String, Codable, Sendable { case open, againstWall }

    /// Whether a pulse of incident overpressure `p` and positive duration `duration` (s) meets
    /// `level`'s criterion for a person standing as `stance` says.
    public static func meets(
        _ level: Level, peak p: Double, duration: Double, stance: Stance = .open, ambient p0: Double = ambient
    ) -> Bool {
        let t = scaledDuration(duration, ambient: p0)
        let dose = stance == .open ? p + dynamic(p, ambient: p0) : reflected(p, ambient: p0)
        switch level {
        case .none: return true
        case .eardrumThreshold: return dose >= eardrumThresholdPa
        case .eardrum50: return dose >= eardrum50Pa
        // Bowen's threshold is a fifth of his 50% curve, which takes a reflected pressure: the
        // open field's dose stands in for it, as Bowen's open-field curve has it.
        case .lungThreshold: return dose >= bowenLethality50(duration: t) / 5
        // Bass's short-duration curve, under 30 ms.
        case .lethality50: return t < 30 && p >= bassLethality50(duration: t)
        }
    }

    /// The worst level a pulse meets.
    public static func level(
        peak p: Double, duration: Double, stance: Stance = .open, ambient p0: Double = ambient
    ) -> Level {
        Level.allCases.reversed().first {
            meets($0, peak: p, duration: duration, stance: stance, ambient: p0)
        }
            ?? .none
    }

    /// How far each level reaches from a bare charge of `kilograms` of TNT in free air (a surface
    /// burst counts as 1.8 times its mass), by the Kingery–Bulmash curves, m; nil where it does not
    /// reach the curves' nearest 0.2 m/kg^(1/3).
    public static func freeFieldRadii(
        kilograms: Double, surfaceBurst: Bool = true, stance: Stance = .open
    ) -> [Level: Double] {
        // The curves are a surface burst's; a free-air burst is one of 1/1.8 its mass.
        let w = surfaceBurst ? kilograms : kilograms / 1.8
        let scale = cbrt(w)
        func meets(_ target: Level, at r: Double) -> Bool {
            let z = r / scale
            guard let point = KingeryBulmash.point(at: z), let d = KingeryBulmash.scaledDuration(at: z) else {
                return false
            }
            return BlastInjury.meets(
                target, peak: point.incidentPressure, duration: d * scale, stance: stance)
        }
        var radii: [Level: Double] = [:]
        for target in Level.allCases.dropFirst() {
            var low = 0.2 * scale
            var high = 40 * scale
            guard meets(target, at: low) else { continue }
            for _ in 0..<60 {
                let r = (low + high) / 2
                if meets(target, at: r) { low = r } else { high = r }
            }
            radii[target] = (low + high) / 2
        }
        return radii
    }
}

/// Blast injury over a horizontal plane at a standing person's height, from the run's own peak
/// overpressure and positive impulse there (`ExposurePlaneSnapshot`), so with the reflections and
/// channelling the free field's radii miss: each probe's worst level for a person standing in the
/// open, and against a wall facing the charge, the positive phase taken as triangular
/// (duration twice the impulse over the peak).
public struct InjuryField: Codable, Sendable, Equatable {
    public var nx: Int
    public var ny: Int
    public var spacingM: Float
    public var heightM: Float
    /// The charge on the map.
    public var centre: SIMD2<Float>
    /// Each probe's level (`BlastInjury.Level.rawValue`), x fastest, for each stance; -1 where the
    /// probe is not read (beside a solid, or never reached).
    public var open: [Int8]
    public var againstWall: [Int8]

    public init(
        _ snapshot: ExposurePlaneSnapshot, centre: SIMD2<Float>, ambient: Double = BlastInjury.ambient
    ) {
        nx = snapshot.nx
        ny = snapshot.ny
        spacingM = snapshot.cellSizeM
        heightM = snapshot.heightM
        self.centre = centre
        func levels(_ stance: BlastInjury.Stance) -> [Int8] {
            zip(snapshot.peakPa, snapshot.positiveImpulsePaS).map { peak, impulse in
                guard let peak, let impulse, peak > 0 else { return -1 }
                let duration = 2 * Double(impulse) / Double(peak)
                return Int8(
                    BlastInjury.level(
                        peak: Double(peak), duration: duration, stance: stance, ambient: ambient
                    )
                    .rawValue)
            }
        }
        open = levels(.open)
        againstWall = levels(.againstWall)
    }

    /// A probe's position on the map.
    public func position(_ i: Int, _ j: Int) -> SIMD2<Float> {
        SIMD2((Float(i) + 0.5) * spacingM, (Float(j) + 0.5) * spacingM)
    }

    /// How far from the charge `level` reaches, the furthest probe at or past it, m; nil where none.
    public func reach(_ level: BlastInjury.Level, stance: BlastInjury.Stance = .open) -> Float? {
        let levels = stance == .open ? open : againstWall
        var furthest: Float?
        for j in 0..<ny {
            for i in 0..<nx where levels[i + nx * j] >= Int8(level.rawValue) {
                let d = simd_distance(position(i, j), centre)
                furthest = max(furthest ?? 0, d)
            }
        }
        return furthest
    }

    public var summary: String {
        let levels = BlastInjury.Level.allCases.dropFirst()
        func line(_ stance: BlastInjury.Stance) -> String {
            levels.map { level in
                level.title.lowercased()
                    + (reach(level, stance: stance).map { String(format: " to %.1f m", $0) } ?? " nowhere")
            }.joined(separator: "; ")
        }
        return String(format: "At %.1f m up, in the open: ", heightM) + line(.open)
            + "; against a wall facing it: "
            + line(.againstWall)
    }
}
