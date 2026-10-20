import Foundation
import Metal
import Testing
import simd

@testable import BlastCore
@testable import BlastModel

/// A precast beam's seat cycled along its corbel, against Batalha et al.'s tests
/// (`PrecastSeatTest`, data in `Samples/PrecastSeat`).
@Suite("Precast seat", .gpuThreads)
struct PrecastSeatTests {
    let samples = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Samples/PrecastSeat")

    @Test(
        "Resting on its bearing with friction 0.7, the model's seat dissipates a test's energy within 6% over its whole history"
    )
    func cycled() throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "This test needs a Metal device")
        let result = try PrecastSeatTest.run(
            device: device, test: "spc_i0_150", samples: samples, law: .resting(friction: 0.7))
        #expect(
            abs(result.energy / result.measuredEnergy - 1) < 0.06,
            "\(result.energy) J against \(result.measuredEnergy)")
        #expect(
            abs(result.sliding / result.measuredSliding - 1) < 0.04,
            "\(result.sliding) N against \(result.measuredSliding)")
        #expect(result.lag < 1e-3)
    }

    @Test(
        "On a neoprene pad, friction falling with pressure: the heavy seat's energy and sliding force near measured"
    )
    func neoprene() throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "This test needs a Metal device")
        // The first 60 reversals, out to about 20 mm, where the one-flat-coefficient law was 40% high.
        let result = try PrecastSeatTest.run(
            device: device, test: "spc_i1_150", samples: samples, law: .neoprenePad, reversals: 60)
        #expect(
            abs(result.energy / result.measuredEnergy - 1) < 0.15,
            "\(result.energy) J against \(result.measuredEnergy)")
        // Below measured, as over the whole history (0.86–0.92): pressed unevenly across the seat, its
        // points slide on less than the law gives at the mean pressure, 0.41 × (150 / 100)^−0.2 = 0.38.
        #expect(
            abs(result.sliding / result.measuredSliding - 1) < 0.15,
            "\(result.sliding) N against \(result.measuredSliding)")
    }
}
