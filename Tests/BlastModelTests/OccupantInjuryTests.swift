import Foundation
import Testing

@testable import BlastModel

@Suite("People in the scene: occupants and the people hurt")
struct OccupantInjuryTests {
    /// A 20 × 10 m block 12 m high (four storeys, 800 m² of floor), `distance` m east of the charge.
    func scene(distance: Float = 100, tag: String? = nil) throws -> (Scenario, UUID) {
        var scene = Scenario(
            name: "People", domainSize: SIMD3(400, 200, 60), boxes: [],
            charge: Charge(mass: 100, position: SIMD3(50, 100, 0)))
        let x = 50 + distance
        let id = try scene.addEnvelopeObject(
            BuildingEnvelope(solids: [Box(min: SIMD3(x, 95, 0), max: SIMD3(x + 20, 105, 12))]), name: "Block")
        var construction = EnvelopeConstruction.assumed(objectID: id)
        construction.use = BuildingUse(mapTag: tag)
        scene.envelopeConstructions = [construction]
        return (scene, id)
    }

    func sides(_ id: UUID, broken: Double, blownOut: Double = 0, distance: Double = 100)
        -> [FacadeLoadSurrogate.SideGlass]
    {
        [(0, -1), (0, 1), (1, -1), (1, 1)].map { axis, outward in
            FacadeLoadSurrogate.SideGlass(
                owner: id, axis: axis, outward: outward, distanceM: distance, someBroken: broken > 0 ? 1 : 0,
                blownOut: blownOut, fractionBroken: broken, thrownPast3b: 0)
        }
    }

    @Test("Map tags give uses; an untagged building has none")
    func tags() {
        #expect(BuildingUse(mapTag: "apartments") == .residential)
        #expect(BuildingUse(mapTag: "office") == .office)
        #expect(BuildingUse(mapTag: "school") == .education)
        #expect(BuildingUse(mapTag: "warehouse") == .industrial)
        #expect(BuildingUse(mapTag: "ruins") == .unoccupied)
        #expect(BuildingUse(mapTag: "yes") == nil)
        #expect(BuildingUse(mapTag: nil) == nil)
    }

    @Test("Kummer's glass injury through its own points: 1% broken 0.1%, half 10%, all of them everyone")
    func kummer() {
        #expect(abs(OccupantInjury.glassHurt(broken: 0.01) - 0.001) < 1e-9)
        #expect(abs(OccupantInjury.glassHurt(broken: 0.5) - 0.1) < 1e-9)
        #expect(abs(OccupantInjury.glassHurt(broken: 1) - 1) < 1e-9)
        #expect(OccupantInjury.glassHurt(broken: 0) == 0)
        #expect(OccupantInjury.glassHurt(broken: 0.25) < 0.1)
    }

    @Test("Eisenberg's eardrum probit: half at UFC's 15 psi, a few in a hundred at its 5 psi threshold")
    func eardrums() {
        #expect(abs(OccupantInjury.eardrumRupture(pa: BlastInjury.eardrum50Pa) - 0.5) < 0.01)
        let threshold = OccupantInjury.eardrumRupture(pa: BlastInjury.eardrumThresholdPa)
        #expect(threshold > 0.01 && threshold < 0.1)
    }

    @Test("Occupants by floor area, use and time; the untagged take the assumed use")
    func occupants() throws {
        let (office, officeID) = try scene(tag: "office")
        var assumptions = OccupantInjury.Assumptions()
        assumptions.time = .workday
        let day = OccupantInjury.estimate(
            scene: office, glass: sides(officeID, broken: 0), structure: [], charge: office.charge.position,
            mass: 100,
            assumptions: assumptions)
        let building = try #require(day.buildings.first)
        #expect(building.floorAreaM2 == 800)
        #expect(!building.useAssumed)
        // 800 m² at 12 m² a person, 0.98 present, 1% of them outside.
        #expect(abs(building.occupants + building.outdoors - 800 / 12 * 0.98) < 1e-6)
        #expect(abs(building.outdoors - 800 / 12 * 0.98 * 0.01) < 1e-6)
        assumptions.time = .night
        let night = OccupantInjury.estimate(
            scene: office, glass: sides(officeID, broken: 0), structure: [], charge: office.charge.position,
            mass: 100,
            assumptions: assumptions)
        #expect(night.people < day.people / 10)

        let (untagged, _) = try scene()
        let home = OccupantInjury.estimate(
            scene: untagged, glass: [], structure: [], charge: untagged.charge.position, mass: 100)
        #expect(home.buildings.first?.use == .residential)
        #expect(home.buildings.first?.useAssumed == true)
    }

    @Test("Nothing broken far away hurts no one; everything broken hurts nearly all inside, within the band")
    func hurt() throws {
        let (scene, id) = try scene(distance: 300)
        let none = OccupantInjury.estimate(
            scene: scene, glass: sides(id, broken: 0, distance: 300), structure: [],
            charge: scene.charge.position,
            mass: 100)
        #expect(none.expected < 1e-6)
        let all = OccupantInjury.estimate(
            scene: scene, glass: sides(id, broken: 1, distance: 300), structure: [],
            charge: scene.charge.position,
            mass: 100)
        let building = try #require(all.buildings.first)
        #expect(building.expected > 0.5 * building.occupants)
        #expect(building.expected <= building.occupants + building.outdoors + 1e-9)
        #expect(all.low <= all.expected && all.expected <= all.high)
        #expect(all.severe < all.expected && all.killed < all.severe)
        #expect(abs(all.glass + all.structure + all.blast - all.expected) < 1e-6 * max(all.expected, 1))
        // The same inputs, the same figures.
        let again = OccupantInjury.estimate(
            scene: scene, glass: sides(id, broken: 1, distance: 300), structure: [],
            charge: scene.charge.position,
            mass: 100)
        #expect(again.buildings == all.buildings && again.low == all.low && again.high == all.high)
    }

    @Test("The blast through blown-out windows and outdoors hurts close in, not far off")
    func blast() throws {
        let (near, nearID) = try scene(distance: 8)
        let close = OccupantInjury.estimate(
            scene: near, glass: sides(nearID, broken: 0, blownOut: 1, distance: 8), structure: [],
            charge: near.charge.position, mass: 100)
        #expect(close.blast > 1)
        let (far, farID) = try scene(distance: 300)
        let away = OccupantInjury.estimate(
            scene: far, glass: sides(farID, broken: 0, blownOut: 1, distance: 300), structure: [],
            charge: far.charge.position, mass: 100)
        #expect(away.blast < 1e-3)
    }

    @Test("Against a pinned baseline: no change against itself, less glass broken a fall, draw by draw")
    func comparison() throws {
        let (scene, id) = try scene(distance: 300)
        func estimate(_ broken: Double, draws: Int = 200) -> OccupantInjury.Estimate {
            OccupantInjury.estimate(
                scene: scene, glass: sides(id, broken: broken, distance: 300), structure: [],
                charge: scene.charge.position, mass: 100, draws: draws)
        }
        let base = estimate(0.8)
        let same = try #require(OccupantInjury.compare(base, against: base))
        #expect(same.hurt == 0 && same.low == 0 && same.high == 0 && same.sameBuildings)
        // A preview's draws are the first of a full estimate's: the same inputs, no change.
        let preview = try #require(OccupantInjury.compare(estimate(0.8, draws: 40), against: base))
        #expect(abs(preview.hurt) < 1e-12 && abs(preview.low) < 1e-12 && abs(preview.high) < 1e-12)
        // Half as much glass broken: Kummer's curve falls more than half.
        let less = try #require(OccupantInjury.compare(estimate(0.4), against: base))
        #expect(less.hurt < -0.5)
        #expect(less.low <= less.hurt && less.hurt <= less.high && less.high < 0)
        // The draws' shared factors cancel: the change's band is narrower than either estimate's.
        let width = less.high - less.low
        let now = estimate(0.4)
        #expect(width < (now.high - now.low) / now.expected)
        #expect(less.summary.hasPrefix("−"))
        // A baseline that hurts no one gives no ratio.
        #expect(OccupantInjury.compare(base, against: estimate(0)) == nil)
    }

    @Test("Bands by scaled distance hold everyone placed")
    func bands() throws {
        let (scene, id) = try scene(distance: 30)
        let estimate = OccupantInjury.estimate(
            scene: scene, glass: sides(id, broken: 0.5, distance: 30), structure: [],
            charge: scene.charge.position,
            mass: 100)
        let bands = OccupantInjury.bands(estimate)
        #expect(abs(bands.reduce(0) { $0 + $1.people } - estimate.people) < 1e-9)
        #expect(abs(bands.reduce(0) { $0 + $1.hurt } - estimate.expected) < 1e-9)
        // 40 m out (the block's middle) from 100 kg: 8.6 m/kg^(1/3), the 5–10 band.
        #expect(bands.count == 1 && abs(bands[0].fromM - 5 * cbrt(100)) < 1e-9)
    }

    @Test("Map placement keeps a building's use from its tags")
    func placement() throws {
        var scene = Scenario(
            name: "Map", domainSize: SIMD3(200, 200, 40), boxes: [],
            charge: Charge(mass: 10, position: SIMD3(10, 10, 0)))
        let square = [
            SIMD2(0.0005, 0.0005), SIMD2(0.0007, 0.0005), SIMD2(0.0007, 0.0007), SIMD2(0.0005, 0.0007),
        ]
        let buildings = [
            MapBuilding(id: "way/1", kind: "school", rings: [square], height: 9),
            MapBuilding(
                id: "way/2", kind: "yes", rings: [square.map { $0 + SIMD2(0.0005, 0) }], height: 9,
                use: "office"),
            MapBuilding(id: "way/3", kind: "yes", rings: [square.map { $0 + SIMD2(0, 0.0005) }], height: 9),
        ]
        let report = try scene.addMapBuildings(
            buildings, placement: MapBuildingPlacement(origin: .zero, resolution: 1))
        let uses = report.placed.map { scene.envelopeConstruction(for: $0.objectID).use }
        #expect(uses == [.education, .office, nil])
    }
}
