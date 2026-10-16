import BlastCore
import Foundation
import Metal
import SwiftUI

// The cost-against-fidelity advisor in the app and `BombCAD run --advise`: the settings of the
// air that meet a target most cheaply, or the best fidelity within a budget, each candidate's
// fidelity read from the standing's error bands and its cost from `RunCost` (see
// docs/performance.md, "Choosing settings").

extension ProjectRunSettings {
    /// The air's settings these are, as the advisor weighs them.
    var advisorSetting: AdvisorSetting {
        AdvisorSetting(
            cellSize: (Resolution(rawValue: resolution) ?? .medium).cellSize,
            refinement: sharpShocks ? 2 : 1, levels: sharpShocks ? (shockLevels ?? 1) : 1,
            threshold: shockThreshold ?? 0.1, afterburning: detailedCharge,
            ownSteps: sharpShocks && adaptiveSubsteps == true)
    }

    /// These settings with the advisor's `setting` of the air.
    func applying(_ setting: AdvisorSetting) -> ProjectRunSettings {
        var settings = self
        settings.resolution = (Resolution(cellSize: setting.cellSize) ?? .medium).rawValue
        settings.sharpShocks = setting.refinement > 1
        settings.shockLevels = setting.refinement > 1 && setting.levels > 1 ? 2 : nil
        settings.shockThreshold = setting.refinement > 1 && setting.threshold != 0.1 ? setting.threshold : nil
        settings.adaptiveSubsteps = setting.refinement > 1 && setting.ownSteps ? true : nil
        settings.detailedCharge = setting.afterburning
        return settings
    }
}

extension ProjectRunSettings {
    /// What a run of `scenario` under these settings is expected to cost.
    func costEstimate(_ scenario: Scenario) -> RunCostEstimate {
        var configuration = SolverConfiguration()
        Self.configureAir(
            &configuration, detailedCharge: detailedCharge, sharpShocks: sharpShocks,
            shockLevels: shockLevels ?? 1, gravity: gravity ?? false, shockThreshold: shockThreshold ?? 0.1,
            adaptiveSubsteps: adaptiveSubsteps ?? false, terrainCutCells: cutsTerrain(over: scenario),
            outlineByOverlap: countsByOverlap(over: scenario))
        return RunCost.estimate(
            scenario, cellSize: (Resolution(rawValue: resolution) ?? .medium).cellSize,
            configuration: configuration,
            duration: duration)
    }
}

extension SimulationInputs {
    /// The advice for `target` on these inputs, within `memory` bytes of GPU memory. `factor`
    /// scales the estimates to this Mac as its runs have gone (`RunCostStore`).
    func advice(for target: AdvisorTarget, memory: Int) -> Advice {
        var configuration = SolverConfiguration()
        ProjectRunSettings.configureAir(
            &configuration, detailedCharge: settings.detailedCharge, sharpShocks: settings.sharpShocks,
            shockLevels: settings.shockLevels ?? 1, gravity: settings.gravity ?? false,
            shockThreshold: settings.shockThreshold ?? 0.1,
            adaptiveSubsteps: settings.adaptiveSubsteps ?? false,
            terrainCutCells: settings.cutsTerrain(over: scenario),
            outlineByOverlap: settings.countsByOverlap(over: scenario))
        return RunAdvisor.advise(
            scenario, configuration: configuration, duration: settings.duration, target: target,
            current: settings.advisorSetting, memory: memory, maximumCells: ProjectDocument.maximumCells
        ) { setting in
            Self.fidelity(scenario, settings.applying(setting), thermal: thermal)
        }
    }

    /// How far each result is expected to lie from the measurements under `settings`, by the
    /// standing's error bands: the worst over the gauges of the farther end of each band from 1.
    static func fidelity(_ scenario: Scenario, _ settings: ProjectRunSettings, thermal: ThermalSpec?) -> (
        error: [AdvisorQuantity: Double], unbanded: [AdvisorQuantity: String]
    ) {
        let standing = SceneStanding(settings.standingInputs(scenario, thermal: thermal))
        var error: [AdvisorQuantity: Double] = [:]
        var unbanded: [AdvisorQuantity: String] = [:]
        func deviation(_ band: ErrorBand) -> Double { max(abs(1 - band.low), abs(band.high - 1)) }
        let gauges = standing.gauges ?? []
        for (quantity, path) in [(AdvisorQuantity.peak, \GaugeBands.peak), (.impulse, \GaugeBands.impulse)] {
            guard !gauges.isEmpty else {
                unbanded[quantity] = "the scene has no gauges"
                continue
            }
            let banded = gauges.compactMap { $0[keyPath: path] }
            let missing = gauges.filter { $0[keyPath: path] == nil }
            if let first = missing.first {
                let reason = (first.note ?? "no comparison on record covers it").trimmingCharacters(
                    in: CharacterSet(charactersIn: "."))
                unbanded[quantity] =
                    missing.count == 1
                    ? "\(first.name): \(reason)" : "\(first.name) and \(missing.count - 1) more: \(reason)"
            }
            // The worst of the gauges that have a band; those without one are said so.
            if !banded.isEmpty { error[quantity] = banded.map(deviation).max() }
        }
        if let band = standing.band(.peakDeflection) {
            error[.deflection] = deviation(band)
        } else if !scenario.structuralObjects.isEmpty {
            unbanded[.deflection] =
                standing[.structuralResponse]?.unbanded?.first ?? "no comparison on record covers it"
        } else {
            unbanded[.deflection] = "the scene has no structure"
        }
        return (error, unbanded)
    }
}

extension SimulationInputs {
    /// For a scene with a structure: the advisor varies the air only, and the structure's band
    /// holds on its calibrated mesh, since no structural result converges on today's defaults.
    var structuralMeshNote: String? {
        guard !scenario.structuralObjects.isEmpty else { return nil }
        let standing = SceneStanding(settings.standingInputs(scenario, thermal: thermal))
        let mesh =
            standing.band(.peakDeflection)?.derivedMesh.map { "the mesh its band was derived on, \($0)" }
            ?? "the meshes of the record's comparisons"
        return "The structure's mesh is not varied: keep \(mesh). A finer structural mesh is not shown to "
            + "bring it closer to the measurements, since no structural result converges on today's defaults."
    }
}

extension SimulationModel {
    /// The GPU memory the advisor may plan for: what the app lets the air take.
    var advisorMemory: Int {
        Int(min(device?.recommendedMaxWorkingSetSize ?? 16 << 30, UInt64(Int.max)) / 10 * 7)
    }

    /// Takes the advisor's setting of the air.
    func apply(_ setting: AdvisorSetting) {
        if let resolution = Resolution(cellSize: setting.cellSize) { settings.resolution = resolution }
        settings.sharpShocks = setting.refinement > 1
        settings.shockLevels = setting.refinement > 1 ? setting.levels : 1
        settings.shockThreshold = setting.refinement > 1 ? setting.threshold : 0.1
        settings.adaptiveSubsteps = setting.refinement > 1 && setting.ownSteps
        settings.detailedCharge = setting.afterburning
    }
}

/// The Run tab's advisor: a target, and the settings that meet it, to apply.
struct AdvisorSection: View {
    @Bindable var model: SimulationModel
    @State private var quantity = Goal.peak
    @State private var percent = 20.0
    @State private var minutes = 10.0
    @State private var advice: Advice?
    @State private var working = false

    enum Goal: String, CaseIterable, Identifiable {
        case peak, impulse, deflection, time
        var id: String { rawValue }
        var title: String {
            switch self {
            case .peak: "Peaks within"
            case .impulse: "Impulse within"
            case .deflection: "Deflection within"
            case .time: "A run under"
            }
        }
    }

    private var target: AdvisorTarget {
        switch quantity {
        case .peak: .fidelity(.peak, within: percent / 100)
        case .impulse: .fidelity(.impulse, within: percent / 100)
        case .deflection: .fidelity(.deflection, within: percent / 100)
        case .time: .seconds(minutes * 60)
        }
    }

    var body: some View {
        Section("Advisor") {
            // The target on a row of its own: beside the value and the button, the sidebar's width
            // cut it to "Pea…".
            Picker("Target", selection: $quantity) {
                ForEach(Goal.allCases) { Text($0.title).tag($0) }
            }
            HStack {
                if quantity == .time {
                    TextField(
                        "Minutes", value: $minutes, format: .number.precision(.significantDigits(1...3))
                    )
                    .labelsHidden().frame(maxWidth: 56).multilineTextAlignment(.trailing)
                    Text("min")
                } else {
                    TextField(
                        "Percent", value: $percent, format: .number.precision(.significantDigits(1...3))
                    )
                    .labelsHidden().frame(maxWidth: 56).multilineTextAlignment(.trailing)
                    Text("%")
                }
                Spacer()
                Button(working ? "Weighing…" : "Suggest") { suggest() }.disabled(working)
            }
            .help(
                "Finds the cheapest grid, refinement and afterburning that bring the result within this of "
                    + "the measurements, as the standing's error bands expect, or the best fidelity a run of this "
                    + "length buys. Times are for an unloaded M4 Max, scaled to this Mac by its recent runs.")
            if let advice {
                Text(advice.summary).font(.callout).fixedSize(horizontal: false, vertical: true)
                if let chosen = advice.chosen {
                    Text(details(chosen)).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(
                        AdvisorQuantity.allCases.filter {
                            chosen.error[$0] != nil && chosen.unbanded[$0] != nil
                        }, id: \.self
                    ) {
                        quantity in
                        Text("Not counted in \(quantity.title): \(chosen.unbanded[quantity]!).").font(
                            .caption
                        )
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if let note = advice.standInNote {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(advice.unmet, id: \.self) { line in
                        Label(line, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(
                            .orange
                        )
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    if let note = SimulationInputs(
                        scenario: model.settings.scenario, settings: ProjectRunSettings(model: model)
                    ).structuralMeshNote {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button("Apply") { model.apply(chosen.setting) }
                        .disabled(chosen.setting == ProjectRunSettings(model: model).advisorSetting)
                }
            }
        }
    }

    private func details(_ candidate: AdvisorCandidate) -> String {
        var parts: [String] = []
        for quantity in AdvisorQuantity.allCases {
            if let error = candidate.error[quantity] {
                parts.append(String(format: "%@ within %.0f%%", quantity.title, error * 100))
            }
        }
        let memory = String(format: "%.1f GB", Double(candidate.cost.memory) / 1e9)
        var time = "about " + RunAdvisor.duration(candidate.cost.seconds) + " unloaded"
        if let factor = RunCostStore.standard.factor {
            time += ", " + RunAdvisor.duration(candidate.cost.seconds * factor) + " here lately"
        }
        return (parts + [String(format: "%.1fM cells", Double(candidate.cost.cells) / 1e6), memory, time])
            .joined(separator: " · ")
    }

    private func suggest() {
        let inputs = SimulationInputs(
            scenario: model.settings.scenario, settings: ProjectRunSettings(model: model),
            thermal: model.thermalSpec)
        let target = target
        let memory = model.advisorMemory
        working = true
        Task {
            let result = await Task.detached { inputs.advice(for: target, memory: memory) }.value
            advice = result
            working = false
        }
    }
}
