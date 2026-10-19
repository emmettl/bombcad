import Foundation
import Testing

@testable import BlastModel

/// Façades whose windows are a mix of panes, each breaking with E1300's probability.
@Suite("Envelope glazing")
struct EnvelopeGlazingTests {
    /// A triangular pulse as mean pressures per 0.1 ms bin.
    func pulse(_ peak: Double, over duration: Double, total: Double = 0.3) -> [Double] {
        (0..<Int(total / 1e-4)).map { index in
            let t = (Double(index) + 0.5) * 1e-4
            return t < duration ? peak * (1 - t / duration) : 0
        }
    }

    @Test("The chance of breaking is the 60 s strength's, inverted")
    func probability() {
        for area in [0.5, 1.8, 6.0] {
            for p in [0.008, 0.5, 0.9] {
                let stress = GlassStrength.sixtySecond(area: area, probability: p)
                #expect(abs(GlassStrength.probability(stress: stress, area: area) - p) < 1e-9)
            }
        }
        #expect(GlassStrength.probability(stress: 0, area: 1) == 0)
    }

    @Test("A pane breaks at its median strength exactly where its chance of breaking passes one half")
    func medianAgrees() {
        let mix = GlazingMix(
            name: "one", panes: [.init(widthM: 1.2, heightM: 1.5, thicknessM: 0.006, share: 1)],
            glazedFraction: 1)
        for peak in stride(from: 1000.0, through: 12000, by: 500) {
            let load = pulse(peak, over: 0.05)
            let glass = mix.breakage(netPa: load, binS: 1e-4, areaM2: 1.8)
            let median = EnvelopeDamageAssessment.annealedPane(thickness: 0.006, a: 1.2, b: 1.5)
                .response(pressures: load, step: 1e-4)
            #expect(abs(glass.panes - 1) < 1e-6)
            // Away from the edge, the two agree.
            if abs(glass.fraction - 0.5) > 0.02 {
                #expect(
                    (median.lostResistanceAt != nil) == (glass.fraction > 0.5), "\(peak): \(glass.fraction)")
            }
        }
    }

    @Test(
        "A façade's panes follow the glazed share, and break more, and thinner ones first, as the load grows")
    func facade() {
        let mix = GlazingMix.apartments
        let area = 6.0 * 3
        let quiet = mix.breakage(netPa: pulse(20, over: 0.05), binS: 1e-4, areaM2: area)
        let expected = mix.panes.reduce(0.0) {
            $0 + Double(mix.glazedFraction * $1.share) * area / Double($1.areaM2)
        }
        #expect(abs(quiet.panes - expected) < 1e-9 && quiet.broken == 0 && quiet.anyBroken == 0)
        var last = 0.0
        for peak in [2e3, 4e3, 8e3, 16e3, 32e3] {
            let glass = mix.breakage(netPa: pulse(peak, over: 0.1), binS: 1e-4, areaM2: area)
            #expect(glass.fraction >= last && glass.anyBroken >= glass.fraction, "\(peak)")
            last = glass.fraction
        }
        #expect(last > 0.99)
        // The same load breaks more 4 mm panes than 8 mm.
        func one(_ thickness: Float) -> Double {
            GlazingMix(
                name: "", panes: [.init(widthM: 1, heightM: 1.5, thicknessM: thickness, share: 1)],
                glazedFraction: 1
            ).breakage(netPa: pulse(4e3, over: 0.1), binS: 1e-4, areaM2: 1.5).fraction
        }
        #expect(one(0.004) > one(0.008))
    }

    @Test("A building's façade strips give each side's glass and the building's, from its construction's mix")
    func assessed() {
        let owner = UUID()
        var construction = EnvelopeConstruction.assumed(objectID: owner)
        construction.glazing = .apartments
        func strip(_ id: String, axis: Int, outward: Int, peak: Double, z: Float) -> EnvelopeComponentLoad {
            EnvelopeComponentLoad(
                id: id, owner: owner, kind: .facade,
                region: Box(
                    min: SIMD3(0, 0, z), max: axis == 1 ? SIMD3(6, 0.5, z + 3) : SIMD3(0.5, 6, z + 3)),
                axis: axis, binS: 1e-4, outerPa: pulse(peak, over: 0.1), innerPa: [], outward: outward)
        }
        let building = EnvelopeDamageAssessment.assess(
            loads: [
                strip("a", axis: 1, outward: -1, peak: 20e3, z: 0),
                strip("b", axis: 1, outward: -1, peak: 20e3, z: 3),
                strip("c", axis: 0, outward: 1, peak: 300, z: 0),
            ], constructions: { _ in construction }
        ).first
        let sides = building?.facadeGlass ?? []
        #expect(sides.count == 2)
        let front = sides.first { $0.axis == 1 && $0.outward == -1 }
        let side = sides.first { $0.axis == 0 && $0.outward == 1 }
        #expect((front?.glass.fraction ?? 0) > 0.9 && (side?.glass.fraction ?? 1) < 0.1)
        let total = (front?.glass ?? GlazingBreakage()) + (side?.glass ?? GlazingBreakage())
        #expect(abs((building?.glass?.broken ?? 0) - total.broken) < 1e-9)
        // Without a mix, nothing is said of the façades' glass.
        let plain = EnvelopeDamageAssessment.assess(
            loads: [strip("a", axis: 1, outward: -1, peak: 20e3, z: 0)],
            constructions: { EnvelopeConstruction.assumed(objectID: $0) })
        #expect(plain.first?.facadeGlass == nil && plain.first?.glass == nil)
    }

    @Test("Map buildings take a mix by their tag and height")
    func mapMixes() {
        #expect(GlazingMix.forMapBuilding(kind: "yes", height: 7) == .olderLowRise)
        #expect(GlazingMix.forMapBuilding(kind: "yes", height: 20) == .apartments)
        #expect(GlazingMix.forMapBuilding(kind: "yes", height: 45) == .commercial)
        #expect(GlazingMix.forMapBuilding(kind: "warehouse", height: 45) == .industrial)
        #expect(GlazingMix.forMapBuilding(kind: "office", height: 8) == .commercial)
        for mix in [GlazingMix.olderLowRise, .apartments, .commercial, .industrial] {
            #expect(abs(mix.panes.reduce(0) { $0 + $1.share } - 1) < 1e-6)
        }
    }
}
