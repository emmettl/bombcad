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
