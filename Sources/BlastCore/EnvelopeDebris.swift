import Foundation
import simd

/// How a failed envelope component is thrown, as its one-way model leaves it: when it went, and its
/// speed then at its point of largest deflection, by UFC 3-340-02 §4-58.2.1 (Equation 4-187, the
/// load's impulse less its resistance's over the effective mass: the single degree of freedom's own
/// velocity at failure); its mass per area; and the pieces it breaks into.
public struct DebrisLaunch: Codable, Sendable, Equatable {
    /// When it failed, s (from t = 0 once assessed), and its speed then, m/s, inward positive.
    public var timeS: Double
    public var speedMS: Double
    /// kg/m² of its face, and its thickness, m.
    public var massPerArea: Double
    public var thicknessM: Double
    /// Each piece's size, m: across its face both ways, and through its thickness.
    public var piece: SIMD3<Float>
    /// How far its sections had turned about their supports when it failed, radians: each piece
    /// leaves at this to its face, towards the edge its section turns about.
    public var rotationRad: Double = 0

    /// Each piece's mass, kg.
    public var pieceKg: Double {
        massPerArea * Double(piece.x * piece.y) * Double(piece.z) / max(thicknessM, 1e-6)
    }

    /// What each construction is taken to break into (assumptions, docs/building-envelopes.md):
    /// - unreinforced masonry, its units: a brick's stretcher face, 215 × 65 mm, through a leaf's
    ///   102.5 mm (or the wall, if thinner);
    /// - concrete and reinforced blockwork, rubble (UFC 3-340-02 §4-57's unlaced elements): cubes
    ///   of half its thickness, 50 mm at least;
    /// - annealed glass, shards 50 mm square; laminated glass, the pane whole;
    /// - profiled sheeting, the sheet between its rails, a metre wide;
    /// - cross-laminated timber, strips 0.3 m wide over its span.
    static func piece(
        _ material: EnvelopeComponentDamage.Material, thickness: Double, span: Double, pane: SIMD2<Double>?
    ) -> SIMD3<Float> {
        let t = Float(thickness)
        switch material {
        case .unreinforcedMasonry: return SIMD3(0.215, 0.065, min(t, 0.1025))
        case .reinforcedConcrete, .reinforcedBlockwork:
            let edge = max(t / 2, 0.05)
            return SIMD3(edge, edge, min(edge, t))
        case .annealedGlass: return SIMD3(0.05, 0.05, t)
        case .laminatedGlass: return SIMD3(Float(pane?.x ?? 1), Float(pane?.y ?? 1), t)
        case .profiledSteel: return SIMD3(Float(span), 1, t)
        case .crossLaminatedTimber: return SIMD3(Float(span), 0.3, t)
        }
    }
}

/// Debris from envelope components that failed (`EnvelopeComponentDamage.launch`), thrown and flown
/// to where it lands, and judged as the fragments are (`GroundHazard`, DDESB's 1 hazardous piece
/// per 55.7 m² at 79 J or more). Each component's face is sampled on a grid, each sample standing
/// for its share of the pieces. Its speed is the one-way model's at failure at the point of
/// largest deflection times its place on the mechanism's shape (UFC 3-340-02 §4-58.2.1: from the
/// most at the largest deflection to nothing at the supports, the shape the recorder weights the
/// load by, `EnvelopeComponentRecorder.shape`). Glass and sheeting, free, are pushed on by the load
/// still on them, the same for every piece, until it turns against them (as `GlazingHazard
/// .speedGone` takes a pane's); concrete, masonry and timber are not, as UFC takes them.
/// Pieces leave square to the face, from the side they move to, and fly through still air with the
/// fragments' drag (a tumbling body of its mean presented area, Cauchy's surface over four),
/// stopping on the scene's blocks and the buildings' solids that did not fail.
public struct EnvelopeDebris: Codable, Sendable {
    public struct Source: Codable, Sendable, Equatable {
        public var component: String
        public var owner: UUID
        public var material: EnvelopeComponentDamage.Material
        /// Its mass thrown (kg), pieces, and the fastest and mean launch speeds (m/s).
        public var massKg: Double
        public var pieces: Double
        public var fastestMS: Double
        public var meanMS: Double
        public var failedAtS: Double
        /// Each piece's mass, kg, and the samples standing for its pieces (the first's index in
        /// `impacts`' fragments, and how many).
        public var pieceKg: Double
        public var samples: Range<Int>
    }

    public var sources: [Source]
    /// Each sample's landing, its `fragment` the sample's index and its `weight` the pieces it
    /// stands for.
    public var impacts: [FragmentImpact]
    public var hazard: GroundHazard

    /// Samples across each component's face, each way.
    public static let samplesEachWay = 16

    /// The debris of `damage`'s failed components on `loads` (joined by id), thrown from where
    /// they stood. `centre` is the charge's, for the hazard's rings; `blocks` the scene's rigid
    /// boxes, and `solids` each building's (keyed by its id), of which those holding a failed
    /// component are left out of the flight. Nil when nothing failed with a launch.
    public static func make(
        loads: [EnvelopeComponentLoad], damage: [EnvelopeBuildingDamage], centre: SIMD3<Float>,
        ambient: Primitive, blocks: [Box] = [], solids: [UUID: [Box]] = [:], terrain: Terrain? = nil
    ) -> EnvelopeDebris? {
        make(
            loads: loads, components: damage.flatMap(\.components), centre: centre, ambient: ambient,
            blocks: blocks, solids: solids, terrain: terrain)
    }

    /// The same from the components' damage alone; `dragScale` scales every piece's drag, to see
    /// how much the reach depends on it.
    public static func make(
        loads: [EnvelopeComponentLoad], components: [EnvelopeComponentDamage], centre: SIMD3<Float>,
        ambient: Primitive, blocks: [Box] = [], solids: [UUID: [Box]] = [:], terrain: Terrain? = nil,
        dragScale: Float = 1
    ) -> EnvelopeDebris? {
        let byID = Dictionary(loads.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var sources: [Source] = []
        var particles: [FragmentCloud.Particle] = []
        var failedRegions: [UUID: [Box]] = [:]
        do {
            for component in components {
                guard let launch = component.launch, let load = byID[component.id] else { continue }
                failedRegions[load.owner, default: []].append(load.region)
                let thrown = Self.thrown(
                    load, launch: launch, material: component.material, dragScale: dragScale)
                guard !thrown.particles.isEmpty else { continue }
                sources.append(
                    Source(
                        component: component.id, owner: component.owner, material: component.material,
                        massKg: thrown.massKg, pieces: thrown.pieces, fastestMS: thrown.fastest,
                        meanMS: thrown.mean, failedAtS: launch.timeS, pieceKg: launch.pieceKg,
                        samples: particles.count..<(particles.count + thrown.particles.count)))
                particles += thrown.particles
            }
        }
        guard !particles.isEmpty else { return nil }
        // The buildings' solids that hold no failed component stop what flies into them.
        var standing = blocks
        for (owner, boxes) in solids {
            let failed = failedRegions[owner] ?? []
            standing += boxes.filter { box in
                !failed.contains { region in
                    (0..<3).allSatisfy { region.min[$0] < box.max[$0] && box.min[$0] < region.max[$0] }
                }
            }
        }
        var cloud = FragmentCloud(particles: particles, blocks: standing, terrain: terrain, centre: centre)
        cloud.land(in: ambient)
        let impacts = cloud.impacts.sorted { $0.fragment < $1.fragment }
        return EnvelopeDebris(
            sources: sources, impacts: impacts,
            hazard: GroundHazard(
                impacts: impacts, centre: SIMD2(centre.x, centre.y), crossings: cloud.crossings))
    }

    /// One component's samples: their particles, its mass and pieces, and its launch speeds.
    static func thrown(
        _ load: EnvelopeComponentLoad, launch: DebrisLaunch, material: EnvelopeComponentDamage.Material,
        dragScale: Float = 1
    ) -> (particles: [FragmentCloud.Particle], massKg: Double, pieces: Double, fastest: Double, mean: Double)
    {
        let region = load.region
        let axes = (0..<3).filter { $0 != load.axis }
        let area = Double(region.size[axes[0]] * region.size[axes[1]])
        let massKg = launch.massPerArea * area
        let pieceKg = launch.pieceKg
        guard massKg > 0, pieceKg > 0 else { return ([], 0, 0, 0, 0) }
        let pieces = massKg / pieceKg
        // Concrete, masonry and timber fly at their speed at failure (UFC 3-340-02 §4-58.2.1: "the
        // maximum velocity of the fragment after failure vf is equal to the maximum velocity of the
        // element at incipient failure vi"): broken up, the gas leaves round them. Glass and sheets,
        // thin and whole, go on being pushed, the same for every piece, the way they were moving.
        let pushed = material.isGlass || material == .profiledSteel
        let push = pushed ? Self.freeSpeed(launch: launch, load: load) - launch.speedMS : 0
        let edges =
            (load.supportEdges?.count == 4 && load.supportEdges!.contains(true))
            ? load.supportEdges! : [true, true, true, true]
        let n = samplesEachWay
        let count = n * n
        let weight = Float(pieces / Double(count))
        let piece = launch.piece
        let mean = (2 * (piece.x * piece.y + piece.x * piece.z + piece.y * piece.z)) / 4
        var inward = SIMD3<Float>.zero
        inward[load.axis] = -Float(load.outward)
        var particles: [FragmentCloud.Particle] = []
        var speeds: [Double] = []
        for j in 0..<n {
            for i in 0..<n {
                let s = SIMD2((Float(i) + 0.5) / Float(n), (Float(j) + 0.5) / Float(n))
                let phi =
                    EnvelopeComponentRecorder.shape(s.x, low: edges[0], high: edges[1])
                    * EnvelopeComponentRecorder.shape(s.y, low: edges[2], high: edges[3])
                let speed = launch.speedMS * Double(phi) + push
                speeds.append(abs(speed))
                // At rest it falls where it was, off the face it was going to.
                let going = speed != 0 ? speed : launch.speedMS != 0 ? launch.speedMS : 1
                let normal = going > 0 ? inward : -inward
                // Its section turns about the held edge nearest it (a yield line's segment): it
                // leaves square to the section as turned, towards that edge.
                var toward = SIMD3<Float>.zero
                var nearest = Float.infinity
                for a in 0..<2 {
                    if edges[2 * a], s[a] < nearest {
                        nearest = s[a]
                        toward = .zero
                        toward[axes[a]] = -1
                    }
                    if edges[2 * a + 1], 1 - s[a] < nearest {
                        nearest = 1 - s[a]
                        toward = .zero
                        toward[axes[a]] = 1
                    }
                }
                let turn = Float(launch.rotationRad)
                let direction = simd_normalize(normal * cos(turn) + toward * sin(turn))
                var position = region.min
                position[axes[0]] += s.x * region.size[axes[0]]
                position[axes[1]] += s.y * region.size[axes[1]]
                // From the face it moves to, a little off it.
                position[load.axis] =
                    direction[load.axis] > 0 ? region.max[load.axis] + 0.01 : region.min[load.axis] - 0.01
                var particle = FragmentCloud.Particle(
                    position: position, velocity: direction * Float(abs(speed)), mass: Float(pieceKg),
                    area: mean * dragScale)
                particle.weight = weight
                particles.append(particle)
            }
        }
        return (
            particles, massKg, pieces, speeds.max() ?? 0, speeds.reduce(0, +) / Double(max(speeds.count, 1))
        )
    }

    /// Its speed, free, once the load still on it has pushed it on in the way it was going (or,
    /// at rest, the way the load first pushes) until it turns against it, m/s, inward positive.
    static func freeSpeed(launch: DebrisLaunch, load: EnvelopeComponentLoad) -> Double {
        let net = load.netPa
        let binS = load.binS
        let at = launch.timeS - load.startS
        var bin = max(Int(at / binS), 0)
        var span = Double(bin + 1) * binS - at
        var speed = launch.speedMS
        var sign: Double = speed > 0 ? 1 : speed < 0 ? -1 : 0
        if sign == 0 {
            guard let first = net[min(bin, net.count)...].first(where: { $0 != 0 }) else { return 0 }
            sign = first > 0 ? 1 : -1
        }
        var pushed = speed != 0
        while bin < net.count, net[bin] * sign >= 0 || !pushed {
            if net[bin] * sign > 0 {
                speed += net[bin] * span / launch.massPerArea
                pushed = true
            }
            bin += 1
            span = binS
        }
        return speed
    }

    public var summary: String {
        let mass = sources.reduce(0) { $0 + $1.massKg }
        let pieces = sources.reduce(0) { $0 + $1.pieces }
        return String(
            format:
                "Envelope debris: %d components failed and thrown, %.0f kg in about %.0f pieces, fastest %.0f m/s, highest landing energy %.0f J; ",
            sources.count, mass, pieces, sources.map(\.fastestMS).max() ?? 0, impacts.map(\.energy).max() ?? 0
        )
            + hazard.summary
    }
}

extension BlastSolver {
    /// The debris of the envelope components `damage` judged failed on `loads`, thrown and flown to
    /// where it lands (`EnvelopeDebris`); nil when none failed with a launch.
    public func envelopeDebris(
        scenario: Scenario, loads: [EnvelopeComponentLoad], damage: [EnvelopeBuildingDamage]
    ) -> EnvelopeDebris? {
        EnvelopeDebris.make(
            loads: loads, damage: damage, centre: scenario.charge.position,
            ambient: Primitive(density: ambientDensity, pressure: configuration.ambientPressure),
            blocks: scenario.rigidBoxes,
            solids: Dictionary(
                scenario.envelopeObjects.map { ($0.id, $0.envelope?.solids ?? []) },
                uniquingKeysWith: { a, _ in a }),
            terrain: scenario.terrain)
    }
}

extension Scenario {
    /// Whether the charge is inside a building: within the bounds of an envelope's solids or a
    /// structure's, for DoD's default structure debris distance.
    public var chargeInsideBuilding: Bool {
        let point = charge.position
        let boxes =
            envelopeObjects.compactMap { $0.envelope?.solids }
            + structuralObjects.compactMap { $0.structure?.solids }
        return boxes.contains { solids in
            guard let first = solids.first else { return false }
            let low = solids.reduce(first.min) { simd_min($0, $1.min) }
            let high = solids.reduce(first.max) { simd_max($0, $1.max) }
            return (0..<3).allSatisfy { point[$0] > low[$0] && point[$0] < high[$0] }
        }
    }
}
