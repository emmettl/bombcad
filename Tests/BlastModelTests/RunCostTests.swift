import Foundation
import Testing
import simd

@testable import BlastModel

/// The cost model against the runs timed on an unloaded Mac in docs/performance.md.
@Suite("Run cost", .timeLimit(.minutes(120)))
struct RunCostTests {
    @Test("Targets read from the command line")
    func targets() {
        #expect(AdvisorTarget(text: "peak:20%") == .fidelity(.peak, within: 0.2))
        #expect(AdvisorTarget(text: "impulse:0.15") == .fidelity(.impulse, within: 0.15))
        #expect(
            AdvisorTarget(text: "time:10m") == .seconds(600)
                && AdvisorTarget(text: "time:2h") == .seconds(7200))
        #expect(AdvisorTarget(text: "time:90") == .seconds(90))
        for bad in ["peak", "peak:", "speed:10%", "time:-1", "peak:0"] {
            #expect(AdvisorTarget(text: bad) == nil, "\(bad)")
        }
    }
}
