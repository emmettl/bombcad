import Foundation
import Testing

@testable import BlastModel

/// Glass as designed (E1300's, weathered) or new or tested, 1.55 times as strong
/// (`GlassCondition`; docs/glass-strength.md).
@Suite("Glass as designed or new")
struct GlassConditionTests {
    /// A blast's net pressure on a façade, Pa every 0.1 ms: a triangle of `peak` falling over 20 ms.
    static func pulse(_ peak: Double) -> [Double] {
        (0..<400).map { n in max(peak * (1 - Double(n) * 1e-4 / 0.02), 0) }
    }

    @Test("As designed leaves every mix, construction and record as it was")
    func asDesignedChangesNothing() throws {
        for mix in [GlazingMix.olderLowRise, .apartments, .commercial, .industrial] {
            #expect(mix.with(condition: .asDesigned) == mix)
        }
        var construction = EnvelopeConstruction.assumed(objectID: UUID())
        construction.glazing = .apartments
        let before = construction
        construction.setGlassCondition(.asDesigned)
        #expect(construction == before)
        let json = String(decoding: try JSONEncoder().encode(construction), as: UTF8.self)
        #expect(!json.contains("glassCondition") && !json.contains("condition"))
        #expect(construction.hasPlainGlass)
    }

    @Test("New glass breaks as E1300's glass would at 1.55 times its strength, and less than weathered glass")
    func newGlassIsStronger() {
        let mix = GlazingMix.apartments
        let new = mix.with(condition: .newOrTested)
        #expect(new.condition == .newOrTested && new.name.hasSuffix("new or tested glass"))
        for peak in [3e3, 8e3, 20e3] {
            let pressures = Self.pulse(peak)
            let asNew = new.breakage(netPa: pressures, binS: 1e-4, areaM2: 100)
            let scaled = mix.breakage(
                netPa: pressures, binS: 1e-4, areaM2: 100, worseThan: nil, strength: 1.55)
            #expect(asNew.broken == scaled.broken && asNew.logNoneBroken == scaled.logNoneBroken)
            let weathered = mix.breakage(netPa: pressures, binS: 1e-4, areaM2: 100)
            // Under the heaviest load every pane breaks either way.
            if peak < 20e3 {
                #expect(asNew.broken < weathered.broken, "\(peak) Pa")
            } else {
                #expect(asNew.broken <= weathered.broken)
            }
        }
        // Back as designed: the mix it came from.
        #expect(new.with(condition: .asDesigned) == mix)
    }

    @Test("A construction's new glass reaches its panes, its windows' mixes and each side")
    func construction() {
        var construction = EnvelopeConstruction.assumed(objectID: UUID())
        construction.glazing = .apartments
        construction.sideGlazing = ["x+": .commercial]
        let weatheredPane = construction.pane(a: 0.9, b: 1.4).response(pressures: Self.pulse(8e3), step: 1e-4)
        construction.setGlassCondition(.newOrTested)
        #expect(construction.glassCondition == .newOrTested && !construction.hasPlainGlass)
        #expect(construction.glazing?.condition == .newOrTested)
        #expect(construction.sideGlazing?["x+"]?.condition == .newOrTested)
        #expect(construction.facade(axis: 0, outward: 1).glassCondition == .newOrTested)
        let newPane = construction.pane(a: 0.9, b: 1.4).response(pressures: Self.pulse(8e3), step: 1e-4)
        let cracked = { (r: SDOFResponse) in r.lostResistanceAt ?? .infinity }
        #expect(cracked(newPane) > cracked(weatheredPane))
        construction.setGlassCondition(.asDesigned)
        #expect(construction.glassCondition == nil && construction.glazing == .apartments)
        #expect(construction.sideGlazing?["x+"] == .commercial)
    }

    @Test("Protective design may re-glaze a side with new glass")
    func reglazed() {
        let option = ProtectionModel.Glazing(name: "new glass", kind: .reglazed, costPerM2: 3)
        let mix = GlazingMix.apartments.with(GlazingMix.Glass(toughened: true))
        let applied = option.applied(to: mix)
        #expect(applied.glass == nil && applied.condition == .newOrTested)
        #expect(applied.panes == mix.panes && applied.glazedFraction == mix.glazedFraction)
    }

    @Test("A scene with new glass carries its standing")
    func standing() throws {
        let layout = try DistrictLayoutTests.layout()
        var (scene, _) = try layout.scene(halfSide: layout.halfSide(radius: 150, cellSize: 4), cellSize: 4)
        #expect(!StandingInputs(scenario: scene, cellSize: 4).options.contains(.newGlass))
        let object = try #require(scene.envelopeObjects.first)
        var construction = scene.envelopeConstruction(for: object.id)
        construction.setGlassCondition(.newOrTested)
        scene.setEnvelopeConstruction(construction)
        #expect(StandingInputs(scenario: scene, cellSize: 4).options.contains(.newGlass))
    }
}
