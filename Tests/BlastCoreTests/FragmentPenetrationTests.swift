import Foundation
import Testing
import simd

@testable import BlastCore

@Suite("Fragments penetrating what they strike")
struct FragmentPenetrationTests {
    let ounce = FragmentPenetration.ounce
    let inch = FragmentPenetration.inch
    let foot = FragmentPenetration.foot
    let psi = FragmentPenetration.psi

    @Test("UFC 3-340-02's Example 4A-10: 30 oz at 3,500 fps into 18 in of 4,000 psi concrete is stopped")
    func example4A10() {
        let result = FragmentPenetration.concrete(
            mass: 30 * ounce, speed: 3_500 * foot, thickness: 18 * inch, strength: 4_000 * psi)
        // Its X'f 10.15 in and Tpf 15.20 in (from the chart's 14.5 in; the equation gives 14.4).
        #expect(abs(result.depthM! / inch / 10.15 - 1) < 0.01)
        #expect(abs(result.perforationThicknessM! / inch / 15.20 - 1) < 0.01)
        #expect(result.outcome == .stopped && result.residualSpeed == 0)
    }

    @Test("Example 4A-11: 20 oz at 4,700 fps through 12 in of 4,500 psi concrete keeps 0.55 of its speed")
    func example4A11() {
        let result = FragmentPenetration.concrete(
            mass: 20 * ounce, speed: 4_700 * foot, thickness: 12 * inch, strength: 4_500 * psi)
        #expect(abs(result.depthM! / inch / 13.0 - 1) < 0.01)
        #expect(abs(result.perforationThicknessM! / inch / 18.1 - 1) < 0.01)
        #expect(result.outcome == .perforated)
        #expect(abs(result.residualSpeed / (4_700 * foot) - 0.55) < 0.01)
    }

    @Test("Example 4A-12: an armour-piercing 40 oz at 3,000 fps into 19 in of 5,000 psi concrete spalls it")
    func example4A12() {
        let result = FragmentPenetration.concrete(
            mass: 40 * ounce, speed: 3_000 * foot, thickness: 19 * inch, strength: 5_000 * psi,
            metal: .armourPiercing)
        #expect(abs(result.perforationThicknessM! / inch / 17.3 - 1) < 0.01)
        #expect(abs(result.spallThicknessM! / inch / 20.3 - 1) < 0.01)
        #expect(result.outcome == .spalled)
    }

    @Test("UFC's steel plate equation and THOR's mild steel agree on the speed to perforate, within 5%")
    func steelMethodsAgree() {
        // A 1 oz fragment on a quarter-inch mild steel plate, THOR's area that of UFC's standard
        // fragment's cross-section.
        let mass = 1 * ounce
        let thickness = 0.25 * inch
        let d = FragmentPenetration.standardDiameter(ounces: 1) * inch
        let area = Float.pi * d * d / 4
        func through(_ speed: Float) -> (ufc: Bool, thor: Bool) {
            (
                FragmentPenetration.steelPlate(mass: mass, speed: speed, thickness: thickness).outcome
                    == .perforated,
                FragmentPenetration.thor(
                    .mildSteel, mass: mass, area: area, speed: speed, thickness: thickness
                )
                .outcome == .perforated
            )
        }
        // UFC's critical speed 1,154 fps; THOR's 1,130.
        #expect(through(1_100 * foot) == (false, false))
        #expect(through(1_200 * foot) == (true, true))
        // Beyond, both keep most of the speed and agree within 10%.
        let ufc = FragmentPenetration.steelPlate(mass: mass, speed: 3_000 * foot, thickness: thickness)
        let thor = FragmentPenetration.thor(
            .mildSteel, mass: mass, area: area, speed: 3_000 * foot, thickness: thickness)
        #expect(abs(ufc.residualSpeed / thor.residualSpeed - 1) < 0.1)
        // A slanted plate is harder to get through.
        let slanted = FragmentPenetration.thor(
            .mildSteel, mass: mass, area: area, speed: 1_200 * foot, thickness: thickness, obliquity: 0.8)
        #expect(slanted.outcome == .stopped)
    }

    @Test("Glass is broken past Kim et al.'s momentum, whatever the mass")
    func glass() {
        #expect(FragmentPenetration.glass(mass: 0.0021, speed: 34).outcome == .stopped)
        #expect(FragmentPenetration.glass(mass: 0.0021, speed: 41).outcome == .perforated)
        #expect(FragmentPenetration.glass(mass: 0.00415, speed: 21).outcome == .perforated)
        let shard = FragmentPenetration.glass(mass: 0.001, speed: 500)
        #expect(shard.outcome == .perforated && shard.residualSpeed == 500)
    }

    @Test("A scene says what fragments strike: a structure's concrete, an envelope's walls and panes")
    func sceneTargets() throws {
        var scene = Scenario(
            name: "Targets", domainSize: SIMD3(10, 6, 4), boxes: [Box(min: .zero, max: SIMD3(1, 1, 1))],
            charge: Charge(mass: 10, position: SIMD3(2, 3, 1)))
        scene.objects.append(
            SceneObject(
                name: "Wall",
                representation: .deformable(
                    StructureModel(
                        solids: [Box(min: SIMD3(4, 1.5, 0), max: SIMD3(4.25, 4.5, 2.5))],
                        material: .reinforcedConcrete,
                        elementSize: 0.125, fixedBase: true))))
        try scene.addEnvelopeObject(
            BuildingEnvelope(
                solids: [Box(min: SIMD3(6.5, 1, 0), max: SIMD3(7, 5, 3))],
                panes: [Box(min: SIMD3(6.4, 2, 1), max: SIMD3(6.5, 3, 2))]),
            name: "Envelope")
        let owner = try #require(scene.envelopeObjects.first?.id)
        let fragments = FragmentScene(scene)
        #expect(fragments.structureTargets == [FragmentTarget(material: .concrete, strength: 30e6)])
        let blocks = try #require(fragments.blockTargets)
        #expect(blocks.count == fragments.blocks.count && blocks[0] == nil)
        #expect(
            blocks[1] == FragmentTarget(material: .concrete, thickness: 0.2, strength: 30e6, owner: owner))
        #expect(blocks[2] == FragmentTarget(material: .glass, thickness: 0.006, owner: owner, pane: 0))
    }

    @Test("A fragment striking a judged block carries what it did, and which building and pane")
    func judgedImpacts() {
        let owner = UUID()
        let wall = Box(min: SIMD3(6.5, 1, 0), max: SIMD3(7, 5, 3))
        let pane = Box(min: SIMD3(6.4, 6, 1), max: SIMD3(6.5, 7, 2))
        let edge: Float = cbrt(0.01 / 7850)
        var cloud = FragmentCloud(
            particles: [
                .init(
                    position: SIMD3(0, 3, 1.5), velocity: SIMD3(1000, 0, 0), mass: 0.01,
                    area: 1.5 * edge * edge),
                .init(
                    position: SIMD3(0, 6.5, 1.5), velocity: SIMD3(1000, 0, 0), mass: 0.01,
                    area: 1.5 * edge * edge),
            ], blocks: [wall, pane],
            blockTargets: [
                FragmentTarget(material: .concrete, thickness: 0.2, strength: 30e6, owner: owner),
                FragmentTarget(material: .glass, thickness: 0.006, owner: owner, pane: 0),
            ])
        cloud.land(in: Primitive(density: 1.2, pressure: 101_325))
        let walled = cloud.impacts.first { $0.fragment == 0 }!
        let glazed = cloud.impacts.first { $0.fragment == 1 }!
        #expect(walled.surface == "block 0" && walled.objectID == owner && walled.pane == nil)
        #expect(
            walled.penetration
                == FragmentPenetration.concrete(
                    mass: 0.01, speed: walled.speed, thickness: 0.2, strength: 30e6))
        #expect(walled.penetration?.outcome == .stopped)
        #expect(glazed.objectID == owner && glazed.pane == 0 && glazed.penetration?.outcome == .perforated)
    }

    @Test("A pane a fragment holes before the blast breaks then, and its building counts it")
    func paneHoledBeforeBlast() throws {
        let owner = UUID()
        // Still for 5 ms, then 1 kPa, which a 6 mm pane a metre square holds.
        let net = Array(repeating: 0.0, count: 50) + Array(repeating: 1_000.0, count: 50)
        let pane = EnvelopeComponentLoad(
            id: "\(owner.uuidString)/pane/0.0", owner: owner, kind: .pane,
            region: Box(min: SIMD3(0, 0, 1), max: SIMD3(0.006, 1, 2)), axis: 0, binS: 1e-4, outerPa: net,
            innerPa: [])
        let construction = EnvelopeConstruction.assumed(objectID: owner)
        #expect(EnvelopeDamageAssessment.assess(pane, construction: construction)?.failedAtS == nil)
        func strike(_ outcome: PenetrationResult.Outcome, pane: Int?) -> FragmentImpact {
            FragmentImpact(
                fragment: 0, time: 0.002, position: .zero, speed: 900, energy: 4_000, surface: "block 1",
                objectID: owner,
                penetration: PenetrationResult(
                    outcome: outcome, residualSpeed: 0, method: "test"), pane: pane)
        }
        let building = try #require(
            EnvelopeDamageAssessment.assess(
                loads: [pane], constructions: { _ in construction },
                strikes: [
                    strike(.perforated, pane: 0), strike(.spalled, pane: nil), strike(.stopped, pane: nil),
                ]
            ).first)
        let damage = try #require(building.components.first)
        #expect(damage.failedAtS == 0.002 && damage.fragmentBrokeAtS == 0.002)
        #expect(abs(damage.blastArrivalS! - 0.005) < 1e-9)
        #expect(building.panesBrokenByFragments == 1 && building.panesBrokenBeforeBlast == 1)
        #expect(building.wallStrikes == 2 && building.wallsSpalled == 1 && building.wallsPerforated == 0)
        // Pushed in from rest by the kilopascal that follows: 5 ms of it on 15 kg/m².
        let glazing = try #require(damage.glazing)
        #expect(abs(glazing.speedMS - 1_000 * 0.005 / 15) < 0.01 && glazing.condition == .threeA)
    }

    @Test("Every hole through an envelope before the run, in time order, each the fragments' area")
    func envelopeHoles() throws {
        var scene = Scenario(
            name: "Glazed", domainSize: SIMD3(16, 20, 6), boxes: [],
            charge: Charge(mass: 1, position: SIMD3(7, 2, 1.6)))
        try scene.addEnvelopeObject(
            EnvelopeVentingTests().building(origin: SIMD3(4, 7, 0), cutOpening: true), name: "Building")
        let owner = scene.envelopeObjects[0].id
        // Walls a centimetre thick, which the fragments go through.
        var construction = EnvelopeConstruction.assumed(objectID: owner)
        construction.wallThicknessM = 0.01
        scene.setEnvelopeConstruction(construction)
        var spec = FragmentSpec()
        spec.casingMass = 1
        spec.count = 4_000
        spec.tracers = 0
        spec.axis = SIMD3(0, 0, 1)
        let holes = FragmentCloud.envelopeHoles(
            spec: spec, scene: FragmentScene(scene), density: 1.225, pressure: 101_325, until: 0.03)
        let walls = holes.filter { $0.pane == nil }
        let panes = holes.filter { $0.pane == 0 }
        #expect(!walls.isEmpty && !panes.isEmpty && holes.allSatisfy { $0.owner == owner && $0.areaM2 > 0 })
        #expect(zip(holes, holes.dropFirst()).allSatisfy { $0.time <= $1.time })
        // The panes' first holes are `paneHoles`' times.
        let first = try #require(
            FragmentCloud.paneHoles(
                spec: spec, scene: FragmentScene(scene), density: 1.225, pressure: 101_325, until: 0.03
            ).values.first)
        #expect(first == panes.map(\.time).min())
        // A hole is a fragment's presented area: a 0.25 g steel cube's is under a square centimetre.
        #expect(holes.allSatisfy { $0.areaM2 < 1e-3 })
    }
}
