import Foundation
import simd

/// The load on one envelope component through a run, as the recorder bins it: area-mean
/// pressures per bin on its outer and inner faces (net = outer − inner pushes it inward).
public struct EnvelopeComponentLoad: Sendable {
    public enum Kind: String, Codable, Sendable { case wall, slab, roof, pane, facade }
    public var id: String
    public var owner: UUID
    public var kind: Kind
    /// The component's region and its thin axis.
    public var region: Box
    public var axis: Int
    public var binS: Double
    /// Area-mean overpressure on each side per bin, Pa (the bin's impulse over its width).
    public var outerPa: [Double]
    public var innerPa: [Double]
    /// Whether each of the region's edges is supported, as `EnvelopeComponent.supportEdges`
    /// ([-u, +u, -v, +v]); nil if not known, when a wall is taken as a panel held on its edges.
    public var supportEdges: [Bool]?
    /// When the first bin starts, s (`EnvelopeComponentHistory.windowStartS`); before it the air
    /// at the component was still.
    public var startS: Double
    /// Which way along `axis` its outer side faces, +1 or −1.
    public var outward: Int
    /// Each side's equivalent uniform load on the middle third across its span, where recorded
    /// (`EnvelopeComponentHistory.strip`), Pa per bin: what a sheet's ribs, spanning on their own,
    /// are judged on.
    public var stripPa: (outer: [Double], inner: [Double])?

    /// The load on the middle third across the span, where recorded, else this.
    public var strip: EnvelopeComponentLoad {
        guard let stripPa else { return self }
        var load = self
        load.outerPa = stripPa.outer
        load.innerPa = stripPa.inner
        load.stripPa = nil
        return load
    }

    public init(
        id: String, owner: UUID, kind: Kind, region: Box, axis: Int, binS: Double, outerPa: [Double],
        innerPa: [Double], supportEdges: [Bool]? = nil, startS: Double = 0, outward: Int = 1
    ) {
        self.id = id
        self.owner = owner
        self.kind = kind
        self.region = region
        self.axis = axis
        self.binS = binS
        self.outerPa = outerPa
        self.innerPa = innerPa
        self.supportEdges = supportEdges
        self.startS = startS
        self.outward = outward
    }

    /// A recorded history's load: its bins' impulses over the bin width, as the equivalent uniform
    /// load of its faces weighted by its deflected shape (`EnvelopeComponentHistory.plate`) where
    /// recorded, which its damage is judged on (a sheeted one's on `strip`), or with `whole` the
    /// mean over all its faces.
    public init(_ history: EnvelopeComponentHistory) { self.init(history, whole: false) }

    public init(_ history: EnvelopeComponentHistory, whole: Bool) {
        self.init(history, equivalent: whole ? nil : history.plate)
        if !whole, let strip = history.strip {
            stripPa = (
                strip.outerImpulsePaS.map { Double($0) / history.binS },
                strip.innerImpulsePaS.map { Double($0) / history.binS }
            )
        }
    }

    package init(_ history: EnvelopeComponentHistory, equivalent: EnvelopeComponentHistory.Equivalent?) {
        let kind = Kind(rawValue: history.component.kind.rawValue) ?? .wall
        self.init(
            id: history.component.id, owner: history.component.owner, kind: kind,
            region: history.component.region,
            axis: history.component.axis, binS: history.binS,
            outerPa: (equivalent?.outerImpulsePaS ?? history.outerImpulsePaS).map {
                Double($0) / history.binS
            },
            innerPa: (equivalent?.innerImpulsePaS ?? history.innerImpulsePaS).map {
                Double($0) / history.binS
            },
            supportEdges: history.component.supportEdges, startS: history.windowStartS ?? 0,
            outward: history.component.outward)
    }

    /// A wall standing free: its foot held (on the ground or a slab) and its top not, so a
    /// cantilever. A wall's in-plane axes are horizontal then z, so its foot and top are the
    /// third and fourth edges.
    public var isFreestanding: Bool {
        guard kind == .wall, axis != 2, let edges = supportEdges, edges.count == 4 else { return false }
        return edges[2] && !edges[3]
    }

    /// The region's height, m.
    public var height: Double { Double(region.size.z) }

    /// The span of a component held on exactly two opposite edges (a wall between floor and
    /// ceiling with free sides), m: one-way, between them. Nil otherwise, for a panel on its edges.
    public var oneWaySpan: Double? {
        guard let edges = supportEdges, edges.count == 4, kind != .pane, !isFreestanding else { return nil }
        let axes = (0..<3).filter { $0 != axis }
        if edges[2] && edges[3] && !edges[0] && !edges[1] { return Double(region.size[axes[1]]) }
        if edges[0] && edges[1] && !edges[2] && !edges[3] { return Double(region.size[axes[0]]) }
        return nil
    }

    /// A wall held one way at its foot and top, spanning up between them.
    public var spansVertically: Bool {
        guard axis != 2, let edges = supportEdges, edges.count == 4 else { return false }
        return edges[2] && edges[3] && !edges[0] && !edges[1] && !isFreestanding
    }

    /// How tall the panel stands for its SDOF, m: a façade strip's storey (3 m), however the air's
    /// cells cut the strip (on 4 m cells a strip is 4 m tall, on 8 m cells 8 m, and a panel that
    /// tall is weaker by the square of it), or the region's height, if less (a top storey's
    /// remainder) or for anything else.
    public var panelHeight: Double {
        let height = Double(region.size.z)
        return kind == .facade ? min(height, Double(BuildingEnvelope.storey)) : height
    }

    /// The spans its SDOF takes, shorter first, m: `spans`, a façade strip's height its storey's.
    public var panelSpans: (short: Double, long: Double) {
        guard kind == .facade, axis != 2 else { return spans }
        let width = Double(region.size[axis == 0 ? 1 : 0])
        let height = panelHeight
        return (min(width, height), max(width, height))
    }

    /// The region's two in-plane sizes, shorter first, m.
    public var spans: (short: Double, long: Double) {
        let sizes = (0..<3).filter { $0 != axis }.map { Double(region.size[$0]) }.sorted()
        return (sizes[0], sizes[1])
    }

    public var netPa: [Double] {
        outerPa.enumerated().map { $0.element - ($0.offset < innerPa.count ? innerPa[$0.offset] : 0) }
    }
}

/// How damaged a component is, by the response limits its construction is judged on.
public enum EnvelopeDamageLevel: Int, Codable, Sendable, Comparable, CaseIterable {
    /// Concrete elastic (ductility at most 1); masonry uncracked; glass whole.
    case none
    /// Concrete: support rotation up to 2°.
    case moderate
    /// Concrete: up to 5°; masonry: cracked, still standing.
    case heavy
    /// Concrete: up to 10°.
    case hazardous
    /// Concrete: beyond 10°; masonry: deflected past its thickness, so fallen; glass: broken.
    case failed

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .none: "None"
        case .moderate: "Moderate"
        case .heavy: "Heavy"
        case .hazardous: "Hazardous"
        case .failed: "Failed"
        }
    }

    /// Reinforced concrete slabs and walls with one layer of bars (ASCE/SEI 59-11, single-reinforced
    /// slab or beam): superficial to ductility 1, moderate to 2°, heavy to 5°, hazardous to 10°.
    public static func concrete(ductility: Double, rotationDeg: Double) -> Self {
        if ductility <= 1 { return .none }
        if rotationDeg <= 2 { return .moderate }
        if rotationDeg <= 5 { return .heavy }
        if rotationDeg <= 10 { return .hazardous }
        return .failed
    }
}

/// One component's one-way damage.
public struct EnvelopeComponentDamage: Codable, Sendable, Identifiable {
    public enum Material: String, Codable, Sendable {
        case reinforcedConcrete, unreinforcedMasonry, annealedGlass, reinforcedBlockwork, profiledSteel
        case crossLaminatedTimber
        case laminatedGlass
        /// Monolithic glass with security film, and toughened glass without it.
        case filmedGlass, toughenedGlass

        /// A pane's glass, annealed, toughened, filmed or laminated.
        public var isGlass: Bool {
            [.annealedGlass, .laminatedGlass, .filmedGlass, .toughenedGlass].contains(self)
        }
    }
    public var id: String
    public var owner: UUID
    public var kind: EnvelopeComponentLoad.Kind
    public var material: Material
    public var shortSpanM: Double
    public var peakNetPa: Double
    /// Support rotation (°) and level with its edges fixed and simply supported: concrete's
    /// range. Masonry and glass give fixed edges only (the two equal).
    public var rotationDeg: ClosedRange<Double>
    public var levels: ClosedRange<EnvelopeDamageLevel>
    /// Glass: broken, and when (s), laminated glass gone from its frame (torn or pulled out);
    /// masonry: fallen, and when.
    public var failedAtS: Double?
    /// Laminated glass: cracked, and when (s), held or not; nil otherwise.
    public var crackedAtS: Double? = nil
    /// A window's glass: how far into the room it is thrown, as GSA and ASTM grade it; nil for a
    /// skylight or anything else.
    public var glazing: GlazingHazard? = nil
    /// A roof pane's or skylight's glass: what falls on the floor below; nil for anything else.
    public var overhead: OverheadGlassHazard? = nil
    /// True for a freestanding wall, judged as a cantilever from its foot rather than a panel on
    /// its edges; nil for a panel (left out of the JSON, which older records lack).
    public var cantilever: Bool?
    /// A pane: when a fragment holed it, if one did, and when the blast reached it (its net load
    /// first past a hundredth of its peak); nil where neither applies.
    public var fragmentBrokeAtS: Double? = nil
    public var blastArrivalS: Double? = nil
    /// Concrete under a close-in charge, by UFC 3-340-02's threshold curves (with venting):
    /// "spalled" or "breached"; nil where neither, or not judged (left out of the JSON).
    public var closeIn: String? = nil
    /// Columns of its cells holed through and opened in the air (fragments' and breaches'), with
    /// venting; nil where none.
    public var holesOpened: Int? = nil
    /// Failed and thrown: how (`EnvelopeDebris`); nil where it stays, or nothing is thrown.
    public var launch: DebrisLaunch? = nil
}

/// How hazardous a window's glass is to the room behind it, by where it lands: GSA-TS01's
/// performance conditions and ASTM F1642's hazard ratings, which a test judges by fragments on
/// the floor within 1 and 3 m of the window and on a witness panel 3 m in, below or above 0.6 m
/// (GSA, 2 ft) or 0.5 m (ASTM). Here the glass flies as one piece from the pane's middle, at
/// the speed it broke with and gained from the load that went on pushing it, falling under
/// gravity without drag, the pane's sill `sillM` above the floor.
public struct GlazingHazard: Codable, Sendable, Equatable {
    public enum Condition: String, Codable, Sendable, CaseIterable, Comparable {
        /// 1: not broken; 2: cracked, held by the frame (laminated glass); 3a: lands within
        /// 1 m; 3b: within 3 m; 4: strikes the witness panel at 3 m no higher than 0.6 m; 5:
        /// higher.
        case one = "1"
        case two = "2"
        case threeA = "3a"
        case threeB = "3b"
        case four = "4"
        case five = "5"

        public static func < (a: Self, b: Self) -> Bool {
            allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
        }
    }

    public enum Rating: String, Codable, Sendable, CaseIterable {
        case noBreak = "No break"
        case noHazard = "No hazard"
        case minimal = "Minimal hazard"
        case
            veryLow = "Very low hazard"
        case low = "Low hazard"
        case high = "High hazard"
    }

    /// The glass's speed into the room, m/s.
    public var speedMS: Double
    /// Where it lands on the floor, m from the window, if before the witness panel.
    public var landsAtM: Double?
    /// Its height crossing the witness panel's plane, m above the floor, if it gets there.
    public var panelHeightM: Double?
    public var condition: Condition
    public var rating: Rating

    public static let sillM = 0.9
    public static let nearM = 1.0
    public static let panelM = 3.0
    public static let gsaPanelHeightM = 0.6
    public static let astmPanelHeightM = 0.5

    /// A pane that did not break.
    public static let whole = GlazingHazard(
        speedMS: 0, landsAtM: nil, panelHeightM: nil, condition: .one, rating: .noBreak)

    /// Glass thrown level into the room at `speed` (m/s; none if moving outward) from `height` m
    /// above the floor.
    public static func thrown(speed: Double, height: Double) -> GlazingHazard {
        let g = 9.81
        let v = max(speed, 0)
        let h = max(height, 0)
        let landing = v * (2 * h / g).squareRoot()
        if landing <= panelM {
            return GlazingHazard(
                speedMS: v, landsAtM: landing, panelHeightM: nil,
                condition: landing <= nearM ? .threeA : .threeB,
                rating: landing <= nearM ? .minimal : .veryLow)
        }
        let time = panelM / v
        let z = h - 0.5 * g * time * time
        return GlazingHazard(
            speedMS: v, landsAtM: nil, panelHeightM: z, condition: z <= gsaPanelHeightM ? .four : .five,
            rating: z <= astmPanelHeightM ? .low : .high)
    }

    /// A broken pane `paneHeight` m tall of `massPerArea` kg/m²: its centre's speed at breaking,
    /// then the net load (Pa, in bins `binS` s long) pushing it on as a free mass until that
    /// load, having pushed, turns outward.
    /// Laminated glass cracked and held in its frame by its interlayer: GSA's condition 2, ASTM's
    /// "no hazard" (F1642 counts a pane held in its frame, cracked, as no hazard).
    public static let held = GlazingHazard(
        speedMS: 0, landsAtM: nil, panelHeightM: nil, condition: .two, rating: .noHazard)

    public static func broken(
        response: SDOFResponse, netPa: [Double], binS: Double, massPerArea: Double, paneHeight: Double
    ) -> GlazingHazard {
        guard let speed = speedGone(response: response, netPa: netPa, binS: binS, massPerArea: massPerArea)
        else { return response.crackedAt == nil ? whole : held }
        return thrown(speed: speed, height: sillM + paneHeight / 2)
    }

    /// A pane's speed inward once gone from its frame (m/s): its speed then, and, moving in (or at
    /// rest, holed by a fragment before the blast), what the net load (Pa, in bins `binS` s long)
    /// gives it as a free mass of `massPerArea` until, having pushed, it turns outward. Nil while
    /// it stays.
    public static func speedGone(response: SDOFResponse, netPa: [Double], binS: Double, massPerArea: Double)
        -> Double?
    {
        guard let at = response.lostResistanceAt else { return nil }
        var speed = response.velocityAtLoss ?? 0
        // Moving in (or at rest, holed by a fragment before the blast), the load goes on pushing
        // it until, having pushed, it turns outward.
        if speed >= 0 {
            var bin = max(Int(at / binS), 0)
            // The rest of the bin it broke in, then whole bins.
            var span = Double(bin + 1) * binS - at
            var pushed = speed > 0
            while bin < netPa.count, netPa[bin] >= 0 || !pushed {
                if netPa[bin] > 0 {
                    speed += netPa[bin] * span / massPerArea
                    pushed = true
                }
                bin += 1
                span = binS
            }
        }
        return speed
    }
}

/// Glass falling from a roof or skylight onto the floor below. A pane that leaves its frame
/// falls from where it was, its speed downward on going (and from the load pushing it on, as
/// `GlazingHazard` takes a window's) plus what gravity gives it over the drop, without drag. It is
/// graded by the energy its pieces strike with against the criteria fragments are
/// (`HazardCriteria`): 79 J hazardous, 14.9 J injurious. A laminated pane that cracks and stays
/// is held. One that leaves (torn or out of its frame) falls whole, its interlayer holding its
/// glass. Annealed glass falls as shards, whose sizes no open test gives. So its line gives the
/// shard, square and of the glass's thickness, that would strike with 79 J and with 14.9 J. It is
/// counted hazardous when a shard that big fits in the pane.
public struct OverheadGlassHazard: Codable, Sendable, Equatable {
    public enum Fall: String, Codable, Sendable {
        /// Not broken; cracked and held by its interlayer; fallen as shards; fallen whole.
        case none, held, shards, whole
    }

    public var fall: Fall
    /// From the pane to the floor below, m.
    public var dropM: Double
    /// Striking the floor, m/s.
    public var impactSpeedMS: Double
    /// The glass that falls, kg, over the pane's area below it, m².
    public var massKg: Double
    public var areaM2: Double
    /// The falling glass's energy over that area, J/m².
    public var energyPerAreaJM2: Double
    /// Fallen whole: the pane's energy, J.
    public var pieceEnergyJ: Double?
    /// Fallen as shards: the side of a square shard of the glass's thickness striking with 79 J and
    /// 14.9 J, m.
    public var hazardousShardM: Double?
    public var injuriousShardM: Double?
    /// A falling piece reaches 79 J: the whole pane, or a shard that fits in it.
    public var hazardous: Bool

    public static let none = OverheadGlassHazard(
        fall: .none, dropM: 0, impactSpeedMS: 0, massKg: 0, areaM2: 0, energyPerAreaJM2: 0, hazardous: false)

    public init(
        fall: Fall, dropM: Double, impactSpeedMS: Double, massKg: Double, areaM2: Double,
        energyPerAreaJM2: Double, pieceEnergyJ: Double? = nil, hazardousShardM: Double? = nil,
        injuriousShardM: Double? = nil, hazardous: Bool
    ) {
        self.fall = fall
        self.dropM = dropM
        self.impactSpeedMS = impactSpeedMS
        self.massKg = massKg
        self.areaM2 = areaM2
        self.energyPerAreaJM2 = energyPerAreaJM2
        self.pieceEnergyJ = pieceEnergyJ
        self.hazardousShardM = hazardousShardM
        self.injuriousShardM = injuriousShardM
        self.hazardous = hazardous
    }

    /// A roof pane `a` × `b` (m), its glass `thickness` (m, of glass alone) at `massPerArea`,
    /// `drop` m above the floor, laminated or not, after `response` under `netPa` (inward, i.e.
    /// downward, positive).
    public static func falling(
        response: SDOFResponse, netPa: [Double], binS: Double, massPerArea: Double, a: Double, b: Double,
        thickness: Double, drop: Double, laminated: Bool
    ) -> OverheadGlassHazard {
        guard
            let speed = GlazingHazard.speedGone(
                response: response, netPa: netPa, binS: binS, massPerArea: massPerArea)
        else { return response.crackedAt == nil ? none : with(.held, drop: drop) }
        let down = max(speed, 0)
        let impact = (down * down + 2 * 9.81 * max(drop, 0)).squareRoot()
        let perMass = 0.5 * impact * impact
        let area = a * b
        let mass = massPerArea * area
        var hazard = OverheadGlassHazard(
            fall: laminated ? .whole : .shards, dropM: drop, impactSpeedMS: impact, massKg: mass,
            areaM2: area,
            energyPerAreaJM2: massPerArea * perMass, hazardous: false)
        if laminated {
            hazard.pieceEnergyJ = mass * perMass
            hazard.hazardous = mass * perMass >= Double(HazardCriteria.hazardousEnergyJ)
        } else {
            let glass = 2500 * thickness
            func side(_ energy: Float) -> Double? {
                perMass > 0 ? (Double(energy) / perMass / glass).squareRoot() : nil
            }
            hazard.hazardousShardM = side(HazardCriteria.hazardousEnergyJ)
            hazard.injuriousShardM = side(HazardCriteria.injuryEnergyJ)
            hazard.hazardous = (hazard.hazardousShardM ?? .infinity) <= min(a, b)
        }
        return hazard
    }

    package static func with(_ fall: Fall, drop: Double) -> OverheadGlassHazard {
        var hazard = none
        hazard.fall = fall
        hazard.dropM = drop
        return hazard
    }
}

/// One building's one-way damage.
public struct EnvelopeBuildingDamage: Codable, Sendable, Identifiable {
    public var id: UUID
    public var construction: EnvelopeConstruction
    public var components: [EnvelopeComponentDamage]
    /// The worst level among its walls, roofs and façades, with fixed edges and simply supported.
    public var structuralLevels: ClosedRange<EnvelopeDamageLevel>
    /// Some panel turned past 2° with simply supported edges: the frame round it (junctions,
    /// neighbouring walls, the roof) goes further than one panel at a time can see.
    public var beyondOneWay: Bool
    public var panes: Int
    public var panesBroken: Int
    public var firstPaneBrokenAtS: Double?
    /// Its windows' worst glazing hazard (GSA's condition, ASTM's rating), nil without windows.
    public var worstGlazing: GlazingHazard? = nil
    /// Its roof glazing's worst fall, by the energy over the floor, nil without roof panes.
    public var worstOverhead: OverheadGlassHazard? = nil
    /// Fragments: panes they broke, and of those before the blast reached them; real fragments
    /// striking its walls and roofs, and of those spalling and perforating them. Nil without
    /// fragments.
    public var panesBrokenByFragments: Int? = nil
    public var panesBrokenBeforeBlast: Int? = nil
    public var wallStrikes: Float? = nil
    public var wallsSpalled: Float? = nil
    public var wallsPerforated: Float? = nil
    /// Its façades' glass where a mix stands for their windows (`GlazingMix`, map buildings'
    /// storeys): each side's, and all together. Nil without façade strips.
    public var facadeGlass: [FacadeGlass]? = nil
    public var glass: GlazingBreakage? = nil
    /// Inside, from a one-way fill through the broken panes (`EnvelopeDamageAssessment.fill`), or
    /// with venting the air's own, its worst room's mean: peak overpressure (Pa) and positive
    /// impulse (Pa s). Zero with no pane broken.
    public var insidePeakPa: Double
    public var insideImpulsePaS: Double
    /// True when the inside and the panes' breaking are the air's, its glazing vented
    /// (`BlastSolver.configureEnvelopeVenting`); nil for the one-way fill (left out of the JSON).
    public var vented: Bool?
}

/// How an envelope building's damage is shown: one colour for each of six codes, the view's
/// (`SceneRenderer.setEnvelopeDamage`, Render.metal) and the app's alike.
public enum EnvelopeDamageColour {
    /// sRGB, by code 1–6: none, glass broken alone, moderate, heavy, hazardous, failed. Chosen to
    /// stay apart under protanopia, deuteranopia and tritanopia (every pair at least ΔE 21 in
    /// Machado et al.'s simulations; native-interface-review.md), and to darken as damage grows.
    public static let palette: [SIMD3<Float>] = [
        SIMD3(0.851, 0.910, 0.824), SIMD3(0.310, 0.659, 0.878), SIMD3(0.949, 0.871, 0.227),
        SIMD3(0.878, 0.541, 0.000), SIMD3(0.702, 0.227, 0.039), SIMD3(0.420, 0.118, 0.333),
    ]
    public static let labels = ["None", "Glass broken", "Moderate", "Heavy", "Hazardous", "Failed"]

    /// A building's code: the worse end of its concrete range, or glass broken alone.
    public static func code(_ building: EnvelopeBuildingDamage) -> Int {
        let worst = building.structuralLevels.upperBound
        if worst == .none { return building.panesBroken > 0 ? 2 : 1 }
        return worst.rawValue + 2
    }
}

/// The one-way damage of envelope components from their loads, by what each building is built of.
/// The air never sees it: envelopes stay whole in the air (see building-envelopes.md).
public enum EnvelopeDamageAssessment {
    /// The panel spans SDOF assumes at most, m: a larger region (a map block's whole roof) is
    /// taken as held by walls inside it at this spacing.
    public static let largestSpan = 6.0
    /// How long a freestanding masonry wall is followed after its load, s: long enough to see a
    /// rocking wall fall.
    public static let rockingFollowS = 3.0
    /// Rotation past which a panel's frame is flagged as beyond the one-way model, degrees.
    public static let frameFlagDeg = 2.0

    /// With `vented`, the run's glazing broke in the air: each pane breaks when the GPU's glass did
    /// (its history after that is the open window's), and the inside is the air's worst room.
    /// With `hazard`, each façade side's glass also carries the chance that some pane is thrown
    /// worse than that GSA condition (`GlazingBreakage.worse`). `glassStrength` scales each
    /// building's glass strength over the flaw model's median, for the side's breakage only (1 if
    /// not given).
    public static func assess(
        loads: [EnvelopeComponentLoad], constructions: (UUID) -> EnvelopeConstruction,
        rooms: [UUID: Double] = [:], strikes: [FragmentImpact]? = nil,
        vented: EnvelopeVentingSnapshot? = nil, hazard: GlazingHazard.Condition? = nil,
        glassStrength: ((UUID) -> Double)? = nil
    ) -> [EnvelopeBuildingDamage] {
        let byOwner = Dictionary(grouping: loads, by: \.owner)
        let owners = byOwner.keys.sorted { $0.uuidString < $1.uuidString }
        // The first fragment through each pane, by its component's id.
        var holed: [String: Double] = [:]
        for strike in strikes ?? [] where strike.penetration?.outcome == .perforated {
            guard let owner = strike.objectID, let pane = strike.pane else { continue }
            let id = "\(owner.uuidString)/pane/\(pane).0"
            holed[id] = min(holed[id] ?? .infinity, strike.time)
        }
        // Each building on its own core: a district's thousands take seconds rather than minutes.
        // The constructions are looked up first, on this thread.
        let built = owners.map(constructions)
        // Each building's glass strength over the flaw model's median, 1 unless drawn.
        let strengths = owners.map { glassStrength?($0) ?? 1 }
        var judged = [EnvelopeBuildingDamage?](repeating: nil, count: owners.count)
        judged.withUnsafeMutableBufferPointer { out in
            concurrently(iterations: owners.count) { n in out[n] = building(n) }
        }
        return judged.map { $0! }

        func building(_ n: Int) -> EnvelopeBuildingDamage {
            let owner = owners[n]
            let construction = built[n]
            let mine = byOwner[owner] ?? []
            let top = mine.map { Double($0.region.max.z) }.max()
            let base = mine.map { Double($0.region.min.z) }.min()
            var components: [EnvelopeComponentDamage] = []
            var broken: [(load: EnvelopeComponentLoad, at: Double)] = []
            var sides: [Int: GlazingBreakage] = [:]
            for load in mine {
                if load.kind == .facade,
                    let mix = construction.glazing(axis: load.axis, outward: load.outward)
                {
                    let spans = load.spans
                    sides[load.axis * 2 + (load.outward > 0 ? 1 : 0), default: GlazingBreakage()] =
                        sides[load.axis * 2 + (load.outward > 0 ? 1 : 0), default: GlazingBreakage()]
                        + mix.breakage(
                            netPa: load.netPa, binS: load.binS, areaM2: spans.short * spans.long,
                            worseThan: hazard, strength: strengths[n])
                }
                guard
                    var damage = assess(
                        load, construction: construction, buildingTop: top, buildingBase: base,
                        holedAt: holed[load.id])
                else {
                    continue
                }
                if damage.material == .annealedGlass,
                    let pane = vented?.panes.first(where: { $0.component == load.id })
                {
                    // Broken in the air, or by a fragment first (which the air does not see).
                    let first = [pane.brokenAtS, damage.fragmentBrokeAtS].compactMap { $0 }.min()
                    if first != damage.fragmentBrokeAtS { damage.fragmentBrokeAtS = nil }
                    damage.failedAtS = first
                    let level: EnvelopeDamageLevel = first == nil ? .none : .failed
                    damage.levels = level...level
                }
                if !damage.material.isGlass, let vented {
                    damage.closeIn = vented.closeIn[load.id]
                    let holes = vented.holes.filter { $0.component == load.id && $0.openedAtS != nil }.count
                    damage.holesOpened = holes > 0 ? holes : nil
                }
                if !damage.material.isGlass,
                    let failed = vented?.walls.first(where: { $0.component == load.id })?.failedAtS
                {
                    // Failed in the air, and opened: the GPU's model is this one's, on the step's load.
                    damage.failedAtS = failed
                    damage.levels = damage.levels.lowerBound ... .failed
                }
                components.append(damage)
                if damage.material.isGlass, let at = damage.failedAtS { broken.append((load, at)) }
                if let pane = facadePane(
                    load, construction: construction.facade(axis: load.axis, outward: load.outward))
                {
                    components.append(pane)
                }
            }
            // The broken panes' outer pressures from the first of their windows' starts.
            let first = broken.map(\.load.startS).min() ?? 0
            let openings = broken.map { pane in
                let spans = pane.load.spans
                let lead = Int(((pane.load.startS - first) / pane.load.binS).rounded())
                return (
                    area: spans.short * spans.long, opens: pane.at - first,
                    outer: [Double](repeating: 0, count: lead) + pane.load.outerPa
                )
            }
            let structural = components.filter { !$0.material.isGlass }
            let low = structural.map(\.levels.lowerBound).max() ?? .none
            let high = structural.map(\.levels.upperBound).max() ?? .none
            let panes = components.filter { $0.material.isGlass }
            let air = vented?.inside(of: owner)
            func filled() -> (peak: Double, impulse: Double) {
                fill(volume: rooms[owner] ?? 0, openings: openings, bin: mine.first?.binS ?? 1e-4)
            }
            var inside =
                openings.isEmpty
                ? (peak: 0.0, impulse: 0.0)
                : air.map { (peak: $0.peakPa, impulse: $0.impulsePaS) } ?? filled()
            // Laminated and filmed panes stay shut in the air when they go, so the fill through them
            // stands in.
            if construction.holdsFragments, air != nil, !openings.isEmpty {
                let through = filled()
                inside = (max(inside.peak, through.peak), max(inside.impulse, through.impulse))
            }
            return EnvelopeBuildingDamage(
                id: owner, construction: construction, components: components,
                structuralLevels: low...max(low, high),
                beyondOneWay: structural.contains { $0.rotationDeg.upperBound > frameFlagDeg },
                panes: panes.count,
                panesBroken: panes.filter { ($0.crackedAtS ?? $0.failedAtS) != nil }.count,
                firstPaneBrokenAtS: panes.compactMap { $0.crackedAtS ?? $0.failedAtS }.min(),
                worstGlazing: panes.compactMap(\.glazing).max {
                    ($0.condition, $0.speedMS) < ($1.condition, $1.speedMS)
                },
                worstOverhead: panes.compactMap(\.overhead).max { $0.energyPerAreaJM2 < $1.energyPerAreaJM2 },
                panesBrokenByFragments: strikes.map { _ in panes.filter { $0.fragmentBrokeAtS != nil }.count
                },
                panesBrokenBeforeBlast: strikes.map { _ in
                    panes.filter { pane in
                        pane.fragmentBrokeAtS.map { $0 < pane.blastArrivalS ?? .infinity } ?? false
                    }.count
                },
                wallStrikes: strikes.map { tally($0, owner: owner, at: nil) },
                wallsSpalled: strikes.map { tally($0, owner: owner, at: .spalled) },
                wallsPerforated: strikes.map { tally($0, owner: owner, at: .perforated) },
                facadeGlass: sides.isEmpty
                    ? nil
                    : sides.keys.sorted().map {
                        FacadeGlass(axis: $0 / 2, outward: $0 % 2 == 1 ? 1 : -1, glass: sides[$0]!)
                    },
                glass: sides.isEmpty ? nil : sides.values.reduce(GlazingBreakage(), +),
                insidePeakPa: inside.peak,
                insideImpulsePaS: inside.impulse, vented: vented == nil ? nil : true)
        }
    }

    /// Real fragments striking `owner`'s walls and roofs judged as `outcome`, or all judged.
    package static func tally(
        _ strikes: [FragmentImpact], owner: UUID, at outcome: PenetrationResult.Outcome?
    )
        -> Float
    {
        strikes.filter { strike in
            strike.objectID == owner && strike.pane == nil
                && (outcome.map { strike.penetration?.outcome == $0 } ?? (strike.penetration != nil))
        }.reduce(0) { $0 + $1.count }
    }

    package static func rotation(_ response: SDOFResponse, span: Double) -> Double {
        atan(max(response.peakDeflection, -response.reboundDeflection) / (span / 2)) * 180 / .pi
    }

    /// Concrete fails past 10° of support rotation (ASCE/SEI 59-11, `EnvelopeDamageLevel.concrete`).
    static let failedRotation = 10 * Double.pi / 180

    /// Concrete's ductility for its level, whichever way it went furthest: pushed out (by a charge
    /// inside, or its rebound) it is judged as pushed in, UFC 3-340-02 §4-26.2's "designed for a
    /// negative load" by "the same equations", with ASCE/SEI 59-11's limits. Only inward, as
    /// before 18 October 2026, with `BOMBCAD_CONCRETE_INWARD_ONLY` set, to compare.
    static func concreteDuctility(_ response: SDOFResponse) -> Double {
        concreteInwardOnly ? response.ductility : response.ductilityEitherWay
    }

    static let concreteInwardOnly = ProcessInfo.processInfo.environment["BOMBCAD_CONCRETE_INWARD_ONLY"] != nil

    /// What a component that failed at `time` (from its load's first bin) moving at `speed` (m/s,
    /// inward positive, at its largest deflection) throws; nil where it did not.
    package static func launch(
        time: Double?, speed: Double?, system: SDOFSystem, material: EnvelopeComponentDamage.Material,
        thickness: Double, span: Double, pane: SIMD2<Double>? = nil, rotation: Double
    ) -> DebrisLaunch? {
        guard let time else { return nil }
        return DebrisLaunch(
            timeS: time, speedMS: speed ?? 0, massPerArea: system.massPerArea, thicknessM: thickness,
            piece: DebrisLaunch.piece(material, thickness: thickness, span: span, pane: pane),
            rotationRad: rotation)
    }

    /// One component's damage, or nil for a component of no known kind; its failure's time from
    /// t = 0. A pane a fragment holed at `holedAt` s, if that came first, breaks then, its glass
    /// pushed in from rest by the load after it. `buildingTop` (m, the building's highest point)
    /// loads an unreinforced masonry wall with the wall above it, whose weight it rocks against;
    /// nil for none.
    public static func assess(
        _ load: EnvelopeComponentLoad, construction: EnvelopeConstruction, buildingTop: Double? = nil,
        buildingBase: Double? = nil, holedAt: Double? = nil
    )
        -> EnvelopeComponentDamage?
    {
        guard
            var damage = assessFromStart(
                load, construction: construction, buildingTop: buildingTop, buildingBase: buildingBase,
                holedAt: holedAt.map { max($0 - load.startS, 0) })
        else { return nil }
        damage.failedAtS = damage.failedAtS.map { $0 + load.startS }
        damage.launch?.timeS += load.startS
        damage.crackedAtS = damage.crackedAtS.map { $0 + load.startS }
        damage.blastArrivalS = damage.blastArrivalS.map { $0 + load.startS }
        // Holed before its window began: when it was, not the window's start.
        if damage.fragmentBrokeAtS != nil {
            damage.fragmentBrokeAtS = holedAt
            damage.failedAtS = holedAt
        }
        return damage
    }

    /// The same, its failure's time from the load's first bin.
    static func assessFromStart(
        _ load: EnvelopeComponentLoad, construction: EnvelopeConstruction, buildingTop: Double? = nil,
        buildingBase: Double? = nil, holedAt: Double? = nil
    )
        -> EnvelopeComponentDamage?
    {
        let spans = load.panelSpans
        let a = min(spans.short, largestSpan)
        let b = min(spans.long, largestSpan)
        let pressures = load.netPa
        let peak = pressures.map(abs).max() ?? 0
        func damage(
            _ material: EnvelopeComponentDamage.Material, _ rotation: ClosedRange<Double>,
            _ levels: ClosedRange<EnvelopeDamageLevel>, _ failed: Double?
        ) -> EnvelopeComponentDamage {
            EnvelopeComponentDamage(
                id: load.id, owner: load.owner, kind: load.kind, material: material, shortSpanM: a,
                peakNetPa: peak, rotationDeg: rotation, levels: levels, failedAtS: failed)
        }
        if load.kind == .pane {
            let pane =
                construction.hasPlainGlass
                ? annealedPane(thickness: Double(construction.glassThicknessM), a: a, b: b)
                : construction.pane(a: a, b: b)
            var response = pane.response(pressures: pressures, step: load.binS)
            let arrival = pressures.firstIndex { abs($0) > 0.01 * peak && peak > 0 }.map {
                Double($0) * load.binS
            }
            if let holedAt, holedAt < response.lostResistanceAt ?? .infinity {
                response.lostResistanceAt = holedAt
                response.velocityAtLoss = 0
            }
            let level = Self.paneLevel(response)
            let rotation = Self.rotation(response, span: a)
            var result = damage(
                construction.paneMaterial, rotation...rotation,
                level...level,
                response.lostResistanceAt)
            result.crackedAtS = response.crackedAt
            result.fragmentBrokeAtS = holedAt.flatMap { $0 == response.lostResistanceAt ? $0 : nil }
            result.launch = Self.launch(
                time: response.lostResistanceAt, speed: response.velocityAtLoss, system: pane,
                material: result.material,
                thickness: construction.glassAloneM,
                span: a, pane: SIMD2(a, b), rotation: atan((response.deflectionAtBreak ?? 0) / (a / 2)))
            result.blastArrivalS = arrival
            if load.axis != 2 {
                result.glazing = GlazingHazard.broken(
                    response: response, netPa: pressures, binS: load.binS, massPerArea: pane.massPerArea,
                    paneHeight: Double(load.region.size.z))
            } else {
                let glass = construction.glassAloneM
                result.overhead = OverheadGlassHazard.falling(
                    response: response, netPa: pressures, binS: load.binS, massPerArea: pane.massPerArea,
                    a: a, b: b,
                    thickness: glass, drop: Double(load.region.min.z) - (buildingBase ?? 0),
                    laminated: construction.holdsFragments)
            }
            return result
        }
        if load.isFreestanding {
            return cantilever(load, construction: construction, pressures: pressures, peak: peak)
        }
        let isRoof = load.kind == .roof || load.kind == .slab
        let kind = isRoof ? construction.roof : construction.walls
        let thickness = Double(isRoof ? construction.roofThicknessM : construction.wallThicknessM)
        if kind == .profiledSteelSheeting {
            return profiledSheet(
                load, construction: construction, roof: isRoof, pressures: pressures, peak: peak)
        }
        if kind == .crossLaminatedTimber {
            return crossLaminated(
                load, construction: construction, roof: isRoof,
                span: load.oneWaySpan.map { min($0, largestSpan) } ?? a, pressures: pressures, peak: peak)
        }
        if let span = load.oneWaySpan.map({ min($0, largestSpan) }) {
            return oneWay(
                load, kind: kind, thickness: thickness, span: span, construction: construction,
                pressures: pressures, peak: peak, buildingTop: buildingTop)
        }
        switch kind {
        case .reinforcedConcrete, .reinforcedBlockwork:
            // Walls as their construction says (a central mat by default: depth half the thickness,
            // steel the ratio of the gross section); roofs the default concrete with a central mat.
            let section = section(construction, thickness: thickness, roof: isRoof)
            let material = isRoof ? StructureMaterial.reinforcedConcrete : construction.wallMaterial
            let systems = [EnvelopePanel.Edges.fixed, .simplySupported].map { edges in
                EnvelopePanel.reinforcedConcrete(
                    thickness: thickness, depth: section.depth, steelArea: section.steelArea,
                    material: material,
                    a: a, b: b, edges: edges)
            }
            let responses = systems.map {
                $0.response(pressures: pressures, step: load.binS, watch: tan(failedRotation) * a / 2)
            }
            let rotations = responses.map { rotation($0, span: a) }
            let levels = zip(responses, rotations).map {
                EnvelopeDamageLevel.concrete(ductility: concreteDuctility($0), rotationDeg: $1)
            }
            let concrete: EnvelopeComponentDamage.Material =
                kind == .reinforcedBlockwork && !isRoof ? .reinforcedBlockwork : .reinforcedConcrete
            var result = damage(
                concrete, rotations.min()!...rotations.max()!, levels.min()!...levels.max()!, nil)
            // Thrown as the simply supported bound fails, the worse.
            result.launch = Self.launch(
                time: responses[1].passedAt, speed: responses[1].velocityPassing, system: systems[1],
                material: concrete, thickness: thickness, span: a, rotation: failedRotation)
            return result
        case .profiledSteelSheeting:
            return profiledSheet(
                load, construction: construction, roof: isRoof, pressures: pressures, peak: peak)
        case .crossLaminatedTimber:
            return crossLaminated(
                load, construction: construction, roof: isRoof, span: a, pressures: pressures, peak: peak)
        case .unreinforcedMasonry:
            var masonry = StructureMaterial.masonry
            masonry.steel = nil
            var system = EnvelopePanel.unreinforcedMasonry(
                thickness: thickness, material: masonry, a: a, b: b,
                axialLoad: isRoof
                    ? 0 : overburden(load, buildingTop, thickness: thickness, material: masonry),
                height: load.panelHeight
            )
            // A liner spans the shorter way, as a membrane between the supports it is lapped onto.
            if let liner = construction.wallLiner, !isRoof { system = system.lined(liner, span: a) }
            let response = system.response(pressures: pressures, step: load.binS)
            // Cracked once past the backbone's first point, lined or not.
            let level: EnvelopeDamageLevel =
                response.lostResistanceAt != nil
                ? .failed : (response.peakDeflection > system.backbone[0].x ? .heavy : .none)
            let rotation = Self.rotation(response, span: a)
            var result = damage(
                .unreinforcedMasonry, rotation...rotation, level...level, response.lostResistanceAt)
            result.launch = Self.launch(
                time: response.lostResistanceAt, speed: response.velocityAtLoss, system: system,
                material: .unreinforcedMasonry, thickness: thickness, span: a,
                rotation: atan(system.backbone.last!.x / (a / 2)))
            return result
        }
    }

    /// A freestanding wall's damage, as a cantilever from its foot (`EnvelopePanel`'s cantilever
    /// systems): concrete by ASCE/SEI 59-11's support rotations, atan(top / height) as UFC Table
    /// 3-5 measures a cantilever's; masonry uncracked, cracked or fallen (its top past its
    /// thickness), as panels are graded. The rotation range is one value: a cantilever's base is
    /// fixed, its top free. The short span reported is the height.
    package static func cantilever(
        _ load: EnvelopeComponentLoad, construction: EnvelopeConstruction, pressures net: [Double],
        peak: Double
    ) -> EnvelopeComponentDamage {
        let pressures = cantileverLoad(net)
        // −1 where the load was turned to push from the face it struck harder: what it throws
        // goes that way, against the recorded net's sign.
        let turned: Double = zip(pressures, net).contains { $0 != $1 } ? -1 : 1
        let height = min(load.height, largestSpan)
        let thickness = Double(construction.wallThicknessM)
        func damage(
            _ material: EnvelopeComponentDamage.Material, _ response: SDOFResponse,
            _ level: EnvelopeDamageLevel
        ) -> EnvelopeComponentDamage {
            let rotation =
                atan(max(response.peakDeflection, -response.reboundDeflection) / height) * 180 / .pi
            return EnvelopeComponentDamage(
                id: load.id, owner: load.owner, kind: load.kind, material: material, shortSpanM: height,
                peakNetPa: peak, rotationDeg: rotation...rotation, levels: level...level,
                failedAtS: response.lostResistanceAt, cantilever: true)
        }
        switch construction.walls {
        case .profiledSteelSheeting:
            // Sheeting spans between its rails whether or not the wall stands alone.
            return profiledSheet(load, construction: construction, roof: false, pressures: net, peak: peak)
        case .crossLaminatedTimber:
            return crossLaminated(
                load, construction: construction, roof: false, span: height, cantilever: true,
                pressures: pressures,
                peak: peak, turned: turned)
        case .reinforcedConcrete, .reinforcedBlockwork:
            let section = construction.wallBars(thickness: thickness)
            let system = EnvelopePanel.reinforcedConcreteCantilever(
                thickness: thickness, depth: section.depth, steelArea: section.steelArea,
                material: construction.wallMaterial, height: height,
                topMass: Double(construction.capMassKgPerM ?? 0)
            )
            let response = system.response(
                pressures: pressures, step: load.binS, watch: tan(failedRotation) * height)
            let rotation =
                atan(max(response.peakDeflection, -response.reboundDeflection) / height) * 180 / .pi
            let concrete: EnvelopeComponentDamage.Material =
                construction.walls == .reinforcedBlockwork ? .reinforcedBlockwork : .reinforcedConcrete
            var result = damage(
                concrete, response,
                EnvelopeDamageLevel.concrete(ductility: concreteDuctility(response), rotationDeg: rotation))
            result.launch = Self.launch(
                time: response.passedAt, speed: response.velocityPassing.map { $0 * turned }, system: system,
                material: concrete,
                thickness: thickness, span: height, rotation: failedRotation)
            return result
        case .unreinforcedMasonry:
            var masonry = StructureMaterial.masonry
            masonry.steel = nil
            let system = EnvelopePanel.unreinforcedMasonryCantilever(
                thickness: thickness, material: masonry, height: height)
            // A rocking wall can fall a second or more after the load: follow it for 3 s.
            let response = system.response(
                pressures: pressures, step: load.binS, tail: max(3, rockingFollowS / system.period))
            let level: EnvelopeDamageLevel =
                response.lostResistanceAt != nil ? .failed : (response.ductility > 1 ? .heavy : .none)
            var result = damage(.unreinforcedMasonry, response, level)
            result.launch = Self.launch(
                time: response.lostResistanceAt, speed: response.velocityAtLoss.map { $0 * turned },
                system: system,
                material: .unreinforcedMasonry, thickness: thickness, span: height,
                rotation: atan(system.backbone.last!.x / height))
            return result
        }
    }

    /// A component held on two opposite edges, as a one-way strip between them (`EnvelopePanel`'s
    /// one-way systems): concrete between fixed and simply supported ends, by ASCE/SEI 59-11;
    /// masonry with fixed ends, as panels, uncracked, cracked or fallen.
    static func oneWay(
        _ load: EnvelopeComponentLoad, kind: EnvelopeConstruction.Kind, thickness: Double, span: Double,
        construction: EnvelopeConstruction, pressures: [Double], peak: Double, buildingTop: Double? = nil
    ) -> EnvelopeComponentDamage {
        func damage(
            _ material: EnvelopeComponentDamage.Material, _ rotation: ClosedRange<Double>,
            _ levels: ClosedRange<EnvelopeDamageLevel>, _ failed: Double?
        ) -> EnvelopeComponentDamage {
            EnvelopeComponentDamage(
                id: load.id, owner: load.owner, kind: load.kind, material: material, shortSpanM: span,
                peakNetPa: peak, rotationDeg: rotation, levels: levels, failedAtS: failed)
        }
        let isRoof = load.kind == .roof || load.kind == .slab
        switch kind {
        case .reinforcedConcrete, .reinforcedBlockwork:
            let section = section(construction, thickness: thickness, roof: isRoof)
            let material = isRoof ? StructureMaterial.reinforcedConcrete : construction.wallMaterial
            let systems = [EnvelopePanel.Edges.fixed, .simplySupported].map { edges in
                EnvelopePanel.reinforcedOneWay(
                    thickness: thickness, depth: section.depth, steelArea: section.steelArea,
                    material: material,
                    span: span, edges: edges)
            }
            let responses = systems.map {
                $0.response(pressures: pressures, step: load.binS, watch: tan(failedRotation) * span / 2)
            }
            let rotations = responses.map { rotation($0, span: span) }
            let levels = zip(responses, rotations).map {
                EnvelopeDamageLevel.concrete(ductility: concreteDuctility($0), rotationDeg: $1)
            }
            let concrete: EnvelopeComponentDamage.Material =
                kind == .reinforcedBlockwork && !isRoof ? .reinforcedBlockwork : .reinforcedConcrete
            var result = damage(
                concrete, rotations.min()!...rotations.max()!, levels.min()!...levels.max()!, nil)
            result.launch = Self.launch(
                time: responses[1].passedAt, speed: responses[1].velocityPassing, system: systems[1],
                material: concrete, thickness: thickness, span: span, rotation: failedRotation)
            return result
        case .profiledSteelSheeting:
            return profiledSheet(
                load, construction: construction, roof: isRoof, pressures: pressures, peak: peak)
        case .crossLaminatedTimber:
            return crossLaminated(
                load, construction: construction, roof: isRoof, span: span, pressures: pressures, peak: peak)
        case .unreinforcedMasonry:
            var masonry = StructureMaterial.masonry
            masonry.steel = nil
            var system = EnvelopePanel.unreinforcedMasonryOneWay(
                thickness: thickness, material: masonry, span: span, edges: .fixed,
                axialLoad: isRoof || !load.spansVertically
                    ? 0 : overburden(load, buildingTop, thickness: thickness, material: masonry)
            )
            if let liner = construction.wallLiner, !isRoof { system = system.lined(liner, span: span) }
            let response = system.response(pressures: pressures, step: load.binS)
            // Cracked once past the backbone's first point, lined or not.
            let level: EnvelopeDamageLevel =
                response.lostResistanceAt != nil
                ? .failed : (response.peakDeflection > system.backbone[0].x ? .heavy : .none)
            let rotation = Self.rotation(response, span: span)
            var result = damage(
                .unreinforcedMasonry, rotation...rotation, level...level, response.lostResistanceAt)
            result.launch = Self.launch(
                time: response.lostResistanceAt, speed: response.velocityAtLoss, system: system,
                material: .unreinforcedMasonry, thickness: thickness, span: span,
                rotation: atan(system.backbone.last!.x / (span / 2)))
            return result
        }
    }

    /// A pane's level: none unbroken, heavy when laminated glass cracks and its interlayer holds it
    /// in the frame, failed when the glass is gone.
    static func paneLevel(_ response: SDOFResponse) -> EnvelopeDamageLevel {
        if response.lostResistanceAt != nil { return .failed }
        return response.crackedAt == nil ? .none : .heavy
    }

    /// An annealed pane on the large-deflection plate (`EnvelopePanel.largeDeflectionGlass`),
    /// built once for each thickness and size: building its backbone from Moore's curves costs more
    /// than its response, and a district's façades share a few sizes.
    static func annealedPane(thickness: Double, a: Double, b: Double) -> SDOFSystem {
        paneSystems.system(SIMD4(thickness, a, b, 0)) {
            EnvelopePanel.largeDeflectionGlass(thickness: thickness, material: .annealedGlass, a: a, b: b)
        }
    }

    /// The same pane with its strength out of reach, so that its response gives the load's 60 s
    /// equivalent stress (`SDOFResponse.equivalentStress`) whatever it is.
    static func unbreakablePane(thickness: Double, a: Double, b: Double) -> SDOFSystem {
        paneSystems.system(SIMD4(thickness, a, b, 1)) {
            EnvelopePanel.largeDeflectionGlass(
                thickness: thickness, material: .annealedGlass, a: a, b: b, sixtySecondStrength: 1e12)
        }
    }

    private static let paneSystems = SystemCache()

    /// The pane systems built so far, by thickness and size; shared between threads behind a lock.
    package final class SystemCache: @unchecked Sendable {
        private let lock = NSLock()
        private var systems: [SIMD4<Double>: SDOFSystem] = [:]

        package func system(_ key: SIMD4<Double>, _ make: () -> SDOFSystem) -> SDOFSystem {
            lock.lock()
            defer { lock.unlock() }
            if let system = systems[key] { return system }
            let system = make()
            if systems.count < 4096 { systems[key] = system }
            return system
        }
    }

    /// The pane a façade strip is taken to hold (`EnvelopeConstruction.facadePaneM`), judged on the
    /// strip's net load as a pane is: annealed glass of the construction's thickness on Moore's
    /// large-deflection plate, at its median strength. Nil for anything but a façade strip, or
    /// without one. Its breaking counts with the building's panes; it opens no hole into the
    /// room, as a block, which a façade strip belongs to, has none.
    public static func facadePane(_ load: EnvelopeComponentLoad, construction: EnvelopeConstruction)
        -> EnvelopeComponentDamage?
    {
        guard load.kind == .facade else { return nil }
        let size = construction.facadePaneM ?? EnvelopeConstruction.assumedFacadePane
        guard size.x > 0, size.y > 0 else { return nil }
        let (a, b) = (Double(min(size.x, size.y)), Double(max(size.x, size.y)))
        let pane =
            construction.hasPlainGlass
            ? annealedPane(thickness: Double(construction.glassThicknessM), a: a, b: b)
            : construction.pane(a: a, b: b)
        let pressures = load.netPa
        let response = pane.response(pressures: pressures, step: load.binS)
        let level = paneLevel(response)
        let rotation = Self.rotation(response, span: a)
        var damage = EnvelopeComponentDamage(
            id: load.id + "/pane", owner: load.owner, kind: .pane,
            material: construction.paneMaterial, shortSpanM: a,
            peakNetPa: pressures.map(abs).max() ?? 0, rotationDeg: rotation...rotation, levels: level...level,
            failedAtS: response.lostResistanceAt.map { $0 + load.startS })
        damage.crackedAtS = response.crackedAt.map { $0 + load.startS }
        damage.glazing = GlazingHazard.broken(
            response: response, netPa: pressures, binS: load.binS, massPerArea: pane.massPerArea,
            paneHeight: Double(size.y))
        return damage
    }

    /// The weight per metre of a wall's own masonry above it, to the building's top, N/m: what a
    /// wall of a building of several storeys carries at least (its floors' loads are not known).
    package static func overburden(
        _ load: EnvelopeComponentLoad, _ buildingTop: Double?, thickness: Double, material: StructureMaterial
    ) -> Double {
        guard let top = buildingTop, load.axis != 2 else { return 0 }
        return Double(material.density) * 9.81 * thickness * max(top - Double(load.region.max.z), 0)
    }

    /// A member's tension bars: a wall's as its construction says, a roof's a central mat.
    package static func section(_ construction: EnvelopeConstruction, thickness: Double, roof: Bool)
        -> (depth: Double, steelArea: Double)
    {
        roof
            ? (thickness / 2, Double(construction.reinforcementRatio) * thickness)
            : construction.wallBars(thickness: thickness)
    }

    /// A freestanding wall's net load, turned so that it pushes from the face the blast strikes:
    /// a wall standing alone has no inside, so its "outer" face (taken from its own middle) may be
    /// its back. Turned when the net pressure's largest excursion is negative.
    public static func cantileverLoad(_ net: [Double]) -> [Double] {
        let high = net.max() ?? 0
        let low = net.min() ?? 0
        return -low > high ? net.map { -$0 } : net
    }

    /// The air inside an envelope, m³: its solids' bounds less the solids (their disjoint blocks).
    /// Nothing for a solid block, which has no inside to fill.
    public static func roomVolume(of envelope: BuildingEnvelope) -> Double {
        let low = envelope.solids.map(\.min).reduce(SIMD3<Float>(repeating: .infinity)) { simd_min($0, $1) }
        let high = envelope.solids.map(\.max).reduce(SIMD3<Float>(repeating: -.infinity)) { simd_max($0, $1) }
        let bounds = SIMD3<Double>(high - low)
        let solid = envelope.blocks.reduce(0.0) { $0 + Double($1.size.x * $1.size.y * $1.size.z) }
        return max(bounds.x * bounds.y * bounds.z - solid, 0)
    }

    /// Inside overpressure of a sealed room of `volume` m³ filled through orifices that open
    /// when their panes break: each `(area m², opens at s, outer mean pressures per bin Pa)`.
    /// Mass flows as through a sharp-edged orifice (discharge 0.6) on the pressure difference, at
    /// the upstream side's isentropic density; the room's air compresses adiabatically. One way:
    /// the air outside never feels it. Within a factor of about 2.3 of the detailed buildings'
    /// inside gauges, mostly above, and 0.95–1.35 times UFC 3-340-02's leakage fill
    /// (`leakageFill`); through windows, well under the UFC's loads on the walls inside
    /// (validation.md).
    public static func fill(
        volume: Double, openings: [(area: Double, opens: Double, outer: [Double])], bin: Double
    )
        -> (peak: Double, impulse: Double)
    {
        guard volume > 0 else { return (0, 0) }
        let ambient = 101_325.0
        let density = 1.204
        let gamma = 1.4
        let count = openings.map(\.outer.count).max() ?? 0
        var mass = density * volume
        var peak = 0.0
        var impulse = 0.0
        let substeps = 20
        let h = bin / Double(substeps)
        for index in 0..<count {
            for sub in 0..<substeps {
                let time = Double(index) * bin + Double(sub) * h
                let inside = ambient * pow(mass / (density * volume), gamma)
                var flow = 0.0
                for opening in openings where time >= opening.opens && index < opening.outer.count {
                    let outside = ambient + opening.outer[index]
                    let difference = outside - inside
                    let upstream = max(outside, inside)
                    let rho = density * pow(upstream / ambient, 1 / gamma)
                    flow +=
                        (difference >= 0 ? 1 : -1) * 0.6 * opening.area
                        * (2 * rho * abs(difference)).squareRoot()
                }
                mass = max(mass + flow * h, 1e-3)
                let over = ambient * pow(mass / (density * volume), gamma) - ambient
                peak = max(peak, over)
                impulse += max(over, 0) * h
            }
        }
        return (peak, impulse)
    }
}
