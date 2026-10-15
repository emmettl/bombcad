import BlastCore
import Foundation
import Testing

@testable import BombCAD

/// The cost-against-fidelity advisor: settings chosen by the standing's bands and the cost model.
@Suite("Advisor")
struct AdvisorTests {
    /// 500 t in an open scene to 20 m/kg^(1/3), gauges along a line from it.
    private func landscape() -> SimulationInputs {
        var scenario = ScenarioPreset.openGround.scenario
        scenario.charge.mass = 500_000
        try? scenario.fitOpenScene(scaledReach: 20)
        scenario.gauges = scenario.gaugeLine(direction: SIMD2(1, 0), scaledDistances: [2, 5, 10, 14, 20])
        var settings = ProjectDocument(scenario: scenario).runSettings!
        settings.resolution = Resolution(cellSize: 16)!.rawValue
        settings.duration = 4.5
        return SimulationInputs(scenario: scenario, settings: settings)
    }

    private let memory = 24 << 30

    @Test("Peaks within 30%: the cheapest setting the bands expect to reach it, and it does")
    func cheapest() throws {
        let inputs = landscape()
        let advice = inputs.advice(for: .fidelity(.peak, within: 0.3), memory: memory)
        #expect(advice.met && advice.kind == .cheapestMeeting)
        let chosen = try #require(advice.chosen)
        #expect((chosen.error[.peak] ?? 1) <= 0.3)
        // Nothing that meets it is much cheaper.
        let meeting = advice.candidates.filter { ($0.error[.peak] ?? 1) <= 0.3 }
        #expect(meeting.allSatisfy { $0.cost.seconds >= chosen.cost.seconds * 0.95 })
        // The standing of the chosen settings gives the same band the advisor read.
        let applied = inputs.settings.applying(chosen.setting)
        #expect(applied.advisorSetting == chosen.setting)
        let fidelity = SimulationInputs.fidelity(inputs.scenario, applied, thermal: nil)
        #expect(fidelity.error[.peak] == chosen.error[.peak])
    }

    @Test("Over terrain, cut cells cost a little more than the staircase")
    func terrainCutCost() throws {
        var inputs = landscape()
        let domain = inputs.scenario.domainSize
        inputs.scenario.replaceTerrain(
            with: .hill(
                domain: domain, spacing: 32, centre: SIMD2(0.6 * domain.x, 0.5 * domain.y), height: 60,
                radius: 0.1 * domain.x))
        inputs.settings = ProjectDocument(scenario: inputs.scenario).runSettings!
        inputs.settings.resolution = Resolution(cellSize: 16)!.rawValue
        inputs.settings.duration = 4.5
        #expect(inputs.advice(for: .seconds(600), memory: memory).chosen != nil)
        var staircase = inputs.settings
        staircase.terrainCutCells = nil
        #expect(
            staircase.costEstimate(inputs.scenario).seconds
                < inputs.settings.costEstimate(inputs.scenario).seconds)
        #expect(
            inputs.settings.costEstimate(landscape().scenario).seconds
                == landscape().settings.costEstimate(landscape().scenario).seconds)
    }

    @Test("Peaks within 2% are out of reach: the nearest is offered, and why")
    func unmet() throws {
        let advice = landscape().advice(for: .fidelity(.peak, within: 0.02), memory: memory)
        #expect(!advice.met && advice.unmet.first?.contains("nearest") == true)
        #expect(advice.chosen != nil)
    }

    @Test("A budget buys the best fidelity it can, and a tiny one says it cannot")
    func budget() throws {
        let inputs = landscape()
        let advice = inputs.advice(for: .seconds(600), memory: memory)
        let chosen = try #require(advice.chosen)
        #expect(advice.met && chosen.cost.seconds <= 600)
        let cheap = inputs.advice(for: .seconds(0.001), memory: memory)
        #expect(!cheap.met && cheap.unmet.first?.contains("cheapest") == true)
        // Without gauges or a structure, nothing has a band to aim at.
        var bare = inputs
        bare.scenario.gauges = []
        let none = bare.advice(for: .fidelity(.peak, within: 0.2), memory: memory)
        #expect(!none.met && none.unmet.first?.contains("no gauges") == true)
    }

    @Test("Close in, refined settings whose patches would fill the domain are told of the uniform grid")
    func uniformCloseIn() throws {
        // 1 kg 0.5 m above rigid ground, 2 m across: 0.04 m cells refined once hold about 30%.
        var scenario = Scenario(
            name: "Close in", domainSize: SIMD3(2, 2, 2), boxes: [],
            charge: Charge(mass: 1, position: SIMD3(1, 1, 0.5)))
        scenario.reflectiveFaces = .ground
        scenario.gauges = [Gauge("below", at: SIMD3(1, 1, 0.01))]
        var settings = try #require(ProjectDocument(scenario: scenario).runSettings)
        settings.resolution = Resolution(cellSize: 0.04)!.rawValue
        settings.sharpShocks = true
        settings.duration = 0.01
        let advice = SimulationInputs(scenario: scenario, settings: settings).advice(
            for: .seconds(600), memory: memory)
        #expect(advice.currentStandIn?.setting == AdvisorSetting(cellSize: 0.02))
        let note = try #require(advice.standInNote)
        #expect(note.hasPrefix("As set (0.04 m cells, refined once), the patches would hold about "))
        #expect(note.hasSuffix("% of the domain: 0.02 m cells cost less, with the same cells at the shock."))
        // In the open, no such note.
        #expect(landscape().advice(for: .seconds(600), memory: memory).standInNote == nil)
    }

    @Test("Advice is asked of a headless run with --advise, which does not run")
    func headless() throws {
        let options = try HeadlessRun.Options.parse(["scene.bombcad", "--advise", "peak:20%"])
        #expect(options.advise == .fidelity(.peak, within: 0.2))
        #expect(throws: (any Error).self) {
            try HeadlessRun.Options.parse(["scene.bombcad", "--advise", "fast"])
        }
    }

    @Test("The cost store scales by the median of this Mac's runs against their estimates")
    func costStore() throws {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "run-costs-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = RunCostStore(url: url)
        #expect(store.factor == nil)
        for (estimate, measured) in [(10.0, 20.0), (10, 40), (10, 30), (0.5, 100)] {
            store.record(estimate: estimate, measured: measured)
        }
        #expect(store.factor == 3, "the run under a second is left out")
    }
}
