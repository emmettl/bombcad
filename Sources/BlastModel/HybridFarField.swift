import Foundation
import simd

/// A district's far field carried by the façade load surrogate from where its near field, run in
/// the air, hands over (Horizons 3, "City scale in minutes"; docs/hybrid-far-field.md). The
/// surrogate's peak and impulse are scaled to meet the near run where both hold, just inside the
/// hand-over, and carry on the near run's trend with distance beyond it; its arrivals are
/// Kingery–Bulmash's scaled to the near run's at its gauges.
public struct HybridFarField: Codable, Sendable, Equatable {
    /// Where the near field hands over, m from the charge.
    public var handoverM: Double
    /// The near run over the surrogate at the hand-over, peak and impulse.
    public var peak: Double
    public var impulse: Double
    /// How that ratio's logarithm runs with the logarithm of distance, from the near run's strips
    /// inside the hand-over; carried on beyond it. Never above nothing (`fit`): a match that rose
    /// outward would carry the near band's misfit ever higher.
    public var peakSlope: Double
    public var impulseSlope: Double
    /// The near run's arrivals over Kingery–Bulmash's.
    public var arrival: Double
    /// The strips the seed was taken from.
    public var seedStrips: Int
    /// How far beyond the hand-over the trend is carried, as a multiple of it, the ratio held
    /// from there on; nil carries it all the way.
    public var trendReach: Double?
    /// Beyond `trendReach`, how quickly the match fades back to the surrogate's own loads: its
    /// logarithm falls by e for each `trendDamping` of log distance past the reach; nil holds it.
    public var trendDamping: Double?
    /// The mean logarithm of distance over the hand-over at which the seeds were taken (they lie
    /// just inside it): the trend is carried from there, so that it meets them where they were
    /// measured; nil for the hand-over itself.
    public var seedLogDistance: Double?

    public init(
        handoverM: Double, peak: Double = 1, impulse: Double = 1, peakSlope: Double = 0,
        impulseSlope: Double = 0,
        arrival: Double = 1, seedStrips: Int = 0, trendReach: Double? = nil, seedLogDistance: Double? = nil
    ) {
        self.trendReach = trendReach
        self.seedLogDistance = seedLogDistance
        self.handoverM = handoverM
        self.peak = peak
        self.impulse = impulse
        self.peakSlope = peakSlope
        self.impulseSlope = impulseSlope
        self.arrival = arrival
        self.seedStrips = seedStrips
    }

    /// A near run's façade strip against the surrogate's prediction for it.
    public struct Sample: Sendable {
        public var distanceM: Double
        public var nearPeakPa: Double
        public var nearImpulsePaS: Double
        public var predicted: FacadeLoadSurrogate.Prediction

        public init(
            distanceM: Double, nearPeakPa: Double, nearImpulsePaS: Double,
            predicted: FacadeLoadSurrogate.Prediction
        ) {
            self.distanceM = distanceM
            self.nearPeakPa = nearPeakPa
            self.nearImpulsePaS = nearImpulsePaS
            self.predicted = predicted
        }
    }

    /// The far field from a near run's strips and gauges: the ratios' medians over the strips from
    /// `seedFromM` to the hand-over, their slopes over those from `trendFromM` (nil for none), and the
    /// arrivals' median over gauges (simulated, Kingery–Bulmash, distance) from 500 m to it.
    ///
    /// A slope that would raise the match outward is held at nothing (emmettl/bombcad-work#56). The
    /// trend is fitted over the near band, where it measures how the surrogate's shape misses the
    /// near run there, not beyond; carried 2.5 times out a rising one compounds. On Beirut at 1.1 kt,
    /// on the façade terms refitted on 23 October 2026, the peak's slope came out +0.09 and read the
    /// far field's peaks 1.29 of the full run's at 2–2.5 km (1.19 held), its blown-out glass at
    /// 1.5–1.75 km 0.96 against 0.69 (0.85 held). Every slope fitted on the terms before was falling.
    public static func fit(
        handoverM: Double, seedFromM: Double, trendFromM: Double?, samples: [Sample],
        arrivals: [(simulatedS: Double, kingeryBulmashS: Double, distanceM: Double)]
    ) -> HybridFarField {
        func median(_ l: [Double]) -> Double { l.isEmpty ? 0 : l.sorted()[l.count / 2] }
        func slope(_ points: [(Double, Double)]) -> Double {
            guard points.count > 2 else { return 0 }
            let mx = points.reduce(0) { $0 + $1.0 } / Double(points.count)
            let my = points.reduce(0) { $0 + $1.1 } / Double(points.count)
            let sxx = points.reduce(0) { $0 + ($1.0 - mx) * ($1.0 - mx) }
            let sxy = points.reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
            return sxx > 0 ? sxy / sxx : 0
        }
        var seedX: [Double] = []
        var peakSeed: [Double] = []
        var impulseSeed: [Double] = []
        var peakTrend: [(Double, Double)] = []
        var impulseTrend: [(Double, Double)] = []
        for s in samples where s.distanceM < handoverM {
            let x = log(s.distanceM / handoverM)
            let p = s.nearPeakPa > 0 && s.predicted.peakPa > 0 ? log(s.nearPeakPa / s.predicted.peakPa) : nil
            let i =
                s.nearImpulsePaS > 0 && s.predicted.impulsePaS > 0
                ? log(s.nearImpulsePaS / s.predicted.impulsePaS) : nil
            if s.distanceM >= seedFromM {
                if p != nil { seedX.append(x) }
                if let p { peakSeed.append(p) }
                if let i { impulseSeed.append(i) }
            }
            if let from = trendFromM, s.distanceM >= from {
                if let p { peakTrend.append((x, p)) }
                if let i { impulseTrend.append((x, i)) }
            }
        }
        let arrivalRatios = arrivals.filter {
            $0.distanceM >= 500 && $0.distanceM < handoverM && $0.kingeryBulmashS > 0
        }
        .map { log($0.simulatedS / $0.kingeryBulmashS) }
        return HybridFarField(
            handoverM: handoverM, peak: exp(median(peakSeed)), impulse: exp(median(impulseSeed)),
            peakSlope: min(slope(peakTrend), 0), impulseSlope: min(slope(impulseTrend), 0),
            arrival: arrivalRatios.isEmpty ? 1 : exp(median(arrivalRatios)), seedStrips: peakSeed.count,
            seedLogDistance: seedX.isEmpty ? nil : seedX.reduce(0, +) / Double(seedX.count))
    }

    /// The surrogate's `prediction` for a strip `distanceM` from the charge, carried as the far field.
    public func apply(_ prediction: FacadeLoadSurrogate.Prediction, distanceM: Double)
        -> FacadeLoadSurrogate.Prediction
    {
        let reach = trendReach.map { $0 * handoverM } ?? .infinity
        let x = log(min(max(distanceM, 1), reach) / handoverM) - (seedLogDistance ?? 0)
        var peakFactor = peak * exp(peakSlope * x)
        var impulseFactor = impulse * exp(impulseSlope * x)
        // Faded past the reach toward the surrogate's own loads.
        if let damping = trendDamping, damping > 0, distanceM > reach {
            let k = exp(-log(distanceM / reach) / damping)
            peakFactor = pow(peakFactor, k)
            impulseFactor = pow(impulseFactor, k)
        }
        var p = prediction
        p.peakPa *= peakFactor
        p.impulsePaS *= impulseFactor
        p.arrivalS *= arrival
        return p
    }

    /// What the mode is, in a line.
    public static let method =
        "The air run in 3-D to the hand-over; beyond it each façade's load from the façade load surrogate, its peak "
        + "and impulse scaled to meet the near run where both hold and carried on flat (New District's, since 25 "
        + "October 2026; districts made before carry the near run's trend with distance)."

    /// Its standing, from Beirut against full runs at 0.2, 0.5 and 1.1 kt with their top clear (8 m
    /// air refined to 4 m, since 25 October 2026), handing over at 1 km, on the clear-top terms with
    /// far terms for façades deep in a city (the deep-city terms) and the match carried flat, adopted
    /// the same day (docs/hybrid-far-field.md).
    public static let standing: [String] = {
        let peak = ValidationTables.figure("hybridFarPeak")
        let impulse = ValidationTables.figure("hybridFarImpulse")
        return [
            "Inside the hand-over: the near run's own loads, which on Beirut were the full run's (peaks 1.00, scatter 3–8%).",
            "Beyond it, against the full run with its top clear: façade peaks \(peak.ratio) of its to 2.5 km, the lower "
                + "the further out, impulses \(impulse.ratio) times; sides with some glass broken within 0.05 of its to "
                + "1.5 km at 0.2 kt, to 2 km at 0.5 kt and to 3 km at 1.1 kt, 0.12–0.46 under at 1.5–2.5 km at 0.2 kt; "
                + "blown-out shares up to 0.36 under in a band. Glass low beyond 1.5 km at the smallest yield: the unsafe side.",
            "Arrivals beyond the hand-over: Kingery–Bulmash's scaled to the near run's, 2–4% earlier than the full run's.",
            "Walls and roofs beyond the hand-over take the façade load surrogate's standing: run the scene for the structure.",
        ]
    }()
}

extension HybridFarField {
    /// The first positive phase's impulse of a net history, Pa s: from its start through its rise
    /// past half its peak, until it first falls below zero.
    public static func firstImpulse(_ net: [Double], binS: Double) -> Double {
        let peak = net.max() ?? 0
        guard peak > 0 else { return 0 }
        var impulse = 0.0
        var risen = false
        for p in net {
            if p >= 0.5 * peak { risen = true }
            if risen, p < 0 { break }
            impulse += max(p, 0) * binS
        }
        return impulse
    }

    /// The far set judged after a near run (and, with `nearBeyond`, the near buildings beyond the
    /// hand-over).
    public struct Judgement: Sendable {
        public var farField: HybridFarField
        /// The buildings judged on the far field: every far one, and every near one whose plan
        /// centre lies beyond the hand-over (its components there on the far field, those inside on
        /// the run's histories).
        public var buildings: [EnvelopeBuildingDamage]
        /// The near run's strips the match was taken from.
        public var nearStrips: Int
        /// Components judged on the far field beyond the distances the surrogate was fitted over
        /// (`FacadeLoadSurrogate.Prediction.outsideFit`): extrapolated.
        public var outsideFit: Int
        /// The judged buildings' façade sides' glass chances on the far field, when asked for.
        public var glass: [FacadeLoadSurrogate.SideGlass] = []
        public var seconds: Double
    }

    /// After a near run of `near` on cells `cellSize`, whose components recorded `histories`, the
    /// far set `far` judged on the far field carried from it: the match over the run's façade strips
    /// from `trendFrom` (half the hand-over) and `seedFrom` (0.8 of it) to the hand-over, and its
    /// arrivals against Kingery–Bulmash's from 500 m (none with the set's `matchFlat`: the match
    /// carried flat). With `glass`, the judged buildings' glass chances too, drawn over it on the
    /// far field (`FacadeLoadSurrogate.glassProbabilities`). The surrogate takes `coefficients`.
    public static func judge(
        near: Scenario, far set: FarFieldSet, histories: [EnvelopeComponentHistory], cellSize: Float,
        seedFrom: Double? = nil, trendFrom: Double? = nil, nearBeyond: Bool = true,
        glass uncertainty: FacadeLoadSurrogate.Uncertainty? = nil,
        coefficients: FacadeLoadSurrogate.Coefficients = .adopted
    ) throws -> Judgement {
        let start = ContinuousClock.now
        let handover = Double(set.handoverM)
        let combined = try set.combined(with: near)
        var estimate = FacadeLoadSurrogate.estimate(
            scene: combined, cellSize: cellSize, coefficients: coefficients)
        let charge = combined.charge.position
        let mass = Double(combined.charge.mass)
        var recorded: [String: EnvelopeComponentHistory] = [:]
        for history in histories where !history.invalid { recorded[history.component.id] = history }
        let distances = estimate.features.map(\.distanceM)
        let seedFromM = seedFrom ?? 0.8 * handover
        let trendFromM: Double? = set.matchFlat == true ? nil : trendFrom ?? 0.5 * handover
        var samples: [Sample] = []
        var arrivals: [(simulatedS: Double, kingeryBulmashS: Double, distanceM: Double)] = []
        for (n, component) in estimate.components.enumerated() where component.kind == .facade {
            let d = distances[n]
            guard d < handover, let history = recorded[component.id] else { continue }
            let load = EnvelopeComponentLoad(history)
            let net = load.netPa
            if d >= min(seedFromM, trendFromM ?? seedFromM) {
                samples.append(
                    Sample(
                        distanceM: d, nearPeakPa: net.max() ?? 0,
                        nearImpulsePaS: firstImpulse(net, binS: load.binS),
                        predicted: estimate.predictions[n]))
            }
            if d >= 500, let arrived = history.windowStartS {
                arrivals.append(
                    (arrived, FacadeLoadSurrogate.base(estimate.features[n], mass: mass).arrival, d))
            }
        }
        var farField = fit(
            handoverM: handover, seedFromM: seedFromM, trendFromM: trendFromM, samples: samples,
            arrivals: arrivals)
        farField.trendReach = set.trendReach
        farField.trendDamping = set.trendDamping
        // The buildings to judge: the far ones, and the near ones beyond the hand-over.
        let farIDs = Set(set.buildings.map(\.id))
        var judged = farIDs
        for object in nearBeyond ? near.envelopeObjects : [] {
            guard let blocks = object.envelope?.blocks, !blocks.isEmpty else { continue }
            let low = blocks.map(\.min).reduce(SIMD3<Float>(repeating: .greatestFiniteMagnitude), simd_min)
            let high = blocks.map(\.max).reduce(SIMD3<Float>(repeating: -.greatestFiniteMagnitude), simd_max)
            let c = 0.5 * (low + high)
            if Double(simd_length(SIMD2(c.x - charge.x, c.y - charge.y))) >= handover {
                judged.insert(object.id)
            }
        }
        var loads: [EnvelopeComponentLoad] = []
        var outsideFit = 0
        for (n, component) in estimate.components.enumerated() where judged.contains(component.owner) {
            if distances[n] < handover, let history = recorded[component.id] {
                loads.append(EnvelopeComponentLoad(history))
            } else {
                if estimate.predictions[n].outsideFit { outsideFit += 1 }
                loads.append(
                    FacadeLoadSurrogate.load(
                        component, farField.apply(estimate.predictions[n], distanceM: distances[n]),
                        binS: estimate.loads[n].binS))
            }
        }
        estimate.loads = loads
        let (buildings, _, _) = FacadeLoadSurrogate.damage(
            estimate, constructions: { combined.envelopeConstruction(for: $0) })
        var glass: [FacadeLoadSurrogate.SideGlass] = []
        if let uncertainty {
            let sides = FacadeLoadSurrogate.glassSides(
                scene: combined, cellSize: cellSize, incidence: coefficients.incidence
            ).filter {
                judged.contains($0.owner)
            }
            glass =
                FacadeLoadSurrogate.glassProbabilities(
                    sides: sides, mass: mass, cellSize: cellSize, uncertainty: uncertainty,
                    coefficients: coefficients, farField: farField
                ).sides
        }
        let took = start.duration(to: .now)
        return Judgement(
            farField: farField, buildings: buildings, nearStrips: samples.count, outsideFit: outsideFit,
            glass: glass,
            seconds: Double(took.components.seconds) + Double(took.components.attoseconds) * 1e-18)
    }
}
