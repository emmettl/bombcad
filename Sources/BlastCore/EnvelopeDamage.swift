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

    public init(
        id: String, owner: UUID, kind: Kind, region: Box, axis: Int, binS: Double, outerPa: [Double],
        innerPa: [Double], supportEdges: [Bool]? = nil
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
    }

    /// A recorded history's load: its bins' impulses over the bin width.
    public init(_ history: EnvelopeComponentHistory) {
        let kind = Kind(rawValue: history.component.kind.rawValue) ?? .wall
        self.init(
            id: history.component.id, owner: history.component.owner, kind: kind,
            region: history.component.region,
            axis: history.component.axis, binS: history.binS,
            outerPa: history.outerImpulsePaS.map { Double($0) / history.binS },
            innerPa: history.innerImpulsePaS.map { Double($0) / history.binS },
            supportEdges: history.component.supportEdges)
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
    /// True for a freestanding wall, judged as a cantilever from its foot rather than a panel on
    /// its edges; nil for a panel (left out of the JSON, which older records lack).
    public var cantilever: Bool?
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
    /// How long a freestanding masonry wall is followed after its load, s: long enough to see a
    /// rocking wall fall.
    public static let rockingFollowS = 3.0
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
                firstPaneBrokenAtS: panes.compactMap(\.failedAtS).min(), insidePeakPa: inside.peak,
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
            let pane = EnvelopePanel.glass(
                thickness: Double(construction.glassThicknessM), material: .annealedGlass, a: a, b: b)
            let response = pane.response(pressures: pressures, step: load.binS)
            let level: EnvelopeDamageLevel = response.lostResistanceAt == nil ? .none : .failed
            let rotation = Self.rotation(response, span: a)
            return damage(.annealedGlass, rotation...rotation, level...level, response.lostResistanceAt)
        }
        if load.isFreestanding {
            return cantilever(load, construction: construction, pressures: pressures, peak: peak)
        }
        let isRoof = load.kind == .roof || load.kind == .slab
        let kind = isRoof ? construction.roof : construction.walls
        let thickness = Double(isRoof ? construction.roofThicknessM : construction.wallThicknessM)
        if let span = load.oneWaySpan.map({ min($0, largestSpan) }) {
            return oneWay(
                load, kind: kind, thickness: thickness, span: span, construction: construction,
                pressures: pressures, peak: peak)
        }
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

    /// A freestanding wall's damage, as a cantilever from its foot (`EnvelopePanel`'s cantilever
    /// systems): concrete by ASCE/SEI 59-11's support rotations, atan(top / height) as UFC Table
    /// 3-5 measures a cantilever's; masonry uncracked, cracked or fallen (its top past its
    /// thickness), as panels are graded. The rotation range is one value: a cantilever's base is
    /// fixed, its top free. The short span reported is the height.
    static func cantilever(
        _ load: EnvelopeComponentLoad, construction: EnvelopeConstruction, pressures net: [Double],
        peak: Double
    ) -> EnvelopeComponentDamage {
        let pressures = cantileverLoad(net)
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
        case .reinforcedConcrete:
            let response = EnvelopePanel.reinforcedConcreteCantilever(
                thickness: thickness, depth: thickness / 2,
                steelArea: Double(construction.reinforcementRatio) * thickness, material: .reinforcedConcrete,
                height: height
            )
            .response(pressures: pressures, step: load.binS)
            let rotation =
                atan(max(response.peakDeflection, -response.reboundDeflection) / height) * 180 / .pi
            return damage(
                .reinforcedConcrete, response,
                EnvelopeDamageLevel.concrete(ductility: response.ductility, rotationDeg: rotation))
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
            return damage(.unreinforcedMasonry, response, level)
        }
    }

    /// A component held on two opposite edges, as a one-way strip between them (`EnvelopePanel`'s
    /// one-way systems): concrete between fixed and simply supported ends, by ASCE/SEI 59-11;
    /// masonry with fixed ends, as panels, uncracked, cracked or fallen.
    static func oneWay(
        _ load: EnvelopeComponentLoad, kind: EnvelopeConstruction.Kind, thickness: Double, span: Double,
        construction: EnvelopeConstruction, pressures: [Double], peak: Double
    ) -> EnvelopeComponentDamage {
        func damage(
            _ material: EnvelopeComponentDamage.Material, _ rotation: ClosedRange<Double>,
            _ levels: ClosedRange<EnvelopeDamageLevel>, _ failed: Double?
        ) -> EnvelopeComponentDamage {
            EnvelopeComponentDamage(
                id: load.id, owner: load.owner, kind: load.kind, material: material, shortSpanM: span,
                peakNetPa: peak, rotationDeg: rotation, levels: levels, failedAtS: failed)
        }
        switch kind {
        case .reinforcedConcrete:
            let responses = [EnvelopePanel.Edges.fixed, .simplySupported].map { edges in
                EnvelopePanel.reinforcedOneWay(
                    thickness: thickness, depth: thickness / 2,
                    steelArea: Double(construction.reinforcementRatio) * thickness,
                    material: .reinforcedConcrete,
                    span: span, edges: edges
                ).response(pressures: pressures, step: load.binS)
            }
            let rotations = responses.map { rotation($0, span: span) }
            let levels = zip(responses, rotations).map {
                EnvelopeDamageLevel.concrete(ductility: $0.ductility, rotationDeg: $1)
            }
            return damage(
                .reinforcedConcrete, rotations.min()!...rotations.max()!, levels.min()!...levels.max()!, nil)
        case .unreinforcedMasonry:
            var masonry = StructureMaterial.masonry
            masonry.steel = nil
            let response = EnvelopePanel.unreinforcedMasonryOneWay(
                thickness: thickness, material: masonry, span: span, edges: .fixed
            )
            .response(pressures: pressures, step: load.binS)
            let level: EnvelopeDamageLevel =
                response.lostResistanceAt != nil ? .failed : (response.ductility > 1 ? .heavy : .none)
            let rotation = Self.rotation(response, span: span)
            return damage(.unreinforcedMasonry, rotation...rotation, level...level, response.lostResistanceAt)
        }
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
