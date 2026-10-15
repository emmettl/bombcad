import Foundation
import simd

/// What the advisor is asked for: a fidelity to reach as cheaply as it can, or a budget of time
/// to spend on the best fidelity it buys (see docs/performance.md, "Choosing settings").
public enum AdvisorTarget: Sendable, Equatable {
    /// A result within `within` of the measurements (0.2 for 20%), at every gauge or for the
    /// structure, as the standing's error bands expect it.
    case fidelity(AdvisorQuantity, within: Double)
    /// A run of at most this many seconds on an unloaded M4 Max.
    case seconds(Double)

    public var summary: String {
        switch self {
        case .fidelity(let quantity, let within):
            String(format: "%@ within %.0f%%", quantity.title, within * 100)
        case .seconds(let seconds): "a run under " + RunAdvisor.duration(seconds)
        }
    }
}

extension AdvisorTarget {
    /// From the command line: "peak:20%", "impulse:0.15" or "deflection:30%" for a fidelity, and
    /// "time:600", "time:10m" or "time:2h" for a budget.
    public init?(text: String) {
        let parts = text.lowercased().split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        if parts[0] == "time" {
            var value = parts[1]
            var unit = 1.0
            if value.hasSuffix("h") {
                unit = 3600
                value.removeLast()
            } else if value.hasSuffix("m") {
                unit = 60
                value.removeLast()
            } else if value.hasSuffix("s") {
                value.removeLast()
            }
            guard let seconds = Double(value), seconds > 0 else { return nil }
            self = .seconds(seconds * unit)
            return
        }
        guard let quantity = AdvisorQuantity(rawValue: parts[0]) else { return nil }
        var value = parts[1]
        var scale = 1.0
        if value.hasSuffix("%") {
            value.removeLast()
            scale = 0.01
        }
        guard let within = Double(value).map({ $0 * scale }), within > 0, within < 10 else { return nil }
        self = .fidelity(quantity, within: within)
    }
}

/// A result the advisor weighs.
public enum AdvisorQuantity: String, CaseIterable, Codable, Sendable {
    case peak, impulse, deflection

    public var title: String {
        switch self {
        case .peak: "peaks at the gauges"
        case .impulse: "impulse at the gauges"
        case .deflection: "the structure's deflection"
        }
    }
}

/// Settings of the air the advisor chooses among.
public struct AdvisorSetting: Sendable, Hashable, Codable {
    public var cellSize: Float
    /// Refinement near the shock: 1 for none, else 2.
    public var refinement: Int
    public var levels: Int
    public var threshold: Float
    public var afterburning: Bool

    public init(
        cellSize: Float, refinement: Int = 1, levels: Int = 1, threshold: Float = 0.1,
        afterburning: Bool = SolverConfiguration.recommended.afterburning
    ) {
        self.cellSize = cellSize
        self.refinement = refinement
        self.levels = levels
        self.threshold = threshold
        self.afterburning = afterburning
    }

    /// `configuration` with these settings of the air.
    public func applied(to configuration: SolverConfiguration) -> SolverConfiguration {
        var configuration = configuration
        configuration.refinement = refinement
        configuration.refinementLevels = refinement > 1 ? levels : 1
        configuration.refinementThreshold = threshold
        configuration.afterburning = afterburning
        configuration.airModel = afterburning ? .thermallyPerfect : .idealGas
        configuration.openFaces = SolverConfiguration.recommended.openFaces
        return configuration
    }

    /// This setting without its first level of refinement: the coarse grid on that level's cells,
    /// refined once more if there were two levels.
    public var withoutFirstLevel: AdvisorSetting {
        guard refinement > 1 else { return self }
        var setting = self
        setting.cellSize = cellSize / Float(refinement)
        if levels > 1 {
            setting.levels = levels - 1
        } else {
            setting = AdvisorSetting(cellSize: setting.cellSize, afterburning: afterburning)
        }
        return setting
    }

    public var summary: String {
        var text = String(format: "%g m cells", Double(cellSize))
        if refinement > 1 {
            text += levels > 1 ? ", refined twice" : ", refined once"
            if threshold != 0.1 { text += String(format: " to %g", Double(threshold)) }
        }
        if afterburning { text += ", afterburning" }
        return text
    }
}

/// A setting with what it is expected to cost and how far each result is expected to lie from
/// the measurements: the worst over the gauges (or the structure) of the farther end of its
/// error band from 1, nil where the standing gives no band.
public struct AdvisorCandidate: Sendable, Equatable {
    public var setting: AdvisorSetting
    public var cost: RunCostEstimate
    public var error: [AdvisorQuantity: Double]
    /// Why a quantity has no expected error: outside what the validation record compared.
    public var unbanded: [AdvisorQuantity: String]
    /// The refined setting this one stands in for, and the share of the domain that setting's first
    /// level was expected to hold: so much that a grid of its cells throughout costs less
    /// (`RunAdvisor.uniformShare`).
    public var standsFor: AdvisorSetting? = nil
    public var standsForShare = 0.0
}

/// The advice for a scene and a target.
public struct Advice: Sendable, Equatable {
    public enum Kind: String, Sendable { case cheapestMeeting, bestWithinBudget }
    public var target: AdvisorTarget
    public var kind: Kind
    /// The setting chosen; nil if none fits the memory at all.
    public var chosen: AdvisorCandidate?
    /// Whether the chosen setting meets the target.
    public var met: Bool
    /// What it could not meet, and why, a line each.
    public var unmet: [String]
    /// Every candidate weighed, cheapest first.
    public var candidates: [AdvisorCandidate]
    /// When the settings as they are refine so much of the domain that a grid of the refined cells
    /// throughout costs less, the candidate that stands for them.
    public var currentStandIn: AdvisorCandidate? = nil

    /// A line saying so, when the settings as they are refine most of the domain.
    public var standInNote: String? {
        guard let standIn = currentStandIn, let refined = standIn.standsFor else { return nil }
        return String(
            format:
                "As set (%@), the patches would hold about %.0f%% of the domain: %@ cost less, with the same cells at the shock.",
            refined.summary, standIn.standsForShare * 100, standIn.setting.summary)
    }

    public var summary: String {
        guard let chosen else { return "No setting fits this Mac's memory." }
        let seconds = chosen.cost.seconds
        let cost = seconds < 1 ? "under a second" : "about " + RunAdvisor.duration(seconds)
        let verb = kind == .cheapestMeeting ? (met ? "Cheapest for" : "Nearest to") : "Best within"
        return "\(verb) \(target.summary): \(chosen.setting.summary), \(cost)."
    }
}

public enum RunAdvisor {
    /// The cells, per cube root of the charge's mass, that the advisor tries: those of the
    /// comparisons on record and halves and doubles of them.
    public static let scaledCells: [Float] = [0.4, 0.2, 0.1, 0.05, 0.025]
    public static let presetCells: [Float] = [0.5, 0.25, 0.125]
    public static let thresholds: [Float] = [0.1, 0.02, 0.005]
    /// The share of the domain a level of refinement's patches may hold, on average over the run
    /// (`RunCostEstimate.refinedShare`), beyond which the coarse grid on that level's cells costs
    /// less than the level: close in, where the shock, the fireball and the reflections behind it
    /// fill most of the domain. Measured: 1 kg 0.5 m above rigid ground in domains 2 to 3.5 m
    /// across, 0.04 m cells refined once against uniform 0.02 m cells, the two cost the same where
    /// the patches hold 25% (docs/performance.md, "Uniform when the patches cover most"). The
    /// per-cell costs alone put it near 47%, but the uniform grid sweeps only the air the blast has
    /// reached and a refined run also fills halos, refluxes, restricts and regrids every step.
    public static let uniformShare = 0.25

    /// The settings worth weighing for `scenario`: cells scaled to its charge and the presets,
    /// unrefined or refined once or twice at each threshold, with and without afterburning, and
    /// no grid larger than `maximumCells` or 2,048 cells a side. A scene with blocks, structures or
    /// other contents keeps to cells no coarser than the coarse preset, which they were built for.
    public static func candidates(_ scenario: Scenario, maximumCells: Int) -> [AdvisorSetting] {
        let scale = cbrt(max(scenario.charge.mass, 1e-6))
        var sizes = Set(scaledCells.map { round2(scale * $0) } + presetCells)
        let coarsest = scenario.contentBounds == nil ? Float.infinity : presetCells[0]
        sizes = sizes.filter { size in
            guard size <= coarsest else { return false }
            let grid = scenario.grid(cellSize: size)
            return grid.cellCount <= maximumCells && max(grid.nx, grid.ny, grid.nz) <= 2048 && size >= 0.01
        }
        var settings: [AdvisorSetting] = []
        for size in sizes.sorted(by: >) {
            for afterburning in [false, true] {
                settings.append(AdvisorSetting(cellSize: size, afterburning: afterburning))
                for levels in [1, 2] {
                    for threshold in thresholds {
                        settings.append(
                            AdvisorSetting(
                                cellSize: size, refinement: 2, levels: levels, threshold: threshold,
                                afterburning: afterburning))
                    }
                }
            }
        }
        return settings
    }

    /// The advice for `target` over `candidates`, each costed by `RunCost` and its errors from
    /// `evaluate` (the standing's error bands for that setting). Ties go to the setting nearest
    /// `current`; a setting over `memory` bytes is never chosen.
    public static func advise(
        _ scenario: Scenario, configuration: SolverConfiguration, duration: Double, target: AdvisorTarget,
        current: AdvisorSetting, memory: Int, maximumCells: Int,
        evaluate: (AdvisorSetting) -> (error: [AdvisorQuantity: Double], unbanded: [AdvisorQuantity: String])
    ) -> Advice {
        func weigh(_ setting: AdvisorSetting) -> AdvisorCandidate? {
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
        let weighed = candidates(scenario, maximumCells: maximumCells).compactMap(weigh).filter {
            seen.insert($0.setting).inserted
        }.sorted { $0.cost.seconds < $1.cost.seconds }
        let stoodIn = weigh(current).flatMap { $0.standsFor == nil ? nil : $0 }
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
                    target: target, kind: .cheapestMeeting, chosen: cheapest, met: true, unmet: [],
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
            } else {
                let reason =
                    weighed.compactMap { $0.unbanded[quantity] }.first
                    ?? "no comparison on record covers this scene"
                unmet.append("No setting has an expected error for \(quantity.title): \(reason).")
            }
            // With nothing to aim by, the settings as they are.
            let fallback = weighed.first { $0.setting == current } ?? weighed.first
            return Advice(
                target: target, kind: .cheapestMeeting, chosen: nearest ?? fallback, met: false, unmet: unmet,
                candidates: weighed, currentStandIn: stoodIn)
        case .seconds(let budget):
            let affordable = weighed.filter { $0.cost.seconds <= budget }
            guard !affordable.isEmpty else {
                return Advice(
                    target: target, kind: .bestWithinBudget, chosen: weighed.first, met: false,
                    unmet: [
                        "Even the cheapest setting is expected to take \(Self.duration(weighed.first?.cost.seconds ?? 0))."
                    ],
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
                target: target, kind: .bestWithinBudget, chosen: best, met: true, unmet: [],
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

    /// Two significant figures.
    static func round2(_ value: Float) -> Float {
        guard value > 0 else { return value }
        let step = pow(10, floor(log10(value)) - 1)
        return (value / step).rounded() * step
    }

    /// Seconds as people say them.
    public static func duration(_ seconds: Double) -> String {
        switch seconds {
        case ..<1: "under a second"
        case ..<90: String(format: "%.0f s", seconds)
        case ..<5400: String(format: "%.0f minutes", seconds / 60)
        default: String(format: "%.1f hours", seconds / 3600)
        }
    }
}
