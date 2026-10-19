import Foundation

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
    /// inside the hand-over; carried on beyond it.
    public var peakSlope: Double
    public var impulseSlope: Double
    /// The near run's arrivals over Kingery–Bulmash's.
    public var arrival: Double
    /// The strips the seed was taken from.
    public var seedStrips: Int

    public init(
        handoverM: Double, peak: Double = 1, impulse: Double = 1, peakSlope: Double = 0,
        impulseSlope: Double = 0,
        arrival: Double = 1, seedStrips: Int = 0
    ) {
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
            peakSlope: slope(peakTrend), impulseSlope: slope(impulseTrend),
            arrival: arrivalRatios.isEmpty ? 1 : exp(median(arrivalRatios)), seedStrips: peakSeed.count)
    }

    /// The surrogate's `prediction` for a strip `distanceM` from the charge, carried as the far field.
    public func apply(_ prediction: FacadeLoadSurrogate.Prediction, distanceM: Double)
        -> FacadeLoadSurrogate.Prediction
    {
        let x = log(max(distanceM, 1) / handoverM)
        var p = prediction
        p.peakPa *= peak * exp(peakSlope * x)
        p.impulsePaS *= impulse * exp(impulseSlope * x)
        p.arrivalS *= arrival
        return p
    }

    /// What the mode is, in a line.
    public static let method =
        "The air run in 3-D to the hand-over; beyond it each façade's load from the façade load surrogate, its peak "
        + "and impulse scaled to meet the near run where both hold and carried on its trend with distance."

    /// Its standing, from Beirut against the full 4 m runs at 0.2, 0.5 and 1.1 kt, handing over at
    /// 1 km (docs/hybrid-far-field.md).
    public static let standing: [String] = {
        let peak = ValidationTables.figure("hybridFarPeak")
        let impulse = ValidationTables.figure("hybridFarImpulse")
        return [
            "Inside the hand-over: the near run's own loads, which on Beirut were the full run's (peaks 1.00, scatter 3–8%).",
            "Beyond it, against the full run: façade peaks \(peak.ratio) of its to 2.5 km, impulses \(impulse.ratio) "
                + "times; sides with some glass broken within 0.03 of its to 1.5 km at every yield, to 2 km at 0.5 kt "
                + "and to 2.5 km at 1.1 kt, 0.13–0.25 under at 1.5–2.5 km at 0.2 kt; blown-out shares up to 0.22 "
                + "apart in a band.",
            "Arrivals beyond the hand-over: Kingery–Bulmash's scaled to the near run's, 2–4% earlier than the full run's.",
            "Walls and roofs beyond the hand-over take the façade load surrogate's standing: run the scene for the structure.",
        ]
    }()
}
