import Foundation
import simd

/// Each building's chance that its walls and its roof are damaged, from the façade load surrogate
/// drawn many times over what is not known (roadmap, Horizons 4; docs/glass-probability.md for the
/// glass's): the charge's yield and each side's load scatter as the glass's chances draw them, and
/// each building's strength, by an assumed scatter. A run's damaged walls are its loads' upper tail,
/// which a single estimate undercounts (docs/surrogate-first-look.md, "Walls and roofs"); drawn,
/// their counts can match a run's.
extension FacadeLoadSurrogate {
    /// A building's chances: that its worst wall is damaged moderately or worse, and heavily or
    /// worse (calibrated for stone, illustrative for concrete), and that its roof is damaged
    /// moderately or worse. No chance of failure is given: against the runs the roofs' read far too
    /// high (skill −0.48) and the walls' were too few to judge (docs/glass-probability.md, "Walls
    /// and roofs").
    public struct StructureChance: Sendable, Equatable, Codable {
        public var owner: UUID
        public var wallsModerate: Double
        public var wallsHeavy: Double
        public var roofModerate: Double

        public init(owner: UUID, wallsModerate: Double = 0, wallsHeavy: Double = 0, roofModerate: Double = 0)
        {
            self.owner = owner
            self.wallsModerate = wallsModerate
            self.wallsHeavy = wallsHeavy
            self.roofModerate = roofModerate
        }
    }

    /// The walls' and roofs' chances' standing, worded from the standing table's figures
    /// (validation.md, "The walls' and roofs' chances against Beirut's runs").
    public static let structureStanding: [String] = {
        let skill = ValidationTables.figure("structureChancesSkill")
        let under = ValidationTables.figure("structureChancesUnderCall")
        let roof = ValidationTables.figure("structureChancesRoofLow")
        return [
            String(
                format:
                    "Walls' and roofs' chances, against Beirut's near runs at ten yields on air refined to 2 m: Brier skill "
                    + "%.2f for concrete walls damaged, each tenth of chance within %.1f of the runs; %.2f for roofs, "
                    + "their middle chances %.2f–%.2f low (the unsafe side), with a load factor fitted to those runs; "
                    + "masonry's high. Drawn over an assumed strength scatter. Heavy damage is illustrative for "
                    + "concrete, and no chance of failure is given.",
                skill.low, under.low, skill.high, roof.low, roof.high)
        ]
    }()

    /// The standard deviation of the logarithm of a building's walls' and roof's resistance, about
    /// the construction's nominal, by what they are built of: assumed, as the glass's strength
    /// scatter is (concrete's strength varies by about 15% between pours; masonry's by about 30%
    /// between units, mortars and workmanship).
    public static func strengthLogSD(_ kind: EnvelopeConstruction.Kind) -> Double {
        switch kind {
        case .reinforcedConcrete, .reinforcedBlockwork: 0.15
        case .unreinforcedMasonry: 0.30
        case .profiledSteelSheeting: 0.10
        case .crossLaminatedTimber: 0.20
        }
    }

    /// The factors on a building's walls' and roof's peak and impulse, and the scale on their load
    /// scatter, by what the walls are built of, and with `learned` for walls whose ground-floor
    /// peaks are the learned field model's (emmettl/bombcad-work#67): calibrated against Beirut's
    /// near boxes at ten yields from 0.15 to 1.5 kt, refined to 2 m below the buildings' tops, each
    /// yield held out in turn (`scenebench wall-calibrate`; docs/glass-probability.md, "Walls and
    /// roofs"). Against them concrete walls took ×1.3 with the whole scatter in nine folds of ten;
    /// with the field model, the peak ×1.15 and the impulse ×0.95, which alone passed the tenths
    /// test; stone ×1.0 with ½ and roofs ×1.3 with ½, as on 4 m cells. The 4 m runs read the walls'
    /// peaks 13–19% low at 400–600 m of 0.5 kt, and had given concrete ×1.0 (emmettl/bombcad-work#19).
    public static func structureCalibration(walls kind: EnvelopeConstruction.Kind, learned: Bool = false) -> (
        walls: (peak: Double, impulse: Double, scatter: Double),
        roof: (peak: Double, impulse: Double, scatter: Double)
    ) {
        let walls: (peak: Double, impulse: Double, scatter: Double) =
            kind == .unreinforcedMasonry ? (1.0, 1.0, 0.5) : learned ? (1.15, 0.95, 1.0) : (1.3, 1.3, 1.0)
        return (walls, (1.3, 1.3, 0.5))
    }

    /// The chances of every building in `estimate` (`FacadeLoadSurrogate.estimate`, a charge of
    /// `mass` kg on cells `cellSize`), each built as `constructions` says. Each draw takes a yield,
    /// a load scatter for each building side (shared by its strips, as the glass's) and for each
    /// roof, and a strength for each building, judged as resistance scaled by it (the load divided
    /// by it; none with `strengthScatter` off). A component that cannot reach moderate at the
    /// scatters' high ends is left out.
    public static func structureProbabilities(
        _ estimate: Estimate, mass base: Double, cellSize: Float,
        constructions: (UUID) -> EnvelopeConstruction,
        uncertainty: Uncertainty = Uncertainty(), binS: Double = 0.7e-3, coefficients: Coefficients = .fitted,
        roofCoefficients: Coefficients? = .roofs, strengthScatter: Bool = true,
        loadFactor: (walls: Double, roof: Double)? = nil, scatterScale: (walls: Double, roof: Double)? = nil,
        impulseRatio: (walls: Double, roof: Double)? = nil, learnedPeaks: Bool = false
    ) -> (chances: [StructureChance], seconds: Double) {
        let start = ContinuousClock.now
        let draws = max(1, uncertainty.samples)
        let masses = uncertainty.masses(base: base, draws: draws)
        let largest = masses.max() ?? base
        // Each building's components (walls and roofs: the façade strips and walls, and the roofs),
        // its side groups, its top and base, and its construction, looked up on this thread.
        let owners = Array(Set(estimate.components.map(\.owner))).sorted { $0.uuidString < $1.uuidString }
        let ownerIndex = Dictionary(uniqueKeysWithValues: owners.enumerated().map { ($1, $0) })
        var members = [[Int]](repeating: [], count: owners.count)
        var tops = [Double](repeating: -.infinity, count: owners.count)
        var bases = [Double](repeating: .infinity, count: owners.count)
        for (n, component) in estimate.components.enumerated() {
            guard let b = ownerIndex[component.owner] else { continue }
            tops[b] = max(tops[b], Double(component.region.max.z))
            bases[b] = min(bases[b], Double(component.region.min.z))
            guard [.facade, .wall, .roof].contains(component.kind) else { continue }
            members[b].append(n)
        }
        let built = owners.map(constructions)
        // Each building's draws by its geometry (`SceneObject.drawKey`), as the glass's: the same
        // scene, the same chances, however often it is laid out. Without the estimate's keys, by
        // its identifier.
        var keyOf: [UUID: UInt64] = [:]
        if !estimate.ownerKeys.isEmpty {
            for (k, n) in estimate.owners.enumerated() where estimate.ownerKeys.indices.contains(n) {
                keyOf[estimate.components[k].owner] = estimate.ownerKeys[n]
            }
        }
        let ownerSeeds = owners.map { id in
            keyOf[id]
                ?? UInt64(
                    truncatingIfNeeded: id.uuidString.utf8.reduce(UInt64(14_695_981_039_346_656_037)) {
                        ($0 ^ UInt64($1)) &* 1_099_511_628_211
                    })
        }

        func level(
            _ n: Int, construction: EnvelopeConstruction, building b: Int, mass: Double, peak: Double,
            impulse: Double
        )
            -> Int
        {
            let component = estimate.components[n]
            var p = predict(
                estimate.features[n], mass: mass, cellSize: Double(cellSize),
                coefficients: component.kind == .roof ? roofCoefficients ?? coefficients : coefficients)
            p.peakPa *= peak
            p.impulsePaS *= impulse
            var load = FacadeLoadSurrogate.load(component, p, binS: binS)
            load.kind = EnvelopeComponentLoad.Kind(rawValue: component.kind.rawValue) ?? .wall
            return EnvelopeDamageAssessment.assess(
                load, construction: construction, buildingTop: tops[b], buildingBase: bases[b]
            )?.levels.upperBound.rawValue ?? 0
        }

        var results = [StructureChance?](repeating: nil, count: owners.count)
        _ = SDOFResponseMemo.remembering {
            results.withUnsafeMutableBufferPointer { out in
                concurrently(iterations: owners.count) { b in
                    let construction = built[b]
                    // Against runs, which judge every wall at its nominal strength, none.
                    let wallSD = strengthScatter ? strengthLogSD(construction.walls) : 0
                    let roofSD = strengthScatter ? strengthLogSD(construction.roof) : 0
                    // The calibration for what its walls are built of, unless given.
                    let calibrated = structureCalibration(walls: construction.walls, learned: learnedPeaks)
                    let factors = loadFactor ?? (calibrated.walls.peak, calibrated.roof.peak)
                    let scales = scatterScale ?? (calibrated.walls.scatter, calibrated.roof.scatter)
                    // The impulse's own factor over the peak's: given, or the calibration's unless a
                    // load factor is given (then 1, both alike).
                    let ratios =
                        impulseRatio
                        ?? (loadFactor != nil
                            ? (1, 1)
                            : (
                                calibrated.walls.impulse / calibrated.walls.peak,
                                calibrated.roof.impulse / calibrated.roof.peak
                            ))
                    // Those that could be damaged at the scatters' high ends and the largest yield.
                    let possible = members[b].filter { n in
                        let component = estimate.components[n]
                        let z = estimate.features[n].distanceM / cbrt(largest)
                        let scatter = uncertainty.scatter(atZ: z)
                        let roof = component.kind == .roof
                        let weak = exp(2.5 * (roof ? roofSD : wallSD)) * (roof ? factors.roof : factors.walls)
                        let scale = 2.5 * (roof ? scales.roof : scales.walls)
                        return level(
                            n, construction: construction, building: b, mass: largest,
                            peak: exp(scale * (scatter?.peak ?? 0)) * weak,
                            impulse: exp(scale * (scatter?.impulse ?? 0)) * weak
                                * max(roof ? ratios.roof : ratios.walls, 1)) > 0
                    }
                    guard !possible.isEmpty else {
                        out[b] = StructureChance(owner: owners[b])
                        return
                    }
                    var counts = [Double](repeating: 0, count: 3)
                    for k in 0..<draws {
                        let mass = masses[k]
                        let wallWeak = exp(
                            -wallSD * uncertainty.normal(5, k, ownerSeeds[b], draws: draws))
                        let roofWeak = exp(
                            -roofSD * uncertainty.normal(6, k, ownerSeeds[b], draws: draws))
                        var worstWall = 0
                        var worstRoof = 0
                        var errorsOf: [Int: SIMD2<Double>] = [:]
                        for n in possible {
                            let component = estimate.components[n]
                            let roof = component.kind == .roof
                            // The side's scatter, shared by its strips (a roof its own).
                            let group = roof ? 6 : component.axis * 2 + (component.outward > 0 ? 1 : 0)
                            let errors =
                                errorsOf[group]
                                ?? {
                                    let z = estimate.features[n].distanceM / cbrt(mass)
                                    guard let scatter = uncertainty.scatter(atZ: z) else { return .zero }
                                    let item = ownerSeeds[b] &+ UInt64(group)
                                    let a = uncertainty.normal(3, k, item, draws: draws)
                                    let c = uncertainty.normal(4, k, item, draws: draws)
                                    let r = scatter.correlation
                                    let scale = roof ? scales.roof : scales.walls
                                    return scale
                                        * SIMD2(
                                            scatter.peak * a,
                                            scatter.impulse * (r * a + (1 - r * r).squareRoot() * c))
                                }()
                            errorsOf[group] = errors
                            let weak = roof ? roofWeak * factors.roof : wallWeak * factors.walls
                            let reached = level(
                                n, construction: construction, building: b, mass: mass,
                                peak: exp(errors.x) * weak,
                                impulse: exp(errors.y) * weak * (roof ? ratios.roof : ratios.walls))
                            if roof {
                                worstRoof = max(worstRoof, reached)
                            } else {
                                worstWall = max(worstWall, reached)
                            }
                        }
                        counts[0] += worstWall >= EnvelopeDamageLevel.moderate.rawValue ? 1 : 0
                        counts[1] += worstWall >= EnvelopeDamageLevel.heavy.rawValue ? 1 : 0
                        counts[2] += worstRoof >= EnvelopeDamageLevel.moderate.rawValue ? 1 : 0
                    }
                    let d = Double(draws)
                    out[b] = StructureChance(
                        owner: owners[b], wallsModerate: counts[0] / d, wallsHeavy: counts[1] / d,
                        roofModerate: counts[2] / d)
                }
            }
        }
        let took = start.duration(to: .now)
        return (
            results.compactMap { $0 },
            Double(took.components.seconds) + Double(took.components.attoseconds) * 1e-18
        )
    }
}
