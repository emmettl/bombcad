import Foundation
import simd

/// A steel column's web under a charge close in: the CODEC project's bunker tests at INSEMEX
/// Petroșani (emmettl/bombcad-work#77; Fixtures/Dinu2017/columns.json), from the test paper,
/// Dinu, Marginean, Dubina, Kovacs and Ghicioi, Procedia Engineering 210 (2017) 377–385,
/// doi:10.1016/j.proeng.2017.11.091.
///
/// - **The specimens** (§2, Figs. 1–2). Two identical beam–column assemblies cut from a moment
///   frame: a HEB260 column 1.99 m long with its flanges cut down to 160 mm, its weak axis in the
///   frame's plane, on supports at both ends; two half-span IPE220 beams on extended 16 mm end
///   plates (M16 10.9) bolted to the flanges, and a transverse half-span IPE220 on an
///   L100×50×10 cleat on the web, its far end on the bunker's wall. No gravity load.
/// - **The steel**, S275 J0 as measured (Table 1): the web 10 mm, f_y 407 MPa, f_u 539 MPa; the
///   flanges 17.5 mm, f_y 420 MPa, f_u 529 MPa; both 27% total elongation at the maximum force.
/// - **The shots** (§3): charges of TNT equivalence 1, assembled from cylindrical units of
///   0.121 kg and hung from the ceiling, 1.25 m above the column's base and 0.30 m below the
///   beams' bottom flanges. m1–m4 (0.121, 0.484, 0.968 and 1.815 kg) at 0.5 m from the web's
///   face, then m5, 1.815 kg at 0.2 m, cumulative on each specimen (specimen 1 skipped m3).
///   - m4 left the web dished out of plane by about 22 mm (specimen 1) and 3 mm (specimen 2), not
///     cracked. Gauge S6 on specimen 2's web, 0.5 m below the beams and 80 mm off the web's
///     centreline, read 1.78% at its peak and 0.61% after, at up to 100 s⁻¹.
///   - m5 removed the web over almost 600 mm (specimen 1) and almost 500 mm (specimen 2), torn
///     along the fillets; the photographs (Fig. 3b–c) show the hole's top at the beams.
/// - **The building's shots** (FRAMEBLAST report, stage II, 2018, pp. 7–9): on the full-scale
///   frame's central HEB260 column (full flanges), 2.24 kg at 0.2 m (E5) dished the web and
///   2.52 kg (E6) holed it, each after the shots before it on the same column.
///
/// Assumed here: the charge is a sphere, on the web's centreline, in the open above rigid ground
/// (the bunker's walls are left out); both ends are held from moving but free to turn; the beams
/// are reduced to what they hold at the joint (`restraint(at:settings:)`); each shot is on an
/// undamaged column, though the tests' were cumulative. The building's column keeps the earlier
/// stand-in: 2.5 m, clamped at both ends, no beams.
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
        /// The FRAMEBLAST building's column rather than the bunker's specimen.
        public var inBuilding: Bool { flangeWidth > 0.2 }
    }

    public static let shots: [Shot] = [
        Shot(
            name: "m4", charge: 1.815, standoff: 0.5, breached: false,
            outcome: "web dished 22 and 3 mm, not cracked; gauge S6 1.78% at its peak, 0.61% after"),
        Shot(
            name: "m5", charge: 1.815, standoff: 0.2, breached: true,
            outcome: "web removed over almost 600 and 500 mm, torn along the fillets"),
        // The FRAMEBLAST building's central column (2018 report, pp. 7–9), cumulative on one column
        // after E1–E4 at 0.5 m, under floors loaded to 10 kN/m2; the explosive is not named.
        Shot(
            name: "E5", charge: 2.24, standoff: 0.2, breached: false,
            outcome: "web dished, not holed (building, cumulative)", flangeWidth: 0.260),
        Shot(
            name: "E6", charge: 2.52, standoff: 0.2, breached: true,
            outcome: "web holed (building, cumulative after E5)", flangeWidth: 0.260),
    ]

    /// The breach's length along the column in the bunker, specimen 2's and specimen 1's ("almost"
    /// 500 and 600 mm, §3). The building's was not measured.
    public static func reportedBreachLength(_ shot: Shot) -> ClosedRange<Float>? {
        shot.breached && !shot.inBuilding ? 0.5...0.6 : nil
    }

    /// The web's permanent dish in m4, specimen 2's and specimen 1's (§3).
    public static let reportedDish: ClosedRange<Float> = 0.003...0.022

    /// `settings` with the shot's flanges, and for the building's column its earlier stand-in.
    public static func settings(_ settings: Settings, for shot: Shot) -> Settings {
        var settings = settings
        settings.section.flangeWidth = shot.flangeWidth
        if shot.inBuilding {
            settings.length = 2.5
            settings.pinnedEnds = false
            settings.joint = false
        }
        return settings
    }

    public struct Settings: Sendable, Hashable {
        public var section = Section()
        /// The column between its end plates (Fig. 2), and the charge's height above its base (§3).
        public var length: Float = 1.99
        public var chargeHeight: Float = 1.25
        /// Ends held from moving but free to turn, as on the test's supports; false clamps them.
        public var pinnedEnds = true
        /// The beams' joint 0.30 m above the charge, reduced to what it holds (`restraint`).
        public var joint = true
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

    /// The charge's centre: `standoff` from the web's face, on its centreline, `chargeHeight` up.
    public static func chargePosition(_ shot: Shot, settings: Settings) -> SIMD3<Float> {
        SIMD3(axis.x, axis.y + settings.section.web / 2 + shot.standoff, settings.chargeHeight)
    }

    /// The beams' bottom flanges, 0.30 m above the charge (§3).
    public static func beamBottom(_ settings: Settings) -> Float { settings.chargeHeight + 0.30 }

    /// Gauge S6's place on the web: 0.5 m below the beams' bottom flanges and 80 mm to either side
    /// of the web's centreline (Fig. 2), on the web's midsurface.
    public static func gaugeS6(_ settings: Settings) -> [SIMD3<Float>] {
        let z = beamBottom(settings) - 0.5
        return [Float(-1), 1].map { SIMD3(axis.x + $0 * 0.08, axis.y, z) }
    }

    /// What holds a node of the column still, by axis (x, y, z), its rotation left free:
    /// - **the ends**, when pinned, in every direction;
    /// - **the joint** (Fig. 2, section A-A), when kept. The end plates, 370 mm tall from 75 mm
    ///   below the beams' bottom flanges, bolt the IPE220s to the flanges: the flanges there are
    ///   held in x and y. The transverse beam's cleat holds the web's middle 100 mm in y over the
    ///   beam's 220 mm depth, the beam's far end being on the bunker's wall. The beams are long and
    ///   heavy beside the few milliseconds of the web's response, so held is taken as still.
    public static func restraint(at p: SIMD3<Float>, settings: Settings) -> (x: Bool, y: Bool, z: Bool) {
        let s = settings.section
        let tolerance: Float = 1e-4
        if settings.pinnedEnds && (p.z < tolerance || p.z > settings.length - tolerance) {
            return (true, true, true)
        }
        guard settings.joint else { return (false, false, false) }
        let bottom = beamBottom(settings)
        let onFlange = abs(abs(p.x - axis.x) - (s.depth - s.flange) / 2) < 1e-3
        if onFlange && p.z > bottom - 0.075 - tolerance && p.z < bottom + 0.295 + tolerance {
            return (true, true, false)
        }
        let onWeb = abs(p.y - axis.y) < 1e-3 && !onFlange
        if onWeb && abs(p.x - axis.x) < 0.05 + tolerance && p.z > bottom - tolerance
            && p.z < bottom + 0.22 + tolerance
        {
            return (false, true, false)
        }
        return (false, false, false)
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
        /// the span of the removed elements' centres plus an element; and how far it reaches above
        /// and below the charge's height (m, to the outer elements' edges, negative if it does not
        /// reach that side).
        public var webRemoved: Int
        public var breachLength: Float
        public var breachWidth: Float
        public var breachAbove: Float
        public var breachBelow: Float
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
        /// Equivalent plastic strain at the end in the web shells at gauge S6's place, the larger
        /// side's (nil when torn away).
        public var gaugeS6PlasticStrain: Float?
        /// Reflected load on the web's face at the charge's height: peak (Pa) and impulse (Pa s).
        public var reflectedPeak: Float
        public var reflectedImpulse: Float
        public var duration: Double
        public var wallSeconds: Double

        package init(
            shot: Shot, webRemoved: Int, breachLength: Float, breachWidth: Float, breachAbove: Float,
            breachBelow: Float, flangeRemoved: Int, webPeak: Float, webFinal: Float,
            webPlasticStrain: Float, flangePlasticStrain: Float, flangeSpread: Float, columnSway: Float,
            gaugeS6PlasticStrain: Float?, reflectedPeak: Float, reflectedImpulse: Float,
            duration: Double, wallSeconds: Double
        ) {
            self.shot = shot
            self.webRemoved = webRemoved
            self.breachLength = breachLength
            self.breachWidth = breachWidth
            self.breachAbove = breachAbove
            self.breachBelow = breachBelow
            self.gaugeS6PlasticStrain = gaugeS6PlasticStrain
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

    /// How far removed elements' centres (along the column) reach above and below `height`, to the
    /// outer elements' edges; negative on a side none reaches, and both -1 when none is removed.
    public static func reach(_ centres: [Float], from height: Float, elementSize: Float) -> (
        above: Float, below: Float
    ) {
        guard let low = centres.min(), let high = centres.max() else { return (-1, -1) }
        return (high + elementSize / 2 - height, height - (low - elementSize / 2))
    }
}
