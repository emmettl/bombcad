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
