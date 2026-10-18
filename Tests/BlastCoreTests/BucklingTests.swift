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

    @Test("Cowper and Symonds's law raises a steel strut's squash load with its strain rate, not when slow")
    func strainRate() throws {
        let law = SIMD2<Float>(40.4, 5)
        func factor(_ rate: Float) -> Float {
            (1 + pow(rate / law.x, 1 / law.y))
                / (1 + pow(StructureMaterial.tensileTestRate / law.x, 1 / law.y))
        }
        // 0.6 m shortened at 0.6 mm/s (10⁻³ /s, near a tensile test's 2.5 × 10⁻⁴) and at 0.18 m/s
        // (0.3 /s): 1.04 and 1.26 times f_y A.
        for (speed, rate) in [(Float(0.0006), Float(1e-3)), (0.18, 0.3)] {
            let r = try BucklingStudy.run(
                device: device, length: 0.6, elementSize: 0.1, rate: speed, shortening: 0.0015,
                yieldStress: 355e6, clamped: true, cowperSymonds: law)
            let expected = max(factor(rate), 1)
            print("strut at \(rate) /s: \(r.peakForce / r.squash) of f_y A, Cowper and Symonds \(expected)")
            #expect(abs(r.peakForce / (r.squash * expected) - 1) < 0.04)
        }
    }

    @Test("A strut struck at its end buckles at Lindberg's preferred wavelength")
    func impact() throws {
        // At 200 m/s a 20 mm square strut buckles about 0.26 m apart, behind the front.
        let r = try BucklingStudy.impact(device: device, speed: 200, seeds: 4)
        #expect(abs(r.measured / r.predicted - 1) < 0.25, "\(r.measured) m against \(r.predicted) m")
    }

    @Test("Bowed as Eurocode 3 takes members to be, a strut carries its buckling curve's resistance")
    func curves() throws {
        // A pinned S355 strut under a slowly rising load, bowed by default.
        for (curve, slenderness) in [(BucklingCurve.a, Float(1)), (.b, 0.5), (.b, 1), (.b, 2), (.c, 1)] {
            let r = try BucklingStudy.curve(device: device, slenderness: slenderness, curve: curve)
            let ratio = r.model / (r.eurocode ?? 1)
            #expect(
                abs(ratio - 1) < 0.05,
                "curve \(curve) at λ̄ \(slenderness): χ \(r.model) against \(r.eurocode ?? 0)")
        }
        // Straight, near λ̄ = 1 it carries its squash load.
        let straight = try BucklingStudy.curve(device: device, slenderness: 1, curve: nil)
        #expect(straight.model > 0.95)
    }
}
