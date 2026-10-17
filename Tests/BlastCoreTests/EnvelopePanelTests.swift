import Foundation
import Testing

@testable import BlastCore

/// The SDOF systems of envelope panels against plate theory, the yield line and hand calculation.
@Suite("Envelope panels")
struct EnvelopePanelTests {
    @Test("The yield line gives 24 (m⁺ + m⁻) / a² on a square, less on a longer panel")
    func yieldLine() {
        #expect(abs(EnvelopePanel.yieldLineResistance(positive: 10, negative: 5, a: 2, b: 2) - 90) < 1e-9)
        // A very long panel tends to a one-way strip: 8 (m⁺ + m⁻) / a².
        let strip = EnvelopePanel.yieldLineResistance(positive: 1, negative: 0, a: 1, b: 1e6)
        #expect(abs(strip / 8 - 1) < 1e-5)
    }

    @Test("Plate coefficients: a clamped square deflects 0.00126 q a⁴ / D, a simply supported one 0.00406")
    func plates() {
        #expect(abs(EnvelopePanel.stiffness(rigidity: 1, a: 1, b: 1, edges: .fixed) - 1 / 0.00126) < 1e-6)
        #expect(
            abs(EnvelopePanel.stiffness(rigidity: 1, a: 1, b: 1, edges: .simplySupported) - 1 / 0.00406)
                < 1e-6)
        // Midway between tabulated ratios, midway between their coefficients.
        let between = EnvelopePanel.coefficient(EnvelopePanel.deflection[.fixed]!, aspect: 1.25)
        #expect(abs(between - (0.00172 + 0.00191) / 2) < 1e-12)
    }

    @Test("A reinforced concrete panel's resistance and stiffness, worked by hand")
    func reinforcedConcrete() {
        // 0.2 m, one central mat of 600 mm²/m at 0.1 m, 4 × 6 m, fixed. Dynamic strengths
        // 1.17 × 500 and 1.19 × 30 MPa: T = 351 kN/m, stress block 11.6 mm, M = 33.07 kN m/m.
        let panel = EnvelopePanel.reinforcedConcrete(
            thickness: 0.2, depth: 0.1, steelArea: 600e-6, material: .reinforcedConcrete, a: 4, b: 6)
        let moment = 351_000 * (0.1 - 351_000 / (0.85 * 1.19 * 30e6) / 2)
        let shape = pow((3 + 4.0 / 9).squareRoot() - 2.0 / 3, 2)
        #expect(abs(panel.ultimateResistance / (24 * 2 * moment / 16 / shape) - 1) < 1e-9)
        #expect(abs(panel.ultimateResistance - 70_100) < 200)
        #expect(abs(panel.massPerArea - 480) < 1e-9)
        // Simply supported, the yield line loses its negative moments: half the resistance.
        let simple = EnvelopePanel.reinforcedConcrete(
            thickness: 0.2, depth: 0.1, steelArea: 600e-6, material: .reinforcedConcrete, a: 4, b: 6,
            edges: .simplySupported)
        #expect(abs(simple.ultimateResistance / panel.ultimateResistance - 0.5) < 1e-9)
        #expect(simple.stiffness < panel.stiffness / 3)
    }

    @Test("A glass pane breaks where its largest bending stress reaches its strength")
    func glass() {
        let pane = EnvelopePanel.glass(thickness: 0.006, material: .annealedGlass, a: 1.25, b: 1.5)
        // Clamped, b/a 1.2: the moment at the middle of a long edge is 0.0639 q a².
        let stress = 6 * 0.0639 * pane.ultimateResistance * 1.25 * 1.25 / (0.006 * 0.006)
        #expect(abs(stress / 45e6 - 1) < 1e-9)
        let response = pane.response(
            pressures: Array(repeating: 2 * pane.ultimateResistance, count: 1000), step: 1e-4)
        #expect(response.lostResistanceAt != nil)
        let held = pane.response(
            pressures: Array(repeating: 0.4 * pane.ultimateResistance, count: 1000), step: 1e-4)
        #expect(held.lostResistanceAt == nil)
    }

    @Test(
        "Moore's pane starts as the small-deflection plate simply supported, and membrane action stiffens it")
    func largeDeflectionGlass() {
        let pane = EnvelopePanel.largeDeflectionGlass(
            thickness: 0.006, material: .annealedGlass, a: 1.25, b: 1.5)
        let small = EnvelopePanel.glass(
            thickness: 0.006, material: .annealedGlass, a: 1.25, b: 1.5, edges: .simplySupported)
        // Moore's curves begin where the plate is nearly linear (ν 0.22 against Timoshenko's 0.3).
        #expect(abs(pane.stiffness / small.stiffness - 1) < 0.08)
        // At five thicknesses the secant stiffness is several times the initial.
        let five = pane.backbone.first { $0.x >= 0.03 }!
        #expect(five.y / five.x > 3 * pane.stiffness)
        // It lets go at ten thicknesses, as UFC takes it.
        #expect(abs(pane.backbone[pane.backbone.count - 2].x - 0.06) < 1e-9 && pane.backbone.last!.y == 0)
        // The median 60 s strength of 1.875 m² of annealed glass by E1300's constants.
        #expect(abs(pane.brittle!.strength / 27.9e6 - 1) < 0.01)
    }

    @Test("Glass held at 1.5 times its 60 s strength breaks after 60 s / 1.5¹⁶ (Brown's integral)")
    func staticFatigue() throws {
        // A stiff, overdamped system that settles at once, its stress in proportion to its deflection.
        let k = 1e9
        let system = SDOFSystem(
            massPerArea: 1, loadMassElastic: 1, loadMassPlastic: 1, backbone: [SIMD2(1, k), SIMD2(2, 2 * k)],
            dampingRatio: 3,
            brittle: SDOFSystem.Brittle(
                stress: [SIMD2(1, 1e8)], strength: 1e7 / 1.5, referenceDuration: 60, fatigueExponent: 16))
        // The pressure holds it at 0.1 m, a stress of 10 MPa: 1.5 times the strength.
        let response = system.response(pressures: Array(repeating: 0.1 * k, count: 1_200), step: 1e-4)
        let broken = try #require(response.lostResistanceAt)
        #expect(abs(broken / (60 / pow(1.5, 16)) - 1) < 0.01, "\(broken)")
    }

    @Test("Unreinforced masonry cracks at f_t t² / 6 and has nothing left at its thickness")
    func masonry() {
        let wall = EnvelopePanel.unreinforcedMasonry(thickness: 0.215, material: .masonry, a: 4, b: 6)
        let cracking = 0.3e6 * 0.215 * 0.215 / 6
        #expect(abs(wall.ultimateResistance - cracking / (0.0757 * 16)) < 1)
        #expect(wall.backbone.last == SIMD2(0.215, 0))
    }
}
