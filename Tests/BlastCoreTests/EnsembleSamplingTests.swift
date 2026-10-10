import Foundation
import Testing

@testable import BlastCore

@Suite("Sampling uncertain inputs for an ensemble")
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

    @Test("A case's samples start with every input at its middle, then follow the seed")
    func samples() throws {
        let samples = try ValidationEnsemble.samples(case: "kb-curve", count: 8, seed: 3)
        #expect(samples.count == 9 && samples.map(\.index) == Array(0...8))
        #expect(abs(samples[0].values["mass"]! - 1) < 1e-12)
        #expect(try ValidationEnsemble.samples(case: "kb-curve", count: 8, seed: 3) == samples)
        #expect(throws: EnsembleError.self) {
            try ValidationEnsemble.samples(case: "nothing", count: 2, seed: 1)
        }
        // Every case's inputs and outputs have distinct keys.
        for item in ValidationEnsemble.cases {
            #expect(Set(item.inputs.map(\.key)).count == item.inputs.count, "\(item.id)")
            #expect(Set(item.outputs.map(\.key)).count == item.outputs.count, "\(item.id)")
        }
    }

    @Test(
        "Varying the concrete moves its stiffness, tensile strength and fracture energy by their correlations"
    )
    func perturbed() {
        var material = StructureMaterial.concrete(
            name: "Test", compressiveStrength: 30e6,
            steel: SteelProperties(
                yieldStress: 500e6, ultimateStress: 600e6, ultimateStrain: 0.1, ruptureStrain: 0.15))
        material.tensileStrength = 3e6  // a case's own measured value
        let moved = ValidationEnsemble.perturbed(
            material, ["fc": 40e6, "ft": 1.1, "gf": 0.5, "fy": 1.05, "fu": 0.9])
        let ratio: Float = 40 / 30
        #expect(moved.compressiveStrength == 40e6)
        #expect(abs(moved.youngsModulus / material.youngsModulus - ratio.squareRoot()) < 1e-5)
        #expect(abs(moved.tensileStrength / 3e6 - pow(ratio, 2 / 3) * 1.1) < 1e-5)
        #expect(abs(moved.fractureEnergy / material.fractureEnergy - pow(ratio, 0.18) * 0.5) < 1e-5)
        // The ultimate never falls below the yield.
        #expect(
            abs(moved.steel!.yieldStress / 525e6 - 1) < 1e-6
                && moved.steel!.ultimateStress >= moved.steel!.yieldStress)
        // Nothing asked, nothing changed.
        let same = ValidationEnsemble.perturbed(material, [:])
        #expect(same.compressiveStrength == material.compressiveStrength && same.tensileStrength == 3e6)
    }

    @Test("The curves' own case gives the reference at its middle and moves with its inputs")
    func curveCase() throws {
        let samples = try ValidationEnsemble.samples(case: "kb-curve", count: 4, seed: 1)
        let middle = try ValidationEnsemble.run(samples[0])
        let reference = try #require(KingeryBulmash.point(at: 2))
        #expect(abs(middle.outputs["impulse"]! / reference.reflectedImpulse(mass: 100) - 1) < 1e-9)
        let outputs = try samples.dropFirst().map { try ValidationEnsemble.run($0).outputs["impulse"]! }
        #expect(Set(outputs).count == 4)
    }
}

@Suite("Rank correlation of an output with an input")
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
