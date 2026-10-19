import Foundation
import Testing
import simd

@testable import BlastModel

/// Building sides' glass chances (`FacadeLoadSurrogate.glassProbabilities`, docs/glass-probability.md).
@Suite("Façade glass chances")
struct FacadeGlassProbabilityTests {
    /// Four glazed 10 m blocks in a row at 20 to 160 m from a 100 kg charge, an apartment block's
    /// mix of panes on each: near ones blown out, far ones whole, some between.
    static func row() throws -> Scenario {
        var scene = Scenario(
            name: "Row", domainSize: SIMD3(400, 60, 30), boxes: [],
            charge: Charge(mass: 100, position: SIMD3(10, 30, 0.5)))
        for x: Float in [30, 60, 100, 170] {
            let id = try scene.addEnvelopeObject(
                BuildingEnvelope(solids: [Box(min: SIMD3(x, 25, 0), max: SIMD3(x + 10, 35, 9))]))
            var construction = EnvelopeConstruction(objectID: id, source: .user, detail: "glazed block")
            construction.glazing = .apartments
            scene.setEnvelopeConstruction(construction)
        }
        return scene
    }

    @Test("The pane table gives a mix's breakage as GlazingMix does, on the same pulse")
    func table() {
        let table = FacadeLoadSurrogate.GlassTable(binS: 0.7e-3)
        for (peak, impulse) in [(800.0, 20.0), (4_000, 60), (20_000, 200)] {
            let prediction = FacadeLoadSurrogate.Prediction(
                peakPa: peak, impulsePaS: impulse, riseShare: 0.3, arrivalS: 0)
            let pressures = FacadeLoadSurrogate.pulse(
                peak: FacadeLoadSurrogate.quantized(peak), impulse: FacadeLoadSurrogate.quantized(impulse),
                riseShare: 0.3, binS: 0.7e-3)
            for mix in [GlazingMix.olderLowRise, .apartments, .commercial] {
                let direct = mix.breakage(netPa: pressures, binS: 0.7e-3, areaM2: 30)
                let tabled = table.breakage(mix, prediction: prediction, areaM2: 30, strength: 1)
                #expect(abs(direct.broken - tabled.broken) < 1e-9)
                #expect(abs(direct.logNoneBroken - tabled.logNoneBroken) < 1e-9)
                #expect(direct.panes == tabled.panes)
            }
        }
        // Stronger glass breaks less.
        let p = FacadeLoadSurrogate.Prediction(peakPa: 4_000, impulsePaS: 60, riseShare: 0.3, arrivalS: 0)
        #expect(
            table.breakage(.apartments, prediction: p, areaM2: 30, strength: 2).broken
                < table.breakage(.apartments, prediction: p, areaM2: 30, strength: 1).broken)
    }

    @Test(
        "A pane thrown past 3 m is one that broke: the chance never exceeds breaking's, and the pulse decides it as a history would"
    )
    func thrown() {
        let table = FacadeLoadSurrogate.GlassTable(binS: 0.7e-3)
        for (peak, impulse) in [(800.0, 20.0), (8_000, 120), (40_000, 400)] {
            let p = FacadeLoadSurrogate.Prediction(
                peakPa: peak, impulsePaS: impulse, riseShare: 0.2, arrivalS: 0)
            let tabled = table.outcome(.apartments, prediction: p, areaM2: 30, strength: 1)
            #expect(tabled.worse <= tabled.glass.anyBroken + 1e-12)
            let pressures = FacadeLoadSurrogate.pulse(
                peak: FacadeLoadSurrogate.quantized(peak), impulse: FacadeLoadSurrogate.quantized(impulse),
                riseShare: 0.2, binS: 0.7e-3)
            let direct = FacadeLoadSurrogate.glassOutcome(
                .apartments, netPa: pressures, binS: 0.7e-3, areaM2: 30)
            #expect(abs(direct.glass.broken - tabled.glass.broken) < 1e-9)
            #expect(abs(direct.worse - tabled.worse) < 0.05)
        }
        let strong = FacadeLoadSurrogate.Prediction(
            peakPa: 40_000, impulsePaS: 400, riseShare: 0.2, arrivalS: 0)
        #expect(table.outcome(.apartments, prediction: strong, areaM2: 30, strength: 1).worse > 0.5)
        let weak = FacadeLoadSurrogate.Prediction(peakPa: 800, impulsePaS: 20, riseShare: 0.2, arrivalS: 0)
        #expect(table.outcome(.apartments, prediction: weak, areaM2: 30, strength: 1).worse < 0.05)
    }

    @Test(
        "Chances lie between nothing and certainty, the same however the work is shared, and the draws soften the single answer"
    )
    func chances() throws {
        let scene = try Self.row()
        let (none, _) = FacadeLoadSurrogate.glassProbabilities(scene: scene, cellSize: 2, uncertainty: .none)
        #expect(!none.isEmpty)
        // Drawn once without scatter: blown out or not.
        #expect(none.allSatisfy { $0.blownOut == 0 || $0.blownOut == 1 })
        let uncertainty = FacadeLoadSurrogate.Uncertainty(yieldLogSD: 0.3, samples: 8)
        let (a, _) = FacadeLoadSurrogate.glassProbabilities(
            scene: scene, cellSize: 2, uncertainty: uncertainty)
        let (b, _) = FacadeLoadSurrogate.glassProbabilities(
            scene: scene, cellSize: 2, uncertainty: uncertainty)
        #expect(a == b)
        #expect(
            a.allSatisfy {
                (0...1).contains($0.someBroken) && (0...1).contains($0.blownOut)
                    && $0.thrownPast3b <= $0.someBroken + 1e-9
            })
        #expect(a.contains { $0.blownOut > 0 && $0.blownOut < 1 })
        // The nearer sides break more often.
        let sorted = a.sorted { $0.distanceM < $1.distanceM }
        let half = sorted.count / 2
        let near = sorted.prefix(half).map(\.someBroken).reduce(0, +) / Double(half)
        let far = sorted.suffix(half).map(\.someBroken).reduce(0, +) / Double(half)
        #expect(near > far)
    }

    @Test(
        "Glass types: annealed alone keeps its own path, toughened breaks less, laminated and filmed hold their glass"
    )
    func glassTypes() {
        let pressures = FacadeLoadSurrogate.pulse(peak: 6_000, impulse: 90, riseShare: 0.2, binS: 0.7e-3)
        let annealed = GlazingMix.apartments
        let alone = annealed.breakage(netPa: pressures, binS: 0.7e-3, areaM2: 40)
        // Annealed glass judged by the general path (an empty glass type) gives the same.
        let general = annealed.with(.init()).breakage(
            netPa: pressures, binS: 0.7e-3, areaM2: 40, worseThan: nil)
        #expect(
            abs(alone.broken - general.broken) < 1e-12
                && abs(alone.logNoneBroken - general.logNoneBroken) < 1e-12)
        #expect(alone.logNoneWorse == nil)
        let threw = annealed.breakage(netPa: pressures, binS: 0.7e-3, areaM2: 40, worseThan: .threeB)
        let toughened = annealed.with(.init(toughened: true))
            .breakage(netPa: pressures, binS: 0.7e-3, areaM2: 40, worseThan: .threeB)
        #expect(toughened.broken < threw.broken)
        #expect((toughened.worse ?? 0) <= (threw.worse ?? 0))
        for glass in [GlazingMix.Glass(laminate: .facade), .init(film: .mils(7, anchorage: .wetGlazed))] {
            let held = annealed.with(glass).breakage(
                netPa: pressures, binS: 0.7e-3, areaM2: 40, worseThan: .threeB)
            #expect((held.worse ?? 1) < (threw.worse ?? 0), "\(glass.label)")
        }
    }

    @Test("A side's own windows are judged in place of its building's, and the others not at all differently")
    func sideGlazing() throws {
        let scene = try Self.row()
        let estimate = FacadeLoadSurrogate.estimate(scene: scene, cellSize: 2)
        let id = scene.envelopeObjects[0].id
        var construction = scene.envelopeConstruction(for: id)
        let before = EnvelopeDamageAssessment.assess(
            loads: estimate.loads, constructions: { scene.envelopeConstruction(for: $0) })
        var filled = GlazingMix.apartments
        filled.glazedFraction = 0
        construction.sideGlazing = [EnvelopeConstruction.sideKey(axis: 0, outward: -1): filled]
        let after = EnvelopeDamageAssessment.assess(
            loads: estimate.loads,
            constructions: { $0 == id ? construction : scene.envelopeConstruction(for: $0) })
        let west = { (b: [EnvelopeBuildingDamage]) in
            b.first { $0.id == id }?.facadeGlass?.first { $0.axis == 0 && $0.outward == -1 }?.glass
        }
        #expect((west(before)?.panes ?? 0) > 0)
        #expect(west(after)?.panes == 0)
        let east = { (b: [EnvelopeBuildingDamage]) in
            b.first { $0.id == id }?.facadeGlass?.first { $0.axis == 0 && $0.outward == 1 }?.glass
        }
        #expect(east(before) == east(after))
        for (a, b) in zip(before, after) where a.id != id {
            #expect(a.facadeGlass == b.facadeGlass && a.structuralLevels == b.structuralLevels)
        }
    }
}
