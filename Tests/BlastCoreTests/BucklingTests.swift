import Foundation
import Metal
import Testing

@testable import BlastCore

/// Whether the shell solver's beams buckle (`BucklingStudy`): a 50 mm square steel strut shortened
/// slowly carries, once buckled, its Euler load for its ends, or squashes where it is stocky; and
/// one struck at its end buckles at Lindberg's preferred wavelength.
@Suite("Buckling", .gpuThreads)
struct BucklingTests {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    @Test("A slender strut carries 4 P_E clamped at both ends and 2.046 P_E pinned at one")
    func euler() throws {
        let clamped = try BucklingStudy.run(
            device: device, length: 1.5, elementSize: 0.1, rate: 0.004, shortening: 0.011, clamped: true)
        #expect(abs(clamped.finalForce / (4 * clamped.euler) - 1) < 0.03)
        let pinned = try BucklingStudy.run(
            device: device, length: 1.5, elementSize: 0.1, rate: 0.004, shortening: 0.008)
        #expect(abs(pinned.finalForce / (2.046 * pinned.euler) - 1) < 0.03)
        // Shortened at a finite speed, it goes past the load before it buckles out.
        #expect(pinned.peakForce > pinned.finalForce && pinned.lateral > 0.02)
    }

    @Test("A stocky strut squashes at f_y A")
    func squash() throws {
        let r = try BucklingStudy.run(
            device: device, length: 0.6, elementSize: 0.1, rate: 0.004, shortening: 0.003, yieldStress: 355e6,
            clamped: true)
        #expect(abs(r.peakForce / r.squash - 1) < 0.02)
    }
}
