import Foundation
import Testing
import simd

@testable import BlastModel

/// A precast beam's seat cycled along its corbel, against Batalha et al.'s tests
/// (`PrecastSeatTest`, data in `Samples/PrecastSeat`).
@Suite("Precast seat")
struct PrecastSeatTests {
    let samples = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Samples/PrecastSeat")

    @Test("The tests' seats slide at 0.68 of the load on concrete and 0.44 on a neoprene pad, out to ±48 mm")
    func measured() throws {
        for (test, ratio) in [
            ("spc_i0_50", Float(0.69)), ("spc_i0_100", 0.68), ("spc_i0_150", 0.68), ("spc_i1_100", 0.44),
        ] {
            let data = try PrecastSeatTest.measured(test, samples: samples)
            let load = PrecastSeatTest.axialLoad(of: test)
            let plateau = PrecastSeatTest.plateau(data.samples)
            #expect(abs(plateau / load - ratio) < 0.01, "\(test): \(plateau / load)")
            #expect(data.reversals.count > 70 && (data.samples.map(\.x).max() ?? 0) > 0.04)
            // On concrete its work is all sliding: ∮ F du is the plateau over the path.
            #expect(test.hasPrefix("spc_i1") || abs(data.energy / (plateau * data.path) - 1) < 0.03)
        }
    }
}
