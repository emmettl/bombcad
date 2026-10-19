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
    /// Refined, each level takes only the substeps its own waves need
    /// (`SolverConfiguration.refinementOwnSteps`); the advisor turns it on where it pays
    /// (`RunAdvisor.ownStepsShare`).
    public var ownSteps: Bool

    public init(
        cellSize: Float, refinement: Int = 1, levels: Int = 1, threshold: Float = 0.1,
        afterburning: Bool = SolverConfiguration.recommended.afterburning, ownSteps: Bool = false
    ) {
        self.cellSize = cellSize
        self.refinement = refinement
        self.levels = levels
        self.threshold = threshold
        self.afterburning = afterburning
        self.ownSteps = refinement > 1 && ownSteps
    }

    private enum CodingKeys: String, CodingKey {
        case cellSize, refinement, levels, threshold, afterburning, ownSteps
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            cellSize: try values.decode(Float.self, forKey: .cellSize),
            refinement: try values.decode(Int.self, forKey: .refinement),
            levels: try values.decode(Int.self, forKey: .levels),
            threshold: try values.decode(Float.self, forKey: .threshold),
            afterburning: try values.decode(Bool.self, forKey: .afterburning),
            // Settings saved before adaptive substeps take every substep.
            ownSteps: try values.decodeIfPresent(Bool.self, forKey: .ownSteps) ?? false)
    }

    /// `configuration` with these settings of the air.
    public func applied(to configuration: SolverConfiguration) -> SolverConfiguration {
        var configuration = configuration
        configuration.refinement = refinement
        configuration.refinementLevels = refinement > 1 ? levels : 1
        configuration.refinementThreshold = threshold
        configuration.refinementOwnSteps = refinement > 1 && ownSteps
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
            if ownSteps { text += ", adaptive substeps" }
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

    /// The memberwise initialiser, written out so that BlastCore can use it.
    package init(
        setting: AdvisorSetting,
        cost: RunCostEstimate,
        error: [AdvisorQuantity: Double],
        unbanded: [AdvisorQuantity: String],
        standsFor: AdvisorSetting? = nil,
        standsForShare: Double = 0.0
    ) {
        self.setting = setting
        self.cost = cost
        self.error = error
        self.unbanded = unbanded
        self.standsFor = standsFor
        self.standsForShare = standsForShare
    }
}

/// A Mac a run may be sent to, and the GPU memory it lets the air take (seven tenths of its
/// recommended working set, as the app allows).
public struct AdvisorMachine: Sendable, Equatable, Codable {
    public var name: String
    public var memory: Int

    public init(name: String, memory: Int) {
        self.name = name
        self.memory = memory
    }

    /// Bytes as people say them, to a tenth of a gigabyte.
    public static func gigabytes(_ bytes: Int) -> String {
        String(format: "%.1f GB", Double(bytes) / 1e9)
    }
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

    /// The memberwise initialiser, written out so that BlastCore can use it.
    package init(
        target: AdvisorTarget,
        kind: Kind,
        chosen: AdvisorCandidate? = nil,
        met: Bool,
        unmet: [String],
        candidates: [AdvisorCandidate],
        currentStandIn: AdvisorCandidate? = nil
    ) {
        self.target = target
        self.kind = kind
        self.chosen = chosen
        self.met = met
        self.unmet = unmet
        self.candidates = candidates
        self.currentStandIn = currentStandIn
    }
}

public enum RunAdvisor {
    /// The cells, per cube root of the charge's mass, that the advisor tries: those of the
    /// comparisons on record and halves and doubles of them.
    public static let scaledCells: [Float] = [0.4, 0.2, 0.1, 0.05, 0.025]
    public static let presetCells: [Float] = [0.5, 0.25, 0.125]
    public static let thresholds: [Float] = [0.1, 0.02, 0.005]
    /// The share of its substeps a refined level is expected to take (`RunCost.ownStepsShare`)
    /// under which the advisor turns adaptive substeps on: 1.6 of 2. Measured on the recommended
    /// air, they make refined runs 1.19 times faster on open ground (0.63 taken) and 1.07 times on
    /// the street (0.70); close in, where every substep is taken, their bookkeeping costs a little.
    public static let ownStepsShare = 0.8
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
