import Foundation

/// From what was seen after an explosion back to the charge: its TNT mass, its place and (when the
/// observations can tell) its height and the observers' common clock offset, each with its
/// uncertainty, as a posterior sampled by an affine-invariant ensemble (Goodman and Weare 2010).
///
/// The forward model is Kingery–Bulmash's arrival for a hemispherical surface burst of TNT, by
/// Sachs scaling for the air's temperature (its time scales with the speed of sound), times an
/// optional ratio per observer from a BombCAD run of the same scene (its arrival over
/// Kingery–Bulmash's, which carries the city's own geometry), interpolated in yield. Arrivals are
/// windows (a video frame, or the gap between a sound's onset and the frame before), and each
/// observer is an inlier, off the model by a fraction `spread` that the inference finds too, or
/// with a small chance an outlier, off by anything up to several times (log-normal, σ 1 in the
/// log of the time), as an observer inside the fireball or with a clock started late can be. Broken glass is an optional second likelihood: the
/// share of façades damaged in each band of distance from the charge, against the share the
/// envelope glass model breaks under Kingery–Bulmash's load, as a beta-binomial, so that façades
/// near each other, which break together, are not counted as independent.
public enum ChargeInference {
    /// A shock arrival seen by an observer `east`, `north` metres from the reference point, between
    /// `earliest` and `latest` seconds after the explosion (by the observer's clock).
    public struct Arrival: Sendable, Hashable {
        public var name: String
        public var east: Double
        public var north: Double
        public var earliest: Double
        public var latest: Double
        /// BombCAD's arrival over Kingery–Bulmash's at this observer, by TNT mass (kg); empty for
        /// none. Taken from a run with the charge at the reference point.
        public var ratios: [(massKg: Double, ratio: Double)]

        public init(
            name: String, east: Double, north: Double, earliest: Double, latest: Double,
            ratios: [(massKg: Double, ratio: Double)] = []
        ) {
            self.name = name
            self.east = east
            self.north = north
            self.earliest = min(earliest, latest)
            self.latest = max(earliest, latest)
            self.ratios = ratios.sorted { $0.massKg < $1.massKg }
        }

        public static func == (a: Arrival, b: Arrival) -> Bool {
            a.name == b.name && a.east == b.east && a.north == b.north && a.earliest == b.earliest
                && a.latest == b.latest && a.ratios.map(\.massKg) == b.ratios.map(\.massKg)
                && a.ratios.map(\.ratio) == b.ratios.map(\.ratio)
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(name)
            hasher.combine(east)
            hasher.combine(north)
        }

        /// The ratio at `massKg`, interpolated in log mass between the runs, held at the ends.
        func ratio(at massKg: Double) -> Double {
            guard let first = ratios.first, let last = ratios.last else { return 1 }
            if massKg <= first.massKg { return first.ratio }
            if massKg >= last.massKg { return last.ratio }
            for (a, b) in zip(ratios, ratios.dropFirst()) where massKg <= b.massKg {
                let t = log(massKg / a.massKg) / log(b.massKg / a.massKg)
                return a.ratio + t * (b.ratio - a.ratio)
            }
            return last.ratio
        }
    }

    /// A surveyed façade `east`, `north` metres from the reference point, whether its glass was
    /// damaged (GEER's W1 or worse), and the way it faces (its outward normal's azimuth, radians
    /// clockwise from north), if known.
    public struct Facade: Sendable, Hashable {
        public var east: Double
        public var north: Double
        public var damaged: Bool
        public var normalAzimuth: Double?

        public init(east: Double, north: Double, damaged: Bool, normalAzimuth: Double? = nil) {
            self.east = east
            self.north = north
            self.damaged = damaged
            self.normalAzimuth = normalAzimuth
        }

        /// Whether it faces a charge at (`east`, `north`), within 60°.
        func faces(east chargeEast: Double, north chargeNorth: Double) -> Bool {
            guard let azimuth = normalAzimuth else { return false }
            let toward = SIMD2(chargeEast - east, chargeNorth - north)
            let length = (toward.x * toward.x + toward.y * toward.y).squareRoot()
            guard length > 0 else { return true }
            return (toward.x * sin(azimuth) + toward.y * cos(azimuth)) / length > 0.5
        }
    }

    /// How a façade's glass is loaded in the glass likelihood.
    public enum GlassLoad: String, Sendable, CaseIterable {
        /// Kingery–Bulmash's side-on pulse: a façade the blast runs along.
        case incident
        /// Its normally reflected pulse: a façade facing the charge.
        case reflected
        /// Reflected on a façade facing the charge (within 60°), side-on on the rest; side-on where
        /// the way a façade faces is not known.
        case facing
    }

    public struct Settings: Sendable {
        /// The air's temperature, °C; Kingery–Bulmash's curves are for 15 °C.
        public var temperatureC = 15.0
        /// The TNT masses searched, kg (uniform in log mass).
        public var massRange: ClosedRange<Double> = 1e3...1e7
        /// The charge is searched within this many metres of the reference point (a disc).
        public var placeRadius = 500.0
        /// The burst's height above the ground, m, if it is to be inferred; nil for a surface burst.
        /// The height enters as slant range only: a burst above the ground is taken to send the
        /// same wave as a surface burst at the slant range.
        public var heightRange: ClosedRange<Double>?
        /// A clock offset common to every observer, s, if it is to be inferred; nil for none.
        public var offsetRange: ClosedRange<Double>?
        /// Each observer's timing uncertainty beyond its window, s (a standard deviation).
        public var timingSigma = 0.005
        /// The inliers' fractional spread about the model is inferred, uniform in its log, here.
        public var spreadRange: ClosedRange<Double> = 0.005...0.3
        /// The chance that an observer is an outlier, and how far off an outlier is: the standard
        /// deviation of the log of its time about the model's.
        public var outlierShare = 0.05
        public var outlierSpread = 1.0
        /// The glass likelihood's loading, the panes of a façade and its area, m².
        public var glassLoad = GlassLoad.facing
        public var glazing = GlazingMix.apartments
        public var facadeAreaM2 = 150.0
        /// The bands of distance (m) the façades are counted in, and how strongly a band's share is
        /// held to the model's: the beta-binomial's concentration (larger is more confident).
        public var glassBandM = 250.0
        public var glassConcentration = 30.0
        /// A façade in a city takes the free field's load times a factor of its exposure: shielded
        /// by the buildings in front, channelled along a street, facing the charge or not. The
        /// factor is log-normal, of this median and spread (the standard deviation of its log),
        /// both pressure and impulse scaled by it; a spread of 0 loads every façade alike.
        public var exposureMedian = 1.0
        public var exposureSpread = 0.0
        /// The sampler: walkers, steps each (the first half discarded) and the seed.
        /// The scene's own damage (`SurrogateDamage`): weighed side by side (a Bernoulli each, its
        /// chance kept `damageFloor` from 0 and 1) or, if not, by bands as the glass is.
        public var damagePerSide = true
        public var damageFloor = 0.02
        /// A bias on every side's load at once (the surrogate's error shared across a district),
        /// sampled as a parameter of its own, `damageBias`, its log normal about nothing with this
        /// standard deviation; nil, the default, for none. On the made-up district it widened the
        /// yield's interval but moved its median up 1.1–2.9 times: given the bias, a larger charge
        /// matches the run's fall of broken glass with distance better than the surrogate's own
        /// does (docs/charge-inference.md).
        public var damageBiasLogSD: Double?
        public var walkers = 48
        public var steps = 3000
        public var seed: UInt64 = 1

        public init() {}

        /// A first step for each parameter in a local search: a tenth of the place's reach, a
        /// tenth of a decade of mass, a third of the spread's log.
        func searchScales(_ dimensions: Int) -> [Double] {
            var scales = [0.1, 0.1 * placeRadius, 0.1 * placeRadius, 0.3]
            if let heights = heightRange {
                scales.append(0.1 * max(heights.upperBound - heights.lowerBound, 1))
            }
            if let offsets = offsetRange {
                scales.append(0.1 * max(offsets.upperBound - offsets.lowerBound, 1e-3))
            }
            if damageBiasLogSD != nil { scales.append(0.1) }
            return Array(scales.prefix(dimensions))
        }
    }

    /// One sampled parameter.
    public struct Summary: Sendable, Codable, Hashable {
        public var name: String
        public var median: Double
        public var p05: Double
        public var p16: Double
        public var p84: Double
        public var p95: Double

        /// The memberwise initialiser, written out so that BlastCore can use it.
        package init(
            name: String,
            median: Double,
            p05: Double,
            p16: Double,
            p84: Double,
            p95: Double
        ) {
            self.name = name
            self.median = median
            self.p05 = p05
            self.p16 = p16
            self.p84 = p84
            self.p95 = p95
        }
    }

    public struct Posterior: Sendable {
        /// The parameters' names and the samples kept (after burn-in), one row each.
        public var names: [String]
        public var samples: [[Double]]
        public var logLikelihoods: [Double]
        public var acceptance: Double
        /// The largest of the parameters' split-ensemble R-hat (near 1 when the walkers agree).
        public var rHat: Double
        public var summaries: [Summary]

        /// The summary of parameter `name`.
        public func summary(_ name: String) -> Summary? { summaries.first { $0.name == name } }

        /// The share of samples within `radius` metres of (`east`, `north`).
        public func placeShare(within radius: Double, ofEast east: Double, north: Double) -> Double {
            guard let e = names.firstIndex(of: "east"), let n = names.firstIndex(of: "north"),
                !samples.isEmpty
            else { return 0 }
            let inside = samples.filter { hypot($0[e] - east, $0[n] - north) <= radius }.count
            return Double(inside) / Double(samples.count)
        }

        /// The radius about the posterior's median place holding `share` of the samples, m.
        public func placeRadius(holding share: Double) -> Double {
            guard let e = names.firstIndex(of: "east"), let n = names.firstIndex(of: "north"),
                let me = summary("east")?.median, let mn = summary("north")?.median, !samples.isEmpty
            else { return 0 }
            let distances = samples.map { hypot($0[e] - me, $0[n] - mn) }.sorted()
            return distances[min(distances.count - 1, Int(share * Double(distances.count)))]
        }
    }

    // MARK: - Forward model

    /// The speed of sound at `temperatureC` over that at 15 °C.
    public static func soundSpeedRatio(temperatureC: Double) -> Double {
        sqrt((temperatureC + 273.15) / 288.15)
    }

    /// Kingery–Bulmash's scaled arrival, s/kg^(1/3), tabulated in log scaled distance; beyond the
    /// fits' 40 m/kg^(1/3) the shock is taken to travel at the speed of sound.
    private static let arrivalTable: (logLow: Double, step: Double, values: [Double]) = {
        let low = log(0.06)
        let high = log(40.0)
        let count = 4000
        let step = (high - low) / Double(count - 1)
        // Each point held inside the fit's range: exp(log 40) can round to just above 40.
        let values = (0..<count).map { n in
            KingeryBulmash.scaledArrival(at: min(max(exp(low + Double(n) * step), 0.06), 40)) ?? 0
        }
        return (low, step, values)
    }()

    /// Kingery–Bulmash's arrival at scaled distance `z`, s/kg^(1/3).
    static func scaledArrival(_ z: Double) -> Double {
        let table = arrivalTable
        if z >= 40 { return table.values[table.values.count - 1] + (z - 40) / 340.3 }
        let x = (log(max(z, 0.06)) - table.logLow) / table.step
        let i = min(max(Int(x), 0), table.values.count - 2)
        let t = x - Double(i)
        return table.values[i] + t * (table.values[i + 1] - table.values[i])
    }

    /// The arrival at `range` metres from `massKg` of TNT at the surface, s, in air whose sound is
    /// `soundRatio` times as fast as at 15 °C.
    public static func arrival(massKg: Double, range: Double, soundRatio: Double = 1) -> Double {
        let scale = cbrt(massKg)
        return scaledArrival(range / scale) * scale / soundRatio
    }

    /// The chance that a façade of `settings.facadeAreaM2` holding `settings.glazing` has some pane
    /// broken, `range` metres from `massKg` of TNT, tabulated in log range and log mass.
    struct GlassTable: Sendable {
        let logRange: (low: Double, step: Double, count: Int)
        let logMass: (low: Double, step: Double, count: Int)
        let incident: [Double]
        let reflected: [Double]

        init(settings: Settings) {
            let ranges = (low: log(100.0), high: log(8000.0), count: 48)
            let masses = (
                low: log(settings.massRange.lowerBound), high: log(settings.massRange.upperBound), count: 30
            )
            let rangeStep = (ranges.high - ranges.low) / Double(ranges.count - 1)
            let massStep = (masses.high - masses.low) / Double(masses.count - 1)
            logRange = (ranges.low, rangeStep, ranges.count)
            logMass = (masses.low, massStep, masses.count)
            func table(reflected: Bool) -> [Double] {
                var values = [Double](repeating: 0, count: ranges.count * masses.count)
                // Each mass's row on its own core.
                values.withUnsafeMutableBufferPointer { out in
                    concurrently(iterations: masses.count) { m in
                        for r in 0..<ranges.count {
                            let mass = exp(masses.low + Double(m) * massStep)
                            let range = exp(ranges.low + Double(r) * rangeStep)
                            out[m * ranges.count + r] = ChargeInference.facadeDamage(
                                massKg: mass, range: range, reflected: reflected, settings: settings)
                        }
                    }
                }
                return values
            }
            incident = settings.glassLoad == .reflected ? [] : table(reflected: false)
            reflected = settings.glassLoad == .incident ? [] : table(reflected: true)
        }

        func value(massKg: Double, range: Double, reflected useReflected: Bool) -> Double {
            let values = useReflected ? reflected : incident
            let x = (log(max(range, 1)) - logRange.low) / logRange.step
            let y = (log(massKg) - logMass.low) / logMass.step
            let i = min(max(Int(floor(x)), 0), logRange.count - 2)
            let j = min(max(Int(floor(y)), 0), logMass.count - 2)
            let s = min(max(x - Double(i), 0), 1)
            let t = min(max(y - Double(j), 0), 1)
            let a = values[j * logRange.count + i]
            let b = values[j * logRange.count + i + 1]
            let c = values[(j + 1) * logRange.count + i]
            let d = values[(j + 1) * logRange.count + i + 1]
            return (1 - t) * ((1 - s) * a + s * b) + t * ((1 - s) * c + s * d)
        }
    }

    /// Kingery–Bulmash's peak (Pa) and impulse (Pa s) at `range` from `massKg`, side-on or normally
    /// reflected; beyond 40 m/kg^(1/3) falling as an acoustic wave does, as 1/range.
    static func load(massKg: Double, range: Double, reflected: Bool) -> (
        peak: Double, impulse: Double
    ) {
        let scale = cbrt(massKg)
        let z = range / scale
        let edge = min(max(z, 0.2), 40)
        guard let point = KingeryBulmash.point(at: edge) else { return (0, 0) }
        let fall = z > 40 ? 40 / z : 1
        let peak = (reflected ? point.reflectedPressure : point.incidentPressure) * fall
        let impulse =
            (reflected ? point.reflectedImpulse(mass: massKg) : point.incidentImpulse(mass: massKg)) * fall
        return (peak, impulse)
    }

    /// The chance that a façade has some pane broken under Kingery–Bulmash's pulse (triangular, of
    /// its peak and impulse), by the envelope glass model (`GlazingMix.breakage`).
    static func facadeDamage(massKg: Double, range: Double, reflected: Bool, settings: Settings) -> Double {
        let (peak, impulse) = load(massKg: massKg, range: range, reflected: reflected)
        guard settings.exposureSpread > 0 else {
            return facadeDamage(
                peak: peak * settings.exposureMedian, impulse: impulse * settings.exposureMedian,
                settings: settings)
        }
        // Gauss–Hermite quadrature over the log of the exposure factor.
        let nodes = [
            -3.190993201781528, -2.266580584531843, -1.468553289216668, -0.7235510187528376, 0,
            0.7235510187528376, 1.468553289216668, 2.266580584531843, 3.190993201781528,
        ]
        let weights = [
            3.960697726326438e-05, 0.004943624275536947, 0.08847452739437657, 0.4326515590025558,
            0.7202352156060510, 0.4326515590025558, 0.08847452739437657, 0.004943624275536947,
            3.960697726326438e-05,
        ]
        var sum = 0.0
        for (x, w) in zip(nodes, weights) {
            let factor = settings.exposureMedian * exp(settings.exposureSpread * 1.4142135623730951 * x)
            sum += w * facadeDamage(peak: peak * factor, impulse: impulse * factor, settings: settings)
        }
        return sum / 1.7724538509055159
    }

    /// The chance that a façade has some pane broken under a triangular pulse of `peak` (Pa) and
    /// `impulse` (Pa s).
    static func facadeDamage(peak: Double, impulse: Double, settings: Settings) -> Double {
        guard peak > 50, impulse > 0 else { return 0 }
        let duration = 2 * impulse / peak
        let step = min(max(duration / 40, 1e-4), 1e-3)
        let pulse = LaminatedGlassMeasurements.triangle(
            peak: peak, impulse: impulse, step: step, until: duration + 0.08)
        let breakage = settings.glazing.breakage(netPa: pulse, binS: step, areaM2: settings.facadeAreaM2)
        return 1 - exp(breakage.logNoneBroken)
    }

    // MARK: - Likelihood

    /// The parameters, in order: log10 of the TNT mass (kg), east and north (m), log of the
    /// inliers' spread, then the height (m) and the clock offset (s) when inferred.
    static func names(_ settings: Settings) -> [String] {
        ["log10MassKg", "east", "north", "logSpread"] + (settings.heightRange != nil ? ["height"] : [])
            + (settings.offsetRange != nil ? ["offset"] : [])
            + (settings.damageBiasLogSD != nil ? ["damageBias"] : [])
    }

    /// The model's chance of the window [a, b] for an arrival predicted at `t` with standard
    /// deviation `sigma`: the normal's probability over the window per unit of time, or its density
    /// for a window of no width.
    static func windowChance(a: Double, b: Double, t: Double, sigma: Double) -> Double {
        if b - a < 1e-9 {
            let u = (a - t) / sigma
            return exp(-0.5 * u * u) / (sigma * 2.5066282746310002)
        }
        let low = 0.5 * erfc(-(a - t) / (sigma * 1.4142135623730951))
        let high = 0.5 * erfc(-(b - t) / (sigma * 1.4142135623730951))
        return max(high - low, 0) / (b - a)
    }

    /// The same for an arrival whose log is normal about log `t`, standard deviation `sigma`.
    static func logWindowChance(a: Double, b: Double, t: Double, sigma: Double) -> Double {
        if b - a < 1e-9 {
            let u = (log(max(a, 1e-9)) - log(t)) / sigma
            return exp(-0.5 * u * u) / (max(a, 1e-9) * sigma * 2.5066282746310002)
        }
        let low = 0.5 * erfc(-(log(max(a, 1e-9)) - log(t)) / (sigma * 1.4142135623730951))
        let high = 0.5 * erfc(-(log(max(b, 1e-9)) - log(t)) / (sigma * 1.4142135623730951))
        return max(high - low, 0) / (b - a)
    }

    /// The log prior (0 inside its bounds, minus infinity outside).
    static func logPrior(_ theta: [Double], settings: Settings) -> Double {
        let mass = pow(10, theta[0])
        guard settings.massRange.contains(mass), hypot(theta[1], theta[2]) <= settings.placeRadius,
            settings.spreadRange.contains(exp(theta[3]))
        else { return -.infinity }
        var k = 4
        if let heights = settings.heightRange {
            guard heights.contains(theta[k]) else { return -.infinity }
            k += 1
        }
        if let offsets = settings.offsetRange, !offsets.contains(theta[k]) { return -.infinity }
        if let sigma = settings.damageBiasLogSD, let bias = theta.last {
            return -0.5 * (bias / sigma) * (bias / sigma)
        }
        return 0
    }

    /// The log likelihood of the arrivals at `massKg`, (`east`, `north`) and inliers' `spread`
    /// (surface burst, no offset), for checks.
    public static func arrivalLogLikelihood(
        massKg: Double, east: Double, north: Double, spread: Double, arrivals: [Arrival], settings: Settings
    ) -> Double {
        var plain = settings
        plain.heightRange = nil
        plain.offsetRange = nil
        return arrivalLogLikelihood(
            [log10(massKg), east, north, log(spread)], arrivals: arrivals, settings: plain)
    }

    /// The log likelihood of the arrivals at parameters `theta`.
    static func arrivalLogLikelihood(_ theta: [Double], arrivals: [Arrival], settings: Settings) -> Double {
        let mass = pow(10, theta[0])
        let spread = exp(theta[3])
        var k = 4
        var height = 0.0
        if settings.heightRange != nil {
            height = theta[k]
            k += 1
        }
        let offset = settings.offsetRange != nil ? theta[k] : 0
        let sound = soundSpeedRatio(temperatureC: settings.temperatureC)
        var sum = 0.0
        for observer in arrivals {
            let range =
                (pow(observer.east - theta[1], 2) + pow(observer.north - theta[2], 2) + height * height)
                .squareRoot()
            let t = arrival(massKg: mass, range: range, soundRatio: sound) * observer.ratio(at: mass) + offset
            // A clock offset can bring an arrival to or before the explosion, which no observer saw:
            // the parameters are impossible (and the log of the time would be a NaN).
            guard t > 0, t.isFinite else { return -.infinity }
            let inlier = (pow(spread * t, 2) + pow(settings.timingSigma, 2)).squareRoot()
            let chance =
                (1 - settings.outlierShare)
                * windowChance(a: observer.earliest, b: observer.latest, t: t, sigma: inlier)
                + settings.outlierShare
                * logWindowChance(
                    a: observer.earliest, b: observer.latest, t: t, sigma: settings.outlierSpread)
            sum += log(max(chance, 1e-300))
        }
        return sum
    }

    /// The beta-binomial's log probability of `k` of `n` at mean share `p`, concentration `kappa`
    /// (without the binomial coefficient, which the parameters do not change).
    public static func logBetaBinomial(k: Int, n: Int, p: Double, kappa: Double) -> Double {
        let p = min(max(p, 1e-6), 1 - 1e-6)
        let a = kappa * p
        let b = kappa * (1 - p)
        return lgamma(Double(k) + a) + lgamma(Double(n - k) + b) - lgamma(Double(n) + kappa) - lgamma(a)
            - lgamma(b)
            + lgamma(kappa)
    }

    /// The log likelihood of the façades at parameters `theta`: by bands of distance from the
    /// charge, how many were damaged against the model's mean chance in the band.
    static func glassLogLikelihood(
        _ theta: [Double], facades: [Facade], table: GlassTable, settings: Settings
    ) -> Double {
        let mass = pow(10, theta[0])
        let height = settings.heightRange != nil ? theta[4] : 0
        let bands = 40
        var count = [Int](repeating: 0, count: bands)
        var damaged = [Int](repeating: 0, count: bands)
        var expected = [Double](repeating: 0, count: bands)
        for facade in facades {
            let range = (pow(facade.east - theta[1], 2) + pow(facade.north - theta[2], 2) + height * height)
                .squareRoot()
            let band = min(Int(range / settings.glassBandM), bands - 1)
            count[band] += 1
            if facade.damaged { damaged[band] += 1 }
            let reflected =
                settings.glassLoad == .reflected
                || (settings.glassLoad == .facing && facade.faces(east: theta[1], north: theta[2]))
            expected[band] += table.value(massKg: mass, range: range, reflected: reflected)
        }
        var sum = 0.0
        for band in 0..<bands where count[band] > 0 {
            sum += logBetaBinomial(
                k: damaged[band], n: count[band], p: expected[band] / Double(count[band]),
                kappa: settings.glassConcentration)
        }
        return sum
    }

    /// Each observer's chance of being an outlier, averaged over `posterior`'s samples (every
    /// `stride`th).
    public static func outlierChances(
        _ posterior: Posterior, arrivals: [Arrival], settings: Settings, stride: Int = 50
    ) -> [Double] {
        var sums = [Double](repeating: 0, count: arrivals.count)
        var count = 0
        let sound = soundSpeedRatio(temperatureC: settings.temperatureC)
        for theta in Swift.stride(from: 0, to: posterior.samples.count, by: max(stride, 1)).map({
            posterior.samples[$0]
        }) {
            let mass = pow(10, theta[0])
            let spread = exp(theta[3])
            var k = 4
            var height = 0.0
            if settings.heightRange != nil {
                height = theta[k]
                k += 1
            }
            let offset = settings.offsetRange != nil ? theta[k] : 0
            for (n, observer) in arrivals.enumerated() {
                let range =
                    (pow(observer.east - theta[1], 2) + pow(observer.north - theta[2], 2) + height * height)
                    .squareRoot()
                let t =
                    arrival(massKg: mass, range: range, soundRatio: sound) * observer.ratio(at: mass) + offset
                // (A sample's arrival is never at or before the explosion: such parameters are impossible.)
                guard t > 0, t.isFinite else { continue }
                let inlier =
                    (1 - settings.outlierShare)
                    * windowChance(
                        a: observer.earliest, b: observer.latest, t: t,
                        sigma: (pow(spread * t, 2) + pow(settings.timingSigma, 2)).squareRoot())
                let outlier =
                    settings.outlierShare
                    * logWindowChance(
                        a: observer.earliest, b: observer.latest, t: t, sigma: settings.outlierSpread)
                sums[n] += outlier / max(inlier + outlier, 1e-300)
            }
            count += 1
        }
        return sums.map { $0 / Double(max(count, 1)) }
    }

    /// By band of distance from a charge of `massKg` at the reference point: the façades surveyed,
    /// the share damaged and the model's mean chance.
    public static func glassBands(massKg: Double, facades: [Facade], settings: Settings) -> [(
        fromM: Double, count: Int, observed: Double, model: Double
    )] {
        let table = GlassTable(settings: settings)
        var bands: [Int: (count: Int, damaged: Int, expected: Double)] = [:]
        for facade in facades {
            let range = hypot(facade.east, facade.north)
            let band = Int(range / settings.glassBandM)
            let reflected =
                settings.glassLoad == .reflected
                || (settings.glassLoad == .facing && facade.faces(east: 0, north: 0))
            var entry = bands[band] ?? (0, 0, 0)
            entry.count += 1
            entry.damaged += facade.damaged ? 1 : 0
            entry.expected += table.value(massKg: massKg, range: range, reflected: reflected)
            bands[band] = entry
        }
        return bands.keys.sorted().map { band in
            let entry = bands[band]!
            return (
                Double(band) * settings.glassBandM, entry.count, Double(entry.damaged) / Double(entry.count),
                entry.expected / Double(entry.count)
            )
        }
    }

    // MARK: - Sampling

    /// The posterior of the charge given `arrivals` and, optionally, `facades`. `progress` is told
    /// the share done now and then, and stops the sampling, with no samples kept, if it returns
    /// false; it changes nothing of the result otherwise.
    public static func infer(
        arrivals: [Arrival], facades: [Facade] = [], damage: SurrogateDamage? = nil,
        settings given: Settings = Settings(), progress: (Double) -> Bool = { _ in true }
    ) -> Posterior {
        var settings = given
        if damage == nil { settings.damageBiasLogSD = nil }
        let names = names(settings)
        let dimensions = names.count
        let table = facades.isEmpty ? nil : GlassTable(settings: settings)
        func logPosterior(_ theta: [Double]) -> (posterior: Double, likelihood: Double) {
            let prior = logPrior(theta, settings: settings)
            guard prior > -.infinity else { return (-.infinity, -.infinity) }
            var likelihood = arrivalLogLikelihood(theta, arrivals: arrivals, settings: settings)
            if let table, likelihood > -.infinity {
                likelihood += glassLogLikelihood(theta, facades: facades, table: table, settings: settings)
            }
            if let damage, likelihood > -.infinity {
                likelihood += damage.logLikelihood(
                    massKg: pow(10, theta[0]), east: theta[1], north: theta[2], bandM: settings.glassBandM,
                    kappa: settings.glassConcentration, perSide: settings.damagePerSide,
                    floor: settings.damageFloor,
                    factor: settings.damageBiasLogSD == nil ? 1 : exp(theta.last ?? 0))
            }
            // Anything that is not a number counts as impossible, so that no search or walker
            // settles on it.
            guard !likelihood.isNaN else { return (-.infinity, -.infinity) }
            return (prior + likelihood, likelihood)
        }
        var random = SplitMix64(seed: settings.seed)
        func priorDraw() -> [Double] {
            let radius = settings.placeRadius * random.unit().squareRoot()
            let angle = 2 * Double.pi * random.unit()
            var theta = [
                log10(settings.massRange.lowerBound)
                    + random.unit() * log10(settings.massRange.upperBound / settings.massRange.lowerBound),
                radius * cos(angle), radius * sin(angle),
                log(settings.spreadRange.lowerBound)
                    + random.unit() * log(settings.spreadRange.upperBound / settings.spreadRange.lowerBound),
            ]
            if let heights = settings.heightRange {
                theta.append(heights.lowerBound + random.unit() * (heights.upperBound - heights.lowerBound))
            }
            if let offsets = settings.offsetRange {
                theta.append(offsets.lowerBound + random.unit() * (offsets.upperBound - offsets.lowerBound))
            }
            if let sigma = settings.damageBiasLogSD {
                // Box–Muller.
                let u = max(random.unit(), 1e-12)
                theta.append(sigma * (-2 * log(u)).squareRoot() * cos(2 * Double.pi * random.unit()))
            }
            return theta
        }
        // Start the walkers among the best of many draws from the prior, so that none starts in a
        // corner the posterior has no mass in.
        let walkers = max(settings.walkers, 2 * dimensions + 2) / 2 * 2
        let candidates = (0..<max(40 * walkers, 4000)).map { _ -> (theta: [Double], score: Double) in
            let theta = priorDraw()
            return (theta, logPosterior(theta).posterior)
        }.sorted { $0.score > $1.score }
        func stopped() -> Posterior {
            Posterior(names: names, samples: [], logLikelihoods: [], acceptance: 0, rHat: .nan, summaries: [])
        }
        guard progress(0.1) else { return stopped() }
        // The walkers start in a small ball about the best local optimum of the posterior, found by
        // Nelder–Mead from the best few dozen draws: a narrow mode (a big charge whose place the
        // arrivals pin to metres) is rarely among the draws themselves, and a broad one is.
        let optima = candidates.prefix(24).map { start in
            nelderMead(start.theta, scales: settings.searchScales(dimensions), iterations: 600) {
                -logPosterior($0).posterior
            }
        }.sorted { ($0.value.isNaN ? .infinity : $0.value) < ($1.value.isNaN ? .infinity : $1.value) }
        guard progress(0.25) else { return stopped() }
        let best = optima[0].point
        var positions: [[Double]] = []
        let scale = settings.searchScales(dimensions).map { 0.01 * $0 }
        while positions.count < walkers {
            let theta = (0..<dimensions).map { d in best[d] + scale[d] * (2 * random.unit() - 1) }
            if logPrior(theta, settings: settings) > -.infinity { positions.append(theta) }
        }
        var scores = positions.map(logPosterior)
        var kept: [[Double]] = []
        var keptLikelihoods: [Double] = []
        var chains = [[[Double]]](repeating: [], count: walkers)
        var accepted = 0
        var proposed = 0
        // At least two steps, so that one is kept after the burn-in.
        let steps = max(settings.steps, 2)
        let burn = steps / 2
        let stretch = 2.0
        for step in 0..<steps {
            if step % max(steps / 100, 1) == 0, !progress(0.25 + 0.75 * Double(step) / Double(steps)) {
                return stopped()
            }
            // Halfway through the burn-in, a walker left far below the rest (stranded in a poor
            // mode, which the stretch move cannot leave) starts again from a good one's place.
            if step == burn / 2 {
                let sorted = scores.map(\.posterior).sorted()
                let median = sorted[sorted.count / 2]
                let good = (0..<walkers).filter { scores[$0].posterior >= median }
                for i in 0..<walkers where scores[i].posterior < median - 10 {
                    let j = good[Int(random.unit() * Double(good.count)) % good.count]
                    positions[i] = positions[j]
                    scores[i] = scores[j]
                }
            }
            // The stretch move in two halves, each half moving against the other.
            for half in 0..<2 {
                let mine = stride(from: half, to: walkers, by: 2)
                let others = Array(stride(from: 1 - half, to: walkers, by: 2))
                for i in mine {
                    let j = others[Int(random.unit() * Double(others.count)) % others.count]
                    let u = random.unit()
                    let z = pow((stretch - 1) * u + 1, 2) / stretch
                    let proposal = (0..<dimensions).map {
                        positions[j][$0] + z * (positions[i][$0] - positions[j][$0])
                    }
                    let score = logPosterior(proposal)
                    let accept = Double(dimensions - 1) * log(z) + score.posterior - scores[i].posterior
                    proposed += 1
                    if score.posterior > -.infinity && log(max(random.unit(), 1e-300)) < accept {
                        positions[i] = proposal
                        scores[i] = score
                        accepted += 1
                    }
                }
            }
            if step >= burn {
                for i in 0..<walkers {
                    kept.append(positions[i])
                    keptLikelihoods.append(scores[i].likelihood)
                    chains[i].append(positions[i])
                }
            }
        }
        var summaries: [Summary] = []
        var rHat = 1.0
        for (d, name) in names.enumerated() {
            let values = kept.map { $0[d] }.sorted()
            func quantile(_ q: Double) -> Double {
                values[min(values.count - 1, Int(q * Double(values.count)))]
            }
            summaries.append(
                Summary(
                    name: name, median: quantile(0.5), p05: quantile(0.05), p16: quantile(0.16),
                    p84: quantile(0.84),
                    p95: quantile(0.95)))
            // Split R-hat over the two halves of the walkers.
            let groups = [Array(chains.prefix(walkers / 2)), Array(chains.suffix(walkers / 2))].map { group in
                group.flatMap { $0.map { $0[d] } }
            }
            let means = groups.map { $0.reduce(0, +) / Double(max($0.count, 1)) }
            let variances = zip(groups, means).map { group, mean in
                group.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(max(group.count - 1, 1))
            }
            let within = variances.reduce(0, +) / 2
            let grand = (means[0] + means[1]) / 2
            let n = Double(groups[0].count)
            let between =
                n * ((means[0] - grand) * (means[0] - grand) + (means[1] - grand) * (means[1] - grand))
            if within > 0 {
                rHat = max(rHat, (((n - 1) / n * within + between / n) / within).squareRoot())
            }
        }
        return Posterior(
            names: names, samples: kept, logLikelihoods: keptLikelihoods,
            acceptance: Double(accepted) / Double(max(proposed, 1)), rHat: rHat, summaries: summaries)
    }

    /// The minimum of `f` near `start` by Nelder and Mead's simplex, first steps `scales`.
    static func nelderMead(
        _ start: [Double], scales: [Double], iterations: Int, _ objective: ([Double]) -> Double
    ) -> (point: [Double], value: Double) {
        // A value that is not a number is taken as the worst there is.
        func f(_ point: [Double]) -> Double {
            let value = objective(point)
            return value.isNaN ? .infinity : value
        }
        let n = start.count
        var simplex =
            [start]
            + (0..<n).map { d -> [Double] in
                var p = start
                p[d] += scales[d]
                return p
            }
        var values = simplex.map(f)
        for _ in 0..<iterations {
            let order = (0...n).sorted { values[$0] < values[$1] }
            simplex = order.map { simplex[$0] }
            values = order.map { values[$0] }
            if abs(values[n] - values[0]) < 1e-9 * (abs(values[0]) + 1e-9) && values[0].isFinite { break }
            let centroid = (0..<n).map { d in (0..<n).reduce(0) { $0 + simplex[$1][d] } / Double(n) }
            func toward(_ t: Double) -> [Double] {
                (0..<n).map { centroid[$0] + t * (simplex[n][$0] - centroid[$0]) }
            }
            let reflected = toward(-1)
            let fr = f(reflected)
            if fr < values[0] {
                let expanded = toward(-2)
                let fe = f(expanded)
                (simplex[n], values[n]) = fe < fr ? (expanded, fe) : (reflected, fr)
            } else if fr < values[n - 1] {
                (simplex[n], values[n]) = (reflected, fr)
            } else {
                let contracted = toward(fr < values[n] ? -0.5 : 0.5)
                let fc = f(contracted)
                if fc < min(fr, values[n]) {
                    (simplex[n], values[n]) = (contracted, fc)
                } else {
                    for i in 1...n {
                        simplex[i] = (0..<n).map { simplex[0][$0] + 0.5 * (simplex[i][$0] - simplex[0][$0]) }
                        values[i] = f(simplex[i])
                    }
                }
            }
        }
        let best = (0...n).min { values[$0] < values[$1] }!
        return (simplex[best], values[best])
    }

    // MARK: - Synthetic observations

    /// Arrivals that `massKg` at (`east`, `north`) would give observers at `places` (east, north),
    /// by Kingery–Bulmash, each off by a fraction `spread` (normally distributed) and seen in a
    /// window of `frame` seconds that holds it.
    public static func syntheticArrivals(
        massKg: Double, east: Double, north: Double, places: [SIMD2<Double>], spread: Double, frame: Double,
        seed: UInt64
    ) -> [Arrival] {
        var random = SplitMix64(seed: seed)
        return places.enumerated().map { n, place in
            let range = hypot(place.x - east, place.y - north)
            let u1 = max(random.unit(), 1e-12)
            let u2 = random.unit()
            let normal = (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
            let t = arrival(massKg: massKg, range: range) * (1 + spread * normal)
            let latest = (t / frame).rounded(.up) * frame
            return Arrival(
                name: "\(n)", east: place.x, north: place.y, earliest: latest - frame, latest: latest)
        }
    }
}

extension ChargeInference {
    /// Its standing, worded from the standing table's figures (validation.md, "Estimates beside a
    /// run").
    public static let standing: [String] = {
        let beirut = ValidationTables.figure("inferredBeirut")
        let alone = ValidationTables.figure("inferredByCurvesAlone")
        let corrected = ValidationTables.figure("inferredWithRatios")
        return [
            "Yield and place from arrival times: an approximation. On Beirut, \(beirut.ratio) kt and Warehouse 12 "
                + "within 25–32 m from Rigby et al.'s observers, their own 0.50 kt.",
            "On charges BombCAD ran, Kingery–Bulmash alone found the place but \(alone.ratio) times the yield; with "
                + "BombCAD's ratios from a run at the estimate (--correction), \(corrected.ratio) of it on 2 m cells.",
            "Height and a clock offset, left free, are not resolved by arrivals alone.",
            "Broken glass: illustrative. It fits no yield and biases the result rather than tightening it.",
        ]
    }()

    /// The standing of broken glass weighed on the scene's own buildings (`SurrogateDamage`).
    public static let sceneGlassStanding =
        "Broken glass on the scene's own buildings: illustrative. On BombCAD's runs of a made-up district it held "
        + "the true yield in its 90% interval for four charges of four on 4 m cells and two on 2 m, but placed "
        + "them 3–70 m off. On Beirut it is circular, as the glazing mixes' openings curve was fitted there."
}
