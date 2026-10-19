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
    /// - annealed glass, shards 50 mm square; toughened, dice 8 mm square; laminated or filmed
    ///   glass, the pane whole;
    /// - profiled sheeting, the sheet between its rails, a metre wide;
    /// - cross-laminated timber, strips 0.3 m wide over its span.
    package static func piece(
        _ material: EnvelopeComponentDamage.Material, thickness: Double, span: Double, pane: SIMD2<Double>?
    ) -> SIMD3<Float> {
        let t = Float(thickness)
        switch material {
        case .unreinforcedMasonry: return SIMD3(0.215, 0.065, min(t, 0.1025))
        case .reinforcedConcrete, .reinforcedBlockwork:
            let edge = max(t / 2, 0.05)
            return SIMD3(edge, edge, min(edge, t))
        case .annealedGlass: return SIMD3(0.05, 0.05, t)
        case .laminatedGlass, .filmedGlass: return SIMD3(Float(pane?.x ?? 1), Float(pane?.y ?? 1), t)
        // EN 12150-1's fragmentation test: 40 or more pieces in a 50 mm square, about 8 mm each.
        case .toughenedGlass: return SIMD3(0.008, 0.008, t)
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

        /// The memberwise initialiser, written out so that BlastCore can use it.
        package init(
            component: String,
            owner: UUID,
            material: EnvelopeComponentDamage.Material,
            massKg: Double,
            pieces: Double,
            fastestMS: Double,
            meanMS: Double,
            failedAtS: Double,
            pieceKg: Double,
            samples: Range<Int>
        ) {
            self.component = component
            self.owner = owner
            self.material = material
            self.massKg = massKg
            self.pieces = pieces
            self.fastestMS = fastestMS
            self.meanMS = meanMS
            self.failedAtS = failedAtS
            self.pieceKg = pieceKg
            self.samples = samples
        }
    }

    public var sources: [Source]
    /// Each sample's landing, its `fragment` the sample's index and its `weight` the pieces it
    /// stands for.
    public var impacts: [FragmentImpact]
    public var hazard: GroundHazard

    /// Samples across each component's face, each way.
    public static let samplesEachWay = 16

    /// Its speed, free, once the load still on it has pushed it on in the way it was going (or,
    /// at rest, the way the load first pushes) until it turns against it, m/s, inward positive.
    package static func freeSpeed(launch: DebrisLaunch, load: EnvelopeComponentLoad) -> Double {
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

    /// The memberwise initialiser, written out so that BlastCore can use it.
    package init(
        sources: [Source],
        impacts: [FragmentImpact],
        hazard: GroundHazard
    ) {
        self.sources = sources
        self.impacts = impacts
        self.hazard = hazard
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
