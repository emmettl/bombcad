import Foundation
import Testing

@testable import BlastModel

@Suite("Sampling uncertain inputs for an ensemble", .timeLimit(.minutes(120)))
struct EnsembleSamplingTests {
    @Test("A Latin hypercube uses each stratum once in every dimension, the same for the same seed")
    func hypercube() {
        let points = latinHypercube(count: 20, dimensions: 4, seed: 7)
        #expect(points.count == 20 && points.allSatisfy { $0.count == 4 })
        for dimension in 0..<4 {
            let strata = Set(points.map { Int($0[dimension] * 20) })
            #expect(strata == Set(0..<20))
        }
        #expect(latinHypercube(count: 20, dimensions: 4, seed: 7) == points)
        #expect(latinHypercube(count: 20, dimensions: 4, seed: 8) != points)
    }

    @Test("Each distribution's inverse gives its median, spread and bounds")
    func distributions() {
        let normal = EnsembleDistribution.normal(mean: 10, deviation: 2)
        #expect(abs(normal.median - 10) < 1e-9)
        // The 84th percentile, a standard deviation up; cut off at three.
        #expect(abs(normal.value(at: 0.841_344_75) - 12) < 1e-6)
        #expect(abs(normal.value(at: 1e-9) - 4) < 1e-9)
        let logNormal = EnsembleDistribution.logNormal(median: 1, variation: 0.3)
        #expect(
            abs(logNormal.median - 1) < 1e-9 && logNormal.value(at: 0.2) < 1 && logNormal.value(at: 0.8) > 1)
        #expect(abs(EnsembleDistribution.uniform(low: 2, high: 4).value(at: 0.25) - 2.5) < 1e-12)
        // Sampled densely, a log-normal's coefficient of variation is the one asked for.
        let values = (0..<20000).map { logNormal.value(at: (Double($0) + 0.5) / 20000) }
        #expect(abs(EnsembleStatistics(values)!.variation - 0.3) < 0.01)
    }

    @Test("Statistics give the mean, the sample deviation and interpolated percentiles")
    func statistics() throws {
        let stats = try #require(EnsembleStatistics([4, 1, 3, 2, 5, .nan]))
        #expect(stats.count == 5 && stats.mean == 3 && stats.minimum == 1 && stats.maximum == 5)
        #expect(abs(stats.deviation - 2.5.squareRoot()) < 1e-12)
        #expect(stats.p50 == 3 && abs(stats.p5 - 1.2) < 1e-12 && abs(stats.p95 - 4.8) < 1e-12)
        #expect(EnsembleStatistics([]) == nil)
    }
}

@Suite("Rank correlation of an output with an input", .timeLimit(.minutes(120)))
struct RankCorrelationTests {
    @Test("Spearman's coefficient follows the order, not the shape, and ties share their rank")
    func spearman() {
        let x: [Double] = [1, 2, 3, 4, 5]
        #expect(rankCorrelation(x, x.map { $0 * $0 * $0 }) == 1)
        #expect(rankCorrelation(x, x.map { -$0 }) == -1)
        #expect(abs(rankCorrelation([1, 2, 2, 3], [1, 2, 3, 4])! - 0.9486833) < 1e-6)
        #expect(rankCorrelation(x, [1, 1, 1, 1, 1]) == nil && rankCorrelation([1, 2], [1, 2]) == nil)
    }
}
