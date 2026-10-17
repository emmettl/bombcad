import Foundation
import Testing

@testable import BlastCore

/// Freestanding walls in envelope damage: the cantilever systems against their closed forms, and
/// which walls are taken as standing free.
@Suite("Envelope cantilevers")
struct EnvelopeCantileverTests {
    @Test("A concrete cantilever's resistance is 2 M / L² and its stiffness 8 E I / L⁴")
    func concreteCantilever() {
        let material = StructureMaterial.reinforcedConcrete
        let height = 2.0
        let wall = EnvelopePanel.reinforcedConcreteCantilever(
            thickness: 0.2, depth: 0.15, steelArea: 500e-6, material: material, height: height)
        // The base's moment capacity on dynamic strengths, as UFC §4 takes it.
        let force = 500e-6 * Double(material.steel!.yieldStress) * EnvelopePanel.reinforcementFlexureIncrease
        let block =
            force / (0.85 * Double(material.compressiveStrength) * EnvelopePanel.concreteFlexureIncrease)
        let moment = force * (0.15 - block / 2)
        #expect(abs(wall.ultimateResistance / (2 * moment / (height * height)) - 1) < 1e-9)
        #expect(wall.loadMassElastic == 0.65 && wall.loadMassPlastic == 0.66)
        // Its span is twice the height, so the support rotation is atan(top / L).
        #expect(wall.span == 2 * height)
        // A load held forever below the resistance deflects it twice as far as statically.
        let p = 0.5 * wall.ultimateResistance
        let response = wall.response(pressures: Array(repeating: p, count: 4000), step: 1e-4)
        #expect(abs(response.peakDeflection / (2 * p / wall.stiffness) - 1) < 0.01)
    }

    @Test("A brick wall stood free rocks under its weight and falls once its top passes its thickness")
    func masonryCantilever() {
        var brick = StructureMaterial.masonry
        brick.steel = nil
        let t = 0.1025
        let height = 2.0
        let unbonded = EnvelopePanel.unreinforcedMasonryCantilever(
            thickness: t, material: brick, height: height, bondedBase: false)
        // Rocking about its toe: at most ρ g t² / L, nothing once the top is a thickness out.
        let weight = Double(brick.density) * 9.81 * t
        #expect(unbonded.ultimateResistance <= weight * t / height + 1e-9)
        #expect(unbonded.ultimateResistance > 0.95 * weight * t / height)
        #expect(unbonded.backbone.last! == SIMD2(t, 0))
        // Bonded, it first holds to its cracking moment, more than rocking gives.
        let bonded = EnvelopePanel.unreinforcedMasonryCantilever(
            thickness: t, material: brick, height: height)
        #expect(bonded.ultimateResistance > unbonded.ultimateResistance)
        // A short push well under the rocking resistance's impulse leaves it standing; a strong
        // one throws it over.
        let weak = unbonded.response(pressures: Array(repeating: 50, count: 10), step: 1e-4, tail: 100)
        #expect(weak.lostResistanceAt == nil)
        let strong = unbonded.response(
            pressures: Array(repeating: 20_000, count: 100), step: 1e-4, tail: 1000)
        #expect(strong.lostResistanceAt != nil)
    }

    @Test("A wall stands free unless a slab carried by another wall holds its top")
    func freestanding() throws {
        let owner = UUID()
        func walls(_ envelope: BuildingEnvelope) -> [EnvelopeComponent] {
            envelope.components(owner: owner).filter { $0.kind == .wall }
        }
        func freestanding(_ component: EnvelopeComponent) -> Bool {
            EnvelopeComponentLoad(
                id: component.id, owner: owner, kind: .wall, region: component.region, axis: component.axis,
                binS: 1e-4, outerPa: [], innerPa: [], supportEdges: component.supportEdges
            ).isFreestanding
        }
        // A wall on the ground alone.
        let alone = Box(min: SIMD3(0, 0, 0), max: SIMD3(0.2, 4, 2))
        #expect(walls(try BuildingEnvelope(solids: [alone], openings: [])).allSatisfy(freestanding))
        // Under a cap it carries alone, it still stands free.
        let cap = Box(min: SIMD3(-0.5, 0, 2), max: SIMD3(0.7, 4, 2.4))
        #expect(walls(try BuildingEnvelope(solids: [alone, cap], openings: [])).allSatisfy(freestanding))
        // Two walls under a roof spanning between them are held at their tops.
        let other = Box(min: SIMD3(5.8, 0, 0), max: SIMD3(6, 4, 2))
        let roof = Box(min: SIMD3(0, 0, 2), max: SIMD3(6, 4, 2.2))
        #expect(
            !walls(try BuildingEnvelope(solids: [alone, other, roof], openings: [])).contains(
                where: freestanding))
    }

    @Test(
        "A one-way strip resists 8 M / L² simply supported and twice that fixed, and a wall held top and bottom spans one way"
    )
    func oneWay() throws {
        let material = StructureMaterial.reinforcedConcrete
        let simple = EnvelopePanel.reinforcedOneWay(
            thickness: 0.2, depth: 0.1, steelArea: 600e-6, material: material, span: 3)
        let fixed = EnvelopePanel.reinforcedOneWay(
            thickness: 0.2, depth: 0.1, steelArea: 600e-6, material: material, span: 3, edges: .fixed)
        let force = 600e-6 * Double(material.steel!.yieldStress) * EnvelopePanel.reinforcementFlexureIncrease
        let block =
            force / (0.85 * Double(material.compressiveStrength) * EnvelopePanel.concreteFlexureIncrease)
        let moment = force * (0.1 - block / 2)
        #expect(abs(simple.ultimateResistance / (8 * moment / 9) - 1) < 1e-9)
        #expect(abs(fixed.ultimateResistance / simple.ultimateResistance - 2) < 1e-9)
        #expect(abs(fixed.stiffness / simple.stiffness - 5) < 1e-9)
        #expect(simple.loadMassElastic == 0.78 && simple.loadMassPlastic == 0.66)
        // A wall between a floor and a slab with free sides spans one way, over its height.
        let load = EnvelopeComponentLoad(
            id: "w", owner: UUID(), kind: .wall, region: Box(min: SIMD3(0, 0, 0), max: SIMD3(0.2, 5, 3)),
            axis: 0,
            binS: 1e-4, outerPa: [], innerPa: [], supportEdges: [false, false, true, true])
        #expect(load.oneWaySpan == 3)
        let panel = EnvelopeComponentLoad(
            id: "p", owner: UUID(), kind: .wall, region: load.region, axis: 0, binS: 1e-4, outerPa: [],
            innerPa: [], supportEdges: [true, true, true, true])
        #expect(panel.oneWaySpan == nil)
    }

    @Test(
        "A construction saved before bars, blockwork and caps opens with their defaults, and they reach the systems"
    )
    func construction() throws {
        let owner = UUID()
        // A construction as projects saved it before 17 October 2026.
        let old = """
            {"objectID":"\(owner.uuidString)","walls":"reinforcedConcrete","wallThicknessM":0.2,
             "roof":"reinforcedConcrete","roofThicknessM":0.2,"reinforcementRatio":0.003,
             "glassThicknessM":0.006,"source":"assumed","detail":"assumed"}
            """
        let decoded = try JSONDecoder().decode(EnvelopeConstruction.self, from: Data(old.utf8))
        #expect(decoded.barsInBothFaces == nil && decoded.capMassKgPerM == nil)
        let central = decoded.wallBars(thickness: 0.2)
        #expect(abs(central.depth - 0.1) < 1e-9 && abs(central.steelArea - 0.0006) < 1e-9)
        // Bars in both faces: one face's share at the cover's depth.
        var built = decoded
        built.barsInBothFaces = true
        built.barCoverM = 0.03
        let section = built.wallBars(thickness: 0.2)
        #expect(abs(section.depth - 0.17) < 1e-9 && abs(section.steelArea - 0.0003) < 1e-9)
        // Hollow blockwork: the concrete block's strength and density.
        built.walls = .reinforcedBlockwork
        built.blockworkGrouted = false
        #expect(built.wallMaterial.compressiveStrength == 3e6 && built.wallMaterial.density == 1400)
        // A freestanding wall under a cap: the cap's mass slows it.
        let load = EnvelopeComponentLoad(
            id: "\(owner.uuidString)/wall/0.0", owner: owner, kind: .wall,
            region: Box(min: SIMD3(0, 0, 0), max: SIMD3(0.4, 4, 2)), axis: 0, binS: 1e-4,
            outerPa: Array(repeating: 2e6, count: 5), innerPa: Array(repeating: 0, count: 5),
            supportEdges: [false, false, true, false])
        var bare = decoded
        bare.wallThicknessM = 0.4
        var capped = bare
        capped.capMassKgPerM = 1000
        let free = try #require(EnvelopeDamageAssessment.assess(load, construction: bare))
        let held = try #require(EnvelopeDamageAssessment.assess(load, construction: capped))
        #expect(free.cantilever == true)
        #expect(held.rotationDeg.upperBound < free.rotationDeg.upperBound)
    }
}
