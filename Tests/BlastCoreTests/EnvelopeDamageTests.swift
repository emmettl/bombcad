import Foundation
import Testing

@testable import BlastCore

/// One-way damage of envelope components, from loads, by construction.
@Suite("Envelope damage")
struct EnvelopeDamageTests {
    /// A triangular pulse as mean pressures per 0.1 ms bin.
    func pulse(_ peak: Double, over duration: Double, total: Double = 0.15) -> [Double] {
        (0..<Int(total / 1e-4)).map { index in
            let t = (Double(index) + 0.5) * 1e-4
            return t < duration ? peak * (1 - t / duration) : 0
        }
    }

    func load(
        _ id: String, _ kind: EnvelopeComponentLoad.Kind, owner: UUID, region: Box, axis: Int, outer: [Double]
    )
        -> EnvelopeComponentLoad
    {
        EnvelopeComponentLoad(
            id: id, owner: owner, kind: kind, region: region, axis: axis, binS: 1e-4, outerPa: outer,
            innerPa: [])
    }

    @Test("Concrete is judged on ASCE/SEI 59-11's limits for single-reinforced slabs")
    func levels() {
        #expect(EnvelopeDamageLevel.concrete(ductility: 0.9, rotationDeg: 0.1) == .none)
        #expect(EnvelopeDamageLevel.concrete(ductility: 1.5, rotationDeg: 1.9) == .moderate)
        #expect(EnvelopeDamageLevel.concrete(ductility: 5, rotationDeg: 4) == .heavy)
        #expect(EnvelopeDamageLevel.concrete(ductility: 9, rotationDeg: 9) == .hazardous)
        #expect(EnvelopeDamageLevel.concrete(ductility: 20, rotationDeg: 11) == .failed)
    }

    @Test("A building's walls give a range of levels, its panes break, and its room fills through them")
    func building() {
        let owner = UUID()
        let wall = Box(min: SIMD3(0, 0, 0), max: SIMD3(6, 0.2, 4))
        let pane = Box(min: SIMD3(2, 0.1, 1), max: SIMD3(3.5, 0.106, 2.25))
        let loads = [
            // The facing wall of the isolated building at 200 kg: about 350 kPa over 2 ms.
            load("w", .wall, owner: owner, region: wall, axis: 1, outer: pulse(350e3, over: 0.002)),
            load("p", .pane, owner: owner, region: pane, axis: 1, outer: pulse(70e3, over: 0.004)),
            load("q", .pane, owner: owner, region: pane, axis: 1, outer: pulse(500, over: 0.004)),
        ]
        let damage = EnvelopeDamageAssessment.assess(
            loads: loads, constructions: { .assumed(objectID: $0) }, rooms: [owner: 5.6 * 5.6 * 3.8])
        let building = try! #require(damage.first)
        let facing = try! #require(building.components.first { $0.id == "w" })
        // Fixed edges turn it less than simply supported; both yield.
        #expect(facing.rotationDeg.lowerBound < facing.rotationDeg.upperBound)
        #expect(facing.levels.lowerBound >= .moderate)
        #expect(building.structuralLevels == facing.levels)
        #expect(building.panes == 2 && building.panesBroken == 1)
        #expect((building.firstPaneBrokenAtS ?? 1) < 0.01)
        #expect(building.insidePeakPa > 100 && building.insideImpulsePaS > 0)
    }

    @Test("A sealed room keeps ambient, and a room open to a held pressure comes up to it")
    func fill() {
        let none = EnvelopeDamageAssessment.fill(volume: 100, openings: [], bin: 1e-4)
        #expect(none.peak == 0)
        let held = EnvelopeDamageAssessment.fill(
            volume: 10, openings: [(area: 1, opens: 0, outer: Array(repeating: 5e3, count: 5_000))], bin: 1e-4
        )
        #expect(abs(held.peak / 5e3 - 1) < 0.02)
    }

    @Test("Brick cracks, then falls once its deflection passes its thickness")
    func masonry() {
        let owner = UUID()
        let wall = Box(min: SIMD3(0, 0, 0), max: SIMD3(6, 0.215, 4))
        let brick = EnvelopeConstruction(
            objectID: owner, walls: .unreinforcedMasonry, source: .user, detail: "")
        let light = EnvelopeDamageAssessment.assess(
            load("w", .wall, owner: owner, region: wall, axis: 1, outer: pulse(3e3, over: 0.01)),
            construction: brick)
        let heavy = EnvelopeDamageAssessment.assess(
            load("w", .wall, owner: owner, region: wall, axis: 1, outer: pulse(300e3, over: 0.005)),
            construction: brick)
        #expect(light?.levels == .heavy ... .heavy)
        #expect(heavy?.levels == .failed ... .failed && heavy?.failedAtS != nil)
    }
}
