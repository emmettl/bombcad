import Foundation
import Testing

@testable import BlastCore

/// Paths through the hybrid far field (`HybridFarField`) that `HybridFarFieldTests` does not
/// reach: the far field meeting the near run at the hand-over when the near run scatters, the
/// strips and gauges `fit` must leave out, the trend carried a decade beyond the hand-over, and
/// the standing it reports against the page it cites. `HybridFarFieldTests` fits a near run with
/// no scatter and no strips beyond the hand-over, and never reads the standing.
@Suite("Hybrid far field paths not otherwise reached")
struct HybridGapTests {
    static func prediction(_ peak: Double, _ impulse: Double, arrival: Double = 1)
        -> FacadeLoadSurrogate.Prediction
    {
        FacadeLoadSurrogate.Prediction(peakPa: peak, impulsePaS: impulse, riseShare: 0.2, arrivalS: arrival)
    }

    /// A near run's strips from 300 m to the hand-over at 1 km every 2 m: the surrogate predicts a
    /// peak falling as 1/d and an impulse as d^-0.8, and the near run is 1.3 times the peak and
    /// 0.85 times the impulse at the hand-over, trending as distance^-0.3 and ^+0.1 against it,
    /// with a fixed ±5% scatter that alternates strip by strip.
    static func nearRun(handover: Double = 1_000) -> [HybridFarField.Sample] {
        stride(from: 300.0, to: handover, by: 2).enumerated().map { n, d in
            let predicted = prediction(4e5 / d, 2e4 * pow(d, -0.8))
            let wobble = n % 2 == 0 ? 1.05 : 1 / 1.05
            let x = d / handover
            return HybridFarField.Sample(
                distanceM: d, nearPeakPa: predicted.peakPa * 1.3 * pow(x, -0.3) * wobble,
                nearImpulsePaS: predicted.impulsePaS * 0.85 * pow(x, 0.1) / wobble, predicted: predicted)
        }
    }

    /// The point of the far field: carried by the surrogate beyond the hand-over, a strip's load
    /// must meet the near run's at the hand-over and not step there. Fitted to a near run that
    /// scatters, the median of the seed (the strips from 950 m) must give the near run's load
    /// at the hand-over within the scatter, and the far field must be continuous across it.
    @Test("Beyond the hand-over the far field meets the near run there, without a step")
    func continuousAtHandover() {
        let handover = 1_000.0
        let far = HybridFarField.fit(
            handoverM: handover, seedFromM: 950, trendFromM: 500, samples: Self.nearRun(handover: handover),
            arrivals: [])
        let atHandover = Self.prediction(4e5 / handover, 2e4 * pow(handover, -0.8))
        let met = far.apply(atHandover, distanceM: handover)
        // The near run at the hand-over without its scatter: 1.3 and 0.85 times the surrogate.
        // Measured on the Studio on 19 October 2026: the peak 3.3% under and the impulse 4.5% over
        // (the seed's median of the ±5% scatter, reaching back along the trend); 1% allowed beyond.
        #expect(abs(met.peakPa / (1.3 * atHandover.peakPa) - 1) < 0.045, "peak ×\(far.peak)")
        #expect(abs(met.impulsePaS / (0.85 * atHandover.impulsePaS) - 1) < 0.055, "impulse ×\(far.impulse)")
        // Just either side of it, the same strip's far-field load hardly moves.
        let inside = far.apply(atHandover, distanceM: handover * (1 - 1e-6))
        let outside = far.apply(atHandover, distanceM: handover * (1 + 1e-6))
        // Measured 6e-7 and 2e-7 across the 2e-6 of distance: the trend's slope, no step.
        #expect(abs(outside.peakPa / inside.peakPa - 1) < 2e-6)
        #expect(abs(outside.impulsePaS / inside.impulsePaS - 1) < 2e-6)
        // The trends are the near run's against the surrogate, through the scatter.
        // Measured -0.3017 and 0.1017: the alternating scatter pulls each slope by 0.0017.
        #expect(abs(far.peakSlope + 0.3) < 0.005, "\(far.peakSlope)")
        #expect(abs(far.impulseSlope - 0.1) < 0.005, "\(far.impulseSlope)")
        #expect(far.seedStrips == 25)
    }

    /// `fit` takes only strips inside the hand-over and only loads above zero (a strip the near
    /// run never loaded, or the surrogate predicts nothing for, would make a logarithm of zero).
    /// Strips beyond the hand-over with wild ratios, and strips with zero loads, must change
    /// nothing; nor may a gauge whose Kingery–Bulmash arrival is zero.
    @Test("Strips beyond the hand-over, unloaded strips and empty gauges leave the fit as it was")
    func leavesOutWhatItShould() {
        let handover = 1_000.0
        let samples = Self.nearRun(handover: handover)
        let arrivals = [(1.05, 1.0, 600.0), (2.1, 2.0, 900)]
        let clean = HybridFarField.fit(
            handoverM: handover, seedFromM: 950, trendFromM: 500, samples: samples, arrivals: arrivals)
        let beyond = stride(from: handover, to: 3_000, by: 50).map {
            HybridFarField.Sample(
                distanceM: $0, nearPeakPa: 1e9, nearImpulsePaS: 1e-9, predicted: Self.prediction(1, 1))
        }
        let unloaded = [960.0, 970, 980, 600, 700].flatMap { d in
            [
                HybridFarField.Sample(
                    distanceM: d, nearPeakPa: 0, nearImpulsePaS: 0, predicted: Self.prediction(5, 5)),
                HybridFarField.Sample(
                    distanceM: d, nearPeakPa: 5, nearImpulsePaS: 5, predicted: Self.prediction(0, 0)),
            ]
        }
        let noisy = HybridFarField.fit(
            handoverM: handover, seedFromM: 950, trendFromM: 500, samples: samples + beyond + unloaded,
            arrivals: arrivals + [(5.0, 0.0, 700)])
        #expect(noisy == clean, "\(noisy) against \(clean)")
    }

    /// The trend is fitted from the near run's strips and carried on beyond the hand-over without
    /// limit: a decade out the far field must be the seed times (d / hand-over)^slope, each of
    /// peak and impulse on its own slope, with arrivals scaled alike at every distance. Inside a
    /// metre the distance is held at 1 m. `HybridFarFieldTests.apply` carries one slope to 4 km
    /// once.
    @Test(
        "The trend is carried on a decade beyond the hand-over, each on its own slope",
        arguments: [1_000.0, 1_500])
    func trendExtrapolated(handover: Double) {
        let far = HybridFarField(
            handoverM: handover, peak: 1.2, impulse: 0.9, peakSlope: -0.47, impulseSlope: -0.30, arrival: 0.97
        )
        let base = Self.prediction(1_000, 40, arrival: 2)
        for ratio in [1.0, 2, 5, 10] {
            let p = far.apply(base, distanceM: handover * ratio)
            #expect(abs(p.peakPa / (1_000 * 1.2 * pow(ratio, -0.47)) - 1) < 1e-12, "×\(ratio)")
            #expect(abs(p.impulsePaS / (40 * 0.9 * pow(ratio, -0.30)) - 1) < 1e-12, "×\(ratio)")
            #expect(abs(p.arrivalS - 2 * 0.97) < 1e-12)
            #expect(p.riseShare == base.riseShare)
        }
        // Each step out lowers the peak more than the impulse, as the slopes say.
        let near = far.apply(base, distanceM: 2 * handover)
        let further = far.apply(base, distanceM: 4 * handover)
        #expect(further.peakPa / near.peakPa < further.impulsePaS / near.impulsePaS)
        #expect(far.apply(base, distanceM: 0) == far.apply(base, distanceM: 1))
    }

    /// A slope from two strips or fewer is no trend, and `fit` gives none; with three it gives one.
    @Test("A trend needs three strips")
    func trendNeedsThreeStrips() {
        let handover = 1_000.0
        func far(_ distances: [Double]) -> HybridFarField {
            HybridFarField.fit(
                handoverM: handover, seedFromM: 900, trendFromM: 500,
                samples: distances.map {
                    HybridFarField.Sample(
                        distanceM: $0, nearPeakPa: 100 * pow($0 / handover, -0.5), nearImpulsePaS: 10,
                        predicted: Self.prediction(100, 10))
                }, arrivals: [])
        }
        #expect(far([600, 800]).peakSlope == 0)
        #expect(abs(far([600, 700, 800]).peakSlope + 0.5) < 1e-9)
    }

    // MARK: Its standing

    /// The standing the mode reports with every district (`HybridBench` writes it into the
    /// result) must say what holds inside the hand-over, beyond it, for arrivals, and for walls
    /// and roofs, in that order; and its figures must be the ones on the page it cites,
    /// docs/hybrid-far-field.md: the façade peaks' range beyond the hand-over to 2.5 km, the glass
    /// agreeing within 0.03 to 1.5 km at every yield, and the shortfall at 0.2 kt from 1.5 to
    /// 2.5 km, each read off that page's table. Nothing else reads the standing.
    @Test("The standing reports its four parts, its figures those of the page it cites")
    func standingMatchesPage() throws {
        let standing = HybridFarField.standing
        try #require(standing.count == 4)
        #expect(standing[0].hasPrefix("Inside the hand-over"))
        #expect(standing[1].hasPrefix("Beyond it"))
        #expect(standing[2].hasPrefix("Arrivals beyond the hand-over"))
        #expect(standing[3].hasPrefix("Walls and roofs"))
        #expect(!HybridFarField.method.isEmpty)

        let page = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "docs/hybrid-far-field.md")
        let text = try String(contentsOf: page, encoding: .utf8)
        // The table's rows: "| 1–1.25 km | full / hybrid (unscaled) | … | peaks |".
        struct Row {
            var from: Double, to: Double
            var glass: [(full: Double, hybrid: Double)]
            var peaks: [Double]
        }
        func numbers(_ s: Substring) -> [Double] {
            s.split(whereSeparator: { " /()".contains($0) }).compactMap { Double($0) }
        }
        let rows: [Row] = text.split(separator: "\n").compactMap { line in
            let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count == 5, cells[0].hasSuffix("km") else { return nil }
            let span = cells[0].dropLast(3).split(separator: "–").compactMap { Double($0) }
            guard span.count == 2 else { return nil }
            let glass = cells[1...3].map { numbers(Substring($0)) }
            guard glass.allSatisfy({ $0.count >= 2 }) else { return nil }
            return Row(
                from: span[0], to: span[1], glass: glass.map { ($0[0], $0[1]) },
                peaks: numbers(Substring(cells[4])))
        }
        try #require(rows.count >= 6, "the page's table was not found")
        let beyond = rows.filter { $0.from >= 1 && $0.to <= 2.5 }
        let peaks = beyond.flatMap(\.peaks)
        let range = String(format: "%.2f–%.2f", try #require(peaks.min()), try #require(peaks.max()))
        #expect(standing[1].contains("façade peaks \(range)"), "the page's peaks run \(range)")
        // Within 0.03 to 1.5 km at every yield.
        let toOneHalf = rows.filter { $0.to <= 1.5 }.flatMap(\.glass).map { abs($0.full - $0.hybrid) }
        #expect((toOneHalf.max() ?? 1) <= 0.03 + 1e-9, "\(toOneHalf)")
        #expect(standing[1].contains("within 0.03 of its to 1.5 km at every yield"))
        // Under at 0.2 kt from 1.5 to 2.5 km.
        let shortfall = rows.filter { $0.from >= 1.5 && $0.to <= 2.5 }.map {
            $0.glass[0].full - $0.glass[0].hybrid
        }
        let under = String(format: "%.2f–%.2f", try #require(shortfall.min()), try #require(shortfall.max()))
        #expect(
            standing[1].contains("\(under) under at 1.5–2.5 km at 0.2 kt"),
            "the page's shortfall runs \(under)")
        // The arrivals' and the inside's figures, as the page gives them.
        #expect(standing[2].contains("2–4% earlier") && text.contains("2–4% before"))
        #expect(standing[0].contains("scatter 3–8%") && text.contains("3–8% (median 1.00)"))
    }
}
