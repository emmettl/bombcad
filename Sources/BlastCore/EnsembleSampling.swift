import Foundation

/// How an uncertain input is spread, as a factor or a value; sampled through its inverse
/// cumulative distribution, so that a Latin hypercube's strata map onto it.
public enum EnsembleDistribution: Codable, Sendable, Equatable {
    /// Normal, cut off at three standard deviations either side.
    case normal(mean: Double, deviation: Double)
    /// Log-normal: `median` times e to a normal of the log-deviation that gives `variation` as
    /// its coefficient of variation.
    case logNormal(median: Double, variation: Double)
    /// Uniform between the two.
    case uniform(low: Double, high: Double)

    /// The value at cumulative probability `p`, from 0 to 1.
    public func value(at p: Double) -> Double {
        let p = min(max(p, 1e-12), 1 - 1e-12)
        switch self {
        case .normal(let mean, let deviation):
            return mean + deviation * min(max(Self.inverseNormal(p), -3), 3)
        case .logNormal(let median, let variation):
            let sigma = (log(1 + variation * variation)).squareRoot()
            return median * exp(sigma * min(max(Self.inverseNormal(p), -3), 3))
        case .uniform(let low, let high):
            return low + (high - low) * p
        }
    }

    /// The middle value, which the case's own inputs take.
    public var median: Double { value(at: 0.5) }

    /// As text, for reports: "normal, 1 ± 0.1", "log-normal, 1, 18%", "uniform, 0.95–1.05".
    public var description: String {
        switch self {
        case .normal(let mean, let deviation): "normal, \(Self.format(mean)) ± \(Self.format(deviation))"
        case .logNormal(let median, let variation):
            "log-normal, \(Self.format(median)), \(Self.format(100 * variation))%"
        case .uniform(let low, let high): "uniform, \(Self.format(low))–\(Self.format(high))"
        }
    }

    private static func format(_ value: Double) -> String { String(format: "%g", value) }

    /// The standard normal's inverse cumulative distribution (Acklam's rational approximation,
    /// relative error below 1.2e-9).
    static func inverseNormal(_ p: Double) -> Double {
        let a = [
            -3.969683028665376e+01, 2.209460984245205e+02, -2.759285104469687e+02, 1.383577518672690e+02,
            -3.066479806614716e+01, 2.506628277459239e+00,
        ]
        let b = [
            -5.447609879822406e+01, 1.615858368580409e+02, -1.556989798598866e+02, 6.680131188771972e+01,
            -1.328068155288572e+01,
        ]
        let c = [
            -7.784894002430293e-03, -3.223964580411365e-01, -2.400758277161838e+00, -2.549732539343734e+00,
            4.374664141464968e+00, 2.938163982698783e+00,
        ]
        let d = [7.784695709041462e-03, 3.224671290700398e-01, 2.445134137142996e+00, 3.754408661907416e+00]
        let low = 0.02425
        if p < low {
            let q = (-2 * log(p)).squareRoot()
            return (((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5])
                / ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1)
        }
        if p > 1 - low {
            let q = (-2 * log(1 - p)).squareRoot()
            return -(((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5])
                / ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1)
        }
        let q = p - 0.5
        let r = q * q
        return (((((a[0] * r + a[1]) * r + a[2]) * r + a[3]) * r + a[4]) * r + a[5]) * q
            / (((((b[0] * r + b[1]) * r + b[2]) * r + b[3]) * r + b[4]) * r + 1)
    }
}

/// A Latin hypercube: `count` points in `dimensions` dimensions, each dimension cut into `count`
/// equal strata and each stratum used once, at a random point within it; the same `seed` always
/// gives the same points, on any Mac. Each point's coordinates are cumulative probabilities, 0 to
/// 1.
public func latinHypercube(count: Int, dimensions: Int, seed: UInt64) -> [[Double]] {
    guard count > 0 else { return [] }
    var random = SplitMix64(seed: seed)
    var points = [[Double]](repeating: [Double](repeating: 0.5, count: dimensions), count: count)
    for dimension in 0..<dimensions {
        // A Fisher–Yates shuffle of the strata, then a point within each.
        var strata = Array(0..<count)
        for index in stride(from: count - 1, to: 0, by: -1) {
            strata.swapAt(index, Int(random.next() % UInt64(index + 1)))
        }
        for point in 0..<count {
            points[point][dimension] = (Double(strata[point]) + random.unit()) / Double(count)
        }
    }
    return points
}

/// A small, fast generator whose sequence is fixed by its seed (Steele, Lea and Flood's SplitMix64).
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

/// What an ensemble's samples of one output came to.
public struct EnsembleStatistics: Codable, Sendable, Equatable {
    public var count: Int
    public var mean: Double
    /// The sample standard deviation.
    public var deviation: Double
    public var minimum: Double
    public var maximum: Double
    /// The 5th, 50th and 95th percentiles, interpolated between the sorted samples.
    public var p5: Double
    public var p50: Double
    public var p95: Double

    public init?(_ values: [Double]) {
        let values = values.filter(\.isFinite).sorted()
        guard let first = values.first, let last = values.last else { return nil }
        let n = values.count
        let average = values.reduce(0, +) / Double(n)
        let squares = values.reduce(0) { $0 + ($1 - average) * ($1 - average) }
        count = n
        mean = average
        deviation = n > 1 ? (squares / Double(n - 1)).squareRoot() : 0
        minimum = first
        maximum = last
        func percentile(_ fraction: Double) -> Double {
            let position = fraction * Double(n - 1)
            let below = Int(position.rounded(.down))
            let above = min(below + 1, n - 1)
            return values[below] + (values[above] - values[below]) * (position - Double(below))
        }
        p5 = percentile(0.05)
        p50 = percentile(0.5)
        p95 = percentile(0.95)
    }

    /// The coefficient of variation.
    public var variation: Double { mean == 0 ? 0 : deviation / abs(mean) }
}

/// Spearman's rank correlation of two series: how far one rises as the other does, from −1 to
/// 1, whatever the shape; ties take their mean rank. Nil for fewer than three pairs, or a series
/// that does not vary.
public func rankCorrelation(_ x: [Double], _ y: [Double]) -> Double? {
    guard x.count == y.count, x.count >= 3 else { return nil }
    func ranks(_ values: [Double]) -> [Double] {
        let order = values.indices.sorted { values[$0] < values[$1] }
        var ranks = [Double](repeating: 0, count: values.count)
        var start = 0
        while start < order.count {
            var end = start
            while end + 1 < order.count, values[order[end + 1]] == values[order[start]] { end += 1 }
            for position in start...end { ranks[order[position]] = Double(start + end) / 2 }
            start = end + 1
        }
        return ranks
    }
    let (a, b) = (ranks(x), ranks(y))
    let n = Double(a.count)
    let (ma, mb) = (a.reduce(0, +) / n, b.reduce(0, +) / n)
    var (sab, saa, sbb) = (0.0, 0.0, 0.0)
    for index in a.indices {
        sab += (a[index] - ma) * (b[index] - mb)
        saa += (a[index] - ma) * (a[index] - ma)
        sbb += (b[index] - mb) * (b[index] - mb)
    }
    guard saa > 0, sbb > 0 else { return nil }
    return sab / (saa * sbb).squareRoot()
}
