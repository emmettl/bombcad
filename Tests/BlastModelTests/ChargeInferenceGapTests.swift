import Foundation
import Testing

@testable import BlastModel

/// Paths through `ChargeInference` that `ChargeInferenceTests` does not reach: the arrival
/// likelihood's slope against a gradient worked out by hand, the Nelder–Mead search that starts
/// the walkers, the arrival table against Kingery–Bulmash's own fits, charges recovered from
/// arrivals built straight from the fits and from arrivals carrying BombCAD's ratios, a clock
/// offset left free, credible intervals widening with the observers' scatter and with the timing
/// uncertainty assumed, and the air's temperature entering as a scaling of every time by the
/// speed of sound.
///
/// The code has no analytic gradient and no gradient-based optimiser: it searches by Nelder–Mead
/// and samples by Goodman and Weare's stretch move, neither of which uses a slope. Beyond the
/// fits' 40 m/kg^(1/3), though, the arrival is exactly linear in range and in the charge's cube
/// root, so there the log likelihood's gradient can be written down in closed form and set
/// against central differences of the code's own likelihood. That checks the window chances,
/// the outlier mixture, the ratio's interpolation in log mass, the slant range and the offset
/// together.
///
/// Every sampled test runs the sampler for 800 steps of 32 walkers with a fixed seed. The
/// sampler's result for a given seed depends on the last bit of every `log`, `erfc` and `pow`, so
/// the values quoted from the Python port (a line-for-line port of the arrival likelihood, the
/// search and the sampler, kept outside the repository) are for the same data and seed but not
/// the same chain. The tolerances were set on the Studio on 19 October 2026 from the Swift
/// chains' own values, with a margin; a change to the sampler's arithmetic may move them.
@Suite("Charge inference paths not otherwise reached")
struct ChargeInferenceGapTests {
    // MARK: Helpers

    /// The sampler as the sampled tests run it: the default priors, fewer steps and walkers.
    static func sampler(seed: UInt64) -> ChargeInference.Settings {
        var settings = ChargeInference.Settings()
        settings.steps = 800
        settings.walkers = 32
        settings.seed = seed
        return settings
    }

    /// Eight observers 600–1,440 m out on a spiral about the reference point, each seeing the
    /// shock of 1,000 kg at the reference point in a window of a 30 fps frame starting a few per
    /// cent off Kingery–Bulmash's time, with BombCAD's `ratios` if given. With a charge of about a
    /// tonne within 50 m of the reference, every observer is beyond 40 m/kg^(1/3).
    static func farObservers(
        ratios: [(massKg: Double, ratio: Double)] = []
    ) -> [ChargeInference.Arrival] {
        let offsets = [-0.04, 0.03, 0.0, 0.06, -0.02, 0.01, 0.05, -0.05]
        return (0..<8).map { n in
            let angle = 2 * Double.pi * Double(n) / 8 + 0.3
            let range = 600 + 120 * Double(n)
            let t = ChargeInference.arrival(massKg: 1_000, range: range) * (1 + offsets[n])
            return ChargeInference.Arrival(
                name: "\(n)", east: range * cos(angle), north: range * sin(angle), earliest: t,
                latest: t + 1.0 / 30, ratios: ratios)
        }
    }

    /// The gradient of `ChargeInference.arrivalLogLikelihood(theta, ...)` in closed form, valid
    /// only while every observer is beyond 40 m/kg^(1/3) (where the arrival is
    /// (A W^(1/3) + (R − 40 W^(1/3)) / 340.3) / c, A the table's last value), no window is of
    /// zero width and no chance is held at the 1e-300 floor.
    static func farFieldGradient(
        _ theta: [Double], arrivals: [ChargeInference.Arrival], settings: ChargeInference.Settings
    ) -> [Double] {
        func density(_ u: Double) -> Double { exp(-0.5 * u * u) / (2 * Double.pi).squareRoot() }
        func cumulative(_ u: Double) -> Double { 0.5 * erfc(-u / 1.4142135623730951) }
        let mass = pow(10, theta[0])
        let spread = exp(theta[3])
        var k = 4
        var height = 0.0
        if settings.heightRange != nil {
            height = theta[k]
            k += 1
        }
        let offset = settings.offsetRange != nil ? theta[k] : 0
        let sound = ChargeInference.soundSpeedRatio(temperatureC: settings.temperatureC)
        let edge = ChargeInference.scaledArrival(40)
        let root = cbrt(mass)
        let q = settings.outlierShare
        let wide = settings.outlierSpread
        var gradient = [Double](repeating: 0, count: theta.count)
        for observer in arrivals {
            let dx = observer.east - theta[1]
            let dy = observer.north - theta[2]
            let range = (dx * dx + dy * dy + height * height).squareRoot()
            let base = (edge * root + (range - 40 * root) / 340.3) / sound
            let ratio = observer.ratio(at: mass)
            // The ratio's slope in log10 mass, between the runs; flat outside them.
            var ratioSlope = 0.0
            if let first = observer.ratios.first, let last = observer.ratios.last,
                mass > first.massKg, mass < last.massKg
            {
                for (a, b) in zip(observer.ratios, observer.ratios.dropFirst()) where mass <= b.massKg {
                    ratioSlope = (b.ratio - a.ratio) * log(10) / log(b.massKg / a.massKg)
                    break
                }
            }
            let t = base * ratio + offset
            let dtdMass = (edge - 40 / 340.3) / sound * root * log(10) / 3 * ratio + base * ratioSlope
            let dtdRange = ratio / (340.3 * sound)
            let sigma = (pow(spread * t, 2) + pow(settings.timingSigma, 2)).squareRoot()
            let a = observer.earliest
            let b = observer.latest
            let width = b - a
            let ua = (a - t) / sigma
            let ub = (b - t) / sigma
            let inlier = (cumulative(ub) - cumulative(ua)) / width
            let inlierByT = (density(ua) - density(ub)) / (sigma * width)
            let inlierBySigma = (ua * density(ua) - ub * density(ub)) / (sigma * width)
            let va = (log(a) - log(t)) / wide
            let vb = (log(b) - log(t)) / wide
            let outlier = (cumulative(vb) - cumulative(va)) / width
            let outlierByT = (density(va) - density(vb)) / (wide * t * width)
            let chance = (1 - q) * inlier + q * outlier
            let byT = (1 - q) * (inlierByT + inlierBySigma * spread * spread * t / sigma) + q * outlierByT
            gradient[0] += byT * dtdMass / chance
            gradient[1] += byT * dtdRange * (-dx / range) / chance
            gradient[2] += byT * dtdRange * (-dy / range) / chance
            gradient[3] += (1 - q) * inlierBySigma * spread * spread * t * t / sigma / chance
            var d = 4
            if settings.heightRange != nil {
                gradient[d] += byT * dtdRange * (height / range) / chance
                d += 1
            }
            if settings.offsetRange != nil { gradient[d] += byT / chance }
        }
        return gradient
    }

    /// Arrivals built straight from `KingeryBulmash.scaledArrival(at:)`, not through
    /// `ChargeInference`'s table, for observers on `ChargeInferenceTests.places`: each time off by
    /// `spread` (normal, drawn as `syntheticArrivals` draws it) and rounded up to a `frame`.
    static func fitArrivals(
        massKg: Double, east: Double, north: Double, spread: Double, frame: Double, seed: UInt64
    ) throws -> [ChargeInference.Arrival] {
        var random = SplitMix64(seed: seed)
        let root = cbrt(massKg)
        return try ChargeInferenceTests.places(massKg: massKg, east: east, north: north).enumerated()
            .map { n, place in
                let range = hypot(place.x - east, place.y - north)
                let u1 = max(random.unit(), 1e-12)
                let u2 = random.unit()
                let normal = (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
                let scaled = try #require(KingeryBulmash.scaledArrival(at: range / root))
                let latest = (scaled * root * (1 + spread * normal) / frame).rounded(.up) * frame
                return ChargeInference.Arrival(
                    name: "\(n)", east: place.x, north: place.y, earliest: latest - frame, latest: latest)
            }
    }

    /// `syntheticArrivals` for `massKg` at (`east`, `north`), 3% off and in 120 fps frames, each
    /// observer then given BombCAD ratios of 0.85–0.95 at the charge (its shock up to a sixth
    /// sooner than Kingery–Bulmash's, as the docs' forward study found) rising by 0.04 from 1 t
    /// to 100 t, and its window multiplied by its ratio at the true mass.
    static func ratioArrivals(
        massKg: Double, east: Double, north: Double, seed: UInt64
    ) -> [ChargeInference.Arrival] {
        let plain = ChargeInference.syntheticArrivals(
            massKg: massKg, east: east, north: north,
            places: ChargeInferenceTests.places(massKg: massKg, east: east, north: north), spread: 0.03,
            frame: 1.0 / 120, seed: seed)
        return plain.enumerated().map { n, arrival in
            let ratio = 0.85 + 0.1 * Double(n % 5) / 4
            var corrected = ChargeInference.Arrival(
                name: arrival.name, east: arrival.east, north: arrival.north, earliest: arrival.earliest,
                latest: arrival.latest,
                ratios: [(massKg: 1e3, ratio: ratio - 0.02), (massKg: 1e5, ratio: ratio + 0.02)])
            let atTruth = corrected.ratio(at: massKg)
            corrected.earliest *= atTruth
            corrected.latest *= atTruth
            return corrected
        }
    }

    // MARK: The likelihood's gradient

    /// Central differences of `arrivalLogLikelihood` in each parameter against the gradient worked
    /// out in closed form (`farFieldGradient`), at a point where every observer is beyond the
    /// fits, on a 25 °C day, with ratios whose interpolation in log mass is live at the point
    /// (1,300 kg between runs at 500 and 4,000 kg), and, in the second case, with a height and a
    /// clock offset inferred too. No other test differentiates the likelihood, and none evaluates
    /// it with a height, an offset or ratios at all: `ChargeInferenceTests` reaches it only
    /// through `infer` on surface bursts without ratios.
    @Test(
        "The arrival likelihood's slope in every parameter is the gradient worked out by hand",
        arguments: [false, true])
    func gradientAgainstCentralDifferences(withHeightAndOffset: Bool) throws {
        var settings = ChargeInference.Settings()
        settings.temperatureC = 25
        if withHeightAndOffset {
            settings.heightRange = 0...100
            settings.offsetRange = -0.2...0.2
        }
        let arrivals = Self.farObservers(ratios: [(massKg: 500, ratio: 0.95), (massKg: 4_000, ratio: 1.02)])
        let theta =
            [log10(1_300.0), 20, -15, log(0.03)] + (withHeightAndOffset ? [30, 0.02] : [])
        // The nearest observer is 54 m/kg^(1/3) out (Python port), well beyond 40.
        let root = cbrt(pow(10, theta[0]))
        let height = withHeightAndOffset ? theta[4] : 0
        let nearest = arrivals.map {
            (pow($0.east - theta[1], 2) + pow($0.north - theta[2], 2) + height * height).squareRoot()
        }.min()!
        try #require(nearest / root > 45, "an observer is \(nearest / root) m/kg^(1/3) out")

        let analytic = Self.farFieldGradient(theta, arrivals: arrivals, settings: settings)
        let steps = [1e-5, 1e-3, 1e-3, 1e-5, 1e-3, 1e-6]
        for d in theta.indices {
            var up = theta
            var down = theta
            up[d] += steps[d]
            down[d] -= steps[d]
            let central =
                (ChargeInference.arrivalLogLikelihood(up, arrivals: arrivals, settings: settings)
                    - ChargeInference.arrivalLogLikelihood(down, arrivals: arrivals, settings: settings))
                / (2 * steps[d])
            // Measured on the Studio on 19 October 2026: 8e-9 relative at worst (east, whose
            // slope is 0.01 per metre), 9e-11 to 3e-9 on the rest.
            #expect(
                abs(central - analytic[d]) <= 5e-8 * abs(analytic[d]) + 1e-9,
                "parameter \(d): central \(central), by hand \(analytic[d])")
        }
        // The point is not a stationary one, so the comparison has slopes to compare.
        #expect(abs(analytic[0]) > 1 && abs(analytic[3]) > 1, "\(analytic)")
    }

    /// `nelderMead`, which finds the mode the walkers start about, is reached only inside `infer`,
    /// where nothing checks that it ends at a minimum. Run on the far-field likelihood from the
    /// same point as above (no ratios, 15 °C), it must end where the gradient worked out by hand
    /// has all but vanished. Each component is scaled by the search's first step in that
    /// parameter, so that metres and decades compare.
    @Test("Nelder–Mead ends where the arrival likelihood's gradient vanishes")
    func nelderMeadEndsAtAStationaryPoint() throws {
        let settings = ChargeInference.Settings()
        let arrivals = Self.farObservers()
        let start = [log10(1_300.0), 20, -15, log(0.03)]
        let scales = settings.searchScales(4)
        let (end, value) = ChargeInference.nelderMead(start, scales: scales, iterations: 600) {
            -ChargeInference.arrivalLogLikelihood($0, arrivals: arrivals, settings: settings)
        }
        // The closed form holds only beyond the fits: the Python port ends at 320 kg, 85 m/kg^(1/3)
        // from the nearest observer.
        let root = cbrt(pow(10, end[0]))
        let nearest = arrivals.map { hypot($0.east - end[1], $0.north - end[2]) }.min()!
        try #require(nearest / root > 40, "ended \(nearest / root) m/kg^(1/3) from an observer")
        let startValue = -ChargeInference.arrivalLogLikelihood(start, arrivals: arrivals, settings: settings)
        #expect(value < startValue, "\(value) from \(startValue)")

        func scaledSlope(_ theta: [Double]) -> Double {
            zip(Self.farFieldGradient(theta, arrivals: arrivals, settings: settings), scales)
                .map { abs($0 * $1) }.max()!
        }
        let before = scaledSlope(start)
        let after = scaledSlope(end)
        // Measured from 1.01 to 2.4e-4 (ending at 320 kg, 85 m/kg^(1/3) from the nearest).
        #expect(
            before > 0.3 && after < 1e-3 * before,
            "scaled slope \(before) at the start, \(after) at the end")
    }

    // MARK: The arrival table

    /// `scaledArrival` reads a table of 4,000 points linear in log scaled distance, not the fits
    /// themselves; `ChargeInferenceTests` checks only its run past 40 m/kg^(1/3). Here it must be
    /// the fits to a few parts in a million across their range, except within a table step of
    /// 1.5 m/kg^(1/3), where Swisdak's two fits meet with a jump of 0.16% (Python port) and the
    /// table interpolates across it.
    @Test(
        "The tabulated arrival is Kingery–Bulmash's fits, except across the fits' own jump at 1.5",
        arguments: [0.07, 0.1, 0.5, 1.0, 1.4, 1.499, 1.5, 1.501, 1.6, 3, 5, 10, 20, 35, 39.9])
    func tableMatchesTheFits(z: Double) throws {
        let fit = try #require(KingeryBulmash.scaledArrival(at: z))
        let error = abs(ChargeInference.scaledArrival(z) / fit - 1)
        // Measured: 1.1e-6 at worst away from 1.5, 4.0e-4 at 1.499 and 1.06e-3 at 1.5 itself.
        let tolerance = abs(z - 1.5) < 0.01 ? 2e-3 : 3e-6
        #expect(error < tolerance, "z \(z): off the fit by \(error)")
    }

    // MARK: Recovering a charge

    /// `ChargeInferenceTests.recoversASyntheticCharge` recovers 50 t from `syntheticArrivals`,
    /// which uses the inference's own table. Here the arrivals are built from Kingery–Bulmash's
    /// fits directly, 3% off and in 120 fps frames, for a 2 t charge near the bottom of the default
    /// prior (1 t to 10 kt) and a 500 t one 200 m from the reference, with the default priors
    /// rather than the widened mass range the other suite uses. The true log mass must lie in the
    /// 90% interval, the median mass near it and the place within a quarter of a metre per
    /// kg^(1/3). (In 30 fps frames the near observers' windows are a third of their times, the
    /// posterior is flat across them and the 2 t charge's median comes out 0.72–1.0 of the truth
    /// over seeds, Python port: hence the finer frame.)
    @Test(
        "A charge seen through arrivals built from Kingery–Bulmash's own fits is found again",
        arguments: [(2_000.0, -150.0, 60.0), (500_000.0, 30.0, 200.0)])
    func recoversFromTheFits(massKg: Double, east: Double, north: Double) throws {
        let arrivals = try Self.fitArrivals(
            massKg: massKg, east: east, north: north, spread: 0.03, frame: 1.0 / 120, seed: 13)
        let posterior = ChargeInference.infer(arrivals: arrivals, settings: Self.sampler(seed: 13))
        let mass = try #require(posterior.summary("log10MassKg"))
        let truth = log10(massKg)
        // Measured: 2 t found at 1.004 of the truth (90% width 0.125 in log10), 500 t at 1.019
        // (0.086).
        #expect((mass.p05...mass.p95).contains(truth), "\(mass) for \(truth)")
        // Measured 0.002 (2 t) and 0.008 (500 t) in log10 mass, the 90% widths 0.12 and 0.09.
        #expect(abs(mass.median - truth) < 0.03, "log10 mass \(mass.median) for \(truth)")
        let root = cbrt(massKg)
        let foundEast = try #require(posterior.summary("east")).median
        let foundNorth = try #require(posterior.summary("north")).median
        // Measured: the median place 0.11 (2 t) and 0.04 (500 t) m/kg^(1/3) off.
        #expect(
            hypot(foundEast - east, foundNorth - north) < 0.2 * root,
            "place (\(foundEast), \(foundNorth)) for (\(east), \(north))")
        // Measured: 96% and 100% of the samples within 0.3 m/kg^(1/3); R-hat 1.006 and 1.016.
        #expect(posterior.placeShare(within: 0.3 * root, ofEast: east, north: north) > 0.85)
        #expect(posterior.rHat < 1.05)
    }

    /// The ratios from a BombCAD run (`Arrival.ratios`, interpolated in log mass by
    /// `ratio(at:)`) are not reached by any test. Arrivals 0.85–0.95 of Kingery–Bulmash's (as
    /// BombCAD's shock in a city reaches observers sooner) must give back a 5 t charge when the
    /// ratios are given, and, by Kingery–Bulmash alone, a bigger charge with the truth below its
    /// 90% interval: the docs' "a bigger charge is the curves' way of saying so". Measured: 1.000 of
    /// the truth with the ratios and 2.59 without (the Python port had 1.004 and 2.56).
    @Test("BombCAD's ratios give back a charge whose arrivals they shaped; without them it comes out bigger")
    func ratiosCorrectTheYield() throws {
        let massKg = 5_000.0
        let truth = log10(massKg)
        let arrivals = Self.ratioArrivals(massKg: massKg, east: -60, north: 90, seed: 21)
        let corrected = ChargeInference.infer(arrivals: arrivals, settings: Self.sampler(seed: 21))
        let withRatios = try #require(corrected.summary("log10MassKg"))
        #expect((withRatios.p05...withRatios.p95).contains(truth), "\(withRatios) for \(truth)")
        // Measured 0.0001 in log10 mass (90% width 0.17).
        #expect(abs(withRatios.median - truth) < 0.03, "\(withRatios) for \(truth)")
        let root = cbrt(massKg)
        let east = try #require(corrected.summary("east")).median
        let north = try #require(corrected.summary("north")).median
        // Measured 0.13 m/kg^(1/3) off.
        #expect(hypot(east + 60, north - 90) < 0.2 * root, "place (\(east), \(north))")

        let plain = arrivals.map {
            ChargeInference.Arrival(
                name: $0.name, east: $0.east, north: $0.north, earliest: $0.earliest, latest: $0.latest)
        }
        let alone = try #require(
            ChargeInference.infer(arrivals: plain, settings: Self.sampler(seed: 21)).summary("log10MassKg"))
        // Measured: the p05 0.28 above the truth, the median 2.59 times the truth.
        #expect(alone.p05 > truth + 0.2, "\(alone) for \(truth)")
        #expect(pow(10, alone.median - truth) > 2, "\(alone) for \(truth)")
    }

    /// With `offsetRange` set the parameters gain an offset, which `infer`, `names` and the
    /// likelihood each handle at their own index; no test sets it. Every observer's clock started
    /// 40 ms late: left free over 0–0.1 s the offset must be found and the mass with it, while
    /// with no offset in the model the late times read as a smaller charge (measured: 0.43 of
    /// the truth, the truth above its 90% interval). The range was kept non-negative while a
    /// negative offset could give a NaN (`negativeOffsetIsImpossible`).
    @Test("A clock offset common to every observer is found when left free, and the mass with it")
    func clockOffsetRecovered() throws {
        let massKg = 20_000.0
        let truth = log10(massKg)
        let late = 0.04
        let arrivals = ChargeInference.syntheticArrivals(
            massKg: massKg, east: 40, north: -30,
            places: ChargeInferenceTests.places(massKg: massKg, east: 40, north: -30), spread: 0.01,
            frame: 1.0 / 1000, seed: 51
        ).map {
            ChargeInference.Arrival(
                name: $0.name, east: $0.east, north: $0.north, earliest: $0.earliest + late,
                latest: $0.latest + late)
        }
        var settings = Self.sampler(seed: 51)
        settings.offsetRange = 0...0.1
        let posterior = ChargeInference.infer(arrivals: arrivals, settings: settings)
        #expect(posterior.names == ["log10MassKg", "east", "north", "logSpread", "offset"])
        let offset = try #require(posterior.summary("offset"))
        // Measured: median 0.0391 s, 90% within 0.021–0.055 s.
        #expect((offset.p05...offset.p95).contains(late), "\(offset)")
        #expect(abs(offset.median - late) < 0.005, "offset \(offset.median) s")
        let mass = try #require(posterior.summary("log10MassKg"))
        #expect((mass.p05...mass.p95).contains(truth), "\(mass) for \(truth)")

        let unawarePosterior = ChargeInference.infer(arrivals: arrivals, settings: Self.sampler(seed: 51))
        let unaware = try #require(unawarePosterior.summary("log10MassKg"))
        // Measured: the p95 0.32 below the truth, the median 0.43 of it.
        #expect(unaware.p95 < truth - 0.25, "\(unaware) for \(truth)")
    }

    // MARK: Credible intervals and the timing noise

    /// The same 24 observers of 20 t, their times off by 1%, 3% and 9%: `syntheticArrivals` draws
    /// the same normal deviate for each observer at every spread (the seed fixes them), so the
    /// data differ only in the noise's size, and in 1 ms frames the frame does not hide it. The
    /// 90% interval of log mass and the radius holding 90% of the places must widen with the
    /// noise, roughly in proportion, and the inferred spread must follow the noise.
    /// `ChargeInferenceTests` only ever infers from 3% scatter and never reads the inferred spread
    /// or an interval's width.
    @Test("The credible intervals widen as the observers' times scatter more")
    func intervalsWidenWithScatter() throws {
        let massKg = 20_000.0
        let spreads = [0.01, 0.03, 0.09]
        var widths: [Double] = []
        var radii: [Double] = []
        for spread in spreads {
            let arrivals = ChargeInference.syntheticArrivals(
                massKg: massKg, east: 40, north: -30,
                places: ChargeInferenceTests.places(massKg: massKg, east: 40, north: -30), spread: spread,
                frame: 1.0 / 1000, seed: 31)
            let posterior = ChargeInference.infer(arrivals: arrivals, settings: Self.sampler(seed: 31))
            let mass = try #require(posterior.summary("log10MassKg"))
            widths.append(mass.p95 - mass.p05)
            radii.append(posterior.placeRadius(holding: 0.9))
            let logSpread = try #require(posterior.summary("logSpread"))
            let found = exp(logSpread.median)
            // Measured 0.59, 0.69 and 0.77 of the true spread: the 5 ms timing uncertainty and the
            // frames take some of the scatter.
            #expect(found > 0.45 * spread && found < 1.1 * spread, "spread \(found) for \(spread)")
        }
        // Measured: widths 0.041, 0.093, 0.256 in log10 mass; radii 1.9, 3.4, 9.2 m.
        #expect(widths[0] < widths[1] && widths[1] < widths[2], "\(widths)")
        #expect(radii[0] < radii[1] && radii[1] < radii[2], "\(radii)")
        // Nine times the noise gives 6.3 times the width.
        #expect(widths[2] / widths[0] > 4.5, "\(widths)")
    }

    /// The same data (1% scatter, 1 ms frames) with the timing uncertainty assumed beyond each
    /// window (`timingSigma`, 5 ms by default) raised to 20 and 80 ms, comparable to the nearest
    /// observers' 0.22 s: the intervals must widen though the data have not changed. Every other
    /// test leaves `timingSigma` at its default.
    @Test("The credible intervals widen as the assumed timing uncertainty grows, on the same data")
    func intervalsWidenWithTimingSigma() throws {
        let massKg = 20_000.0
        let arrivals = ChargeInference.syntheticArrivals(
            massKg: massKg, east: 40, north: -30,
            places: ChargeInferenceTests.places(massKg: massKg, east: 40, north: -30), spread: 0.01,
            frame: 1.0 / 1000, seed: 31)
        var widths: [Double] = []
        var radii: [Double] = []
        for sigma in [0.005, 0.02, 0.08] {
            var settings = Self.sampler(seed: 31)
            settings.timingSigma = sigma
            let posterior = ChargeInference.infer(arrivals: arrivals, settings: settings)
            let mass = try #require(posterior.summary("log10MassKg"))
            widths.append(mass.p95 - mass.p05)
            radii.append(posterior.placeRadius(holding: 0.9))
            #expect((mass.p05...mass.p95).contains(log10(massKg)), "\(mass) at \(sigma) s")
        }
        // Measured: widths 0.041, 0.104, 0.368 in log10 mass; radii 1.9, 4.9, 18.5 m.
        #expect(widths[0] < widths[1] && widths[1] < widths[2], "\(widths)")
        #expect(radii[0] < radii[1] && radii[1] < radii[2], "\(radii)")
        // The widest is 9.0 times the narrowest.
        #expect(widths[2] / widths[0] > 6.5, "\(widths)")
    }

    // MARK: Temperature

    /// The docs and the code say the temperature enters only by Sachs scaling of the time with
    /// the speed of sound, c = √(T / 288.15 K) of 15 °C's. If so, the whole arrival likelihood at
    /// temperature T equals the 15 °C likelihood of every window, the timing uncertainty and the
    /// clock offset multiplied by c, plus log c per observer (each window's chance is per unit
    /// of time). That holds for any parameters, near field or far, with ratios, a height and an
    /// offset; it fails if the temperature reached anything but the time (the inliers' spread, the
    /// outliers' log-normal or the ratio), or reached the time by any other power.
    /// `ChargeInferenceTests` checks only that `arrival` divides by the ratio, never that the
    /// likelihood takes `temperatureC`.
    @Test(
        "At any temperature the likelihood is 15 °C's on times scaled by the speed of sound",
        arguments: [-10.0, 30.0, 45.0])
    func temperatureScalesTime(temperatureC: Double) {
        let c = ChargeInference.soundSpeedRatio(temperatureC: temperatureC)
        let arrivals = Self.ratioArrivals(massKg: 5_000, east: -60, north: 90, seed: 21)
        var hot = ChargeInference.Settings()
        hot.temperatureC = temperatureC
        hot.heightRange = 0...50
        hot.offsetRange = -0.1...0.1
        var standard = hot
        standard.temperatureC = 15
        standard.timingSigma = hot.timingSigma * c
        let theta = [log10(7_000.0), -40, 70, log(0.04), 12, 0.03]
        var scaledTheta = theta
        scaledTheta[5] *= c
        let scaled = arrivals.map {
            ChargeInference.Arrival(
                name: $0.name, east: $0.east, north: $0.north, earliest: $0.earliest * c,
                latest: $0.latest * c, ratios: $0.ratios)
        }
        let atT = ChargeInference.arrivalLogLikelihood(theta, arrivals: arrivals, settings: hot)
        let at15 =
            ChargeInference.arrivalLogLikelihood(scaledTheta, arrivals: scaled, settings: standard)
            + Double(arrivals.count) * log(c)
        // Rounding: measured 4e-15 relative at worst.
        #expect(abs(atT - at15) < 1e-12 * (1 + abs(atT)), "\(atT) at \(temperatureC) °C, \(at15) from 15 °C")
        #expect(atT.isFinite)
    }

    /// The same, through the sampler: the arrivals 20 t would give on a 30 °C day (15 °C's divided
    /// by c, 1.0257) inferred at 30 °C must give back the charge, and the same posterior as the
    /// 15 °C arrivals at 15 °C; read at 15 °C, as the calculators Stennett et al. used did, they
    /// give a bigger charge. The docs find "the day's heat lowers it by a fifth" on Beirut (0.42
    /// of 0.54 kt); here the 30 °C reading is 0.77 of the 15 °C one (Python port), and a least
    /// squares fit of the curves in log time over these ranges gives 0.80.
    @Test(
        "A hotter day's arrivals read at their own temperature give the charge back; at 15 °C, a bigger one")
    func hotterDayLowersTheYield() throws {
        let massKg = 20_000.0
        let truth = log10(massKg)
        let c = ChargeInference.soundSpeedRatio(temperatureC: 30)
        let standard = ChargeInference.syntheticArrivals(
            massKg: massKg, east: 40, north: -30,
            places: ChargeInferenceTests.places(massKg: massKg, east: 40, north: -30), spread: 0.02,
            frame: 1.0 / 1000, seed: 42)
        let hot = standard.map {
            ChargeInference.Arrival(
                name: $0.name, east: $0.east, north: $0.north, earliest: $0.earliest / c,
                latest: $0.latest / c)
        }
        var warm = Self.sampler(seed: 42)
        warm.temperatureC = 30
        let atOwn = try #require(ChargeInference.infer(arrivals: hot, settings: warm).summary("log10MassKg"))
        let atStandard = try #require(
            ChargeInference.infer(arrivals: hot, settings: Self.sampler(seed: 42)).summary("log10MassKg"))
        let referencePosterior = ChargeInference.infer(arrivals: standard, settings: Self.sampler(seed: 42))
        let reference = try #require(referencePosterior.summary("log10MassKg"))

        #expect((atOwn.p05...atOwn.p95).contains(truth), "\(atOwn) for \(truth)")
        // Measured 0.002 in log10 mass apart; the 5 ms timing uncertainty, not scaled here, and
        // the chains' rounding are the only differences.
        #expect(abs(atOwn.median - reference.median) < 0.006, "\(atOwn.median) and \(reference.median)")
        let lowered = pow(10, atOwn.median - atStandard.median)
        // Measured 0.767 (the Python port had 0.75–0.77 over three seeds).
        #expect(lowered > 0.72 && lowered < 0.81, "the 30 °C reading is \(lowered) of the 15 °C one")
        // Measured: the 15 °C reading's p05 0.08 above the truth.
        #expect(atStandard.p05 > truth + 0.04, "\(atStandard) for \(truth)")
    }

    // MARK: An arrival before the explosion

    /// A negative clock offset larger than the model's arrival makes the predicted time negative,
    /// and the outliers' log-normal (`logWindowChance`) took the log of it: NaN, which
    /// `max(chance, 1e-300)` did not catch (Swift's `max` returns its first argument when the
    /// comparison with NaN fails), so with the CLI's own `--offset -0.2,0.2` a NaN optimum could win
    /// the search (review-2 #45). Since c44acf2f such parameters are impossible: the likelihood is
    /// −∞, never NaN. Here the charge is put on the observer (arrival 0.26 ms for 20 t) with the
    /// clock 50 ms early; with the clock 10 ms late the same place is possible again.
    @Test("A negative clock offset larger than the arrival makes the parameters impossible, not NaN")
    func negativeOffsetIsImpossible() {
        var settings = ChargeInference.Settings()
        settings.offsetRange = -0.1...0.1
        let arrivals = [
            ChargeInference.Arrival(name: "near", east: 100, north: 0, earliest: 0.02, latest: 0.03)
        ]
        let theta = [log10(20_000.0), 100, 0, log(0.03), -0.05]
        let value = ChargeInference.arrivalLogLikelihood(theta, arrivals: arrivals, settings: settings)
        #expect(!value.isNaN, "log likelihood \(value)")
        #expect(value == -.infinity, "log likelihood \(value)")
        var late = theta
        late[4] = 0.01
        let possible = ChargeInference.arrivalLogLikelihood(late, arrivals: arrivals, settings: settings)
        #expect(possible.isFinite, "log likelihood \(possible)")
    }
}
