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
                    "Against GEER's survey of Beirut's façades they are not: they share the glass model's over-breaking "
                    + "(blown out %.2f at 0.75–1 km where GEER saw %.2f), and no one glass strength brings both "
                    + "classes into line. Read them as a run's spread, not the event's.", survey.high,
                survey.low),
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
    }

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
        let raster = Raster(objects: objects, terrain: scene.terrain, cell: cellSize)
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
    /// whether it is blown out, draw by draw.
    public static func glassProbabilities(
        sides: [GlassSideStrips], mass base: Double, cellSize: Float,
        uncertainty: Uncertainty = Uncertainty(),
        binS: Double = 0.7e-3, coefficients: Coefficients = .fitted, keepDraws: Bool = false
    ) -> (sides: [SideGlass], draws: [[(someBroken: Float, blownOut: Bool, thrownPast3b: Float)]]?) {
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
        var outcomes = [[(someBroken: Float, blownOut: Bool, thrownPast3b: Float)]](
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
                    var mine: [(someBroken: Float, blownOut: Bool, thrownPast3b: Float)] = []
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
                        for strip in side.strips {
                            var p = predict(
                                strip.features, mass: mass, cellSize: Double(cellSize),
                                coefficients: coefficients)
                            p.peakPa *= exp(errors.x)
                            p.impulsePaS *= exp(errors.y)
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
                        thrown += outcome.thrownPast3b
                        if keepDraws {
                            mine.append((Float(glass.anyBroken), isBlown, Float(outcome.thrownPast3b)))
                        }
                    }
                    let n = Double(draws)
                    out[s] = SideGlass(
                        owner: side.owner, axis: side.axis, outward: side.outward, distanceM: middle,
                        someBroken: some / n, blownOut: blown / n, fractionBroken: fraction / n,
                        thrownPast3b: thrown / n)
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
    /// chance that no broken pane is thrown worse than GSA's condition 3b (its glass beyond 3 m
    /// of the window, `GlazingHazard`).
    public struct GlassOutcome: Sendable {
        public var glass = GlazingBreakage()
        public var logNoneThrownPast3b = 0.0

        public init() {}

        /// The chance some broken pane is thrown worse than condition 3b.
        public var thrownPast3b: Double { 1 - exp(logNoneThrownPast3b) }

        public static func + (a: Self, b: Self) -> Self {
            var sum = a
            sum.glass = a.glass + b.glass
            sum.logNoneThrownPast3b += b.logNoneThrownPast3b
            return sum
        }
    }

    /// `mix`'s glass over a façade region of `areaM2`, its panes' strength `strength` times the
    /// flaw model's median, as `GlazingMix.breakage` judges it: each pane type's chance of breaking
    /// from the 60 s stress its load gives it (`answer`: let go, and that stress), and whether a
    /// pane of it that breaks is thrown worse than condition 3b (`thrownFar`, given the 60 s strength
    /// it broke at: the draw's, or just under the stress reached where that is less, as the panes
    /// that break are the weaker).
    static func glassOutcome(
        _ mix: GlazingMix, areaM2: Double, strength: Double,
        answer: (GlazingMix.Pane) -> (lost: Bool, stress: Double),
        thrownFar: (GlazingMix.Pane, Double) -> Bool
    ) -> GlassOutcome {
        var result = GlassOutcome()
        for pane in mix.panes where pane.areaM2 > 0 && pane.share > 0 {
            let count = Double(mix.glazedFraction * pane.share) * areaM2 / Double(pane.areaM2)
            guard count > 0 else { continue }
            result.glass.panes += count
            result.glass.glazedM2 += count * Double(pane.areaM2)
            let response = answer(pane)
            let area = Double(min(pane.widthM, pane.heightM)) * Double(max(pane.widthM, pane.heightM))
            let probability =
                response.lost ? 1 : GlassStrength.probability(stress: response.stress / strength, area: area)
            result.glass.broken += count * probability
            result.glass.brokenM2 += count * probability * Double(pane.areaM2)
            result.glass.logNoneBroken += count * log(max(1 - probability, 1e-300))
            guard probability > 0 else { continue }
            let median = GlassStrength.sixtySecond(area: area)
            let broke = response.lost ? strength * median : min(strength * median, 0.99 * response.stress)
            if thrownFar(pane, broke) {
                result.logNoneThrownPast3b += count * log(max(1 - probability, 1e-300))
            }
        }
        return result
    }

    /// Whether a pane of `pane`'s type with 60 s strength `strength` Pa, under `pressures` (in bins
    /// `binS` long), breaks and is thrown worse than condition 3b.
    static func thrownPast3b(_ pane: GlazingMix.Pane, strength: Double, pressures: [Double], binS: Double)
        -> Bool
    {
        let a = Double(min(pane.widthM, pane.heightM))
        let b = Double(max(pane.widthM, pane.heightM))
        let system = EnvelopePanel.largeDeflectionGlass(
            thickness: Double(pane.thicknessM), material: .annealedGlass, a: a, b: b,
            sixtySecondStrength: strength)
        let response = system.response(pressures: pressures, step: binS)
        let hazard = GlazingHazard.broken(
            response: response, netPa: pressures, binS: binS, massPerArea: system.massPerArea,
            paneHeight: Double(pane.heightM))
        return hazard.condition > .threeB
    }

    /// `mix`'s glass under a recorded history (net pressures, Pa, in bins `binS` long), at the flaw
    /// model's median strength: as `glassOutcome` on the surrogate's pulses, for judging them.
    public static func glassOutcome(_ mix: GlazingMix, netPa: [Double], binS: Double, areaM2: Double)
        -> GlassOutcome
    {
        let peak = netPa.map(abs).max() ?? 0
        return glassOutcome(
            mix, areaM2: areaM2, strength: 1,
            answer: { pane in
                guard peak > 50 else { return (false, 0) }
                let a = Double(min(pane.widthM, pane.heightM))
                let b = Double(max(pane.widthM, pane.heightM))
                let r = EnvelopeDamageAssessment.unbreakablePane(
                    thickness: Double(pane.thicknessM), a: a, b: b
                )
                .response(pressures: netPa, step: binS)
                return (r.lostResistanceAt != nil, r.equivalentStress ?? 0)
            },
            thrownFar: { pane, strength in
                thrownPast3b(pane, strength: strength, pressures: netPa, binS: binS)
            })
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

        /// `mix`'s glass over a façade region of `areaM2` under `prediction`'s pulse, its panes'
        /// strength `strength` times the flaw model's (`glassOutcome`).
        func outcome(_ mix: GlazingMix, prediction: Prediction, areaM2: Double, strength: Double)
            -> GlassOutcome
        {
            let peakStep =
                prediction.peakPa > 0 ? Int32((log(prediction.peakPa) / Self.step).rounded()) : Int32.min
            let impulseStep =
                prediction.impulsePaS > 0
                ? Int32((log(prediction.impulsePaS) / Self.step).rounded()) : Int32.min
            let rise = Int8((prediction.riseShare * 20).rounded())
            let peak = peakStep == .min ? 0 : exp(Double(peakStep) * Self.step)
            let impulse = impulseStep == .min ? 0 : exp(Double(impulseStep) * Self.step)
            var pressures: [Double]?
            func load() -> [Double] {
                if let pressures { return pressures }
                let made = FacadeLoadSurrogate.pulse(
                    peak: peak, impulse: impulse, riseShare: Double(rise) / 20, binS: binS)
                pressures = made
                return made
            }
            func key(_ pane: GlazingMix.Pane, strength: Int16 = 0) -> Key {
                Key(
                    thickness: pane.thicknessM, width: pane.widthM, height: pane.heightM, peak: peakStep,
                    impulse: impulseStep, rise: rise, strength: strength)
            }
            return FacadeLoadSurrogate.glassOutcome(
                mix, areaM2: areaM2, strength: strength,
                answer: { pane in
                    lookup(key(pane)) {
                        // Under 50 Pa no pane comes near breaking (as `GlazingMix.breakage`).
                        guard (load().max() ?? 0) > 50 else { return (false, 0) }
                        let a = Double(min(pane.widthM, pane.heightM))
                        let b = Double(max(pane.widthM, pane.heightM))
                        let r = EnvelopeDamageAssessment.unbreakablePane(
                            thickness: Double(pane.thicknessM), a: a, b: b
                        ).response(pressures: load(), step: binS)
                        return (r.lostResistanceAt != nil, r.equivalentStress ?? 0)
                    }
                },
                thrownFar: { pane, broke in
                    let step = Int16((log(broke) * 20).rounded())
                    return lookup(key(pane, strength: step)) {
                        let far = FacadeLoadSurrogate.thrownPast3b(
                            pane, strength: exp(Double(step) / 20), pressures: load(), binS: binS)
                        return (far, 0)
                    }.lost
                })
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
        static func uniform(_ seed: UInt64, _ stream: UInt64, _ draw: UInt64, _ item: UInt64) -> Double {
            Double(bits(seed, stream, draw, item) >> 11) * 0x1p-53
        }

        /// Standard normal, by Box–Muller.
        static func normal(_ seed: UInt64, _ stream: UInt64, _ draw: UInt64, _ item: UInt64) -> Double {
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
