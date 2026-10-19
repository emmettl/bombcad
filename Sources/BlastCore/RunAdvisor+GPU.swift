import BlastModel
import Foundation
import simd

extension RunAdvisor {
    /// The advice for `target` over `candidates`, each costed by `RunCost` and its errors from
    /// `evaluate` (the standing's error bands for that setting). Ties go to the setting nearest
    /// `current`; a setting over `memory` bytes, this Mac's, is never chosen. Each is priced with
    /// the coarse grid and the pools its refined levels are expected to grow to, so that the
    /// finest that fits is found; where what is wanted needs more, the advice says so, and which
    /// of the Macs `elsewhere` (the sweep workers) it would fit.
    public static func advise(
        _ scenario: Scenario, configuration: SolverConfiguration, duration: Double, target: AdvisorTarget,
        current: AdvisorSetting, memory: Int, elsewhere: [AdvisorMachine] = [], maximumCells: Int,
        evaluate: (AdvisorSetting) -> (error: [AdvisorQuantity: Double], unbanded: [AdvisorQuantity: String])
    ) -> Advice {
        func weigh(_ setting: AdvisorSetting, within memory: Int) -> AdvisorCandidate? {
            let stand = standIn(
                for: setting, scenario, configuration: configuration, duration: duration, memory: memory,
                maximumCells: maximumCells)
            guard stand.cost.memory <= memory else { return nil }
            let fidelity = evaluate(stand.setting)
            return AdvisorCandidate(
                setting: stand.setting, cost: stand.cost, error: fidelity.error, unbanded: fidelity.unbanded,
                standsFor: stand.setting == setting ? nil : setting, standsForShare: stand.share)
        }
        var seen = Set<AdvisorSetting>()
        // Refined settings take adaptive substeps where they are expected to pay.
        let ownSteps = RunCost.ownStepsShare(scenario, duration: duration) < ownStepsShare
        let settings = candidates(scenario, maximumCells: maximumCells).map { setting in
            var setting = setting
            setting.ownSteps = setting.refinement > 1 && ownSteps
            return setting
        }
        let weighed = settings.compactMap { weigh($0, within: memory) }.filter {
            seen.insert($0.setting).inserted
        }.sorted { $0.cost.seconds < $1.cost.seconds }
        let stoodIn = weigh(current, within: memory).flatMap { $0.standsFor == nil ? nil : $0 }
        // Open faces too near the structure (`Scenario.tightOpenFaces`); what this Mac cannot hold:
        // the settings as they are, and the cheapest that meets a target nothing here meets, with
        // the Mac it would fit.
        var tooLarge: [String] = scenario.tightFacesNote.map { [$0] } ?? []
        let here = AdvisorMachine.gigabytes(memory)
        func fits(_ need: Int) -> String {
            if let machine = elsewhere.filter({ $0.memory >= need }).min(by: { $0.memory < $1.memory }) {
                return "; it fits \(machine.name) (\(AdvisorMachine.gigabytes(machine.memory)))."
            }
            guard let largest = elsewhere.max(by: { $0.memory < $1.memory }) else { return "." }
            return
                ", or any other Mac's (the largest, \(largest.name), \(AdvisorMachine.gigabytes(largest.memory)))."
        }
        if weigh(current, within: memory) == nil, let need = weigh(current, within: .max) {
            tooLarge.append(
                "As set, the run needs about \(AdvisorMachine.gigabytes(need.cost.memory)), more than this "
                    + "Mac's \(here)" + fits(need.cost.memory))
        }
        func closeness(_ a: AdvisorSetting) -> Int {
            (a.afterburning == current.afterburning ? 0 : 4) + (a.refinement == current.refinement ? 0 : 2)
                + (a.levels == current.levels ? 0 : 1)
        }
        switch target {
        case .fidelity(let quantity, let within):
            let meeting = weighed.filter { ($0.error[quantity] ?? .infinity) <= within + 1e-9 }
            if let cheapest = meeting.min(by: {
                $0.cost.seconds < $1.cost.seconds * 0.95
                    || ($0.cost.seconds <= $1.cost.seconds * 1.05
                        && closeness($0.setting) < closeness($1.setting))
            }) {
                return Advice(
                    target: target, kind: .cheapestMeeting, chosen: cheapest, met: true, unmet: tooLarge,
                    candidates: weighed, currentStandIn: stoodIn)
            }
            // Nothing meets it: the nearest, and why.
            let banded = weighed.filter { $0.error[quantity] != nil }
            let nearest = banded.min {
                ($0.error[quantity]!, $0.cost.seconds) < ($1.error[quantity]!, $1.cost.seconds)
            }
            var unmet: [String] = []
            if let nearest, let error = nearest.error[quantity] {
                unmet.append(
                    String(
                        format: "No setting this Mac holds brings %@ within %.0f%%; the nearest is %.0f%%.",
                        quantity.title, within * 100, error * 100))
                let larger = settings.compactMap { weigh($0, within: .max) }.filter {
                    ($0.error[quantity] ?? .infinity) <= within + 1e-9
                }
                if let need = larger.min(by: { $0.cost.memory < $1.cost.memory }) {
                    unmet.append(
                        "\(need.setting.summary) would, in about \(AdvisorMachine.gigabytes(need.cost.memory)): "
                            + "more than this Mac's \(here)" + fits(need.cost.memory))
                }
            } else {
                let reason =
                    weighed.compactMap { $0.unbanded[quantity] }.first
                    ?? "no comparison on record covers this scene"
                unmet.append("No setting has an expected error for \(quantity.title): \(reason).")
            }
            // With nothing to aim by, the settings as they are.
            let fallback = weighed.first { $0.setting == current } ?? weighed.first
            return Advice(
                target: target, kind: .cheapestMeeting, chosen: nearest ?? fallback, met: false,
                unmet: unmet + tooLarge,
                candidates: weighed, currentStandIn: stoodIn)
        case .seconds(let budget):
            let affordable = weighed.filter { $0.cost.seconds <= budget }
            guard !affordable.isEmpty else {
                return Advice(
                    target: target, kind: .bestWithinBudget, chosen: weighed.first, met: false,
                    unmet: [
                        "Even the cheapest setting is expected to take \(Self.duration(weighed.first?.cost.seconds ?? 0))."
                    ] + tooLarge,
                    candidates: weighed, currentStandIn: stoodIn)
            }
            // The best of the peaks, impulse and deflection the scene has bands for, the worst of them
            // weighed first; where none has one, or they tie, the finest cells near the shock.
            func score(_ c: AdvisorCandidate) -> Double { c.error.values.max() ?? .infinity }
            func finest(_ c: AdvisorCandidate) -> Float {
                let levels = c.setting.refinement > 1 ? c.setting.levels : 0
                return c.setting.cellSize / pow(Float(c.setting.refinement), Float(levels))
            }
            let best = affordable.min {
                (score($0), finest($0), $0.cost.seconds) < (score($1), finest($1), $1.cost.seconds)
            }!
            return Advice(
                target: target, kind: .bestWithinBudget, chosen: best, met: true, unmet: tooLarge,
                candidates: weighed, currentStandIn: stoodIn)
        }
    }

    /// What the advisor weighs in place of `setting`, and its cost: `setting` itself, or, where its
    /// first level would hold more of the domain than `uniformShare`, the grid of that level's
    /// cells (refined once if there were two levels, and so on while the share stays as high), as
    /// long as that grid is one the advisor may weigh. The cells at the shock are the same, and finer
    /// elsewhere, for less. `share` is the first level's share of `setting` when it gave way.
    public static func standIn(
        for setting: AdvisorSetting, _ scenario: Scenario, configuration: SolverConfiguration,
        duration: Double, memory: Int, maximumCells: Int
    ) -> (setting: AdvisorSetting, cost: RunCostEstimate, share: Double) {
        func cost(_ setting: AdvisorSetting) -> RunCostEstimate {
            RunCost.estimate(
                scenario, cellSize: setting.cellSize, configuration: setting.applied(to: configuration),
                duration: duration)
        }
        var chosen = setting
        var estimate = cost(setting)
        var share = 0.0
        while chosen.refinement > 1, estimate.refinedShare.x >= uniformShare {
            let finer = chosen.withoutFirstLevel
            let grid = scenario.grid(cellSize: finer.cellSize)
            guard finer.cellSize >= 0.01, grid.cellCount <= maximumCells,
                max(grid.nx, grid.ny, grid.nz) <= 2048
            else { break }
            let finerEstimate = cost(finer)
            guard finerEstimate.memory <= memory else { break }
            if chosen == setting { share = estimate.refinedShare.x }
            (chosen, estimate) = (finer, finerEstimate)
        }
        return (chosen, estimate, share)
    }
}
