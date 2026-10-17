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
        #expect(lower.fineUpdates > high.fineUpdates && lower.memory >= high.memory)
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

    /// 500 t on rigid ground, a quarter of it in the corner, as `blastbench landscape` runs it.
    private var landscape: (scenario: Scenario, duration: Double) {
        var scenario = Scenario(
            name: "Landscape burst", domainSize: SIMD3(3334, 3334, 833), boxes: [],
            charge: Charge(mass: 500_000, position: .zero))
        scenario.reflectiveFaces = [.xMin, .yMin, .zMin]
        return (scenario, 9.41)
    }

    @Test("The refined pools are priced as they grow: 500 t refined twice to 2 m, as measured")
    func poolPrice() {
        let (scenario, duration) = landscape
        var configuration = configured(refine: 2, levels: 2)
        configuration.afterburning = true
        configuration.refinementThreshold = 0.005
        configuration.refinementMemory = 12 << 30
        let estimate = RunCost.estimate(
            scenario, cellSize: 8, configuration: configuration, duration: duration)
        // Measured (docs/large-scenes.md, "The refined pool's memory"): the pools held 20,022 and
        // 62,852 patches of 77,000 bytes at the end; under a top at 320 m over 2.5 km (Beirut's
        // district, a quarter of it), 10,252 and 25,745.
        let measured = 6.38e9
        #expect(
            Double(estimate.refinementMemory) > measured
                && Double(estimate.refinementMemory) < 1.6 * measured,
            "\(estimate.refinementMemory) bytes against \(measured)")
        var low = scenario
        low.domainSize = SIMD3(2500, 2500, 320)
        let lowEstimate = RunCost.estimate(low, cellSize: 8, configuration: configuration, duration: 8)
        let lowMeasured = 2.77e9
        #expect(
            Double(lowEstimate.refinementMemory) > 0.95 * lowMeasured
                && Double(lowEstimate.refinementMemory) < 1.3 * lowMeasured,
            "\(lowEstimate.refinementMemory) bytes against \(lowMeasured)")
        #expect(
            estimate.memory == RunCost.coarseMemory(scenario.grid(cellSize: 8), configuration: configuration)
                + estimate.refinementMemory)
        // Without refinement, nothing for the pools; refined, never less than they start with.
        let open = ScenarioPreset.openGround.scenario
        #expect(
            RunCost.estimate(open, cellSize: 0.5, configuration: configured(), duration: 0.01)
                .refinementMemory == 0)
        #expect(
            RunCost.estimate(open, cellSize: 0.5, configuration: configured(refine: 2), duration: 0.01)
                .refinementMemory >= 64 << 20)
    }

    @Test("The advisor finds the finest cells that fit, and says which Mac holds what this one cannot")
    func memoryAware() {
        let (scenario, duration) = landscape
        var configuration = SolverConfiguration.recommended
        configuration.refinementMemory = 64 << 30
        // Within 10% at the shock only on 2 m cells, refined at 0.005.
        func evaluate(_ setting: AdvisorSetting) -> ([AdvisorQuantity: Double], [AdvisorQuantity: String]) {
            let levels = setting.refinement > 1 ? setting.levels : 0
            let finest = setting.cellSize / pow(Float(setting.refinement), Float(levels))
            let sharp = finest <= 2.01 && (setting.refinement == 1 || setting.threshold == 0.005)
            return ([.peak: sharp ? 0.08 : 0.2], [:])
        }
        func advice(memory: Int, elsewhere: [AdvisorMachine] = []) -> Advice {
            RunAdvisor.advise(
                scenario, configuration: configuration, duration: duration,
                target: .fidelity(.peak, within: 0.1),
                current: AdvisorSetting(cellSize: 16), memory: memory, elsewhere: elsewhere,
                maximumCells: 400_000_000, evaluate: evaluate)
        }
        // The Studio lets the air take 19.7 GB, the mini 12.4 GB.
        let studio = advice(memory: 19_700_000_000)
        let chosen = studio.chosen?.setting
        #expect(studio.met && chosen?.refinement == 2 && chosen?.levels == 2 && chosen?.threshold == 0.005)
        #expect(chosen?.cellSize ?? 0 > 7 && chosen?.cellSize ?? 0 < 9)
        // A Mac with 4 GB cannot hold it, and is told which can.
        let small = advice(
            memory: 4 << 30, elsewhere: [AdvisorMachine(name: "the mini", memory: 12_400_000_000)])
        #expect(!small.met)
        #expect(
            small.unmet.contains { $0.contains("more than this Mac's") && $0.contains("it fits the mini") })
        let none = advice(memory: 4 << 30)
        #expect(none.unmet.contains { $0.contains("more than this Mac's 4.3 GB.") })
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
