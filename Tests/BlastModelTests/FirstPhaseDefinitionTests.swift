import Foundation
import Testing

@testable import BlastModel

@Suite("The offline first-phase definition")
struct FirstPhaseDefinitionTests {
    struct Fixture: Decodable {
        var name: String
        var pressurePa: [Double]
        var binS: Double
        var expectedWholeHistoryImpulse: Double
    }

    struct Controls: Decodable { var fixtures: [Fixture] }

    @Test("Both façade functions use half the final peak on the declared scalar histories")
    func wholeHistoryPeak() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appending(path: "Benchmarks/CUDAAcceptance/2026-10-22-phase-contract/fixtures.json")
        let controls = try JSONDecoder().decode(Controls.self, from: Data(contentsOf: file))
        #expect(controls.fixtures.count == 8)
        for fixture in controls.fixtures {
            let a = HybridFarField.firstImpulse(fixture.pressurePa, binS: fixture.binS)
            let b = SurrogateBench.firstImpulse(fixture.pressurePa, binS: fixture.binS)
            // Hand calculations are real values; allow only a short Double sum's rounding.
            let rounding = 16 * Double.ulpOfOne * max(1, abs(fixture.expectedWholeHistoryImpulse))
            #expect(abs(a - fixture.expectedWholeHistoryImpulse) <= rounding, "\(fixture.name)")
            #expect(a == b, "\(fixture.name)")
        }
    }

    @Test("Both offline functions agree on all 39 declared independent-history bin means")
    func independentHistories() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appending(
            path: "Benchmarks/CUDAAcceptance/2026-10-22-phase-contract/binned-fixtures.json")
        let controls = try JSONDecoder().decode(Controls.self, from: Data(contentsOf: file))
        #expect(controls.fixtures.count == 39)
        for fixture in controls.fixtures {
            let a = HybridFarField.firstImpulse(fixture.pressurePa, binS: fixture.binS)
            let b = SurrogateBench.firstImpulse(fixture.pressurePa, binS: fixture.binS)
            let positive = fixture.pressurePa.reduce(0) { $0 + max($1, 0) * fixture.binS }
            // Conservative error of two ordinary Double product/sum evaluations, not a dataset gate.
            let rounding = 4 * Double(fixture.pressurePa.count) * Double.ulpOfOne * positive
            #expect(abs(a - fixture.expectedWholeHistoryImpulse) <= rounding, "\(fixture.name)")
            #expect(a == b, "\(fixture.name)")
        }
    }

}
