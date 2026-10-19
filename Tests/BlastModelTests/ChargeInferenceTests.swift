import Foundation
import Testing

@testable import BlastModel

/// From observed arrivals and broken glass back to the charge (`ChargeInference`).
@Suite("Charge inference")
struct ChargeInferenceTests {
    /// Observers on a ring of scaled distances about a charge at (`east`, `north`).
    static func places(massKg: Double, east: Double, north: Double, count: Int = 24) -> [SIMD2<Double>] {
        (0..<count).map { n in
            let z = 5 + 30 * Double(n % 6) / 5
            let angle = 2 * Double.pi * Double(n) / Double(count)
            let range = z * cbrt(massKg)
            return SIMD2(east + range * cos(angle), north + range * sin(angle))
        }
    }

    static func settings() -> ChargeInference.Settings {
        var settings = ChargeInference.Settings()
        settings.steps = 800
        settings.walkers = 32
        settings.massRange = 10...1e7
        return settings
    }

    @Test("Kingery–Bulmash's arrival runs on smoothly past its fits' 40 m/kg^(1/3), at the speed of sound")
    func arrivalBeyondTheFits() {
        let mass = 1_000.0
        let edge = 40 * cbrt(mass)
        let below = ChargeInference.arrival(massKg: mass, range: edge - 1)
        let above = ChargeInference.arrival(massKg: mass, range: edge + 1)
        #expect(abs(above - below) < 2 / 340, "\(below) s to \(above) s across the edge")
        let far = ChargeInference.arrival(massKg: mass, range: edge + 1_000)
        #expect(abs((far - above) - 999 / 340.3) < 1e-6)
        // 30 °C air's sound is 2.6% faster.
        let warm = ChargeInference.arrival(
            massKg: mass, range: 500, soundRatio: ChargeInference.soundSpeedRatio(temperatureC: 30))
        #expect(abs(ChargeInference.arrival(massKg: mass, range: 500) / warm - 1.0257) < 1e-3)
    }

    @Test("Finds a known charge's mass and place from 24 arrivals 3% off, within its credible intervals")
    func recoversASyntheticCharge() {
        let mass = 50_000.0
        let arrivals = ChargeInference.syntheticArrivals(
            massKg: mass, east: 80, north: -40, places: Self.places(massKg: mass, east: 80, north: -40),
            spread: 0.03,
            frame: 1.0 / 30, seed: 3)
        let posterior = ChargeInference.infer(arrivals: arrivals, settings: Self.settings())
        let found = posterior.summary("log10MassKg")!
        #expect((found.p05...found.p95).contains(log10(mass)), "\(found)")
        #expect(abs(pow(10, found.median) / mass - 1) < 0.3)
        let east = posterior.summary("east")!.median
        let north = posterior.summary("north")!.median
        #expect(hypot(east - 80, north + 40) < 15, "place (\(east), \(north))")
        #expect(posterior.rHat < 1.1)
    }

    @Test("An observer seven times late is taken as an outlier and leaves the mass where it was")
    func outlier() {
        let mass = 50_000.0
        var arrivals = ChargeInference.syntheticArrivals(
            massKg: mass, east: 0, north: 0, places: Self.places(massKg: mass, east: 0, north: 0),
            spread: 0.03,
            frame: 1.0 / 30, seed: 4)
        let clean = ChargeInference.infer(arrivals: arrivals, settings: Self.settings())
        arrivals[0].earliest *= 7
        arrivals[0].latest *= 7
        let settings = Self.settings()
        let posterior = ChargeInference.infer(arrivals: arrivals, settings: settings)
        let chances = ChargeInference.outlierChances(posterior, arrivals: arrivals, settings: settings)
        #expect(chances[0] > 0.9 && chances.dropFirst().allSatisfy { $0 < 0.5 }, "\(chances)")
        let shift = posterior.summary("log10MassKg")!.median - clean.summary("log10MassKg")!.median
        #expect(abs(shift) < 0.05, "log10 mass moved \(shift)")
    }

    @Test("A façade's glass breaks more often nearer and under more TNT")
    func glassMonotone() {
        var settings = ChargeInference.Settings()
        settings.exposureSpread = 0.8
        let near = ChargeInference.facadeDamage(massKg: 1e5, range: 500, reflected: false, settings: settings)
        let far = ChargeInference.facadeDamage(
            massKg: 1e5, range: 3_000, reflected: false, settings: settings)
        let bigger = ChargeInference.facadeDamage(
            massKg: 1e6, range: 3_000, reflected: false, settings: settings)
        let facing = ChargeInference.facadeDamage(
            massKg: 1e5, range: 3_000, reflected: true, settings: settings)
        #expect(near > far && bigger > far && facing > far, "\(near) \(far) \(bigger) \(facing)")
        #expect((0...1).contains(near) && (0...1).contains(far))
    }

    @Test("The beta-binomial is a distribution over k of n")
    func betaBinomial() {
        let n = 40
        let total = (0...n).reduce(0.0) { sum, k in
            let lnChoose = lgamma(Double(n + 1)) - lgamma(Double(k + 1)) - lgamma(Double(n - k + 1))
            return sum + exp(lnChoose + ChargeInference.logBetaBinomial(k: k, n: n, p: 0.3, kappa: 12))
        }
        #expect(abs(total - 1) < 1e-9)
    }

    @Test("A clock offset that would put an arrival at or before the explosion is impossible, not a NaN")
    func offsetBeforeTheExplosion() {
        let mass = 50_000.0
        let arrivals = ChargeInference.syntheticArrivals(
            massKg: mass, east: 0, north: 0, places: Self.places(massKg: mass, east: 0, north: 0),
            spread: 0.03,
            frame: 1.0 / 30, seed: 5)
        var settings = Self.settings()
        settings.offsetRange = -2...2
        // An offset of -2 s brings every arrival nearer than about 600 m to before the explosion.
        let likelihood = ChargeInference.arrivalLogLikelihood(
            [log10(mass), 0, 0, log(0.03), -2], arrivals: arrivals, settings: settings)
        #expect(likelihood == -.infinity)
        let posterior = ChargeInference.infer(arrivals: arrivals, settings: settings)
        #expect(posterior.summaries.allSatisfy { [$0.p05, $0.median, $0.p95].allSatisfy(\.isFinite) })
        let found = posterior.summary("log10MassKg")!
        #expect((found.p05...found.p95).contains(log10(mass)), "\(found)")
        #expect(found.p95 - found.p05 > 0.01, "an interval falsely tiny: \(found)")
    }

    @Test("No steps asked for still gives samples")
    func noSteps() {
        let mass = 50_000.0
        let arrivals = ChargeInference.syntheticArrivals(
            massKg: mass, east: 0, north: 0, places: Self.places(massKg: mass, east: 0, north: 0),
            spread: 0.03,
            frame: 1.0 / 30, seed: 6)
        var settings = Self.settings()
        settings.steps = 0
        let posterior = ChargeInference.infer(arrivals: arrivals, settings: settings)
        #expect(!posterior.samples.isEmpty && posterior.summary("log10MassKg") != nil)
    }
}
