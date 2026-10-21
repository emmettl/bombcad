import BlastCore
import Foundation
import Testing
import simd

@testable import BombCAD

/// People in the scene (emmettl/bombcad-work#41): the quick estimate's people follow its chances,
/// the planner's assumptions, and colour the buildings by the share hurt.
@MainActor
@Suite("People in the scene", .serialized)
struct PeopleInSceneTests {
    @Test(
        "A quick estimate places the people; the time of day moves them; the view colours by the share hurt")
    func people() async throws {
        var scene = Scenario(
            name: "People", domainSize: SIMD3(120, 60, 20), boxes: [],
            charge: Charge(mass: 50, position: SIMD3(20, 30, 0.5)))
        for (x, use) in [(Float(40), BuildingUse.office), (70, nil)] {
            let id = try scene.addEnvelopeObject(
                BuildingEnvelope(solids: [Box(min: SIMD3(x, 22, 0), max: SIMD3(x + 10, 38, 9))]))
            var construction = EnvelopeConstruction(objectID: id, source: .user, detail: "glazed")
            construction.glazing = .apartments
            construction.use = use
            scene.setEnvelopeConstruction(construction)
        }
        var document = ProjectDocument(scenario: scene)
        document.runSettings?.resolution = "coarse"
        let model = SimulationModel(document: document)
        model.refinesCloseCalls = false
        func settle() async throws {
            while model.estimatingEnvelopeDamage || model.isLoadingInputs {
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        try await settle()
        #expect(model.peopleEstimate == nil)
        model.quickEstimate()
        try await settle()
        let evening = try #require(model.peopleEstimate)
        #expect(evening.buildings.count == 2)
        #expect(evening.people > 0)
        #expect(evening.low <= evening.expected && evening.expected <= evening.high)
        #expect(evening.buildings.first { $0.use == .office }?.useAssumed == false)
        #expect(evening.buildings.first { $0.use == .residential }?.useAssumed == true)

        // At night the offices empty and the homes fill.
        model.occupancy.time = .night
        let night = try #require(model.peopleEstimate)
        let office = { (e: OccupantInjury.Estimate) in
            e.buildings.first { $0.use == .office }.map { $0.occupants + $0.outdoors } ?? 0
        }
        #expect(office(night) < office(evening) / 10)

        model.showsEnvelopeDamage = true
        model.envelopeColouring = .peopleHurt
        #expect(model.previewParts == .glass)
        let codes = model.peopleCodes()
        #expect(codes.count == 2)
        #expect(codes.values.allSatisfy { $0 >= EnvelopeChanceColour.first })

        // Pinned at night, then the evening: the change against it, with what changed.
        #expect(model.peopleComparisonLine == nil)
        model.pinPeopleBaseline()
        #expect(model.peopleBaseline?.assumptions.time == .night)
        let unchanged = try #require(model.peopleComparison)
        #expect(unchanged.hurt == 0)
        #expect(model.peopleComparisonLine?.hasSuffix("nothing changed.") == true)
        model.occupancy.time = .evening
        let line = try #require(model.peopleComparisonLine)
        #expect(line.contains("evening (5 pm)"))
        let change = try #require(model.peopleComparison)
        let expected = (model.peopleEstimate?.expected ?? 0) / night.expected - 1
        #expect(abs(change.hurt - expected) < 1e-9)
        #expect(change.sameBuildings)
        model.peopleBaseline = nil
        #expect(model.peopleComparison == nil)
    }
}
