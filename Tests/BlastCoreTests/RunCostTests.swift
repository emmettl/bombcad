import Foundation
import Testing
import simd

@testable import BlastCore

/// The cost model against the runs timed on an unloaded Mac in docs/performance.md.
@Suite("Run cost")
struct RunCostTests {
    private func configured(refine: Int = 1, levels: Int = 1, burning: Bool = false) -> SolverConfiguration {
        var configuration = SolverConfiguration()
        configuration.refinement = refine
        configuration.refinementLevels = levels
        if burning {
            configuration.afterburning = true
            configuration.airModel = .thermallyPerfect
        }
        return configuration
    }

    @Test("Whole events come within a factor of two of the times docs/performance.md records")
    func againstRecord() {
        let street = ScenarioPreset.streetCanyon.scenario
        let open = ScenarioPreset.openGround.scenario
        // (scene, cells, configuration, seconds recorded): "Air solver" and "Refinement".
        let cases: [(Scenario, Float, SolverConfiguration, Double)] = [
            (street, 0.5, configured(), 0.3), (street, 0.25, configured(), 3.2),
            (street, 0.125, configured(), 46), (street, 0.25, configured(burning: true), 7.5),
            (street, 0.5, configured(refine: 2), 1.2), (street, 0.25, configured(refine: 2), 11.5),
            (street, 0.5, configured(refine: 2, levels: 2), 8.8), (open, 0.25, configured(), 5.5),
            (open, 0.125, configured(), 97.6), (open, 0.5, configured(refine: 2), 1.6),
            (open, 0.25, configured(refine: 2), 16.0), (open, 0.5, configured(refine: 2, levels: 2), 8.1),
        ]
        for (scene, cells, configuration, recorded) in cases {
            let estimate = RunCost.estimate(
                scene, cellSize: cells, configuration: configuration, duration: scene.acousticCrossingTime)
            let ratio = recorded / estimate.seconds
            #expect(
                ratio > 0.5 && ratio < 2,
                "\(scene.name) \(cells) m: \(recorded) s against \(estimate.seconds) s")
        }
    }

    @Test(
        "Halving the cells sweeps about sixteen times the air; refining lower costs more; memory follows the cells"
    )
    func scaling() {
        let open = ScenarioPreset.openGround.scenario
        let event = open.acousticCrossingTime
        let coarse = RunCost.estimate(open, cellSize: 0.5, configuration: configured(), duration: event)
        let fine = RunCost.estimate(open, cellSize: 0.25, configuration: configured(), duration: event)
        #expect(fine.cells == 8 * coarse.cells && abs(Double(fine.steps) / Double(coarse.steps) - 2) < 0.01)
        #expect(
            fine.coarseUpdates / coarse.coarseUpdates > 14 && fine.coarseUpdates / coarse.coarseUpdates < 18)
        #expect(fine.memory == fine.cells * RunCost.bytesPerCell)
        var low = configured(refine: 2, levels: 2)
        let high = RunCost.estimate(open, cellSize: 0.5, configuration: low, duration: event)
        low.refinementThreshold = 0.02
        let lower = RunCost.estimate(open, cellSize: 0.5, configuration: low, duration: event)
        #expect(lower.fineUpdates > high.fineUpdates && lower.memory == high.memory)
        #expect(
            RunCost.refinementReach(threshold: 0.1) > 19_000
                && RunCost.refinementReach(threshold: 0.1) < 21_000)
    }

    @Test("Targets read from the command line")
    func targets() {
        #expect(AdvisorTarget(text: "peak:20%") == .fidelity(.peak, within: 0.2))
        #expect(AdvisorTarget(text: "impulse:0.15") == .fidelity(.impulse, within: 0.15))
        #expect(
            AdvisorTarget(text: "time:10m") == .seconds(600)
                && AdvisorTarget(text: "time:2h") == .seconds(7200))
        #expect(AdvisorTarget(text: "time:90") == .seconds(90))
        for bad in ["peak", "peak:", "speed:10%", "time:-1", "peak:0"] {
            #expect(AdvisorTarget(text: bad) == nil, "\(bad)")
        }
    }
}
