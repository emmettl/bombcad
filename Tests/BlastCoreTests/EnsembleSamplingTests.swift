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
