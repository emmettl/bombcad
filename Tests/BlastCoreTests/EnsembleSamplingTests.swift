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

    @Test("The calibration's glass cases give the record's figures at today's flaw constant and move with it")
    func calibrationGlass() throws {
        let today = try ValidationEnsemble.monkBreakTimes(flawFactor: 1)
        // docs/validation.md, "Window glass": 2.92, 3.01, 3.21 and 2.97 ms.
        #expect(abs((today["t1-1"] ?? 0) - 2.92) < 0.02 && abs((today["t1-1.7"] ?? 0) - 3.21) < 0.02)
        let stronger = try ValidationEnsemble.monkBreakTimes(flawFactor: 0.1)
        #expect(today.keys.allSatisfy { (stronger[$0] ?? 0) > (today[$0] ?? .infinity) })
        // E1300's: 0.57–0.72 of its load resistance with the whole pane at its largest stress.
        let resistances = ValidationEnsemble.e1300Resistances(flawFactor: 1)
        for pane in ValidationEnsemble.e1300Panes {
            let ratio = (resistances["lr" + pane.name] ?? 0) / pane.load
            #expect((0.56...0.73).contains(ratio), "\(pane.name): \(ratio)")
        }
        #expect(
            ValidationEnsemble.cases.contains { $0.id == "glass-monk" && $0.outputs.count == 4 }
                && ValidationEnsemble.cases.contains { $0.id == "kb-open" && $0.outputs.count == 3 })
    }
}
