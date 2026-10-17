import Foundation
import Testing

@testable import BlastCore

/// Thick annealed glass on the large-deflection model (`EnvelopePanel.largeDeflectionGlass`),
/// beyond ASTM E1300's charts (which end at 19 mm), against a hand check. See docs/validation.md,
/// "Thick glass".
@Suite("Thick glass")
struct ThickGlassTests {
    @Test("50 mm annealed glass 1.25 by 1.5 m breaks under 5 kg at 5 m, as the closed form says")
    func fiftyMillimetres() throws {
        // Kingery–Bulmash's reflected load at 2.92 m/kg^(1/3): about 354 kPa and 395 Pa s, 2.2 ms.
        let mass = 5.0
        let range = 5.0
        let kb = try #require(KingeryBulmash.point(at: range / cbrt(mass)))
        let peak = kb.reflectedPressure
        let impulse = kb.reflectedImpulse(mass: mass)
        let duration = 2 * impulse / peak
        // By hand: a simply supported plate, b/a = 1.2 (Timoshenko's α 0.00564, β 0.376), small
        // deflections; its period about 7.7 ms, so the load is an impulse (td/T 0.29) and the
        // peak deflection i / (m ω); the stress at it against the glass's strength held for about
        // half a period, the 60 s strength for the pane's area (E1300's flaw model) raised by
        // (60 s / t)^(1/16).
        let (t, a) = (0.05, 1.25)
        let glass = StructureMaterial.annealedGlass
        let e = Double(glass.youngsModulus)
        let nu = Double(glass.poissonRatio)
        let rigidity = e * t * t * t / (12 * (1 - nu * nu))
        let stiffness = rigidity / (0.00564 * pow(a, 4))
        let areal = Double(glass.density) * t * min(0.63 + 0.16 * (1.5 / a - 1), 0.79)
        let omega = (stiffness / areal).squareRoot()
        #expect(duration * omega / (2 * .pi) < 0.35)
        let deflection = impulse / (areal * omega)
        let stress = 0.376 * stiffness * deflection * a * a / (t * t)
        let strength = GlassStrength.sixtySecond(area: a * 1.5) * pow(60 / (.pi / omega), 1 / 16.0)
        #expect(stress / strength > 1.3, "\(stress / 1e6) MPa against \(strength / 1e6) MPa")
        // The model breaks it, in its first swing.
        let model = EnvelopePanel.largeDeflectionGlass(thickness: t, material: glass, a: a, b: 1.5)
        let bin = 1e-5
        let pressures = (0..<5_000).map { i -> Double in
            let time = Double(i) * bin
            return time < duration ? peak * (1 - time / duration) : 0
        }
        let broke = try #require(model.response(pressures: pressures, step: bin).lostResistanceAt)
        #expect(broke < .pi / omega)
    }
}
