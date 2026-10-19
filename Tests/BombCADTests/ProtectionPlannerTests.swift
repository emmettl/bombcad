import BlastCore
import Foundation
import Testing
import simd

@testable import BombCAD

/// Simulation ▸ Protective Design: the search run off the main thread, the plans listed, the
/// view coloured by a plan, and a plan written into the project's constructions.
@MainActor @Suite("Protective design planner", .serialized, .hangLimit)
struct ProtectionPlannerTests {
    /// Two glazed blocks, 10 m and 50 m from a 50 kg charge, an apartment block's windows on each.
    static func document() throws -> ProjectDocument {
        var scene = Scenario(
            name: "Two blocks", domainSize: SIMD3(160, 60, 30), boxes: [],
            charge: Charge(mass: 50, position: SIMD3(10, 30, 0.5)))
        for (n, x) in [Float(20), 60].enumerated() {
            let id = try scene.addEnvelopeObject(
                BuildingEnvelope(solids: [Box(min: SIMD3(x, 25, 0), max: SIMD3(x + 10, 35, 6))]),
                name: "Block \(n + 1)")
            var construction = EnvelopeConstruction(objectID: id, source: .user, detail: "glazed")
            construction.glazing = .apartments
            scene.setEnvelopeConstruction(construction)
        }
        var document = ProjectDocument(scenario: scene)
        document.runSettings?.resolution = "coarse"
        return document
    }

    @Test("Searches off the main thread, lists the plans, colours a plan and writes it into the project")
    func searchAndApply() async throws {
        let model = SimulationModel(document: try Self.document())
        let planner = ProtectionPlannerModel()
        planner.draws = 2
        planner.changes = planner.changes.map {
            var change = $0
            change.allowed = change.kind == .laminated || change.kind == .infill
            return change
        }
        planner.search(model.settings.scenario, cellSize: model.settings.resolution.cellSize)
        #expect(planner.isRunning)
        while planner.isRunning { try await Task.sleep(for: .milliseconds(20)) }
        #expect(planner.error == nil)
        let plans = planner.plans
        #expect(plans.first?.label == "As built")
        #expect(plans.count >= 2)
        let best = try #require(plans.dropFirst().first)
        #expect(best.plan.meets)
        #expect(planner.selected == 1)
        #expect(!planner.selectedChances.isEmpty)
        model.showProtectionPlan(planner.selectedChances)

        let solution = try #require(planner.model)
        model.applyProtectionPlan(best.plan, model: solution, label: best.label)
        // Each changed side now has its own windows in its building's construction.
        for (s, option) in best.plan.choices.enumerated() where option != 0 {
            let construction = model.settings.scenario.envelopeConstruction(for: solution.owners[s])
            let key = EnvelopeConstruction.sideKey(axis: solution.axes[s], outward: solution.outwards[s])
            let mix = try #require(construction.sideGlazing?[key])
            let glazing = solution.glazing[option - 1]
            #expect(mix == glazing.applied(to: solution.mixes[s]))
            #expect(construction.source == .user)
        }
        model.showProtectionPlan([:])
    }

    @Test("Offers the scene's stand-off lines with the user's costs, and searches with them")
    func standOffLines() async throws {
        var document = try Self.document()
        // A fence at x = 15 guarding the blocks east of it, the charge 3 m inside it: put up, it
        // stops the charge a metre west of it.
        document.scenario.charge.position.x = 18
        document.scenario.standOffLines = [
            StandOffLine(name: "Fence", points: [SIMD2(15, 0), SIMD2(15, 60)], guardsLeft: false)
        ]
        let model = SimulationModel(document: document)
        let planner = ProtectionPlannerModel()
        planner.draws = 2
        planner.offerLines(of: model.settings.scenario)
        #expect(planner.lines.map(\.name) == ["Fence"] && !planner.lines[0].allowed)
        #expect(planner.inputs(model.settings.scenario).standOffs?.isEmpty == true)
        planner.lines[0].allowed = true
        planner.lines[0].cost = 40
        let inputs = planner.inputs(model.settings.scenario)
        #expect(inputs.standOffs?.map(\.line) == ["Fence"] && inputs.standOffs?.first?.cost == 40)
        // Offered again, the cost set is kept.
        planner.offerLines(of: model.settings.scenario)
        #expect(planner.lines[0].allowed && planner.lines[0].cost == 40)
        planner.search(model.settings.scenario, cellSize: model.settings.resolution.cellSize)
        while planner.isRunning { try await Task.sleep(for: .milliseconds(20)) }
        #expect(planner.error == nil)
        let solution = try #require(planner.model)
        #expect(solution.problem.site.map(\.cost) == [40])
        // The fence moves the charge back: no side's chance is higher with it.
        for s in solution.problem.sides.indices {
            #expect(solution.problem.chance([0], s, 0) <= solution.problem.chance([], s, 0) + 1e-12)
        }
    }
}
