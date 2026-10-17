import Foundation
import Testing

@testable import BlastCore

@Suite("Cross-laminated timber envelopes")
struct CrossLaminatedEnvelopeTests {
    @Test("A 3-ply CLT wall's single degree of freedom is the layered section's, as derived by hand")
    func singleDegree() throws {
        // 105 mm of C24 lamellae, 35 mm each; span 3.66 m (the Tyndall walls' storey).
        let system = EnvelopePanel.crossLaminatedOneWay(thickness: 0.105, span: 3.66)
        let t = 0.035
        let ei = 11e9 * 2 * (t * t * t / 12 + t * t * t) + 0.37e9 * t * t * t / 12
        let ga = (2 * t) * (2 * t) / (t / (2 * 0.69e9) + t / 0.069e9 + t / (2 * 0.69e9))
        let strength = Double(TimberProperties.strengthClass(.c24).tensionAlong) * 1.28
        let moment = strength * ei / (11e9 * 0.0525)
        let resistance = 8 * moment / (3.66 * 3.66)
        let elastic = resistance * (5 * pow(3.66, 4) / (384 * ei) + 3.66 * 3.66 / (8 * ga))
        #expect(abs(system.ultimateResistance - resistance) < 1e-6 * resistance)
        #expect(abs(system.equivalentElasticDeflection - elastic) < 1e-6 * elastic)
        #expect(abs(system.massPerArea - 420 * 0.105) < 1e-9)
        #expect(EnvelopePanel.crossLaminatedLamellae(thickness: 0.175) == 5)
        #expect(EnvelopePanel.crossLaminatedLamellae(thickness: 0.2) == 7)
    }

    @Test("Graded by WoodWorks' ductility limits, blown out past 2")
    func grading() {
        #expect(EnvelopeDamageLevel.crossLaminated(ductility: 0.9) == .none)
        #expect(EnvelopeDamageLevel.crossLaminated(ductility: 1.2) == .moderate)
        #expect(EnvelopeDamageLevel.crossLaminated(ductility: 1.6) == .heavy)
        #expect(EnvelopeDamageLevel.crossLaminated(ductility: 1.9) == .hazardous)
        #expect(EnvelopeDamageLevel.crossLaminated(ductility: 2.1) == .failed)
    }
}
