import Foundation
import Testing
import simd

@testable import BlastCore

/// The cost model against the runs timed on an unloaded Mac in docs/performance.md.
@Suite("Run cost", .timeLimit(.minutes(120)))
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

    @Test(
        "Close in, a level whose patches would hold a quarter of the domain gives way to its cells throughout"
    )
    func uniformCloseIn() {
        // `blastbench profile --closein --width`: 1 kg 0.5 m above rigid ground.
        func closeIn(width: Float) -> Scenario {
            let height = max(width, 1.4)
            var scenario = Scenario(
                name: "Close-in reflection", domainSize: SIMD3(width, width, height), boxes: [],
                charge: Charge(mass: 1, position: SIMD3(width / 2, width / 2, 0.5)))
            scenario.reflectiveFaces = .ground
            return scenario
        }
        // Until the blast has crossed the domain; 1.5 m across, `closeair`'s 5.5 ms, as measured.
        func duration(_ scenario: Scenario) -> Double {
            scenario.domainSize.x == 1.5
                ? 0.5 / 340 + 0.004
                : Double(simd_length(scenario.domainSize * SIMD3(0.5, 0.5, 1) - SIMD3(0, 0, 0.5))) / 340
                    + 0.004
        }
        func standIn(_ scenario: Scenario, _ current: AdvisorSetting) -> AdvisorSetting? {
            let stand = RunAdvisor.standIn(
                for: current, scenario, configuration: SolverConfiguration(), duration: duration(scenario),
                memory: 32 << 30, maximumCells: 400_000_000)
            return stand.setting == current ? nil : stand.setting
        }
        let once = AdvisorSetting(cellSize: 0.04, refinement: 2)
        let twice = AdvisorSetting(cellSize: 0.04, refinement: 2, levels: 2)
        // Measured: uniform 0.02 m 1.37 times faster than 0.04 m refined once 2 m across, the two
        // alike 2.5 m across, and refined once 1.6 times faster 3.5 m across; with two levels,
        // uniform 0.01 m cells cheapest 1.5 m across, 0.02 m refined once 2 m across.
        #expect(standIn(closeIn(width: 2), once) == AdvisorSetting(cellSize: 0.02))
        #expect(standIn(closeIn(width: 3.5), once) == nil)
        #expect(standIn(closeIn(width: 1.5), twice) == AdvisorSetting(cellSize: 0.01))
        #expect(standIn(closeIn(width: 2), twice) == AdvisorSetting(cellSize: 0.02, refinement: 2))
        // The model's share against the runs' (0.63, 0.31 and 0.15 of the domain's blocks).
        for (width, measured) in [(Float(1.5), 0.63), (2, 0.31), (3.5, 0.15)] {
            var configuration = SolverConfiguration()
            configuration.refinement = 2
            let scenario = closeIn(width: width)
            let share = RunCost.estimate(
                scenario, cellSize: 0.04, configuration: configuration, duration: duration(scenario)
            ).refinedShare.x
            #expect(abs(share / measured - 1) < 0.2, "\(width) m: \(share) against \(measured)")
        }
        // In the open, nothing changes.
        let open = ScenarioPreset.openGround.scenario
        let stand = RunAdvisor.standIn(
            for: AdvisorSetting(cellSize: 0.5, refinement: 2), open, configuration: SolverConfiguration(),
            duration: open.acousticCrossingTime, memory: 32 << 30, maximumCells: 400_000_000)
        #expect(stand.setting == AdvisorSetting(cellSize: 0.5, refinement: 2))
    }

    @Test("Adaptive substeps: the share taken as measured, and the advisor turns them on in the open only")
    func adaptiveSubsteps() {
        func closeIn(width: Float) -> (Scenario, Double) {
            let height = max(width, 1.4)
            var scenario = Scenario(
                name: "Close-in reflection", domainSize: SIMD3(width, width, height), boxes: [],
                charge: Charge(mass: 1, position: SIMD3(width / 2, width / 2, 0.5)))
            scenario.reflectiveFaces = .ground
            let duration =
                width == 1.5
                ? 0.5 / 340 + 0.004
                : Double(simd_length(SIMD3(width / 2, width / 2, height - 0.5))) / 340 + 0.004
            return (scenario, duration)
        }
        // `blastbench profile --refine 2 --refine-own-steps` on the recommended air: substeps taken
        // of 2.
        let open = ScenarioPreset.openGround.scenario
        let street = ScenarioPreset.streetCanyon.scenario
        var cases = [(open, open.acousticCrossingTime, 0.625), (street, street.acousticCrossingTime, 0.695)]
        for (width, measured) in [(Float(1.5), 1.0), (2, 0.82), (3.5, 0.755), (6, 0.665)] {
            let (scenario, duration) = closeIn(width: width)
            cases.append((scenario, duration, measured))
        }
        for (scenario, duration, measured) in cases {
            let predicted = RunCost.ownStepsShare(scenario, duration: duration)
            #expect(abs(predicted - measured) < 0.06, "\(scenario.name): \(predicted) against \(measured)")
        }
        // Taking fewer substeps costs less.
        var configuration = SolverConfiguration.recommended
        configuration.refinement = 2
        let all = RunCost.estimate(
            open, cellSize: 0.5, configuration: configuration, duration: open.acousticCrossingTime)
        configuration.refinementOwnSteps = true
        let fewer = RunCost.estimate(
            open, cellSize: 0.5, configuration: configuration, duration: open.acousticCrossingTime)
        #expect(fewer.fineUpdates < 0.7 * all.fineUpdates && fewer.seconds < all.seconds)
        // The advisor's refined settings take them in the open, and not close in.
        func refinedTakeThem(_ scenario: Scenario, _ duration: Double) -> Bool {
            let advice = RunAdvisor.advise(
                scenario, configuration: .recommended, duration: duration, target: .seconds(3600),
                current: AdvisorSetting(cellSize: 0.5), memory: 32 << 30, maximumCells: 2_000_000
            ) { _ in ([.peak: 0.1], [:]) }
            let refined = advice.candidates.filter { $0.setting.refinement > 1 }
            #expect(!refined.isEmpty)
            return refined.allSatisfy(\.setting.ownSteps)
        }
        #expect(refinedTakeThem(open, open.acousticCrossingTime))
        let (near, nearDuration) = closeIn(width: 1.5)
        #expect(!refinedTakeThem(near, nearDuration))
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
