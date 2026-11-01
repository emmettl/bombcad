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
/// are reduced to what they hold at the joint (`restraint(at:settings:)`), or built as members
/// (`Settings.beams`, the frame as built); each shot is on an undamaged column, though the tests'
/// were cumulative. With `Settings.axialLoad`, the paper's own parametric study (§5): a weight on
/// the column's top before the shot. The building's column keeps the earlier
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
        // The bunker's first three shots (§3), elastic on specimen 2, its gauges read (Fig. 4a–c).
        Shot(
            name: "m1", charge: 0.121, standoff: 0.5, breached: false, outcome: "no visible effect; elastic"),
        Shot(
            name: "m2", charge: 0.484, standoff: 0.5, breached: false, outcome: "no visible effect; elastic"),
        Shot(
            name: "m3", charge: 0.968, standoff: 0.5, breached: false,
            outcome: "no visible deformation; elastic"),
        // The paper's parametric study (§5, Figs. 9–10), its own model's: the frame under an
        // axial load, each charge at 0.2 m; the web removed in every one (Fig. 10).
        Shot(
            name: "A1.8", charge: 1.80, standoff: 0.2, breached: true,
            outcome: "the paper's model: holds at Ω 0.25, collapses at 0.3 and above"),
        Shot(
            name: "A1.0", charge: 1.0, standoff: 0.2, breached: true,
            outcome: "the paper's model: holds at Ω 0.3 and 0.4, collapses above 0.4"),
        Shot(
            name: "A0.5", charge: 0.5, standoff: 0.2, breached: true,
            outcome: "the paper's model: holds at Ω 0.5 and 0.6, collapses above 0.6"),
    ]

    /// The paper's model's axial-load thresholds (§5, Fig. 9): the largest Ω at which the column
    /// held after the shot, and the smallest at which it collapsed.
    public static let axialThresholds: [String: (holds: Float, collapses: Float)] = [
        "A1.8": (0.25, 0.3), "A1.0": (0.4, 0.5), "A0.5": (0.6, 0.7),
    ]

    /// Whether the column fell after the shot under its axial load: its top dropped more than
    /// 50 mm (the paper's model's columns that fell passed 10 mm by 0.1 s and 500 mm by about
    /// 0.4 s; those that held stayed within 3 mm). Nil while it is between 10 and 50 mm.
    public static func collapsed(_ topDrop: [SIMD2<Float>]) -> Bool? {
        let largest = topDrop.map(\.y).max() ?? 0
        if largest > 0.05 || !largest.isFinite { return true }
        return largest < 0.01 ? false : nil
    }

    /// The breach's length along the column in the bunker, specimen 2's and specimen 1's ("almost"
    /// 500 and 600 mm, §3). The building's was not measured.
    public static func reportedBreachLength(_ shot: Shot) -> ClosedRange<Float>? {
        shot.name == "m5" ? 0.5...0.6 : nil
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
        /// The frame as built (Figs. 1–2; emmettl/bombcad-work#77, item 2) instead of the joint
        /// reduced to what it holds: the two longitudinal IPE220s as members (`beamBoxes`), bolted
        /// to the flanges by `connection`, held sideways at their far ends by the tubular
        /// restraints. The transverse beam stays a hold on the web's middle at its cleat
        /// (`restraint(at:settings:)`).
        public var beams = false
        /// The longitudinal beams' end plates; nil joins them rigidly to the flanges.
        public var connection: SteelConnection? = .extendedEndPlate
        /// Axial load on the column (N), as in the paper's parametric study (§5): a weight on the
        /// column's top, which is then held sideways only. Zero as tested.
        public var axialLoad: Float = 0
        public init() {}
    }

    /// The tearing strain that falls with the shell's size, read off the 30 October runs (23% at
    /// 10 mm, 8.7 points less per doubling): ε_f = 23% − 12.5% ln(h / 10 mm). A named option for
    /// comparison only: proposed in docs/validation.md, not adopted (the user's decision).
    public static func sizeScaledTearingStrain(elementSize h: Float) -> Float {
        0.23 - 0.125 * log(h / 0.010)
    }

    /// The column's plastic squash load with the measured yields, A f_y (N): 3.27 MN. The
    /// paper's Ω (§5, Eq. 3) is the axial force over the column's capacity; the shortening its
    /// model shows before the blast in Fig. 9 (about 1.2 mm at Ω = 0.25, 2.8 mm at 0.7, so 3.3–4.0
    /// MN for N_Rd) fits this, not the nominal 2.16 MN.
    public static func squashLoad(_ section: Section = Section()) -> Float {
        2 * section.flangeWidth * section.flange * 420e6 + (section.depth - 2 * section.flange) * section.web
            * 407e6
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
    public static func domain(_ settings: Settings) -> SIMD3<Float> {
        SIMD3(settings.beams ? 3.0 : 0.8, 1.3, settings.length + 0.3)
    }

    /// Plan position of the column's axis; the web faces +y. The frame's beams reach 1.4 m to
    /// either side, so its air is wider and the axis further in.
    public static let axis = SIMD2<Float>(0.4, 0.4)
    public static func axis(_ settings: Settings) -> SIMD2<Float> { settings.beams ? SIMD2(1.5, 0.4) : axis }

    /// The flanges (normal to x) and the web (normal to y), the column standing on the ground.
    public static func solids(_ settings: Settings) -> (flanges: [Box], web: Box) {
        let s = settings.section
        let axis = axis(settings)
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
        if settings.beams {
            // The beams' steel as measured in their flanges (Table 1), which carry their bending.
            let beamSteel = beamSection.equivalent(
                of: steel(
                    name: "S275 IPE220 (measured flange)", yield: 345e6, ultimate: 464e6, elongation: 0.28,
                    settings: settings), width: beamWidth)
            let boxes = beamBoxes(settings)
            model.solids += boxes
            model.solidMaterial += boxes.map { _ in beamSteel }
            model.steelConnection = settings.connection
        }
        return model
    }

    /// The charge's centre: `standoff` from the web's face, on its centreline, `chargeHeight` up.
    public static func chargePosition(_ shot: Shot, settings: Settings) -> SIMD3<Float> {
        let axis = axis(settings)
        return SIMD3(axis.x, axis.y + settings.section.web / 2 + shot.standoff, settings.chargeHeight)
    }

    /// The beams' bottom flanges, 0.30 m above the charge (§3).
    public static func beamBottom(_ settings: Settings) -> Float { settings.chargeHeight + 0.30 }

    /// Gauge S6's place on the web: 0.5 m below the beams' bottom flanges and 80 mm to either side
    /// of the web's centreline (Fig. 2), on the web's midsurface.
    public static func gaugeS6(_ settings: Settings) -> [SIMD3<Float>] {
        let z = beamBottom(settings) - 0.5
        let axis = axis(settings)
        return [Float(-1), 1].map { SIMD3(axis.x + $0 * 0.08, axis.y, z) }
    }

    /// What holds a node of the column still, by axis (x, y, z), its rotation left free:
    /// - **the ends**, when pinned, in every direction; with an axial load the top is held
    ///   sideways only, free to shorten under its weight;
    /// - **the joint** (Fig. 2, section A-A), when kept. The end plates, 370 mm tall from 75 mm
    ///   below the beams' bottom flanges, bolt the IPE220s to the flanges: the flanges there are
    ///   held in x and y. The transverse beam's cleat holds the web's middle 100 mm in y over the
    ///   beam's 220 mm depth, the beam's far end being on the bunker's wall. The beams are long and
    ///   heavy beside the few milliseconds of the web's response, so held is taken as still.
    /// - **the frame** (`Settings.beams`): the longitudinal beams are members, so the flanges are
    ///   held only through them; their far ends, 1.4 m from the column's axis (Fig. 2), are held
    ///   sideways (y) by the tubular lateral restraints (§2, Fig. 1a). The transverse beam, a strut
    ///   to the bunker's wall on a simple cleat, is still the hold on the web's middle: its bending
    ///   is released by the cleat, and its length along y holds the web as a strut would.
    public static func restraint(at p: SIMD3<Float>, settings: Settings) -> (x: Bool, y: Bool, z: Bool) {
        let s = settings.section
        let axis = axis(settings)
        let tolerance: Float = 1e-4
        if settings.pinnedEnds && p.z < tolerance { return (true, true, true) }
        if settings.pinnedEnds && p.z > settings.length - tolerance {
            return (true, true, settings.axialLoad <= 0)
        }
        guard settings.joint else { return (false, false, false) }
        let bottom = beamBottom(settings)
        if settings.beams && abs(abs(p.x - axis.x) - beamReach) < 1e-3 { return (false, true, false) }
        let onFlange = abs(abs(p.x - axis.x) - (s.depth - s.flange) / 2) < 1e-3
        if !settings.beams && onFlange && p.z > bottom - 0.075 - tolerance && p.z < bottom + 0.295 + tolerance
        {
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

    /// The longitudinal beams reach 1.40 m from the column's axis (Fig. 2).
    public static let beamReach: Float = 1.40
    /// IPE220 (EN 10365: A 33.4 cm², I_y 2,772 cm⁴, W_pl,y 285 cm³) as the rectangle a beam element
    /// can stand for it with (`SteelSection.equivalent`): 275 mm deep and 140 mm wide.
    /// - **Its width** sets the patch of flange it holds where it ends on one: 140 mm of the
    ///   flange's 160, over the beam's depth, covering the end plate's two lines of bolts 70 mm
    ///   apart. Its faces fall on the 10 mm mesh's lines, 10 mm in from the flange's edges: a face
    ///   within half an element of an edge would take the edge's place on the mesh, and a member
    ///   as wide as a panel it meets would end that panel on its centreline.
    /// - **Its depth** must be under twice its width for it to be meshed as a beam. The deeper it
    ///   is, the nearer its wave speed comes to the section's (√(12 I / A d²) = 1.15 here), so the
    ///   less it shortens the step; its axial stiffness is 1.32 times the IPE220's, and its weak-axis
    ///   stiffness 4 times. Its major-axis bending stiffness and strength, and its mass, are the
    ///   section's.
    public static let beamSection = SteelSection(
        name: "IPE220", depth: 0.275, width: 0.110, area: 33.4e-4, secondMoment: 2772e-8,
        plasticModulus: 285.4e-6)
    public static let beamWidth: Float = 0.140

    /// The longitudinal beams, each from a flange's outer face to 1.4 m from the column's axis,
    /// on the web's plane, their centre 110 mm above their bottom flange (the IPE220's half depth).
    public static func beamBoxes(_ settings: Settings) -> [Box] {
        let axis = axis(settings)
        let s = settings.section
        let centre = beamBottom(settings) + 0.110
        return [Float(-1), 1].map { side in
            let face = axis.x + side * s.depth / 2
            let end = axis.x + side * beamReach
            return Box(
                min: SIMD3(min(face, end), axis.y - beamWidth / 2, centre - beamSection.depth / 2),
                max: SIMD3(max(face, end), axis.y + beamWidth / 2, centre + beamSection.depth / 2))
        }
    }

    /// A strain gauge on the web (Fig. 2): S1–S8 in pairs at four stations, 0.1, 0.3, 0.5 and
    /// 0.7 m below the beams' bottom flanges. Each pair is drawn as a T, so taken here as a
    /// rosette, one gauge along the column and one across the web; which is which, which face,
    /// and whether the pair is on the centreline or 80 mm off it (the drawing's one dimension)
    /// are not stated, so each is read every way.
    public struct StrainGauge: Sendable, Hashable {
        /// The pair's station (1 for S1/S2 … 4 for S7/S8).
        public var station: Int
        /// On the web's midsurface.
        public var position: SIMD3<Float>
        /// 0 across the web (x), 2 along the column (z).
        public var along: Int
        /// +1 on the loaded face, −1 on the back.
        public var face: Float
        /// From the web's centreline (m).
        public var offset: Float

        public var label: String {
            String(
                format: "S%d/S%d %@ %@ %@", 2 * station - 1, 2 * station, offset > 0 ? "80 mm off" : "centre",
                along == 2 ? "along" : "across", face > 0 ? "loaded face" : "back face")
        }
    }

    public static func strainGauges(_ settings: Settings) -> [StrainGauge] {
        let axis = axis(settings)
        var gauges: [StrainGauge] = []
        for station in 1...4 {
            let z = beamBottom(settings) - 0.1 - 0.2 * Float(station - 1)
            for offset: Float in [0, 0.08] {
                for along in [0, 2] {
                    for face: Float in [-1, 1] {
                        gauges.append(
                            StrainGauge(
                                station: station, position: SIMD3(axis.x + offset, axis.y, z), along: along,
                                face: face, offset: offset))
                    }
                }
            }
        }
        return gauges
    }

    /// The engineering strain on a shell's face between two of its nodes: the distance between
    /// the points `offset` from each node's midsurface (half the thickness along the face's
    /// normal, turned by the node's rotation) over the same distance unloaded.
    public static func faceStrain(
        reference a: SIMD3<Float>, _ b: SIMD3<Float>, displacement ua: SIMD3<Float>, _ ub: SIMD3<Float>,
        rotation qa: simd_quatf, _ qb: simd_quatf, offset: SIMD3<Float>
    ) -> Float {
        let unloaded = simd_length(b - a)
        guard unloaded > 0 else { return 0 }
        let pa = a + ua + qa.act(offset)
        let pb = b + ub + qb.act(offset)
        return simd_length(pb - pa) / unloaded - 1
    }

    public static func scenario(_ shot: Shot, settings: Settings = Settings()) -> Scenario {
        let c = chargePosition(shot, settings: settings)
        let axis = axis(settings)
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
        /// The strain gauges' readings (`strainGauges`), sampled at `gaugeTimes` (s); empty when
        /// not read.
        public var gauges: [StrainGauge] = []
        public var gaugeTimes: [Float] = []
        public var gaugeHistories: [[Float]] = []
        /// The frame's end-plate hinges: how many let go, and the largest turn (rad).
        public var hingesReleased = 0
        public var largestHingeTurn: Float = 0
        /// With an axial load: the top's drop from where it settled under the load (m), sampled
        /// after the blast (time s, drop m), and its shortening under the load before it.
        public var topDrop: [SIMD2<Float>] = []
        public var settledShortening: Float = 0
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

    /// A gauge's reading: its largest and smallest strain, the mean over the last `tail` seconds
    /// (what it keeps), and its fastest rate of strain (s⁻¹).
    public struct Reading: Sendable, Hashable {
        public var maximum: Float
        public var minimum: Float
        public var kept: Float
        public var fastestRate: Float
    }

    public static func reading(times: [Float], strains: [Float], tail: Float = 0.001) -> Reading {
        guard let last = times.last, !strains.isEmpty else {
            return Reading(maximum: 0, minimum: 0, kept: 0, fastestRate: 0)
        }
        let kept = zip(times, strains).filter { $0.0 >= last - tail }.map(\.1)
        var rate: Float = 0
        for i in 1..<max(times.count, 1) where times[i] > times[i - 1] {
            rate = max(rate, abs(strains[i] - strains[i - 1]) / (times[i] - times[i - 1]))
        }
        return Reading(
            maximum: strains.max() ?? 0, minimum: strains.min() ?? 0,
            kept: kept.reduce(0, +) / Float(max(kept.count, 1)), fastestRate: rate)
    }

    /// The period of a ringing history (s): the mean spacing of its local maxima above half its
    /// largest swing about the mean, after `start`; nil with fewer than two.
    public static func period(times: [Float], values: [Float], after start: Float = 0) -> Float? {
        let pairs = zip(times, values).filter { $0.0 >= start }
        guard pairs.count > 2 else { return nil }
        let mean = pairs.map(\.1).reduce(0, +) / Float(pairs.count)
        let swing = pairs.map { abs($0.1 - mean) }.max() ?? 0
        guard swing > 0 else { return nil }
        var peaks: [Float] = []
        for i in 1..<(pairs.count - 1)
        where pairs[i].1 > pairs[i - 1].1 && pairs[i].1 >= pairs[i + 1].1 && pairs[i].1 - mean > 0.5 * swing {
            peaks.append(pairs[i].0)
        }
        guard peaks.count >= 2, let first = peaks.first, let last = peaks.last else { return nil }
        return (last - first) / Float(peaks.count - 1)
    }

    /// What the paper gives of the frame's gauges and its parametric study
    /// (`Fixtures/Dinu2017/frame.json`): the gauges' peaks read off Fig. 4 (specimen 2), the
    /// ringing's period, and for m4 what gauge S6 kept and its fastest rate (§3, Fig. 5).
    public struct FrameReference: Codable, Sendable {
        public struct Peak: Codable, Sendable, Hashable {
            /// The gauge's number, 1–8 (`station` is its pair's).
            public var gauge: Int
            public var microstrain: Float
            public var timeMS: Float?
            public var station: Int { (gauge + 1) / 2 }
        }
        public struct Shot: Codable, Sendable {
            public var name: String
            public var peaks: [Peak]
            public var periodMS: Float?
            public var keptMicrostrain: Float?
            public var fastestRate: Float?
        }
        public struct Axial: Codable, Sendable {
            public var shot: String
            public var holds: [Float]
            public var collapses: [Float]
        }
        public var shots: [Shot]
        public var axial: [Axial]
    }

    public static func frameReference(from url: URL) throws -> FrameReference {
        try JSONDecoder().decode(FrameReference.self, from: Data(contentsOf: url))
    }
}
