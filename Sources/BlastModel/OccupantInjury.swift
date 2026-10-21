import Foundation
import simd

// People in the scene (emmettl/bombcad-work#41, first step): each envelope building's occupants by
// its use and the time of day, and the people it would expect hurt from the quick estimate's glass
// and wall chances and the blast's own peak, with a band over the assumptions and their standing.
// docs/people-in-the-scene.md gives the sources, the judge and the limits.

/// What a building is used for, as far as who is in it goes.
public enum BuildingUse: String, Codable, Sendable, CaseIterable, Identifiable {
    case residential, office, retail, education, health, hotel, worship, industrial, unoccupied

    public var id: Self { self }

    public var label: String {
        switch self {
        case .residential: "Residential"
        case .office: "Offices"
        case .retail: "Shops and restaurants"
        case .education: "Schools and universities"
        case .health: "Hospitals and clinics"
        case .hotel: "Hotels"
        case .worship: "Places of worship"
        case .industrial: "Industry and storage"
        case .unoccupied: "Unoccupied"
        }
    }

    /// From a map building's `building` or `building:use` tag; nil where it says nothing of use
    /// (`yes`, or a value not listed).
    public init?(mapTag tag: String?) {
        guard let tag = tag?.lowercased() else { return nil }
        switch tag {
        case "residential", "apartments", "house", "detached", "terrace", "semidetached_house", "dormitory",
            "bungalow", "farm", "flats", "home":
            self = .residential
        case "office", "commercial", "government", "government_office", "public", "civic", "embassy", "bank":
            self = .office
        case "retail", "shop", "supermarket", "kiosk", "restaurant", "market", "mall":
            self = .retail
        case "school", "university", "college", "kindergarten":
            self = .education
        case "hospital", "clinic":
            self = .health
        case "hotel", "hostel":
            self = .hotel
        case "church", "mosque", "chapel", "cathedral", "temple", "synagogue", "religious", "monastery":
            self = .worship
        case "industrial", "warehouse", "factory", "manufacture", "shed", "hangar", "storage_tank", "silo",
            "barn", "garage", "garages", "service", "transportation", "train_station", "port":
            self = .industrial
        case "roof", "ruins", "construction", "collapsed", "abandoned", "carport", "bunker", "tower":
            self = .unoccupied
        default:
            return nil
        }
    }
}

/// The time of day the people are placed for: Hazus's three (FEMA Hazus Earthquake Model
/// Technical Manual 4.2, Table 12-2).
public enum OccupancyTime: String, Codable, Sendable, CaseIterable, Identifiable {
    /// 2 am: nearly everyone at home.
    case night
    /// 2 pm on a working day: at work and school.
    case workday
    /// 5 pm on a working day: going home (Beirut's explosion was at 18:08).
    case evening

    public var id: Self { self }

    public var label: String {
        switch self {
        case .night: "Night (2 am)"
        case .workday: "Working day (2 pm)"
        case .evening: "Evening (5 pm)"
        }
    }
}

/// Each envelope building's occupants and the people it would expect hurt, from the quick
/// estimate's chances (`FacadeLoadSurrogate.Prepared.Look`). Illustrative: the injury rates are
/// published models from other events and hazards, not fitted to this one, with wide bands
/// (docs/people-in-the-scene.md).
public enum OccupantInjury {
    /// How the figures are judged: illustrative, whatever the estimate under them.
    public static let level = EvidenceLevel.illustrative

    /// What the planner says first: its figures are relative (docs/people-in-the-scene.md).
    public static let relativeNote =
        "Illustrative, not a casualty estimate: where people are hurt, as shares, and how a place of the charge, "
        + "the time of day or a protection changes it against a pinned baseline. The shares read high as the "
        + "counts do; compare them with each other."

    /// What the counts say first, behind their disclosure (docs/people-in-the-scene.md, "Judged
    /// against Beirut").
    public static let warning =
        "These counts read 4 to 12 times Beirut's record. On Beirut 2020 (0.5 kt at 5 pm) they give about 78,000 "
        + "hurt and 900 killed within 2.5 km, where about 6,500 injured and 218 killed were recorded across the "
        + "city. Glass is nearly all of it: inside 1.5 km the estimate breaks 80–98% of panes, where Kummer's "
        + "injury curve is steep, and the injury rates come from other events and hazards, fitted to none here."

    /// Its standing, worded from docs/people-in-the-scene.md.
    public static let standing: [String] = [
        "\(level.title). People by published planning densities and Hazus's distribution by time of day; most "
            + "map buildings' use is not tagged, and is the one chosen for untagged buildings.",
        "Hurt by glass by Kummer's injury against the share of panes broken (2004), on the estimate's own share, "
            + "which inside 1.5 km of Beirut breaks nearly every pane; by the walls at Hazus's earthquake casualty "
            + "rates for moderate and extensive damage, borrowed; by the blast by Eisenberg's eardrum and lung "
            + "probits on the free field. No collapse, fragments, envelope debris or falling glass outdoors.",
        "A change against the pinned baseline is the ratio of the two, draw by draw over the same draws of the "
            + "assumptions, so what they share cancels; the look's own doubt (the yield's) does not.",
    ]

    /// The counts' standing, shown with them.
    public static let countsStanding: [String] = [
        "Against Beirut: 12 times the injured recorded, severely hurt or killed about as many as all the injured "
            + "recorded, 4 times the killed; 80% of the hurt 0.5–1.7 km out where 71% of a hospital sample were, "
            + "and nearly all indoors where 81% were. No open record gives injuries by place to fit it to.",
        "The band (5–95%) is over the assumptions (density, the glass's and walls' rates, the share out of doors), "
            + "each drawn once for the whole district; the yield's doubt is in the chances' means, not the band.",
    ]

    /// What the figures assume. The time, the density's factor and the use of untagged buildings
    /// are the user's; the rest are the defaults docs/people-in-the-scene.md sources.
    public struct Assumptions: Sendable, Equatable, Codable {
        public var time: OccupancyTime = .evening
        /// A factor on every building's density, for a district fuller or emptier than the table.
        public var densityScale: Double = 1
        /// The use of a building whose tags say nothing (most of a map's: OSM's `building=yes`).
        public var untaggedUse: BuildingUse = .residential

        public init() {}
    }

    /// The factors each assumption lies within nine times in ten, drawn for the band.
    public static let within = (density: 1.5, glass: 3.0, structure: 3.0, outdoors: 2.0)
    /// How deep the zone behind a façade is whose people see the blast through a blown-out window,
    /// m (GSA's condition 3b's 3 m).
    public static let windowZoneM = 3.0

    /// Gross floor area per person when the building is full, m², by use (planning densities,
    /// docs/people-in-the-scene.md, "Occupants").
    public static func floorAreaPerPerson(_ use: BuildingUse) -> Double {
        switch use {
        case .residential: 30
        case .office: 12
        case .retail: 15
        case .education: 10
        case .health: 25
        case .hotel: 35
        case .worship: 10
        case .industrial: 50
        case .unoccupied: .infinity
        }
    }

    /// The share of a full building's people in it or by it at `time`, by use: Hazus's Table 12-2
    /// where it gives one (residential, commercial, industrial, hotels), otherwise assumed.
    public static func present(_ use: BuildingUse, at time: OccupancyTime) -> Double {
        switch (use, time) {
        // 0.99 NRES at night, 0.75 DRES (about 0.6 NRES) by day, 0.5 NRES at 5 pm.
        case (.residential, .night): 0.99
        case (.residential, .workday): 0.45
        case (.residential, .evening): 0.50
        // Commercial workers: 0.02, 0.98 and 0.98 × 0.5.
        case (.office, .night): 0.02
        case (.office, .workday): 0.98
        case (.office, .evening): 0.49
        case (.retail, .night): 0.02
        case (.retail, .workday): 0.98
        case (.retail, .evening): 0.49
        case (.health, .night): 0.70
        case (.health, .workday): 0.98
        case (.health, .evening): 0.80
        case (.education, .night): 0
        case (.education, .workday): 0.90
        case (.education, .evening): 0.10
        case (.worship, .night): 0
        case (.worship, .workday): 0.05
        case (.worship, .evening): 0.10
        // Hotels: 0.999, 0.19 and 0.299 of their guests.
        case (.hotel, .night): 0.999
        case (.hotel, .workday): 0.19
        case (.hotel, .evening): 0.299
        // Industrial workers: 0.10, 0.80 and 0.50.
        case (.industrial, .night): 0.10
        case (.industrial, .workday): 0.80
        case (.industrial, .evening): 0.50
        case (.unoccupied, _): 0
        }
    }

    /// The share of those present who are out of doors by the building: one less Hazus's indoor
    /// fraction (Table 12-2: residential 0.999 at night and 0.70 by day and at 5 pm; commercial
    /// 0.999, 0.99 and 0.98; industrial 0.999, 0.90 and 0.90).
    public static func outdoorShare(_ use: BuildingUse, at time: OccupancyTime) -> Double {
        if time == .night { return 0.001 }
        switch use {
        case .residential: return 0.30
        case .industrial: return 0.10
        case .unoccupied: return 0
        default: return time == .workday ? 0.01 : 0.02
        }
    }

    /// The chance a person inside is hurt by flying glass, when a share `broken` of the building's
    /// panes break: Kummer's model (31st DoD Explosives Safety Seminar, 2004, Table 3), 1% broken
    /// hurting 0.1%, half 10% and all of them everyone, between them on logarithms. Severe injury
    /// is a tenth of it, death a hundredth.
    public static func glassHurt(broken: Double) -> Double {
        let b = min(max(broken, 0), 1)
        guard b > 0 else { return 0 }
        let points: [(b: Double, p: Double)] = [(0.01, 0.001), (0.5, 0.1), (1, 1)]
        let (lo, hi) = b <= points[1].b ? (points[0], points[1]) : (points[1], points[2])
        let slope = log(hi.p / lo.p) / log(hi.b / lo.b)
        return min(1, lo.p * pow(b / lo.b, slope))
    }

    /// Hazus's indoor casualty rates, all severities and severity 2 or worse, at its moderate and
    /// extensive damage states (Tables 12-4 and 12-5, most building types; unreinforced masonry's
    /// twice as high when extensive), borrowed for the walls damaged moderately and heavily: there is no blast-damage
    /// table like it in the open.
    public static func structureRates(_ walls: EnvelopeConstruction.Kind) -> (
        moderate: (hurt: Double, severe: Double), heavy: (hurt: Double, severe: Double)
    ) {
        walls == .unreinforcedMasonry
            ? ((0.0028, 0.0003), (0.02204, 0.00204)) : ((0.0028, 0.0003), (0.01102, 0.00102))
    }

    /// The chance of an eardrum rupture under an effective overpressure `pa` (Pa): Eisenberg's
    /// probit, `Y = −12.6 + 1.524 ln p` (as the TNO Green Book gives it), 50% at 103 kPa, UFC
    /// 3-340-02's 15 psi.
    public static func eardrumRupture(pa: Double) -> Double {
        guard pa > 0 else { return 0 }
        return probit(-12.6 + 1.524 * log(pa))
    }

    /// The chance of death from lung injury under an incident overpressure `pa` (Pa): Eisenberg's
    /// probit, `Y = −77.1 + 6.91 ln p`.
    public static func lungDeath(pa: Double) -> Double {
        guard pa > 0 else { return 0 }
        return probit(-77.1 + 6.91 * log(pa))
    }

    static func probit(_ y: Double) -> Double { 0.5 * (1 + erf((y - 5) / 2.0.squareRoot())) }

    /// The blast's own chances at `distanceM` from a surface burst whose cube root is `scale`
    /// (Kingery–Bulmash's free field, no shielding): hurt (an eardrum ruptured on the incident plus
    /// dynamic pressure, or the lungs) and severely (death from the lungs).
    static func blastHurt(distanceM: Double, scale: Double) -> (hurt: Double, severe: Double) {
        let z = max(distanceM, 0) / scale
        guard z < 40, let point = KingeryBulmash.point(at: max(z, 0.2)) else { return (0, 0) }
        let p = point.incidentPressure
        let lung = lungDeath(pa: p)
        return (1 - (1 - eardrumRupture(pa: p + BlastInjury.dynamic(p))) * (1 - lung), lung)
    }

    /// One building's people.
    public struct Building: Sendable, Equatable, Identifiable {
        public var owner: UUID
        public var use: BuildingUse
        /// Whether `use` is the assumption for untagged buildings, not its own.
        public var useAssumed: Bool
        public var floorAreaM2: Double
        /// Inside at the time, and out of doors by it, at the density's median.
        public var occupants: Double
        public var outdoors: Double
        /// The people expected hurt (all severities, the killed among them): the mean over the
        /// assumptions' draws, and their 5% and 95% points; and those hurt severely or killed.
        public var expected: Double
        public var low: Double
        public var high: Double
        public var severe: Double
        /// Of them, the killed: glass's hundredth (Kummer) and the lungs' (the walls' Hazus rate,
        /// a hundred-thousandth, is left out).
        public var killed: Double = 0
        /// The mean's parts by cause: glass, the walls and roof, the blast's own pressure.
        public var glass: Double
        public var structure: Double
        public var blast: Double
        /// The share of its panes the estimate expects broken.
        public var broken: Double
        /// From the charge to its middle, across the ground, m.
        public var distanceM: Double = 0

        public var id: UUID { owner }
        /// The share of its people expected hurt.
        public var share: Double {
            let people = occupants + outdoors
            return people > 0 ? min(1, expected / people) : 0
        }
    }

    /// The district's people.
    public struct Estimate: Sendable, Equatable {
        public var buildings: [Building]
        public var assumptions: Assumptions
        /// Everyone placed, inside and out, at the density's median.
        public var people: Double
        /// The people expected hurt: the mean, and the 5% and 95% points over the assumptions'
        /// draws, each draw shared by every building (the assumptions are the same everywhere);
        /// and those hurt severely or killed, with theirs.
        public var expected: Double
        public var low: Double
        public var high: Double
        public var severe: Double
        public var severeLow: Double
        public var severeHigh: Double
        public var killed: Double = 0
        public var glass: Double
        public var structure: Double
        public var blast: Double
        /// Whether its glass and walls came from a drag's preview.
        public var preview: Bool
        /// Whether the walls' and roofs' chances were in the look (a preview of the glass has none).
        public var hasStructure: Bool
        public var seconds: Double
        /// The hurt and the severely hurt or killed in each draw of the assumptions, in the draws'
        /// order: the same seed gives every estimate the same draws, so two estimates compare draw
        /// by draw (`compare`).
        public var totals: [Double] = []
        public var severeTotals: [Double] = []
        /// The charge's cube root, kg^(1/3), for bands by scaled distance.
        public var scale: Double = 1

        public static let empty = Estimate(
            buildings: [], assumptions: Assumptions(), people: 0, expected: 0, low: 0, high: 0, severe: 0,
            severeLow: 0, severeHigh: 0, glass: 0, structure: 0, blast: 0, preview: false,
            hasStructure: false,
            seconds: 0)

        /// The planner's lines: the people, those hurt with the band, and the causes.
        public var summary: String {
            String(
                format:
                    "%@ people placed (%@). Expected hurt %@ (%@–%@), severely or killed %@ (%@–%@), killed %@: by glass %@, the walls and roofs %@, the blast itself %@.",
                OccupantInjury.count(people), assumptions.time.label.lowercased(),
                OccupantInjury.count(expected),
                OccupantInjury.count(low), OccupantInjury.count(high), OccupantInjury.count(severe),
                OccupantInjury.count(severeLow), OccupantInjury.count(severeHigh),
                OccupantInjury.count(killed),
                OccupantInjury.count(glass),
                hasStructure ? OccupantInjury.count(structure) : "not in a preview",
                OccupantInjury.count(blast))
        }
    }

    /// A count of people as the planner shows it: whole, with thousands separated.
    public static func count(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        if value > 0, value < 10 { return String(format: "%.1f", value) }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value.rounded())) ?? "\(Int(value.rounded()))"
    }

    /// The bounds of an envelope's solids.
    package struct Bounds {
        package var centre: SIMD3<Float>
        package var size: SIMD3<Float>

        package init(_ object: SceneObject) {
            let solids = object.envelope?.solids ?? []
            let low = solids.map(\.min).reduce(SIMD3<Float>(repeating: .greatestFiniteMagnitude)) {
                simd_min($0, $1)
            }
            let high = solids.map(\.max).reduce(SIMD3<Float>(repeating: -.greatestFiniteMagnitude)) {
                simd_max($0, $1)
            }
            centre = solids.isEmpty ? .zero : 0.5 * (low + high)
            size = solids.isEmpty ? .zero : high - low
        }
    }

    /// A building's floor area and footprint, m²: its footprint (a map building's solids, which are
    /// disjoint and full height; otherwise its solids' bounds) times a storey each 3 m.
    public static func floorArea(of object: SceneObject, map: Bool) -> (areaM2: Double, footprintM2: Double) {
        guard let envelope = object.envelope, !envelope.solids.isEmpty else { return (0, 0) }
        let bounds = Bounds(object)
        let footprint =
            map
            ? envelope.solids.reduce(0.0) { $0 + Double(($1.max.x - $1.min.x) * ($1.max.y - $1.min.y)) }
            : Double(bounds.size.x * bounds.size.y)
        let storeys = max(1, (Double(bounds.size.z) / 3).rounded())
        return (footprint * storeys, footprint)
    }

    /// The district's people and those expected hurt, for `scene`'s envelope buildings, from a
    /// look's glass chances by side and walls' and roofs' chances (either may be empty: its part is
    /// then nought), a charge of `mass` kg TNT at `charge`.
    public static func estimate(
        scene: Scenario, glass: [FacadeLoadSurrogate.SideGlass],
        structure: [FacadeLoadSurrogate.StructureChance],
        charge: SIMD3<Float>, mass: Double, assumptions: Assumptions = Assumptions(), preview: Bool = false,
        draws: Int = 200
    ) -> Estimate {
        let start = ContinuousClock.now
        let sides = Dictionary(grouping: glass, by: \.owner)
        let structures = Dictionary(structure.map { ($0.owner, $0) }, uniquingKeysWith: { a, _ in a })
        let mapped = Set((scene.envelopeSources ?? []).filter { $0.kind == .map }.map(\.objectID))
        let scale = cbrt(max(mass, 1e-9))
        let constructions = constructionsByObject(scene)

        // Each building's groups of people, worked out once: who is where and what each is exposed
        // to. The draws scale the rates.
        struct Group {
            var people: Double
            var outdoors: Bool
            /// Glass's chance of hurting them at the model's median (Kummer's, on the building's
            /// broken share).
            var glass: Double
            /// The walls' rates, hurt and severe, at their medians.
            var structure: (hurt: Double, severe: Double)
            /// The blast's own chances.
            var blast: (hurt: Double, severe: Double)
        }
        var people: [(building: Building, groups: [Group])] = []
        people.reserveCapacity(scene.envelopeObjects.count)
        for object in scene.envelopeObjects {
            let construction = constructions[object.id] ?? .assumed(objectID: object.id)
            let use = construction.use ?? assumptions.untaggedUse
            let (area, footprint) = floorArea(of: object, map: mapped.contains(object.id))
            let perPerson = floorAreaPerPerson(use)
            let full = perPerson.isFinite && area > 0 ? area / perPerson * assumptions.densityScale : 0
            let present = full * present(use, at: assumptions.time)
            let outdoors = present * outdoorShare(use, at: assumptions.time)
            let inside = present - outdoors
            let bounds = Bounds(object)
            var building = Building(
                owner: object.id, use: use, useAssumed: construction.use == nil, floorAreaM2: area,
                occupants: inside, outdoors: outdoors, expected: 0, low: 0, high: 0, severe: 0, glass: 0,
                structure: 0, blast: 0, broken: 0)
            building.distanceM = Double(
                simd_length(SIMD2(bounds.centre.x - charge.x, bounds.centre.y - charge.y)))
            guard present > 0 else {
                people.append((building, []))
                continue
            }

            // The building's broken share, its sides' weighted by their length; and each side's zone.
            let mine = (sides[object.id] ?? []).filter { $0.axis < 2 }
            func length(_ side: FacadeLoadSurrogate.SideGlass) -> Double {
                Double(side.axis == 0 ? bounds.size.y : bounds.size.x)
            }
            let lengths = mine.reduce(0) { $0 + length($1) }
            let broken = lengths > 0 ? mine.reduce(0) { $0 + length($1) * $1.fractionBroken } / lengths : 0
            building.broken = broken
            let glassRate = glassHurt(broken: broken)

            // The walls' moderate-only and heavy chances, and the roof's on the top storey.
            let rates = structureRates(construction.walls)
            let walls = structures[object.id]
            let heavy = walls.map { min(max($0.wallsHeavy, 0), 1) } ?? 0
            let moderate =
                (walls.map { min(max($0.wallsModerate - $0.wallsHeavy, 0), 1) } ?? 0)
                + (walls.map { min(max($0.roofModerate, 0), 1) } ?? 0)
                / max(1, footprint > 0 ? area / footprint : 1)
            let structureRate = (
                hurt: min(1, moderate * rates.moderate.hurt + heavy * rates.heavy.hurt),
                severe: min(1, moderate * rates.moderate.severe + heavy * rates.heavy.severe)
            )

            // By a blown-out window the blast reaches them as it is outside.
            var groups: [Group] = []
            var zone = 0.0
            for side in mine {
                let share = footprint > 0 ? min(1, windowZoneM * length(side) / footprint) : 0
                let open = blastHurt(distanceM: side.distanceM, scale: scale)
                groups.append(
                    Group(
                        people: share, outdoors: false, glass: glassRate, structure: structureRate,
                        blast: (side.blownOut * open.hurt, side.blownOut * open.severe)))
                zone += share
            }
            if zone > 1 {
                for g in groups.indices { groups[g].people /= zone }
                zone = 1
            }
            for g in groups.indices { groups[g].people *= inside }
            groups.append(
                Group(
                    people: inside * (1 - zone), outdoors: false, glass: glassRate, structure: structureRate,
                    blast: (0, 0)))
            if outdoors > 0 {
                let nearest =
                    mine.map(\.distanceM).min()
                    ?? Double(simd_length(SIMD2(bounds.centre.x - charge.x, bounds.centre.y - charge.y)))
                groups.append(
                    Group(
                        people: outdoors, outdoors: true, glass: 0, structure: (0, 0),
                        blast: blastHurt(distanceM: nearest, scale: scale)))
            }
            people.append((building, groups))
        }

        // The draws: every assumption's factor, shared by the whole district.
        let n = max(1, draws)
        var random = SplitMix64(seed: 0x41_0CC0_9A47)
        func factor(_ within: Double) -> Double {
            let u = max(random.unit(), 1e-300)
            let v = random.unit()
            return exp((-2 * log(u)).squareRoot() * cos(2 * .pi * v) * log(max(within, 1)) / 1.645)
        }
        let factors = (0..<n).map { _ in
            (
                density: factor(within.density), glass: factor(within.glass),
                structure: factor(within.structure),
                outdoors: factor(within.outdoors)
            )
        }
        var totals = [Double](repeating: 0, count: n)
        var severeTotals = [Double](repeating: 0, count: n)
        var estimate = Estimate.empty
        estimate.assumptions = assumptions
        estimate.preview = preview
        estimate.hasStructure = !structure.isEmpty
        var buildings: [Building] = []
        buildings.reserveCapacity(people.count)
        var hurtDraws = [Double](repeating: 0, count: n)
        for (building, groups) in people {
            var result = building
            var parts = (glass: 0.0, structure: 0.0, blast: 0.0)
            var severe = 0.0
            var killed = 0.0
            for (d, f) in factors.enumerated() {
                var hurt = 0.0
                for g in groups {
                    let count = g.people * f.density * (g.outdoors ? f.outdoors : 1)
                    let glass = min(1, g.glass * f.glass)
                    let walls = min(1, g.structure.hurt * f.structure)
                    let blast = g.blast.hurt
                    let p = 1 - (1 - glass) * (1 - walls) * (1 - blast)
                    hurt += count * p
                    let sum = glass + walls + blast
                    if sum > 0 {
                        parts.glass += count * p * glass / sum
                        parts.structure += count * p * walls / sum
                        parts.blast += count * p * blast / sum
                    }
                    let s =
                        1 - (1 - glass * 0.1) * (1 - min(1, g.structure.severe * f.structure))
                        * (1 - g.blast.severe)
                    severe += count * s
                    severeTotals[d] += count * s
                    killed += count * (1 - (1 - glass * 0.01) * (1 - g.blast.severe))
                }
                hurtDraws[d] = hurt
                totals[d] += hurt
            }
            result.expected = hurtDraws.reduce(0, +) / Double(n)
            (result.low, result.high) = percentiles(hurtDraws)
            result.severe = severe / Double(n)
            result.killed = killed / Double(n)
            estimate.killed += result.killed
            result.glass = parts.glass / Double(n)
            result.structure = parts.structure / Double(n)
            result.blast = parts.blast / Double(n)
            estimate.people += result.occupants + result.outdoors
            estimate.glass += result.glass
            estimate.structure += result.structure
            estimate.blast += result.blast
            buildings.append(result)
        }
        estimate.buildings = buildings
        estimate.totals = totals
        estimate.severeTotals = severeTotals
        estimate.scale = scale
        estimate.expected = totals.reduce(0, +) / Double(n)
        (estimate.low, estimate.high) = percentiles(totals)
        estimate.severe = severeTotals.reduce(0, +) / Double(n)
        (estimate.severeLow, estimate.severeHigh) = percentiles(severeTotals)
        let took = start.duration(to: .now)
        estimate.seconds = Double(took.components.seconds) + Double(took.components.attoseconds) * 1e-18
        return estimate
    }

    /// How one estimate's people hurt compare with a pinned one's: the relative change in the hurt
    /// and in the severely hurt or killed, means' ratio less one, and the 5% and 95% points of the
    /// change draw by draw. The assumptions' draws are the same in both (one seed), so what they
    /// share largely cancels: the band is narrower than either estimate's own.
    public struct Comparison: Sendable, Equatable {
        public var hurt: Double
        public var low: Double
        public var high: Double
        public var severe: Double
        /// Whether the two are for the same buildings; when not, the change is for the district as a
        /// whole, not like for like.
        public var sameBuildings: Bool

        /// "−38% hurt (−41% to −35%)".
        public var summary: String {
            func percent(_ x: Double) -> String {
                let p = (x * 100).rounded()
                return p == 0 ? "0%" : String(format: "%@%.0f%%", p > 0 ? "+" : "−", abs(p))
            }
            return
                "\(percent(hurt)) hurt (\(percent(low)) to \(percent(high))), \(percent(severe)) severely hurt or killed"
        }
    }

    /// `now` against `base`, draw by draw over the draws both have (a preview's are the first of a
    /// full estimate's); nil when the base expects no one hurt.
    public static func compare(_ now: Estimate, against base: Estimate) -> Comparison? {
        let n = min(now.totals.count, base.totals.count)
        func change(_ a: [Double], _ b: [Double]) -> Double {
            let (x, y) = (a.prefix(n).reduce(0, +), b.prefix(n).reduce(0, +))
            return y > 0 ? x / y - 1 : 0
        }
        guard n > 0, base.totals.prefix(n).reduce(0, +) > 0 else { return nil }
        let changes = (0..<n).compactMap { d in base.totals[d] > 0 ? now.totals[d] / base.totals[d] - 1 : nil
        }
        let (low, high) = changes.isEmpty ? (0, 0) : percentiles(changes)
        return Comparison(
            hurt: change(now.totals, base.totals), low: low, high: high,
            severe: change(now.severeTotals, base.severeTotals),
            sameBuildings: Set(now.buildings.map(\.owner)) == Set(base.buildings.map(\.owner)))
    }

    /// The people and the share of them hurt by distance from the charge, in bands of scaled
    /// distance (m/kg^(1/3)) shown in metres.
    public struct Band: Sendable, Equatable, Identifiable {
        public var fromM: Double
        public var toM: Double
        public var people: Double
        public var hurt: Double
        public var id: Double { fromM }
        public var share: Double { people > 0 ? hurt / people : 0 }
    }

    /// The bands' edges, m/kg^(1/3).
    public static let bandEdges: [Double] = [0, 5, 10, 15, 20, 30]

    public static func bands(_ estimate: Estimate) -> [Band] {
        let edges = bandEdges.map { $0 * estimate.scale } + [.infinity]
        return (0..<(edges.count - 1)).compactMap { k in
            let mine = estimate.buildings.filter { $0.distanceM >= edges[k] && $0.distanceM < edges[k + 1] }
            let people = mine.reduce(0) { $0 + $1.occupants + $1.outdoors }
            guard people > 0 else { return nil }
            return Band(
                fromM: edges[k], toM: edges[k + 1], people: people, hurt: mine.reduce(0) { $0 + $1.expected })
        }
    }

    /// Each envelope's construction, the last recorded for it (`Scenario.envelopeConstruction`),
    /// looked up once rather than searched for each building.
    static func constructionsByObject(_ scene: Scenario) -> [UUID: EnvelopeConstruction] {
        Dictionary(
            (scene.envelopeConstructions ?? []).map { ($0.objectID, $0) },
            uniquingKeysWith: { _, last in last })
    }

    /// The 5% and 95% points of `values`.
    static func percentiles(_ values: [Double]) -> (Double, Double) {
        guard !values.isEmpty else { return (0, 0) }
        let sorted = values.sorted()
        func at(_ q: Double) -> Double {
            sorted[min(sorted.count - 1, max(0, Int((q * Double(sorted.count - 1)).rounded())))]
        }
        return (at(0.05), at(0.95))
    }

    /// For the judge only: the deaths the Chemical Industries Association's vulnerability curves
    /// (1998, as DNV's Phast documents them) give the people inside, by the free field's incident
    /// overpressure at each building's nearest side: a two-storey brick house's curve for
    /// masonry, a four-storey concrete-frame office's for the rest. Siting curves, cautious by
    /// design: the judge sets them beside the estimate, not in it.
    package static func ciaDeaths(_ estimate: Estimate, scene: Scenario, mass: Double) -> Double {
        let scale = cbrt(max(mass, 1e-9))
        let objects = Dictionary(uniqueKeysWithValues: scene.envelopeObjects.map { ($0.id, $0) })
        let charge = scene.charge.position
        let constructions = constructionsByObject(scene)
        let brick: [(Double, Double)] = [(5e3, 0.01), (10e3, 0.048), (30e3, 0.5), (60e3, 0.7), (100e3, 1)]
        let office: [(Double, Double)] = [(10e3, 0.01), (30e3, 0.62), (60e3, 0.92), (100e3, 1)]
        func curve(_ points: [(Double, Double)], _ p: Double) -> Double {
            guard p >= points[0].0 else { return 0 }
            for k in 1..<points.count where p <= points[k].0 {
                let (a, b) = (points[k - 1], points[k])
                return exp(log(a.1) + log(b.1 / a.1) * log(p / a.0) / log(b.0 / a.0))
            }
            return 1
        }
        return estimate.buildings.reduce(0) { sum, building in
            guard let object = objects[building.owner] else { return sum }
            let b = Bounds(object)
            let r = Double(simd_length(SIMD2(b.centre.x - charge.x, b.centre.y - charge.y)))
            let half = Double(min(b.size.x, b.size.y)) / 2
            let z = max(r - half, 0) / scale
            guard z < 40, let point = KingeryBulmash.point(at: max(z, 0.2)) else { return sum }
            let masonry = constructions[building.owner]?.walls == .unreinforcedMasonry
            return sum + building.occupants * curve(masonry ? brick : office, point.incidentPressure)
        }
    }
}
