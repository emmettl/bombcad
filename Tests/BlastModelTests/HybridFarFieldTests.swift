import Foundation
import Testing

@testable import BlastModel

/// The far field carried from a near run (docs/hybrid-far-field.md).
@Suite("Hybrid far field")
struct HybridFarFieldTests {
    static func prediction(_ peak: Double, _ impulse: Double, arrival: Double = 1)
        -> FacadeLoadSurrogate.Prediction
    {
        FacadeLoadSurrogate.Prediction(peakPa: peak, impulsePaS: impulse, riseShare: 0.2, arrivalS: arrival)
    }

    @Test("Fitted to a near run that is the surrogate scaled and trending with distance, it finds both")
    func fit() {
        // The near run 1.2 times the surrogate's peak at the hand-over, falling as distance^-0.4; its
        // impulse 0.9 times, flat.
        let handover = 1000.0
        let samples = stride(from: 400.0, to: handover, by: 5).map { d in
            HybridFarField.Sample(
                distanceM: d, nearPeakPa: 1_000 * 1.2 * pow(d / handover, -0.4), nearImpulsePaS: 50 * 0.9,
                predicted: Self.prediction(1_000, 50))
        }
        let far = HybridFarField.fit(
            handoverM: handover, seedFromM: 990, trendFromM: 500, samples: samples,
            arrivals: [(1.05, 1.0, 600), (2.1, 2.0, 900), (9, 1, 1_500), (3, 1, 300)])
        #expect(abs(far.peak - 1.2) < 0.01, "\(far.peak)")
        #expect(abs(far.impulse - 0.9) < 1e-9)
        #expect(abs(far.peakSlope + 0.4) < 1e-6, "\(far.peakSlope)")
        #expect(abs(far.impulseSlope) < 1e-9)
        // The arrivals from 500 m to the hand-over only.
        #expect(abs(far.arrival - 1.05) < 1e-9)
        #expect(far.seedStrips == 2)
        // Where the seeds were taken, the far field is the seed: no step at the hand-over.
        let atSeeds = 1_000 * exp(far.seedLogDistance ?? 0)
        let p = far.apply(Self.prediction(1_000, 50), distanceM: atSeeds)
        #expect(abs(p.peakPa / 1_000 - far.peak) < 1e-9)
    }

    @Test("Without a trend the far field is the seed alone; beyond the hand-over it carries the trend on")
    func apply() {
        let flat = HybridFarField.fit(
            handoverM: 1000, seedFromM: 800, trendFromM: nil,
            samples: [800, 900, 950].map {
                HybridFarField.Sample(
                    distanceM: $0, nearPeakPa: 1_100, nearImpulsePaS: 60,
                    predicted: Self.prediction(1_000, 50))
            }, arrivals: [])
        #expect(flat.peakSlope == 0 && flat.impulseSlope == 0 && flat.arrival == 1)
        let p = flat.apply(Self.prediction(500, 20, arrival: 3), distanceM: 2_000)
        #expect(abs(p.peakPa - 550) < 1e-6 && abs(p.impulsePaS - 24) < 1e-6 && p.arrivalS == 3)
        let trending = HybridFarField(handoverM: 1000, peak: 1, impulse: 1, peakSlope: -0.5, arrival: 0.98)
        let q = trending.apply(Self.prediction(400, 10, arrival: 4), distanceM: 4_000)
        #expect(abs(q.peakPa - 200) < 1e-6, "\(q.peakPa)")
        #expect(abs(q.arrivalS - 3.92) < 1e-9)
        // It round-trips, as a district's result saves it.
        let data = try? JSONEncoder().encode(trending)
        #expect(data.flatMap { try? JSONDecoder().decode(HybridFarField.self, from: $0) } == trending)
    }

    @Test("Damped past its reach, the match fades back to the surrogate's own loads; undamped, it is held")
    func damped() {
        var far = HybridFarField(handoverM: 1000, peak: 1.2, impulse: 1.3, peakSlope: -0.4, trendReach: 1.5)
        let held = far.apply(Self.prediction(1_000, 50), distanceM: 3_000)
        let atReach = far.apply(Self.prediction(1_000, 50), distanceM: 1_500)
        #expect(held.peakPa == atReach.peakPa && held.impulsePaS == atReach.impulsePaS)
        far.trendDamping = 0.5
        // At the reach as before; one damping length past it, the log of the match down by e.
        #expect(far.apply(Self.prediction(1_000, 50), distanceM: 1_500).peakPa == atReach.peakPa)
        let beyond = far.apply(Self.prediction(1_000, 50), distanceM: 1_500 * exp(0.5))
        #expect(abs(log(beyond.peakPa / 1_000) - log(atReach.peakPa / 1_000) / M_E) < 1e-9)
        #expect(abs(log(beyond.impulsePaS / 50) - log(1.3) / M_E) < 1e-9)
        // Far out, the surrogate's own.
        let farOut = far.apply(Self.prediction(1_000, 50), distanceM: 1e6)
        #expect(abs(farOut.peakPa - 1_000) < 1 && abs(farOut.impulsePaS - 50) < 0.1)
    }
}
