import Foundation

/// Beauchamp and Matalucci's windows at EMRTC, Socorro (*Dynamics of Window Glass Fracture in
/// Explosions*, SAND98-0598, Sandia, 1998; OSTI 658184; `Fixtures/BeauchampMatalucci1998`): four
/// 4–13 mm panes of 16 × 22 in a window facing small charges, three shots and a fourth filmed,
/// against the envelope's one-way glass (docs/validation.md#sandias-windows).
///
/// The pane is Moore's large-deflection plate at E1300's median strength, annealed or toughened (four
/// times), as the app judges it; the load, the charge's Kingery–Bulmash reflected peak and impulse
/// as a triangle, the charge on the ground, with a TNT equivalence for C4 and ANFO. Once broken, the
/// glass flies at the speed it broke with and what the load gave it after, as the glazing hazard
/// takes it (`GlazingHazard.speedGone`).
public enum SandiaWindows1998 {
    public struct Shot: Decodable, Sendable {
        public var name: String
        public var explosive: String
        public var massLb: Double
        public var standoffFt: Double
        public var nominalPeakPsi: Double
        public var nominalImpulsePsiMs: Double
        public var measuredPeakPsi: Double?
    }

    public struct Pane: Decodable, Sendable {
        public var shot: String
        public var glass: String
        public var thicknessMM: Double
        public var flaws: String
        public var broke: Bool
    }

    public struct Speed: Decodable, Sendable {
        public var shot: String
        public var glass: String
        public var thicknessMM: Double
        public var label: String
        public var ftPerS: Double
    }

    public struct Opening: Decodable, Sendable {
        public var widthM: Double
        public var heightM: Double
    }

    public struct Fixture: Decodable, Sendable {
        public var opening: Opening
        public var shots: [Shot]
        public var panes: [Pane]
        public var speeds: [Speed]

        public func shot(_ name: String) -> Shot? { shots.first { $0.name == name } }
    }

    public static func fixture(from url: URL) throws -> Fixture {
        try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    /// TNT equivalence by mass for the air blast: C4 1.37 (UFC 3-340-02's for pressure), ANFO 0.82
    /// (as for Alsubaei's shots, `PerimeterWallTests.tntFactor`).
    public static func tntFactor(_ explosive: String) -> Double {
        switch explosive {
        case "C4": 1.37
        case "ANFO": Double(PerimeterWallTests.tntFactor)
        default: 1
        }
    }

    /// The shot's charge as TNT, kg, and its range, m.
    public static func charge(_ shot: Shot) -> (tnt: Double, range: Double) {
        (shot.massLb * 0.453_592 * tntFactor(shot.explosive), shot.standoffFt * 0.3048)
    }

    /// Kingery–Bulmash for a hemispherical surface burst at the shot's scaled distance.
    public static func blast(_ shot: Shot) -> KingeryBulmash.Point? {
        let (tnt, range) = charge(shot)
        return KingeryBulmash.point(at: range / cbrt(tnt))
    }

    /// The load on the window: a triangle of the reflected peak and impulse (Pa, in bins of `step`
    /// s from the shock's arrival), optionally scaled to a measured peak at the same duration, or
    /// with the reflected values scaled as the report's nominal incident values stand to
    /// Kingery–Bulmash's (`nominal`).
    public static func load(_ shot: Shot, step: Double, peak: Double? = nil, nominal: Bool = false)
        -> [Double]?
    {
        guard let point = blast(shot) else { return nil }
        let (tnt, _) = charge(shot)
        let psi = 6894.76
        let peakScale = nominal ? shot.nominalPeakPsi * psi / point.incidentPressure : 1
        let impulseScale =
            nominal ? shot.nominalImpulsePsiMs * psi / 1000 / point.incidentImpulse(mass: tnt) : 1
        let impulse = point.reflectedImpulse(mass: tnt) * impulseScale
        let duration = 2 * impulse / (point.reflectedPressure * peakScale)
        let top = peak ?? point.reflectedPressure * peakScale
        let bins = Int((duration / step).rounded(.up)) + 1
        return (0..<bins).map { i in
            let t = (Double(i) + 0.5) * step
            return t < duration ? top * (1 - t / duration) : 0
        }
    }

    /// The pane as the app judges it: Moore's plate at E1300's median strength, toughened glass four
    /// times as strong.
    public static func pane(glass: String, thicknessMM: Double, opening: Opening) -> SDOFSystem {
        // As `EnvelopeConstruction.pane` builds plain glass, as designed.
        let (a, b) = (min(opening.widthM, opening.heightM), max(opening.widthM, opening.heightM))
        let toughened = glass == "tempered"
        return EnvelopePanel.largeDeflectionGlass(
            thickness: thicknessMM / 1000, material: toughened ? .toughenedGlass : .annealedGlass, a: a, b: b,
            sixtySecondStrength: toughened ? 4 * GlassStrength.sixtySecond(area: a * b) : nil)
    }

    public struct Outcome: Sendable {
        /// Cracked, or out of its frame (deflected ten thicknesses, where UFC's edges let go).
        public var broke: Bool { crackedAt != nil || lostAt != nil }
        /// After the shock's arrival, s.
        public var crackedAt: Double?
        public var lostAt: Double?
        public var peakDeflection: Double
        /// The glass's speed into the room once gone, m/s.
        public var speed: Double?
        public var peakStress: Double?
    }

    public static func outcome(
        glass: String, thicknessMM: Double, opening: Opening, shot: Shot, peak: Double? = nil,
        nominal: Bool = false, step: Double = 2e-5
    ) -> Outcome? {
        guard let pressures = load(shot, step: step, peak: peak, nominal: nominal) else { return nil }
        let system = pane(glass: glass, thicknessMM: thicknessMM, opening: opening)
        let response = system.response(pressures: pressures, step: step)
        let speed = GlazingHazard.speedGone(
            response: response, netPa: pressures, binS: step, massPerArea: system.massPerArea)
        return Outcome(
            crackedAt: response.crackedAt, lostAt: response.lostResistanceAt,
            peakDeflection: response.peakDeflection, speed: speed, peakStress: response.peakStress)
    }
}
