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
        "A preview's coarser pane table judges a pulse as its rounded pulse is judged, near the fine table's")
    func previewTable() {
        let fine = FacadeLoadSurrogate.GlassTable(binS: 0.7e-3)
        let coarse = FacadeLoadSurrogate.GlassTable(
            binS: 0.7e-3, quantum: FacadeLoadSurrogate.Prepared.previewQuantum,
            strengthSteps: FacadeLoadSurrogate.Prepared.previewStrengthSteps)
        #expect(fine.step == FacadeLoadSurrogate.GlassTable.step && fine.strengthSteps == 20)
        let step = log(1 + FacadeLoadSurrogate.Prepared.previewQuantum)
        for (peak, impulse) in [(800.0, 20.0), (4_000, 60), (20_000, 200)] {
            let prediction = FacadeLoadSurrogate.Prediction(
                peakPa: peak, impulsePaS: impulse, riseShare: 0.3, arrivalS: 0)
            // As GlazingMix judges the pulse rounded to the preview's steps.
            let pressures = FacadeLoadSurrogate.pulse(
                peak: exp((log(peak) / step).rounded() * step),
                impulse: exp((log(impulse) / step).rounded() * step),
                riseShare: 0.3, binS: 0.7e-3)
            let direct = GlazingMix.apartments.breakage(netPa: pressures, binS: 0.7e-3, areaM2: 30)
            let tabled = coarse.breakage(.apartments, prediction: prediction, areaM2: 30, strength: 1)
            #expect(abs(direct.broken - tabled.broken) < 1e-9)
            // And near the fine table's: loads rounded by at most 5%.
            let finer = fine.breakage(.apartments, prediction: prediction, areaM2: 30, strength: 1)
            #expect(
                abs(finer.fraction - tabled.fraction) < 0.15,
                "\(peak) Pa: \(finer.fraction) against \(tabled.fraction)")
        }
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

    @Test(
        "Openings blown out: the fragility fitted to Beirut's survey, half at 18.5 kPa; older results read as none"
    )
    func openingsFragility() throws {
        typealias F = FacadeLoadSurrogate.OpeningsFragility
        #expect(abs(F.chance(peakPa: 18_500) - 0.5) < 1e-12)
        #expect(F.chance(peakPa: 0) == 0 && F.chance(peakPa: 1e6) > 0.99)
        // One log standard deviation either side: 0.16 and 0.84.
        #expect(abs(F.chance(peakPa: 18_500 * exp(-0.75)) - 0.1587) < 1e-3)
        #expect(abs(F.chance(peakPa: 18_500 * exp(0.75)) - 0.8413) < 1e-3)
        // A side's chances saved before the openings had one read with none.
        let old = """
            {"owner":"\(UUID().uuidString)","axis":0,"outward":1,"distanceM":900,"someBroken":1,
             "blownOut":0.9,"fractionBroken":0.95,"thrownPast3b":0.4}
            """
        let side = try JSONDecoder().decode(FacadeLoadSurrogate.SideGlass.self, from: Data(old.utf8))
        #expect(side.openingsBlownOut == 0 && side.blownOut == 0.9)
        // The quick estimate's row: nearer sides' openings likelier blown out than farther ones'.
        let scene = try Self.row()
        let (sides, _) = FacadeLoadSurrogate.glassProbabilities(
            scene: scene, cellSize: 1, uncertainty: .none)
        let byDistance = sides.sorted { $0.distanceM < $1.distanceM }
        #expect(byDistance.first!.openingsBlownOut > byDistance.last!.openingsBlownOut)
        #expect(sides.allSatisfy { (0...1).contains($0.openingsBlownOut) })
    }

    /// The glass front (emmettl/bombcad-work#103): the share of its peak a façade pulse reaches at
    /// once, fitted on the clear-top fit runs by scaled distance; a candidate, off by default.
    @Test(
        "Without a front a pulse is the triangle bin for bin; with one it keeps the impulse and starts at its share"
    )
    func frontPulse() {
        typealias S = FacadeLoadSurrogate
        for (peak, impulse, rise) in [(800.0, 20.0, 0.3), (4_000, 60, 0.35), (20_000, 200, 0)] {
            let triangle = S.pulse(peak: peak, impulse: impulse, riseShare: rise, binS: 0.7e-3)
            #expect(
                S.pulse(peak: peak, impulse: impulse, riseShare: rise, front: 0, binS: 0.7e-3) == triangle)
            for front in [0.1, 0.3, 0.54] {
                let fronted = S.pulse(
                    peak: peak, impulse: impulse, riseShare: rise, front: front, binS: 0.7e-3)
                let carried = fronted.reduce(0, +) * 0.7e-3
                #expect(abs(carried - impulse) < 1e-9 * impulse, "\(carried) against \(impulse)")
                #expect(fronted.max()! <= peak * (1 + 1e-12))
                if rise > 0 {
                    // Its first bin's mean is at least the front, and shorter than the triangle.
                    #expect(fronted[0] >= front * peak * (1 - 1e-12))
                    #expect(fronted.count <= triangle.count)
                } else {
                    #expect(fronted == triangle)
                }
            }
        }
        // The share, by scaled distance: none close in, growing far out, held beyond the fit.
        let front = S.Coefficients.GlassFront.clearTop
        #expect(front.share(atZ: 3) == 0 && front.share(atZ: 8.4) == 0)
        #expect(abs(front.share(atZ: 23.7) - 0.19) < 1e-12)
        #expect(front.share(atZ: 14) > 0.05 && front.share(atZ: 14) < 0.10)
        #expect(front.share(atZ: 80) == front.share(atZ: 49))
        // A prediction keeps its loads; only its front is set, and only by terms that have one.
        let p = S.Prediction(peakPa: 3_000, impulsePaS: 80, riseShare: 0.3, arrivalS: 1)
        #expect(S.Coefficients.clearTop.forGlass(p, distanceM: 1_500, mass: 500_000) == p)
        let fronted = S.Coefficients.clearTopFront.forGlass(p, distanceM: 1_500, mass: 500_000)
        #expect(fronted.peakPa == p.peakPa && fronted.impulsePaS == p.impulsePaS)
        #expect(abs(fronted.frontShare - front.share(atZ: 1_500 / cbrt(500_000))) < 1e-12)
    }

    @Test("The glass front is a named candidate: the defaults, the walls and the loads stay as they were")
    func frontCandidate() throws {
        typealias S = FacadeLoadSurrogate
        #expect(S.TermSet.adopted == .deepCity && S.Coefficients.adopted.glassFront == nil)
        #expect(S.Coefficients.fitted.glassFront == nil)
        let candidate = S.TermSet.clearTopFront
        #expect(candidate.loadScatter == S.TermSet.clearTop.loadScatter)
        var withoutFront = candidate.coefficients
        withoutFront.glassFront = nil
        #expect(withoutFront == .clearTop)
        // The walls take no front, and the terms' loads are the same.
        #expect(candidate.coefficients.forStructures == S.Coefficients.clearTop.forStructures)
        let f = FacadeLoadSurrogateTests.facing(1_500)
        #expect(
            S.predict(f, mass: 500_000, cellSize: 4, coefficients: candidate.coefficients)
                == S.predict(f, mass: 500_000, cellSize: 4))
        #expect(try SurrogateBench.termSet(["--terms", "clear-top-front"]) == .clearTopFront)
        // Saved terms without a front read as before, and a front survives JSON.
        let data = try JSONEncoder().encode(S.Coefficients.clearTop)
        #expect(!String(decoding: data, as: UTF8.self).contains("glassFront"))
        let back = try JSONDecoder().decode(
            S.Coefficients.self, from: try JSONEncoder().encode(candidate.coefficients))
        #expect(back == candidate.coefficients)
        // Whole from the fit's smallest charge (20 t), none below 2 t, evenly in the log between.
        let front = try #require(candidate.coefficients.glassFront)
        #expect(front.share(atZ: 30, mass: 20_000) == front.share(atZ: 30))
        #expect(front.share(atZ: 30, mass: 2_000) == 0 && front.share(atZ: 30, mass: 500) == 0)
        #expect(
            abs(front.share(atZ: 30, mass: 2_000 * 10.0.squareRoot()) - 0.5 * front.share(atZ: 30)) < 1e-12)
        // So a 100 kg charge's glass chances are as without it.
        let scene = try Self.row()
        let (plain, _) = S.glassProbabilities(scene: scene, cellSize: 2, uncertainty: .none)
        let (small, _) = S.glassProbabilities(
            scene: scene, cellSize: 2, uncertainty: .none, coefficients: candidate.coefficients)
        #expect(plain == small)
        // A façade 2.4 km from 500 t (Z 30), its load long against its panes' periods: its glass
        // breaks more with the front, by more than a few per cent of its panes.
        let table = S.GlassTable(binS: 0.7e-3)
        let p = S.predict(FacadeLoadSurrogateTests.facing(2_400), mass: 500_000, cellSize: 4)
        let fronted = candidate.coefficients.forGlass(p, distanceM: 2_400, mass: 500_000)
        #expect(fronted.frontShare > 0.2 && fronted.frontShare < 0.3, "\(fronted.frontShare)")
        for mix in [GlazingMix.olderLowRise, .apartments] {
            let without = table.breakage(mix, prediction: p, areaM2: 200, strength: 1)
            let with = table.breakage(mix, prediction: fronted, areaM2: 200, strength: 1)
            #expect(
                with.fraction > without.fraction && with.logNoneBroken < without.logNoneBroken, "\(mix.name)")
        }
    }

    @Test("Charge inference's break table with fronts reads the unfronted table's values at no front")
    func frontedBreakTable() {
        typealias T = ChargeInference.BreakTable
        let plain = T(.apartments, coarsening: 6)
        let fronted = T(.apartments, coarsening: 6, fronted: true)
        #expect(plain.fronts == [0] && fronted.fronts.count > 1)
        for (peak, duration, rise) in [(800.0, 0.05, 0.3), (4_000, 0.2, 0.35), (20_000, 0.01, 0.1)] {
            let a = plain.logNoneBrokenPerM2(logPeak: log(peak), logDuration: log(duration), rise: rise)
            let b = fronted.logNoneBrokenPerM2(
                logPeak: log(peak), logDuration: log(duration), rise: rise, front: 0)
            #expect(abs(a - b) < 1e-12)
            #expect(
                plain.logNoneBrokenPerM2(
                    logPeak: log(peak), logDuration: log(duration), rise: rise, front: 0.3) == a)
            // On a load long against the panes' periods a front breaks more: the log of none broken
            // no higher.
            let c = fronted.logNoneBrokenPerM2(
                logPeak: log(peak), logDuration: log(duration), rise: rise, front: 0.4)
            if duration >= 0.05 { #expect(c <= b + 1e-9) }
        }
    }
}
