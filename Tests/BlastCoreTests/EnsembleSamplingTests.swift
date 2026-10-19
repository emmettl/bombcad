import Foundation
import Testing

@testable import BlastCore
@testable import BlastModel

@Suite("Sampling uncertain inputs for an ensemble", .timeLimit(.minutes(120)))
struct EnsembleSamplingTests {
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
