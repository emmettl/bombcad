import Foundation
import simd

/// Each building side's chance that its glass breaks, and that it is blown out, from the façade
/// load surrogate drawn many times over what is not known (roadmap, Horizons 4;
/// docs/glass-probability.md): the charge's yield, each building's glass strength, and the
/// surrogate's own scatter about the runs it was fitted to. The glass only: the surrogate's walls
/// and roofs are not to be relied on, so no chance is given for them.
extension FacadeLoadSurrogate {
    /// The glass chances' standing, worded from the standing table's figures (validation.md,
    /// "The glass chances against Beirut's runs and survey").
    public static let glassStanding: [String] = {
        let brier = ValidationTables.figure("glassChancesBrier")
        let bins = ValidationTables.figure("glassChancesBins")
        let survey = ValidationTables.figure("glassChancesSurvey")
        let thrown = ValidationTables.figure("glassChancesThrown")
        let test = ValidationTables.figure("glassChancesTest")
        let openings = ValidationTables.figure("openingsSurvey")
        let openingsSkill = ValidationTables.figure("openingsSkill")
        return [
            String(
                format:
                    "Glass chances, against Beirut's full runs at 0.2, 0.5 and 1.1 kt, drawn over those yields: calibrated. "
                    + "Blown out: Brier %.3f, against %.3f giving every side the mean, each tenth of chance within %.2f "
                    + "of the share seen; thrown past 3 m (GSA 3b) skill %.2f; some glass broken a little high. All three "
                    + "pass the protective-design test, each tenth of chance within %.1f of the share seen.",
                brier.low,
                brier.high, bins.high, thrown.low, test.high),
            String(
                format:
                    "Not judged against GEER's survey of Beirut's façades, whose classes are openings (frames and doors "
                    + "with the windows) photographed two months on: the glass's blown out %.2f at 0.75–1 km where GEER "
                    + "saw %.2f compares unlike things. Read the glass chances as a run's spread, not the event's.",
                survey.high, survey.low),
            String(
                format:
                    "Openings blown out: a fragility fitted to that survey (one event, Beirut, at 4 m cells, whose peaks "
                    + "are 0.7–0.8 of Kingery–Bulmash's), not physics: %.2f at 0.75–1 km where GEER saw %.2f, skill %.2f "
                    + "against it. Illustrative elsewhere.", openings.high, openings.low, openingsSkill.low),
        ]
    }()

    /// What the chances are drawn over.
    public struct Uncertainty: Sendable, Equatable {
        /// The charge masses to draw from, kg (a posterior's samples, `scenebench infer-charge`);
        /// empty for the scene's charge, scaled by a log-normal factor of `yieldLogSD`.
        public var masses: [Double]
        public var yieldLogSD: Double
        /// Every building's glass strength over the flaw model's median (1: the model's own; more
        /// for toughened or stronger glass).
        public var strengthMedian: Double
        /// The standard deviation of the logarithm of each building's glass strength, about the
        /// flaw model's median (whose scatter between one pane and the next is in each pane's
        /// own chance): its panes' age, make and fixing, not known for a map's buildings.
        public var strengthLogSD: Double
        /// The surrogate's scatter about the runs, by scaled distance: up to `upToZ`, the
        /// standard deviations of the logarithms of its peak and impulse, and their correlation.
        /// Drawn once for each building side, shared by its strips.
        public var loadScatter: [LoadScatter]
        public var samples: Int
        public var seed: UInt64

        public struct LoadScatter: Sendable, Equatable, Codable {
            public var upToZ: Double
            public var peak: Double
            public var impulse: Double
            public var correlation: Double

            public init(upToZ: Double, peak: Double, impulse: Double, correlation: Double) {
                self.upToZ = upToZ
                self.peak = peak
                self.impulse = impulse
                self.correlation = correlation
            }
        }

        /// The fitted runs' scatter, each held out of a fit to the other three
        /// (docs/glass-probability.md): the root of the mean square, bias and spread together.
        public static let leaveOneOut: [LoadScatter] = [
            LoadScatter(upToZ: 7, peak: 0.41, impulse: 0.26, correlation: 0.51),
            LoadScatter(upToZ: 10, peak: 0.30, impulse: 0.19, correlation: 0.31),
            LoadScatter(upToZ: 14, peak: 0.25, impulse: 0.16, correlation: 0.26),
            LoadScatter(upToZ: 20, peak: 0.24, impulse: 0.17, correlation: 0.29),
            LoadScatter(upToZ: 28, peak: 0.23, impulse: 0.21, correlation: 0.60),
            LoadScatter(upToZ: .infinity, peak: 0.30, impulse: 0.26, correlation: 0.67),
        ]

        public init(
            masses: [Double] = [], yieldLogSD: Double = 0, strengthMedian: Double = 1,
            strengthLogSD: Double = 0.25,
            loadScatter: [LoadScatter] = Uncertainty.leaveOneOut, samples: Int = 100, seed: UInt64 = 1
        ) {
            self.masses = masses
            self.yieldLogSD = yieldLogSD
            self.strengthMedian = strengthMedian
            self.strengthLogSD = strengthLogSD
            self.loadScatter = loadScatter
            self.samples = samples
            self.seed = seed
        }

        /// No scatter at all: the first look's own answer, drawn once.
        public static let none = Uncertainty(strengthLogSD: 0, loadScatter: [], samples: 1)

        func scatter(atZ z: Double) -> LoadScatter? { loadScatter.first { z <= $0.upToZ } }
    }

    /// A side's openings (windows, doors and their frames) nearly all blown out, as GEER's
    /// surveyors classed façades (W3) from photographs two months after the Beirut explosion: a
    /// log-normal fragility on the side's peak net load, fitted to GEER's W3 against the side's peak
    /// in Beirut's 0.5 kt run on 4 m cells (docs/glass-probability.md). Fitted to one event's survey,
    /// and tied to that resolution, whose peaks are 0.7–0.8 of Kingery–Bulmash's: illustrative
    /// elsewhere. Not physics: no frame or fixing is modelled.
    public enum OpeningsFragility {
        /// The peak net load at which half of the sides are blown out, Pa.
        public static let medianPa = 18_500.0
        /// The log standard deviation.
        public static let logSD = 0.75

        /// The chance a side whose peak net load is `peakPa` has its openings blown out.
        public static func chance(peakPa: Double) -> Double {
            guard peakPa > 0 else { return 0 }
            return 0.5 * (1 + erf(log(peakPa / medianPa) / (logSD * 2.0.squareRoot())))
        }
    }

    /// One side of a building (its façade strips facing `outward` along `axis`), its glass's chances.
    public struct SideGlass: Sendable, Codable, Equatable {
        public var owner: UUID
        public var axis: Int
        public var outward: Int
        /// From the charge to the side's middle, m.
        public var distanceM: Double
        /// The chance that some pane of it breaks (GEER's W1 or worse).
        public var someBroken: Double
        /// The chance that it is blown out: nine in ten of its panes expected broken (GEER's W3).
        public var blownOut: Double
        /// The panes expected broken, as a share, over the draws.
        public var fractionBroken: Double
        /// The chance that some pane of it breaks and is thrown worse than GSA's condition 3b: its
        /// glass beyond 3 m of the window, or high on a witness panel there (`GlazingHazard`).
        public var thrownPast3b: Double
        /// The chance its openings, frames and doors with them, are nearly all blown out, by the
        /// fragility fitted to Beirut's survey (`OpeningsFragility`): fitted, not physics. Zero in
        /// results saved before it.
        public var openingsBlownOut: Double = 0

        public init(
            owner: UUID, axis: Int, outward: Int, distanceM: Double, someBroken: Double, blownOut: Double,
            fractionBroken: Double, thrownPast3b: Double, openingsBlownOut: Double = 0
        ) {
            self.owner = owner
            self.axis = axis
            self.outward = outward
            self.distanceM = distanceM
            self.someBroken = someBroken
            self.blownOut = blownOut
            self.fractionBroken = fractionBroken
            self.thrownPast3b = thrownPast3b
            self.openingsBlownOut = openingsBlownOut
        }

        enum CodingKeys: String, CodingKey {
            case owner, axis, outward, distanceM, someBroken, blownOut, fractionBroken, thrownPast3b,
                openingsBlownOut
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            owner = try c.decode(UUID.self, forKey: .owner)
            axis = try c.decode(Int.self, forKey: .axis)
            outward = try c.decode(Int.self, forKey: .outward)
            distanceM = try c.decode(Double.self, forKey: .distanceM)
            someBroken = try c.decode(Double.self, forKey: .someBroken)
            blownOut = try c.decode(Double.self, forKey: .blownOut)
            fractionBroken = try c.decode(Double.self, forKey: .fractionBroken)
            thrownPast3b = try c.decode(Double.self, forKey: .thrownPast3b)
            openingsBlownOut = try c.decodeIfPresent(Double.self, forKey: .openingsBlownOut) ?? 0
        }
    }

    /// A side's outcome in one draw: the chance some pane breaks, whether it is blown out, the
    /// chance a pane is thrown worse than condition 3b, and the chance its openings are blown out.
    public typealias GlassDraw = (someBroken: Float, blownOut: Bool, thrownPast3b: Float, openingsOut: Float)

    /// A building side's façade strips, for `glassProbabilities(sides:)`.
    public struct GlassSideStrips: Sendable {
        public var owner: UUID
        public var axis: Int
        public var outward: Int
        public var mix: GlazingMix
        /// Each strip's features and area, m².
        public var strips: [(features: Features, areaM2: Double)]

        public init(
            owner: UUID, axis: Int, outward: Int, mix: GlazingMix,
            strips: [(features: Features, areaM2: Double)]
        ) {
            self.owner = owner
            self.axis = axis
            self.outward = outward
            self.mix = mix
            self.strips = strips
        }
    }

    /// The façade sides of `scene`'s map buildings (those whose construction has a glazing mix),
    /// their strips with a face on the air, on cells `cellSize` m across.
    public static func glassSides(scene: Scenario, cellSize: Float) -> [GlassSideStrips] {
        let objects = scene.envelopeObjects
        let raster = Raster(objects: objects, blocks: scene.boxes, terrain: scene.terrain, cell: cellSize)
        let charge = scene.charge.position
        let mixes = objects.map { scene.envelopeConstruction(for: $0.id).glazing }
        var perObject = [[GlassSideStrips]](repeating: [], count: objects.count)
        perObject.withUnsafeMutableBufferPointer { out in
            concurrently(iterations: objects.count) { n in
                guard let mix = mixes[n], let envelope = objects[n].envelope else { return }
                let strips = envelope.components(owner: objects[n].id, cellSize: cellSize)
                    .filter { $0.kind == .facade && facesAir($0, raster: raster) }
                out[n] = Dictionary(grouping: strips, by: { $0.axis * 2 + ($0.outward > 0 ? 1 : 0) })
                    .sorted { $0.key < $1.key }
                    .map { key, members in
                        GlassSideStrips(
                            owner: objects[n].id, axis: key / 2, outward: key % 2 == 1 ? 1 : -1, mix: mix,
                            strips: members.map { component in
                                let spans = component.spans
                                return (
                                    features(component, owner: n, charge: charge, raster: raster),
                                    Double(spans.x * spans.y)
                                )
                            })
                    }
            }
        }
        return perObject.flatMap { $0 }
    }

    /// The glass chances of `scene`'s map buildings' façade sides (`glassSides`); and the seconds
    /// they took.
    public static func glassProbabilities(
        scene: Scenario, cellSize: Float, uncertainty: Uncertainty = Uncertainty(), binS: Double = 0.7e-3,
        coefficients: Coefficients = .fitted
    ) -> (sides: [SideGlass], seconds: Double) {
        let start = ContinuousClock.now
        let sides = glassSides(scene: scene, cellSize: cellSize)
        let (result, _) = glassProbabilities(
            sides: sides, mass: Double(scene.charge.mass), cellSize: cellSize, uncertainty: uncertainty,
            binS: binS,
            coefficients: coefficients)
        let took = start.duration(to: .now)
        return (result, Double(took.components.seconds) + Double(took.components.attoseconds) * 1e-18)
    }

    /// The chances of `sides` for a charge of `mass` kg (unless `uncertainty` gives masses to draw),
    /// and with `keepDraws` each draw's outcome too: per side, the chance some pane breaks and
    /// whether it is blown out, draw by draw. With `farField`, each strip's load is carried as that
    /// far field carries it (`HybridFarField.apply`).
    public static func glassProbabilities(
        sides: [GlassSideStrips], mass base: Double, cellSize: Float,
        uncertainty: Uncertainty = Uncertainty(),
        binS: Double = 0.7e-3, coefficients: Coefficients = .fitted, keepDraws: Bool = false,
        farField: HybridFarField? = nil
    ) -> (sides: [SideGlass], draws: [[GlassDraw]]?) {
        let draws = max(1, uncertainty.samples)
        let masses = (0..<draws).map { k -> Double in
            if !uncertainty.masses.isEmpty {
                let u = Random.uniform(uncertainty.seed, 1, UInt64(k), 0)
                return uncertainty.masses[
                    min(Int(u * Double(uncertainty.masses.count)), uncertainty.masses.count - 1)]
            }
            return base * exp(uncertainty.yieldLogSD * Random.normal(uncertainty.seed, 1, UInt64(k), 1))
        }
        // Each building's strength draws by its owner.
        let owners = Dictionary(
            Array(Set(sides.map(\.owner))).sorted { $0.uuidString < $1.uuidString }.enumerated().map {
                ($1, $0)
            },
            uniquingKeysWith: { a, _ in a })
        let table = GlassTable(binS: binS)
        var results = [SideGlass?](repeating: nil, count: sides.count)
        var outcomes = [[GlassDraw]](
            repeating: [], count: keepDraws ? sides.count : 0)
        results.withUnsafeMutableBufferPointer { out in
            outcomes.withUnsafeMutableBufferPointer { kept in
                concurrently(iterations: sides.count) { s in
                    let side = sides[s]
                    guard !side.strips.isEmpty else { return }
                    let owner = UInt64(owners[side.owner] ?? 0)
                    var some = 0.0
                    var blown = 0.0
                    var fraction = 0.0
                    var thrown = 0.0
                    var mine: [GlassDraw] = []
                    var openings = 0.0
                    let middle = side.strips.map(\.features.distanceM).sorted()[side.strips.count / 2]
                    for k in 0..<draws {
                        let mass = masses[k]
                        let strength =
                            uncertainty.strengthMedian
                            * exp(
                                uncertainty.strengthLogSD
                                    * Random.normal(uncertainty.seed, 2, UInt64(k), owner))
                        var errors = SIMD2<Double>.zero
                        if let scatter = uncertainty.scatter(atZ: middle / cbrt(mass)) {
                            let a = Random.normal(uncertainty.seed, 3, UInt64(k), UInt64(s))
                            let b = Random.normal(uncertainty.seed, 4, UInt64(k), UInt64(s))
                            let r = scatter.correlation
                            errors = SIMD2(
                                scatter.peak * a, scatter.impulse * (r * a + (1 - r * r).squareRoot() * b))
                        }
                        var outcome = GlassOutcome()
                        var sidePeak = 0.0
                        for strip in side.strips {
                            var p = predict(
                                strip.features, mass: mass, cellSize: Double(cellSize),
                                coefficients: coefficients)
                            if let farField { p = farField.apply(p, distanceM: strip.features.distanceM) }
                            p.peakPa *= exp(errors.x)
                            p.impulsePaS *= exp(errors.y)
                            sidePeak = max(sidePeak, p.peakPa)
                            outcome =
                                outcome
                                + table.outcome(
                                    side.mix, prediction: p, areaM2: strip.areaM2, strength: strength)
                        }
                        let glass = outcome.glass
                        some += glass.anyBroken
                        let isBlown = glass.fraction >= 0.9
                        blown += isBlown ? 1 : 0
                        fraction += glass.fraction
                        thrown += outcome.worse
                        let out = OpeningsFragility.chance(peakPa: sidePeak)
                        openings += out
                        if keepDraws {
                            mine.append((Float(glass.anyBroken), isBlown, Float(outcome.worse), Float(out)))
                        }
                    }
                    let n = Double(draws)
                    out[s] = SideGlass(
                        owner: side.owner, axis: side.axis, outward: side.outward, distanceM: middle,
                        someBroken: some / n, blownOut: blown / n, fractionBroken: fraction / n,
                        thrownPast3b: thrown / n, openingsBlownOut: openings / n)
                    if keepDraws { kept[s] = mine }
                }
            }
        }
        // In `sides`' order; a side without strips has no chance.
        let judged = results.indices.map { s in
            results[s]
                ?? SideGlass(
                    owner: sides[s].owner, axis: sides[s].axis, outward: sides[s].outward, distanceM: 0,
                    someBroken: 0, blownOut: 0, fractionBroken: 0, thrownPast3b: 0)
        }
        return (judged, keepDraws ? outcomes : nil)
    }

    /// A side's glass under one load: the panes broken (`GlazingBreakage`), and the log of the
    /// chance that no broken pane is thrown worse than a GSA condition (3b unless asked otherwise:
    /// its glass beyond 3 m of the window, `GlazingHazard`).
    public struct GlassOutcome: Sendable {
        public var glass = GlazingBreakage()
        public var logNoneWorse = 0.0

        public init() {}

        init(_ glass: GlazingBreakage) {
            self.glass = glass
            logNoneWorse = glass.logNoneWorse ?? 0
        }

        /// The chance some broken pane is thrown worse than the condition asked.
        public var worse: Double { 1 - exp(logNoneWorse) }

        public static func + (a: Self, b: Self) -> Self {
            var sum = a
            sum.glass = a.glass + b.glass
            sum.logNoneWorse += b.logNoneWorse
            return sum
        }
    }

    /// `mix`'s glass under a recorded history (net pressures, Pa, in bins `binS` long), its panes
    /// `strength` times their glass's median, against `worseThan` (`GlazingMix.breakage`): as the
    /// surrogate's pulses are judged, for judging them.
    public static func glassOutcome(
        _ mix: GlazingMix, netPa: [Double], binS: Double, areaM2: Double, strength: Double = 1,
        worseThan: GlazingHazard.Condition = .threeB
    ) -> GlassOutcome {
        GlassOutcome(
            mix.breakage(netPa: netPa, binS: binS, areaM2: areaM2, worseThan: worseThan, strength: strength))
    }

    /// A pane type's response to the surrogate's pulses, by their rounded peak, impulse and rise:
    /// whether it lets go of its frame and the 60 s stress it reaches, so that each draw's
    /// strength gives its chance without integrating it again; and, by the strength it broke at
    /// (in twentieths of e), whether it is thrown worse than condition 3b.
    final class GlassTable: @unchecked Sendable {
        struct Key: Hashable {
            var thickness: Float
            var width: Float
            var height: Float
            var peak: Int32
            var impulse: Int32
            var rise: Int8
            /// For a throw: the strength it broke at; 0 for the stress.
            var strength: Int16 = 0
            var glass: GlazingMix.Glass?
        }
        /// One part of the table, by its keys' hash, with its own lock: classes in a `let` array,
        /// so that writing one never touches the array the others are read through (as
        /// `SDOFResponseMemo`'s).
        private final class Shard: @unchecked Sendable {
            let lock = NSLock()
            var responses: [Key: (lost: Bool, stress: Double)] = [:]
        }

        private static let shardCount = 64
        private let shards = (0..<GlassTable.shardCount).map { _ in Shard() }
        let binS: Double

        init(binS: Double) { self.binS = binS }

        static let step = log(1 + FacadeLoadSurrogate.quantum)

        /// The rounded pulse of `prediction`: its keys' parts and its pressures, made once.
        struct Pulse {
            var peak: Int32
            var impulse: Int32
            var rise: Int8
            let binS: Double
            private var made: [Double]?

            init(_ prediction: Prediction, binS: Double) {
                peak =
                    prediction.peakPa > 0
                    ? Int32((log(prediction.peakPa) / GlassTable.step).rounded()) : Int32.min
                impulse =
                    prediction.impulsePaS > 0
                    ? Int32((log(prediction.impulsePaS) / GlassTable.step).rounded()) : Int32.min
                rise = Int8((prediction.riseShare * 20).rounded())
                self.binS = binS
            }

            mutating func pressures() -> [Double] {
                if let made { return made }
                let p = peak == .min ? 0 : exp(Double(peak) * GlassTable.step)
                let i = impulse == .min ? 0 : exp(Double(impulse) * GlassTable.step)
                let load = FacadeLoadSurrogate.pulse(
                    peak: p, impulse: i, riseShare: Double(rise) / 20, binS: binS)
                made = load
                return load
            }

            func key(_ pane: GlazingMix.Pane, glass: GlazingMix.Glass?, strength: Int16 = 0) -> Key {
                Key(
                    thickness: pane.thicknessM, width: pane.widthM, height: pane.heightM, peak: peak,
                    impulse: impulse, rise: rise, strength: strength, glass: glass)
            }
        }

        /// `mix`'s glass over a façade region of `areaM2` under `prediction`'s pulse, its panes'
        /// strength `strength` times their glass's (`GlazingMix.judged`), against `worseThan`.
        func outcome(
            _ mix: GlazingMix, prediction: Prediction, areaM2: Double, strength: Double,
            worseThan: GlazingHazard.Condition = .threeB
        ) -> GlassOutcome {
            var pulse = Pulse(prediction, binS: binS)
            return GlassOutcome(
                mix.judged(
                    areaM2: areaM2, strength: strength, worseThan: worseThan,
                    answer: { pane in
                        lookup(pulse.key(pane, glass: mix.glass)) {
                            // Under 50 Pa no pane comes near breaking (as `GlazingMix.breakage`).
                            guard (pulse.pressures().max() ?? 0) > 50 else { return (false, 0) }
                            let (a, b) = GlazingMix.sides(pane)
                            let r = EnvelopeDamageAssessment.unbreakablePane(
                                thickness: mix.glassAlone(pane), a: a, b: b
                            ).response(pressures: pulse.pressures(), step: binS)
                            return (r.lostResistanceAt != nil, r.equivalentStress ?? 0)
                        }
                    },
                    thrown: { pane, broke in
                        let step = Int16(max(min((log(broke) * 20).rounded(), 32_000), -32_000))
                        let rank = lookup(pulse.key(pane, glass: mix.glass, strength: step)) {
                            let condition = mix.condition(
                                pane, strength: exp(Double(step) / 20), pressures: pulse.pressures(),
                                binS: binS)
                            return (
                                false, Double(GlazingHazard.Condition.allCases.firstIndex(of: condition)!)
                            )
                        }.stress
                        return GlazingHazard.Condition.allCases[Int(rank)]
                    }))
        }

        /// `mix`'s glass alone (`outcome`), as `GlazingMix.breakage` on the pulse.
        func breakage(_ mix: GlazingMix, prediction: Prediction, areaM2: Double, strength: Double)
            -> GlazingBreakage
        {
            outcome(mix, prediction: prediction, areaM2: areaM2, strength: strength).glass
        }

        private func lookup(_ key: Key, _ make: () -> (lost: Bool, stress: Double)) -> (
            lost: Bool, stress: Double
        ) {
            let shard = shards[abs(key.hashValue % Self.shardCount)]
            shard.lock.lock()
            if let known = shard.responses[key] {
                shard.lock.unlock()
                return known
            }
            shard.lock.unlock()
            let made = make()
            shard.lock.lock()
            shard.responses[key] = made
            shard.lock.unlock()
            return made
        }
    }

    /// Counter-based random numbers: the same draw for the same (seed, stream, draw, item)
    /// whichever thread asks, so the chances do not depend on how the work is shared.
    enum Random {
        static func bits(_ seed: UInt64, _ stream: UInt64, _ draw: UInt64, _ item: UInt64) -> UInt64 {
            var x =
                seed &* 0x9E37_79B9_7F4A_7C15 ^ stream &* 0xBF58_476D_1CE4_E5B9 ^ draw
                &* 0x94D0_49BB_1331_11EB
                ^ item &* 0xD6E8_FEB8_6659_FD93
            // SplitMix64's finaliser.
            x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
            x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
            return x ^ (x >> 31)
        }

        /// Uniform in [0, 1).
        static func uniform(_ seed: UInt64, _ stream: UInt64, _ draw: UInt64, _ item: UInt64)
            -> Double
        {
            Double(bits(seed, stream, draw, item) >> 11) * 0x1p-53
        }

        /// Standard normal, by Box–Muller.
        package static func normal(_ seed: UInt64, _ stream: UInt64, _ draw: UInt64, _ item: UInt64) -> Double
        {
            let u = max(uniform(seed, stream &+ 100, draw, item), 1e-300)
            let v = uniform(seed, stream &+ 200, draw, item)
            return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
        }
    }
}

/// The view's colours for a building side's glass chance (`FacadeLoadSurrogate.SideGlass`), in
/// eighths: viridis reversed, light to dark as the chance grows, apart under the common colour
/// blindnesses. A building's sides go to the view as one code (`code`), which the shader reads
/// by the face it draws; its roof takes its worst side's.
public enum EnvelopeChanceColour {
    /// sRGB, by eighth of chance: 0–⅛ first.
    public static let ramp: [SIMD3<Float>] = [
        SIMD3(0.992, 0.906, 0.145), SIMD3(0.627, 0.855, 0.224), SIMD3(0.290, 0.757, 0.427),
        SIMD3(0.122, 0.631, 0.529), SIMD3(0.153, 0.498, 0.557), SIMD3(0.212, 0.361, 0.553),
        SIMD3(0.275, 0.196, 0.494), SIMD3(0.267, 0.005, 0.329),
    ]

    /// The first code that is a chance, not `EnvelopeDamageColour`'s.
    public static let first = 16

    /// A chance's eighth, 0–7.
    public static func eighth(_ chance: Double) -> Int { min(7, max(0, Int(chance * 8))) }

    /// A building's code from its sides' chances (axis, outward, chance): `first` plus each side's
    /// eighth in three bits, −x, +x, −y then +y; a side not given is taken as none.
    public static func code(_ sides: [(axis: Int, outward: Int, chance: Double)]) -> Int {
        var code = 0
        for side in sides where side.axis < 2 {
            let slot = side.axis * 2 + (side.outward > 0 ? 1 : 0)
            code |= eighth(side.chance) << (3 * slot)
        }
        return first + code
    }

    /// The eighth `code` gives the side facing along `axis` to `outward`.
    public static func eighth(code: Int, axis: Int, outward: Int) -> Int {
        ((code - first) >> (3 * (axis * 2 + (outward > 0 ? 1 : 0)))) & 7
    }
}
