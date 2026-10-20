import Foundation
import Testing
import simd

@testable import BlastModel

/// The model against a real test: the normal-strength slab of the Blast Blind Simulation Contest.
@Suite("Slab benchmark")
struct SlabBenchmarkTests {
    @Test("The recorded load has the stated peak and impulse")
    func load() {
        let load = SlabBenchmark.load
        #expect(abs(load.impulse - SlabBenchmark.statedImpulse) / SlabBenchmark.statedImpulse < 1e-4)
        let peak = load.history.map(\.y).max() ?? 0
        #expect(abs(peak - SlabBenchmark.statedPeakPressure) / SlabBenchmark.statedPeakPressure < 0.03)
    }
}
