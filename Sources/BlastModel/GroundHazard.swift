import Foundation
import simd

/// What makes a fragment, or a piece of debris, a hazard to people in the open, as the US
/// explosives safety standards define it.
public enum HazardCriteria {
    /// A hazardous fragment strikes with 58 ft-lb (79 J) or more: DoD 6055.09-M, equation
    /// V3.E3.T2-1 (now DESR 6055.09), as FAA Guide 437.53-1 (2011) restates it.
    public static let hazardousEnergyJ: Float = 79
    /// The hazardous fragment distance is where hazardous fragments fall below one per 600 ft²
    /// (55.7 m²), about a 1% chance of one striking a standing person's 6.2 ft² (0.58 m²): DDESB
    /// TP-12 (Zaker, 1975), p = 1 − exp(−q A_T).
    public static let hazardousAreaM2: Float = 55.7
    /// FAA's lower threshold for a fragment that can seriously injure, 11 ft-lb (14.9 J) (Guide
    /// 437.53-1, "Hazardous fragment").
    public static let injuryEnergyJ: Float = 14.9
}

/// Hazardous fragments (79 J or more) crossing spheres round the charge near the horizontal, where
/// a person standing at that range would meet them: the density DDESB judges by, on a surface
/// normal to the fragments' rays (TP-12, Zaker 1975, p. 10: q = Q₀/R² with Q₀ the fragments per
/// unit solid angle towards the person), rather than where they land. TP-12 takes Q₀ in the one
/// direction of interest; the band of `band` either side of the horizontal averages it over enough
/// of the spray to be sampled, and its part below the ground, which no fragment crosses, is left
/// out (`chargeHeight`). Counted by `FragmentCloud` as each flies.
public struct FragmentCrossings: Codable, Sendable, Equatable {
    /// The spheres' radii, m (`GroundHazard.edges` out to 5 km, the first 1 m).
    public var radii: [Float]
    public var sectors: Int
    /// How far from the horizontal a crossing counts, radians either way.
    public var band: Float
    /// Real hazardous fragments crossing each sphere in each direction (`sphere * sectors +
    /// sector`), and the flown ones among them.
    public var counts: [Float]
    public var samples: [Int]
    /// The charge's height above the ground beneath it, m: below the ground no fragment crosses a
    /// sphere, so that part of the band is not in its area. Nil in results kept before 18 October
    /// 2026, which counted the whole band, and so half the density of a charge on the ground.
    public var chargeHeight: Float?

    public static let standardBand: Float = 10 * .pi / 180

    public init(sectors: Int = 8, band: Float = standardBand) {
        radii = Array(GroundHazard.edges(reaching: 5_000).dropFirst())
        self.sectors = sectors
        self.band = band
        counts = Array(repeating: 0, count: radii.count * sectors)
        samples = Array(repeating: 0, count: radii.count * sectors)
    }

    /// The sphere `s`'s area in one direction's cell of the band above the ground, m².
    public func area(sphere s: Int) -> Float {
        let r = radii[s]
        let lowest = chargeHeight.map { -min(asin(min(max($0, 0) / r, 1)), band) } ?? -band
        return r * r * (2 * .pi / Float(sectors)) * (sin(band) - sin(lowest))
    }

    public func density(sphere s: Int, sector: Int) -> Float {
        counts[s * sectors + sector] / area(sphere: s)
    }

    /// The direction a point lies in from `centre`, as `GroundHazard`'s sectors are.
    static func sector(of offset: SIMD2<Float>, sectors: Int) -> Int {
        var angle = atan2(offset.y, offset.x) + .pi / Float(sectors)
        if angle < 0 { angle += 2 * .pi }
        return min(Int(angle / (2 * .pi) * Float(sectors)), sectors - 1)
    }
}

/// Where fragments or debris landed on the open ground round a charge, by range and direction:
/// the areal density of hazardous ones, and the hazardous fragment distance, past which it stays
/// below one per 55.7 m² (`HazardCriteria`). Pieces stopped by a structure or block are counted
/// apart, as they do not reach open ground.
public struct GroundHazard: Codable, Sendable, Equatable {
    /// The charge's position on the map, m.
    public var centre: SIMD2<Float>
    /// The rings' edges, m from the charge, ring k from `edges[k]` to `edges[k + 1]`; the
    /// directions' sectors, the first centred on +x, counting towards +y.
    public var edges: [Float]
    public var sectors: Int
    public var rings: Int { edges.count - 1 }
    /// Real pieces landed in each cell, ring by ring (`ring * sectors + sector`): all, those of
    /// at least 79 J and those of at least 14.9 J.
    public var landed: [Float]
    public var hazardous: [Float]
    public var injurious: [Float]
    /// The pieces flown that landed hazardous in each cell, which each stand for `hazardous`'s
    /// count between them: how well sampled the cell is.
    public var samples: [Int]
    /// The hazardous fragment distance in each sector, m: the outer edge of the furthest cell
    /// whose density reaches one per 55.7 m²; nil where none does.
    public var sectorDistances: [Float?]
    /// Real hazardous pieces stopped by a structure or block, and the furthest hazardous landing
    /// on open ground (m from the charge).
    public var stoppedHazardous: Float
    public var furthestHazardous: Float?
    /// The same criterion in flight (`FragmentCrossings`): each direction's distance, the
    /// furthest sphere crossed at one per 55.7 m² or more, and the fragments flown setting it;
    /// nil in results without crossings.
    public var airDistances: [Float?]?
    public var airSamples: [Int]?

    /// On the ground, the largest of the sectors' distances, m; nil with no cell over it.
    public var groundDistance: Float? { sectorDistances.compactMap { $0 }.max() }
    /// In flight, the largest of the sectors' distances, m.
    public var airDistance: Float? { airDistances?.compactMap { $0 }.max() }

    /// The hazardous fragment distance: the larger of the ground's and the air's, m.
    public var hazardDistance: Float? { [groundDistance, airDistance].compactMap { $0 }.max() }

    /// The pieces flown in the cell that sets the hazard distance: a handful means it is set by
    /// sampling as much as by the fragments, and more should be flown.
    public var samplesAtDistance: Int {
        if let air = airDistance, air >= groundDistance ?? 0, let distances = airDistances,
            let samples = airSamples
        {
            return distances.indices.filter { distances[$0] == air }.map { samples[$0] }.max() ?? 0
        }
        guard let distance = groundDistance, let ring = edges.firstIndex(of: distance).map({ $0 - 1 }) else {
            return 0
        }
        return (0..<sectors).filter { sectorDistances[$0] == distance }
            .map { samples[ring * sectors + $0] }.max() ?? 0
    }

    /// Fewer hazardous pieces flown than this in the cell that sets the distance, and it is
    /// sampling-limited.
    public static let wellSampled = 10

    /// The ground area of a cell, m².
    public func area(ring: Int) -> Float {
        let (inner, outer) = (edges[ring], edges[ring + 1])
        return .pi * (outer * outer - inner * inner) / Float(sectors)
    }

    /// Hazardous pieces per m² in a cell.
    public func density(ring: Int, sector: Int) -> Float {
        hazardous[ring * sectors + sector] / area(ring: ring)
    }

    /// Real pieces landed in all, and the share of them that are hazardous and injurious.
    public var landedCount: Float { landed.reduce(0, +) }
    public var hazardousShare: Float { landedCount > 0 ? hazardous.reduce(0, +) / landedCount : 0 }
    public var injuriousShare: Float { landedCount > 0 ? injurious.reduce(0, +) / landedCount : 0 }

    /// From impacts round a charge at `centre`, in rings at `edges`, or by default the first a
    /// metre across and each after 10% wider out to the furthest landing, so the distance is to
    /// within 10% at any range.
    public init(
        impacts: [FragmentImpact], centre: SIMD2<Float>, sectors: Int = 8, edges given: [Float]? = nil,
        crossings: FragmentCrossings? = nil
    ) {
        precondition(sectors > 0)
        let ground = impacts.filter { $0.surface == "ground" }
        func range(_ impact: FragmentImpact) -> Float {
            simd_length(SIMD2(impact.position.x, impact.position.y) - centre)
        }
        let furthest = ground.map(range).max() ?? 0
        let edges = given ?? Self.edges(reaching: furthest)
        let rings = edges.count - 1
        self.centre = centre
        self.edges = edges
        self.sectors = sectors
        landed = Array(repeating: 0, count: rings * sectors)
        hazardous = landed
        injurious = landed
        samples = Array(repeating: 0, count: rings * sectors)
        stoppedHazardous = impacts.filter {
            $0.surface != "ground" && $0.energy >= HazardCriteria.hazardousEnergyJ
        }
        .reduce(0) { $0 + $1.count }
        furthestHazardous = ground.filter { $0.energy >= HazardCriteria.hazardousEnergyJ }.map(range).max()
        for impact in ground {
            let offset = SIMD2(impact.position.x, impact.position.y) - centre
            let distance = range(impact)
            let ring = min(max((edges.firstIndex { $0 > distance } ?? edges.count) - 1, 0), rings - 1)
            var angle = atan2(offset.y, offset.x) + .pi / Float(sectors)
            if angle < 0 { angle += 2 * .pi }
            let sector = min(Int(angle / (2 * .pi) * Float(sectors)), sectors - 1)
            let cell = ring * sectors + sector
            landed[cell] += impact.count
            if impact.energy >= HazardCriteria.injuryEnergyJ { injurious[cell] += impact.count }
            if impact.energy >= HazardCriteria.hazardousEnergyJ {
                hazardous[cell] += impact.count
                samples[cell] += 1
            }
        }
        sectorDistances = []
        let criterion = 1 / HazardCriteria.hazardousAreaM2
        var distances: [Float?] = Array(repeating: nil, count: sectors)
        for sector in 0..<sectors {
            if let ring = (0..<rings).last(where: { density(ring: $0, sector: sector) >= criterion }) {
                distances[sector] = edges[ring + 1]
            }
        }
        sectorDistances = distances
        if let crossings {
            var air: [Float?] = Array(repeating: nil, count: crossings.sectors)
            var setBy = Array(repeating: 0, count: crossings.sectors)
            for sector in 0..<crossings.sectors {
                if let s = crossings.radii.indices.last(where: {
                    crossings.density(sphere: $0, sector: sector) >= criterion
                }) {
                    air[sector] = crossings.radii[s]
                    setBy[sector] = crossings.samples[s * crossings.sectors + sector]
                }
            }
            airDistances = air
            airSamples = setBy
        }
    }

    /// One line: the hazard distance, how it is sampled, and the shares hazardous and injurious.
    public var summary: String {
        let distance =
            hazardDistance.map {
                String(format: "hazardous fragment distance %.0f m", $0)
                    + (airDistance.map { String(format: " (in flight %.0f m", $0) } ?? "")
                    + (airDistance != nil
                        ? String(format: ", on the ground %.0f m)", groundDistance ?? 0) : "")
                    + (samplesAtDistance < Self.wellSampled
                        ? " (set by \(samplesAtDistance) flown; fly more)" : "")
            } ?? "no ground over 1 hazardous fragment per 55.7 m²"
        return distance
            + String(
                format: ", %.0f%% of landings hazardous (≥ 79 J), %.0f%% injurious (≥ 14.9 J)",
                100 * hazardousShare,
                100 * injuriousShare)
            + (furthestHazardous.map { String(format: ", furthest hazardous %.0f m", $0) } ?? "")
    }

    /// Ring edges from the charge: 0, 1 m, then each 10% further than the last, past `furthest`.
    package static func edges(reaching furthest: Float) -> [Float] {
        var edges: [Float] = [0, 1]
        while edges.last! <= furthest { edges.append(edges.last! * 1.1) }
        return edges
    }
}

/// Debris thrown off a structure where a run makes it (`StructureModel.rubbleParticles`: failed
/// concrete and masonry as particles keeping their mass), flown on from where the run left it in
/// still air until it lands, like the fragments (`FragmentCloud.land`), each a tumbling cube of
/// its own volume, and judged by the same criteria.
public struct DebrisResult: Codable, Sendable, Equatable {
    /// Each piece's landing, its `fragment` the piece's index: on the ground, or on a block.
    /// Pieces at rest when the run ended land where they lie, with the energy they then had.
    public var impacts: [FragmentImpact]
    public var pieces: Int
    /// kg.
    public var mass: Float
    public var hazard: GroundHazard

    /// Pieces slower than this (m/s) when the run ends are taken as lying where they are.
    public static let restSpeed: Float = 1

    public init(
        rubble: [RubbleParticle], centre: SIMD2<Float>, ambient: Primitive, blocks: [Box] = [],
        terrain: Terrain? = nil
    ) {
        let pieces = rubble.filter { $0.mass > 0 }
        var lying: [FragmentImpact] = []
        var flying: [(index: Int, particle: FragmentCloud.Particle)] = []
        for (index, piece) in pieces.enumerated() {
            let speed = simd_length(piece.velocity)
            if speed < Self.restSpeed {
                let ground = terrain?.height(at: piece.position) ?? 0
                lying.append(
                    FragmentImpact(
                        fragment: index, time: 0, position: piece.position, speed: speed,
                        energy: piece.kineticEnergy,
                        surface: piece.position.z - ground <= max(2 * piece.reach, 0.5)
                            ? "ground" : "structure"))
            } else {
                let edge = cbrt(max(piece.volume, 1e-9))
                flying.append(
                    (
                        index,
                        FragmentCloud.Particle(
                            position: piece.position, velocity: piece.velocity, mass: piece.mass,
                            area: 1.5 * edge * edge)
                    ))
            }
        }
        var cloud = FragmentCloud(particles: flying.map(\.particle), blocks: blocks, terrain: terrain)
        cloud.land(in: ambient)
        let flown = cloud.impacts.map { impact in
            var impact = impact
            impact.fragment = flying[impact.fragment].index
            return impact
        }
        impacts = (lying + flown).sorted { $0.fragment < $1.fragment }
        self.pieces = pieces.count
        mass = pieces.reduce(0) { $0 + $1.mass }
        hazard = GroundHazard(impacts: impacts, centre: centre)
    }

    public var summary: String {
        String(
            format: "Debris: %d pieces, %.0f kg, highest landing energy %.0f J; ", pieces, mass,
            impacts.map(\.energy).max() ?? 0) + hazard.summary
    }
}
