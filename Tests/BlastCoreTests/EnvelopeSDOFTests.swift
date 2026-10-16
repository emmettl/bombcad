import Foundation
import Testing

@testable import BlastCore

/// The equivalent single degree of freedom against closed forms and UFC 3-340-02's worked examples.
@Suite("Envelope SDOF")
struct EnvelopeSDOFTests {
    /// A triangular pulse falling from `peak` to 0 over `duration`, as mean pressures per bin.
    func triangle(_ peak: Double, over duration: Double, step: Double) -> [Double] {
        let count = Int((duration / step).rounded(.up))
        return (0..<count).map { index in
            let start = Double(index) * step
            let end = min(start + step, duration)
            return peak * (1 - (start + end) / 2 / duration) * (end - start) / step
        }
    }

    /// One unit of mass, stiffness and resistance with a period of 1.
    let unit = SDOFSystem.elasticPlastic(massPerArea: 1 / (4 * .pi * .pi), stiffness: 1, ultimate: 1)

    @Test("A load held forever at three quarters of the resistance gives a ductility of 2")
    func stepLoad() {
        // Work done equals energy absorbed: F x_m = r_u (x_m − x_e / 2), so μ = 1 / (2 (1 − F / r_u)).
        let response = unit.response(pressures: Array(repeating: 0.75, count: 20_000), step: 1e-3)
        #expect(abs(response.ductility - 2) < 1e-3)
    }

    @Test("An impulse goes in whole, elastic or plastic")
    func impulse() {
        let width = 1e-4
        // Elastic: x_m = I / (m ω).
        let elastic = SDOFSystem.elasticPlastic(massPerArea: unit.massPerArea, stiffness: 1, ultimate: 1e9)
        let small = elastic.response(pressures: [0.01 / width], step: width)
        let expected = 0.01 / (unit.massPerArea * 2 * .pi)
        #expect(abs(small.peakDeflection / expected - 1) < 1e-4)
        #expect(abs(small.reboundDeflection / expected + 1) < 1e-4)
        // Plastic: I² / 2m = r_u (x_m − x_e / 2).
        let large = unit.response(pressures: [1 / width], step: width)
        let ductility = 1 / (2 * unit.massPerArea) + 0.5
        #expect(abs(large.ductility / ductility - 1) < 1e-4)
        #expect(abs(large.residualDeflection - (large.peakDeflection - 1)) < 1e-6)
    }

    @Test("UFC 3-340-02 Example 3A-5: an elastic–plastic system under a triangular pulse")
    func example3A5() {
        // m 2.5 kip s²/ft, K 9,860 kip/ft, r_u 750 kip; 1,000 kip falling to 0 in 0.1 s. Published
        // (read off Fig. 3-64): X_m/X_E 3.7, X_m 0.281 ft, t_m 0.077 s.
        let system = SDOFSystem.elasticPlastic(massPerArea: 2.5, stiffness: 9_860, ultimate: 750)
        let response = system.response(pressures: triangle(1_000, over: 0.1, step: 1e-4), step: 1e-4)
        #expect(abs(response.peakDeflection - 0.281) < 0.003)
        #expect(abs(response.peakTime - 0.077) < 0.001)
        #expect(abs(response.ductility - 3.7) < 0.05)
    }

    @Test("UFC 3-340-02 Example 3A-6(a): the chart's ductility at P/r_u 1 and T/T_N 3")
    func example3A6() {
        // Published (Fig. 3-64a): X_m/X_E 3.55, t_m/T_N 0.98.
        let response = unit.response(pressures: triangle(1, over: 3, step: 1e-3), step: 1e-3)
        #expect(abs(response.ductility - 3.55) < 0.05)
        #expect(abs(response.peakTime / unit.period - 0.98) < 0.01)
    }

    @Test("UFC 3-340-02 Example 4A-1: a two-way wall's three-step resistance under a triangular pulse")
    func example4A1() {
        // Effective mass 1,620 psi ms²/in; resistance 10.63 psi at 0.0269 in, 10.97 at 0.028,
        // 24.13 at 0.128; 35 psi falling to 0 in 10.5 ms. Published: X_E 0.098 in, T_N 16.1 ms,
        // X_m/X_E 2.8, t_m/T_N 0.60. Units are the example's own (psi, in, ms).
        let system = SDOFSystem(
            massPerArea: 1_620, loadMassElastic: 1, loadMassPlastic: 1,
            backbone: [SIMD2(0.0269, 10.63), SIMD2(0.028, 10.97), SIMD2(0.128, 24.13)])
        #expect(abs(system.equivalentElasticDeflection - 0.098) < 0.001)
        #expect(abs(system.period - 16.1) < 0.1)
        let response = system.response(pressures: triangle(35, over: 10.5, step: 0.01), step: 0.01)
        #expect(abs(response.ductility - 2.8) < 0.05)
        #expect(abs(response.peakTime / system.period - 0.60) < 0.02)
    }

    @Test("A backbone that falls to nothing loses its resistance, and says when")
    func lostResistance() {
        let falling = SDOFSystem(
            massPerArea: unit.massPerArea, loadMassElastic: 1, loadMassPlastic: 1,
            backbone: [SIMD2(1, 1), SIMD2(5, 0)])
        let held = falling.response(pressures: Array(repeating: 0.5, count: 2_000), step: 1e-3)
        #expect(held.lostResistanceAt == nil)
        let lost = falling.response(pressures: Array(repeating: 1.2, count: 5_000), step: 1e-3)
        #expect(lost.lostResistanceAt != nil)
    }

    @Test("The load–mass factor follows UFC §3-17.4 through yield")
    func loadMassFactor() {
        // The elastic factor sets the period and the whole response while elastic; past yield the
        // plastic factor (here the mean of the two, under 2° of rotation) changes it.
        let system = SDOFSystem.elasticPlastic(
            massPerArea: 100, stiffness: 1e6, ultimate: 1e4, loadMassElastic: 0.77, loadMassPlastic: 0.66,
            span: 3)
        #expect(abs(system.period - 2 * .pi * (0.77 * 100 / 1e6).squareRoot()) < 1e-12)
        let elastic = SDOFSystem.elasticPlastic(
            massPerArea: 100, stiffness: 1e6, ultimate: 1e4, loadMassElastic: 0.77, loadMassPlastic: 0.77,
            span: 3)
        let small = triangle(5e3, over: 0.02, step: 1e-4)
        #expect(
            system.response(pressures: small, step: 1e-4) == elastic.response(pressures: small, step: 1e-4))
        let pulse = triangle(3e4, over: 0.02, step: 1e-4)
        let yielding = system.response(pressures: pulse, step: 1e-4)
        #expect(yielding.ductility > 1)
        #expect(yielding.peakDeflection != elastic.response(pressures: pulse, step: 1e-4).peakDeflection)
    }
}
