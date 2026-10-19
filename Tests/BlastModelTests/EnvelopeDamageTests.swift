import Foundation
import Testing

@testable import BlastModel

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
            // A pane under a longer pulse, which it outlasts a while (the large-deflection pane breaks at about 3 ms).
            load("p", .pane, owner: owner, region: pane, axis: 1, outer: pulse(70e3, over: 0.01)),
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

    @Test(
        "UFC 3-340-02 Example 2A-12's room fills by equation 2-31 as the UFC works it, and the orifice fill near it"
    )
    func leakage() {
        // Figure 2-235 at the example's first difference, 3.5 psi: it reads 8.75 psi ft/ms.
        let psi = 6_894.757
        let first =
            EnvelopeDamageAssessment.leakageCoefficient(difference: 3.5 * psi) / (psi * 0.3048 * 1_000)
        #expect(abs(first - 8.75) < 0.2)
        #expect(EnvelopeDamageAssessment.leakageCoefficient(difference: -3.5 * psi) < 0)
        // A 3 by 3 ft opening into 1,000 ft³ under 3.5 psi falling to nothing over 55 ms. The
        // UFC's table, in 5.5 ms steps, peaks at 1.41 psi near 30 ms; in fine steps it is 1.29.
        let bin = 5e-4
        let outer = (0..<280).map { max(3.5 * (1 - Double($0) * bin / 0.055), 0) * psi }
        let opening = [(area: 9 * 0.3048 * 0.3048, opens: 0.0, outer: outer)]
        let volume = 1_000 * 0.3048 * 0.3048 * 0.3048
        let ufc = EnvelopeDamageAssessment.leakageFill(volume: volume, openings: opening, bin: bin)
        #expect(abs(ufc.peak / psi - 1.29) < 0.04, "\(ufc.peak / psi) psi")
        let orifice = EnvelopeDamageAssessment.fill(volume: volume, openings: opening, bin: bin)
        #expect(orifice.peak / ufc.peak > 1 && orifice.peak / ufc.peak < 1.25, "\(orifice.peak / psi) psi")
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

    @Test("Stone carrying the storeys above rocks against their weight and holds where a top storey falls")
    func overburden() {
        let owner = UUID()
        let stone = EnvelopeConstruction(
            objectID: owner, walls: .unreinforcedMasonry, wallThicknessM: 0.5, source: .user, detail: "")
        // A façade strip a storey tall at the foot, in the middle and at the top of a building 9 m
        // tall, under the same 40 kPa, 0.2 s pulse.
        func strip(_ z: Float) -> EnvelopeComponentLoad {
            load(
                "s\(z)", .facade, owner: owner, region: Box(min: SIMD3(0, 0, z), max: SIMD3(6, 0.5, z + 3)),
                axis: 1, outer: pulse(40e3, over: 0.2, total: 0.5))
        }
        let foot = EnvelopeDamageAssessment.assess(strip(0), construction: stone, buildingTop: 9)
        let top = EnvelopeDamageAssessment.assess(strip(6), construction: stone, buildingTop: 9)
        let unloaded = EnvelopeDamageAssessment.assess(strip(0), construction: stone)
        #expect(top?.levels == .failed ... .failed && unloaded?.levels == .failed ... .failed)
        #expect(foot.map { $0.levels.upperBound < .failed } == true, "\(String(describing: foot?.levels))")
        // Its rocking resistance, 8 P t / h² with P the 6 m of stone above.
        var masonry = StructureMaterial.masonry
        masonry.steel = nil
        let p = Double(masonry.density) * 9.81 * 0.5 * 6
        let system = EnvelopePanel.unreinforcedMasonry(
            thickness: 0.5, material: masonry, a: 3, b: 6, axialLoad: p, height: 3)
        #expect(abs(system.backbone[0].y - 8 * p * 0.5 / 9) < 1e-6 * system.backbone[0].y)
        // The whole building, assessed together, gives its foot the stone above.
        let building = EnvelopeDamageAssessment.assess(
            loads: [strip(0), strip(3), strip(6)], constructions: { _ in stone })
        #expect(
            building.first?.components.filter { $0.kind != .pane }.map(\.levels.upperBound)
                == [.heavy, .failed, .failed])
    }

    @Test("A façade strip holds a window where nothing says otherwise, which breaks under a strong load")
    func facadeGlazing() {
        let owner = UUID()
        let strip = Box(min: SIMD3(0, 0, 0), max: SIMD3(6, 0.5, 3))
        func building(_ peak: Double, pane: SIMD2<Float>? = nil) -> EnvelopeBuildingDamage? {
            var construction = EnvelopeConstruction.assumed(objectID: owner)
            construction.facadePaneM = pane
            return EnvelopeDamageAssessment.assess(
                loads: [
                    load("f", .facade, owner: owner, region: strip, axis: 1, outer: pulse(peak, over: 0.1))
                ],
                constructions: { _ in construction }
            ).first
        }
        let strong = building(8e3)
        let weak = building(500)
        #expect(strong?.panes == 1 && strong?.panesBroken == 1 && strong?.firstPaneBrokenAtS != nil)
        #expect(weak?.panes == 1 && weak?.panesBroken == 0)
        // Glass broken alone colours the building so.
        #expect(strong.map { EnvelopeDamageColour.code($0) } == 2)
        #expect(building(8e3, pane: .zero)?.panes == 0)
        // A larger pane breaks under less.
        let medium = building(3e3)
        let large = building(3e3, pane: SIMD2(2, 2.5))
        #expect((medium?.panesBroken ?? 1) <= (large?.panesBroken ?? 0))
    }

    @Test("A façade strip spans its storey however tall the cells cut it")
    func storeySpan() {
        let owner = UUID()
        let stone = EnvelopeConstruction(
            objectID: owner, walls: .unreinforcedMasonry, wallThicknessM: 0.5, source: .user, detail: "")
        // The same storey of a 9 m building as 3 m cells cut it and as 4 m cells do.
        func strip(_ height: Float) -> EnvelopeComponentLoad {
            load(
                "s", .facade, owner: owner, region: Box(min: SIMD3(0, 0, 0), max: SIMD3(6, 0.5, height)),
                axis: 1,
                outer: pulse(30e3, over: 0.2, total: 0.5))
        }
        let three = EnvelopeDamageAssessment.assess(strip(3), construction: stone, buildingTop: 9)
        let four = EnvelopeDamageAssessment.assess(strip(4), construction: stone, buildingTop: 9)
        #expect(strip(4).panelHeight == 3 && strip(2).panelHeight == 2)
        #expect(
            three?.levels == four?.levels && three?.shortSpanM == four?.shortSpanM,
            "\(String(describing: three?.levels)) \(String(describing: four?.levels))")
    }

    @Test("The view's shader draws the same six colours as the palette")
    func shaderPalette() throws {
        let shader = try String(
            contentsOf: URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appending(path: "Sources/BlastRender/Shaders/Render.metal"),
            encoding: .utf8)
        for colour in EnvelopeDamageColour.palette {
            let text = String(format: "float3(%.3ff, %.3ff, %.3ff)", colour.x, colour.y, colour.z)
            #expect(shader.contains(text), "\(text) not in Render.metal")
        }
        #expect(EnvelopeDamageColour.labels.count == EnvelopeDamageColour.palette.count)
        for colour in EnvelopeChanceColour.ramp {
            let text = String(format: "float3(%.3ff, %.3ff, %.3ff)", colour.x, colour.y, colour.z)
            #expect(shader.contains(text), "\(text) not in Render.metal")
        }
    }

    @Test("A building's sides' glass chances go to the view as one code and come back by side")
    func chanceCode() {
        let code = EnvelopeChanceColour.code([
            (axis: 0, outward: -1, chance: 0.05), (axis: 0, outward: 1, chance: 1),
            (axis: 1, outward: 1, chance: 0.5),
        ])
        #expect(code >= EnvelopeChanceColour.first && code < 1 << 24)
        #expect(EnvelopeChanceColour.eighth(code: code, axis: 0, outward: -1) == 0)
        #expect(EnvelopeChanceColour.eighth(code: code, axis: 0, outward: 1) == 7)
        #expect(EnvelopeChanceColour.eighth(code: code, axis: 1, outward: -1) == 0)
        #expect(EnvelopeChanceColour.eighth(code: code, axis: 1, outward: 1) == 4)
    }
}
