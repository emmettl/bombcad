import Foundation
import simd

/// A steel column's web under a charge close in: the CODEC project's bunker tests at INSEMEX
/// Petroșani (Timișoara and Petroșani, 2016–2017), as reported by the FRAMEBLAST project
/// (emmettl/bombcad-work#77; Fixtures/Dinu2017/columns.json).
///
/// - **The specimens.** Two identical beam–column assemblies cut from a moment frame: a HEB260
///   column with its flanges cut down to 160 mm, its weak axis in the frame's plane, two
///   half-span IPE beams on extended end plates and a transverse half-span beam on cleats
///   (B. Ahmed, SUSCOS master's thesis, CTU Prague, 2018, §4.2). No axial load beyond its own
///   weight (FRAMEBLAST technical report, stage I, 2017, p. 7).
/// - **The steel**, S275 J0 as measured (Ahmed's Table 5): the web 10 mm, f_y 407 MPa, f_u
///   539 MPa; the flanges 17.5 mm, f_y 420 MPa, f_u 529 MPa; both 27% total elongation at the
///   maximum force.
/// - **The shots** (report, p. 6–7, and Dinu et al., ASCCS 2018, doi:10.4995/ASCCS2018.2018.7186):
///   the specimens were loaded by charges of rising size and falling distance, m1 to m5, facing
///   the web. m4 was at 0.5 m; m5 was 1.815 kg at 0.2 m from the web. 1.815 kg at 0.5 m left
///   "little plastic deformations"; at 0.2 m the web was removed over almost twice the flange's
///   width and the freed flanges bowed out. Gauge S6 on the web read 17,600 µm/m at its peak in
///   m4 (about 0.5 ms) and 5,000–10,000 µm/m to 3 ms; m5 destroyed the gauges.
/// - **The building's shots** (FRAMEBLAST report, stage II, 2018, pp. 7–9): on the full-scale
///   frame's central HEB260 column (full flanges), 2.24 kg at 0.2 m (E5) dished the web and
///   2.52 kg (E6) holed it, each after the shots before it on the same column.
///
/// Assumed here (none is given): the charge is a sphere of TNT; m4 is 1.815 kg, as the ASCCS paper's
/// outcome at 0.5 m reads; the column is 2.5 m long (a storey of the reference frame), clamped at
/// both ends, the charge at mid-height and on the web's centreline, in the open above rigid ground
/// (the bunker's walls are left out); the beams are left out; each shot is on an undamaged column,
/// though the tests' were cumulative.
public enum DinuColumnTest {
    /// HEB260 (EN 10365) with the test's flanges, fillets left out.
    public struct Section: Sendable, Hashable {
        public var depth: Float = 0.260
        public var flangeWidth: Float = 0.160
        public var web: Float = 0.010
        public var flange: Float = 0.0175

        public init(flangeWidth: Float = 0.160) { self.flangeWidth = flangeWidth }

        /// The full HEB260, as the FRAMEBLAST building's columns were.
        public static let full = Section(flangeWidth: 0.260)
    }

    public struct Shot: Sendable, Hashable {
        public var name: String
        /// kg of TNT, and m from the web's face to the charge's centre.
        public var charge: Float
        public var standoff: Float
        /// The outcome reported.
        public var breached: Bool
        public var outcome: String
        /// The column's flanges (m): 160 mm in the bunker, the full 260 mm in the building.
        public var flangeWidth: Float = 0.160

        public var scaledDistance: Float { standoff / cbrt(charge) }
    }

    public static let shots: [Shot] = [
        Shot(
            name: "m4", charge: 1.815, standoff: 0.5, breached: false,
            outcome: "little plastic deformation; web gauge S6 peaked at 17,600 µm/m"),
        Shot(
            name: "m5", charge: 1.815, standoff: 0.2, breached: true,
            outcome: "web removed over almost twice the flange width (about 0.3 m); flanges bowed, held"),
        // The FRAMEBLAST building's central column (2018 report, pp. 7–9), cumulative on one column
        // after E1–E4 at 0.5 m, under floors loaded to 10 kN/m2; the explosive is not named.
        Shot(
            name: "E5", charge: 2.24, standoff: 0.2, breached: false,
            outcome: "web dished, not holed (building, cumulative)", flangeWidth: 0.260),
        Shot(
            name: "E6", charge: 2.52, standoff: 0.2, breached: true,
            outcome: "web holed (building, cumulative after E5)", flangeWidth: 0.260),
    ]

    /// The breach's measure in the bunker: almost twice the flange's width. The building's was not
    /// measured.
    public static func reportedBreachLength(_ shot: Shot) -> Float? {
        shot.breached && shot.flangeWidth < 0.2 ? 2 * shot.flangeWidth : nil
    }

    /// `settings` with the shot's flanges.
    public static func settings(_ settings: Settings, for shot: Shot) -> Settings {
        var settings = settings
        settings.section.flangeWidth = shot.flangeWidth
        return settings
    }

    public struct Settings: Sendable, Hashable {
        public var section = Section()
        public var length: Float = 2.5
        public var elementSize: Float = 0.010
        public var shellLayers = 8
        /// Equivalent plastic strain at which a shell layer tears. Nil: the measured total
        /// elongation at the maximum force, 27%.
        public var failureStrain: Float?
        /// Strain-rate law: Jones's mild steel (S275's grade), or none.
        public var rateLaw = true
        public init() {}
    }

    /// Steel as measured, hardening linearly from f_y to f_u at the elongation at the maximum
    /// force, with S275's rate law (by its grade, not its measured yield, which is that of a
    /// stronger grade).
    public static func steel(
        name: String, yield fy: Float, ultimate fu: Float, elongation: Float = 0.27, settings: Settings
    ) -> StructureMaterial {
        let modulus: Float = 210e9
        var material = StructureMaterial(
            name: name, density: 7850, youngsModulus: modulus, poissonRatio: 0.3, yieldStress: fy,
            hardeningModulus: (fu - fy) / (elongation - fy / modulus),
            failureStrain: settings.failureStrain ?? elongation)
        if settings.rateLaw {
            let c = SteelRateLaw.constants(yield: 275e6)
            material.rateLaw = .cowperSymonds(d: c.x, q: c.y)
        }
        return material
    }

    /// The air around the column: room for the charge beyond its web, and for the blast to wrap
    /// round it.
    public static func domain(_ settings: Settings) -> SIMD3<Float> { SIMD3(0.8, 1.3, settings.length + 0.3) }

    /// Plan position of the column's axis; the web faces +y.
    public static let axis = SIMD2<Float>(0.4, 0.4)

    /// The flanges (normal to x) and the web (normal to y), the column standing on the ground.
    public static func solids(_ settings: Settings) -> (flanges: [Box], web: Box) {
        let s = settings.section
        let (cx, cy, length) = (axis.x, axis.y, settings.length)
        let flanges = [Float(-1), 1].map { side -> Box in
            let outer = cx + side * s.depth / 2
            let inner = outer - side * s.flange
            return Box(
                min: SIMD3(min(inner, outer), cy - s.flangeWidth / 2, 0),
                max: SIMD3(max(inner, outer), cy + s.flangeWidth / 2, length))
        }
        let web = Box(
            min: SIMD3(cx - s.depth / 2 + s.flange, cy - s.web / 2, 0),
            max: SIMD3(cx + s.depth / 2 - s.flange, cy + s.web / 2, length))
        return (flanges, web)
    }

    public static func model(_ settings: Settings) -> StructureModel {
        let (flanges, web) = solids(settings)
        let flangeSteel = steel(
            name: "S275 flange (measured)", yield: 420e6, ultimate: 529e6, settings: settings)
        let webSteel = steel(name: "S275 web (measured)", yield: 407e6, ultimate: 539e6, settings: settings)
        var model = StructureModel(
            solids: flanges + [web], material: flangeSteel, elementSize: settings.elementSize, fixedBase: true
        )
        model.elementKind = .shell
        model.shellLayers = settings.shellLayers
        model.solidMaterial = [nil, nil, webSteel]
        // The column is straight as drawn: a bow along it is not what decides the web.
        model.memberImperfections = false
        return model
    }

    /// The charge's centre: `standoff` from the web's face, on its centreline, at mid-height.
    public static func chargePosition(_ shot: Shot, settings: Settings) -> SIMD3<Float> {
        SIMD3(axis.x, axis.y + settings.section.web / 2 + shot.standoff, settings.length / 2)
    }

    public static func scenario(_ shot: Shot, settings: Settings = Settings()) -> Scenario {
        let c = chargePosition(shot, settings: settings)
        let face = axis.y + settings.section.web / 2
        // On the web's back, as a gauge glued there would be, and in front of it at the charge's height.
        let gauges = [
            Gauge("Web, loaded face", at: SIMD3(axis.x, face + 0.003, c.z)),
            Gauge("Web, back face", at: SIMD3(axis.x, axis.y - settings.section.web / 2 - 0.003, c.z)),
        ]
        return Scenario(
            name: "Dinu column \(shot.name)", domainSize: domain(settings), boxes: [],
            charge: Charge(mass: shot.charge, position: c), gauges: gauges, structure: model(settings))
    }

    /// What the run left of the column.
    public struct Result: Sendable {
        public var shot: Shot
        /// Web shells removed, and the breach's extent along the column and across the web (m):
        /// the span of the removed elements' centres plus an element.
        public var webRemoved: Int
        public var breachLength: Float
        public var breachWidth: Float
        public var flangeRemoved: Int
        /// The web's movement away from the charge at its centre, at the charge's height: the most
        /// it reached and at the end (m).
        public var webPeak: Float
        public var webFinal: Float
        /// The largest equivalent plastic strain in the web and in the flanges at the end, over the
        /// shells left.
        public var webPlasticStrain: Float
        public var flangePlasticStrain: Float
        /// The flange tips' largest outward movement at the end (m), and the column's sideways
        /// movement away from the charge at mid-height (m), the flanges' mean.
        public var flangeSpread: Float
        public var columnSway: Float
        /// Reflected load on the web's face at the charge's height: peak (Pa) and impulse (Pa s).
        public var reflectedPeak: Float
        public var reflectedImpulse: Float
        public var duration: Double
        public var wallSeconds: Double

        package init(
            shot: Shot, webRemoved: Int, breachLength: Float, breachWidth: Float, flangeRemoved: Int,
            webPeak: Float, webFinal: Float, webPlasticStrain: Float, flangePlasticStrain: Float,
            flangeSpread: Float, columnSway: Float, reflectedPeak: Float, reflectedImpulse: Float,
            duration: Double, wallSeconds: Double
        ) {
            self.shot = shot
            self.webRemoved = webRemoved
            self.breachLength = breachLength
            self.breachWidth = breachWidth
            self.flangeRemoved = flangeRemoved
            self.webPeak = webPeak
            self.webFinal = webFinal
            self.webPlasticStrain = webPlasticStrain
            self.flangePlasticStrain = flangePlasticStrain
            self.flangeSpread = flangeSpread
            self.columnSway = columnSway
            self.reflectedPeak = reflectedPeak
            self.reflectedImpulse = reflectedImpulse
            self.duration = duration
            self.wallSeconds = wallSeconds
        }

        /// Whether the run reads as the test did: breached where it was, and not where it was not.
        public var agrees: Bool { (webRemoved > 0) == shot.breached }
    }

    /// The breach's extent from the removed web elements' centres (one coordinate each), plus an
    /// element; zero when none is removed.
    public static func extent(_ centres: [Float], elementSize: Float) -> Float {
        guard let low = centres.min(), let high = centres.max() else { return 0 }
        return high - low + elementSize
    }
}
