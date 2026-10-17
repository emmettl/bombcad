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

    public init(
        id: String, owner: UUID, kind: Kind, region: Box, axis: Int, binS: Double, outerPa: [Double],
        innerPa: [Double]
    ) {
        self.id = id
        self.owner = owner
        self.kind = kind
        self.region = region
        self.axis = axis
        self.binS = binS
        self.outerPa = outerPa
        self.innerPa = innerPa
    }

    /// A recorded history's load: its bins' impulses over the bin width.
    public init(_ history: EnvelopeComponentHistory) {
        let kind = Kind(rawValue: history.component.kind.rawValue) ?? .wall
        self.init(
            id: history.component.id, owner: history.component.owner, kind: kind,
            region: history.component.region,
            axis: history.component.axis, binS: history.binS,
            outerPa: history.outerImpulsePaS.map { Double($0) / history.binS },
            innerPa: history.innerImpulsePaS.map { Double($0) / history.binS })
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
        case reinforcedConcrete, unreinforcedMasonry, annealedGlass
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
    /// Glass: broken, and when (s); masonry: fallen, and when.
    public var failedAtS: Double?
    /// A window's glass: how far into the room it is thrown, as GSA and ASTM grade it; nil for a
    /// skylight or anything else.
    public var glazing: GlazingHazard? = nil
}

/// How hazardous a window's glass is to the room behind it, by where it lands: GSA-TS01's
/// performance conditions and ASTM F1642's hazard ratings, which a test judges by fragments on
/// the floor within 1 and 3 m of the window and on a witness panel 3 m in, below or above 0.6 m
/// (GSA, 2 ft) or 0.5 m (ASTM). Here the glass flies as one piece from the pane's middle, at
/// the speed it broke with and gained from the load that went on pushing it, falling under
/// gravity without drag, the pane's sill `sillM` above the floor.
public struct GlazingHazard: Codable, Sendable, Equatable {
    public enum Condition: String, Codable, Sendable, CaseIterable, Comparable {
        /// 1: not broken; 2: cracked, held by the frame (not distinguished here); 3a: lands within
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
    /// load first stops pushing inward.
    public static func broken(
        response: SDOFResponse, netPa: [Double], binS: Double, massPerArea: Double, paneHeight: Double
    ) -> GlazingHazard {
        guard let at = response.lostResistanceAt else { return whole }
        var speed = response.velocityAtLoss ?? 0
        if speed > 0 {
            var bin = Int(at / binS)
            // The rest of the bin it broke in, then whole bins.
            var span = Double(bin + 1) * binS - at
            while bin < netPa.count, netPa[bin] > 0 {
                speed += netPa[bin] * span / massPerArea
                bin += 1
                span = binS
            }
        }
        return thrown(speed: speed, height: sillM + paneHeight / 2)
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
    /// Inside, from a one-way fill through the broken panes (`EnvelopeDamageAssessment.fill`):
    /// peak overpressure (Pa) and positive impulse (Pa s). Zero with no pane broken.
    public var insidePeakPa: Double
    public var insideImpulsePaS: Double
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
    /// Rotation past which a panel's frame is flagged as beyond the one-way model, degrees.
    public static let frameFlagDeg = 2.0

    public static func assess(
        loads: [EnvelopeComponentLoad], constructions: (UUID) -> EnvelopeConstruction,
        rooms: [UUID: Double] = [:]
    ) -> [EnvelopeBuildingDamage] {
        let owners = Array(Set(loads.map(\.owner))).sorted { $0.uuidString < $1.uuidString }
        return owners.map { owner in
            let construction = constructions(owner)
            let mine = loads.filter { $0.owner == owner }
            var components: [EnvelopeComponentDamage] = []
            var openings: [(area: Double, opens: Double, outer: [Double])] = []
            for load in mine {
                guard let damage = assess(load, construction: construction) else { continue }
                components.append(damage)
                if damage.material == .annealedGlass, let broken = damage.failedAtS {
                    let spans = load.spans
                    openings.append((spans.short * spans.long, broken, load.outerPa))
                }
            }
            let structural = components.filter { $0.material != .annealedGlass }
            let low = structural.map(\.levels.lowerBound).max() ?? .none
            let high = structural.map(\.levels.upperBound).max() ?? .none
            let panes = components.filter { $0.material == .annealedGlass }
            let inside =
                openings.isEmpty
                ? (peak: 0.0, impulse: 0.0)
                : fill(volume: rooms[owner] ?? 0, openings: openings, bin: mine.first?.binS ?? 1e-4)
            return EnvelopeBuildingDamage(
                id: owner, construction: construction, components: components,
                structuralLevels: low...max(low, high),
                beyondOneWay: structural.contains { $0.rotationDeg.upperBound > frameFlagDeg },
                panes: panes.count, panesBroken: panes.filter { $0.failedAtS != nil }.count,
                firstPaneBrokenAtS: panes.compactMap(\.failedAtS).min(),
                worstGlazing: panes.compactMap(\.glazing).max {
                    ($0.condition, $0.speedMS) < ($1.condition, $1.speedMS)
                },
                insidePeakPa: inside.peak,
                insideImpulsePaS: inside.impulse)
        }
    }

    static func rotation(_ response: SDOFResponse, span: Double) -> Double {
        atan(max(response.peakDeflection, -response.reboundDeflection) / (span / 2)) * 180 / .pi
    }

    /// One component's damage, or nil for a component of no known kind.
    public static func assess(_ load: EnvelopeComponentLoad, construction: EnvelopeConstruction)
        -> EnvelopeComponentDamage?
    {
        let spans = load.spans
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
            let pane = EnvelopePanel.largeDeflectionGlass(
                thickness: Double(construction.glassThicknessM), material: .annealedGlass, a: a, b: b)
            let response = pane.response(pressures: pressures, step: load.binS)
            let level: EnvelopeDamageLevel = response.lostResistanceAt == nil ? .none : .failed
            let rotation = Self.rotation(response, span: a)
            var result = damage(.annealedGlass, rotation...rotation, level...level, response.lostResistanceAt)
            if load.axis != 2 {
                result.glazing = GlazingHazard.broken(
                    response: response, netPa: pressures, binS: load.binS, massPerArea: pane.massPerArea,
                    paneHeight: Double(load.region.size.z))
            }
            return result
        }
        let isRoof = load.kind == .roof || load.kind == .slab
        let kind = isRoof ? construction.roof : construction.walls
        let thickness = Double(isRoof ? construction.roofThicknessM : construction.wallThicknessM)
        switch kind {
        case .reinforcedConcrete:
            // A central mat: depth half the thickness, steel the ratio of the gross section.
            let steel = Double(construction.reinforcementRatio) * thickness
            let responses = [EnvelopePanel.Edges.fixed, .simplySupported].map { edges in
                EnvelopePanel.reinforcedConcrete(
                    thickness: thickness, depth: thickness / 2, steelArea: steel,
                    material: .reinforcedConcrete,
                    a: a, b: b, edges: edges
                ).response(pressures: pressures, step: load.binS)
            }
            let rotations = responses.map { rotation($0, span: a) }
            let levels = zip(responses, rotations).map {
                EnvelopeDamageLevel.concrete(ductility: $0.ductility, rotationDeg: $1)
            }
            return damage(
                .reinforcedConcrete, rotations.min()!...rotations.max()!, levels.min()!...levels.max()!, nil)
        case .unreinforcedMasonry:
            var masonry = StructureMaterial.masonry
            masonry.steel = nil
            let response = EnvelopePanel.unreinforcedMasonry(
                thickness: thickness, material: masonry, a: a, b: b
            )
            .response(pressures: pressures, step: load.binS)
            let level: EnvelopeDamageLevel =
                response.lostResistanceAt != nil ? .failed : (response.ductility > 1 ? .heavy : .none)
            let rotation = Self.rotation(response, span: a)
            return damage(.unreinforcedMasonry, rotation...rotation, level...level, response.lostResistanceAt)
        }
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
    /// inside gauges, mostly above (building-envelopes.md).
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
