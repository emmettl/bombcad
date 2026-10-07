import SwiftUI

struct ParameterSweepView: View {
    let model: SimulationModel
    @Environment(\.dismiss) private var dismiss
    @State private var prefix = "Experiment"
    @State private var variesGrid = false
    @State private var masses = "1, 2, 5"
    @State private var grids: Set<Resolution> = [.coarse, .medium, .fine]
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Parameter sweep").font(.title2)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(
                "Cases run sequentially at unlimited playback. Successful results are kept; your original editor inputs and playback speed are restored at the end."
            )
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                Text("Result name prefix").font(.caption).fixedSize(horizontal: false, vertical: true)
                TextField("Result name prefix", text: $prefix).textFieldStyle(.roundedBorder)
                Picker("Vary", selection: $variesGrid) {
                    Text("Primary charge mass").tag(false)
                    Text("Air grid resolution").tag(true)
                }
                if variesGrid {
                    ForEach(Resolution.allCases) { grid in
                        Toggle(
                            grid.title,
                            isOn: Binding(
                                get: { grids.contains(grid) },
                                set: { selected in
                                    if selected { grids.insert(grid) } else { grids.remove(grid) }
                                }))
                    }
                    Text(
                        "Attached imports resample independently from the baseline for each case. Detached geometry and its structural element size stay unchanged."
                    )
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Masses (kg TNT, comma-separated)").font(.caption).fixedSize(
                        horizontal: false, vertical: true)
                    TextField("Masses (kg TNT, comma-separated)", text: $masses).textFieldStyle(
                        .roundedBorder)
                    Text(
                        "Use one to eight distinct nonnegative masses. Other charges and all other inputs remain at their baseline values."
                    )
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
                }
            }.disabled(model.sweep.isActive)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            if !model.sweep.message.isEmpty {
                Text(model.sweep.message).font(.callout)
            }
            if model.sweep.isActive {
                ProgressView(value: Double(model.sweep.completed), total: Double(max(1, model.sweep.total)))
                Button("Cancel sweep") { model.sweep.cancel() }
            } else {
                Button("Start sweep") {
                    do {
                        let parameter: ParameterSweepPlan.Parameter
                        if variesGrid {
                            parameter = .grid(Resolution.allCases.filter { grids.contains($0) })
                        } else {
                            let fields = masses.split(separator: ",", omittingEmptySubsequences: false)
                            let values = fields.compactMap {
                                Float($0.trimmingCharacters(in: .whitespacesAndNewlines))
                            }
                            guard values.count == fields.count else {
                                throw SweepInputError.invalidMasses
                            }
                            parameter = .chargeMass(values)
                        }
                        try model.sweep.start(ParameterSweepPlan(prefix: prefix, parameter: parameter))
                        error = nil
                    } catch { self.error = error.localizedDescription }
                }.disabled(!model.experimentIsReady)
                if !model.experimentIsReady {
                    Text("Reset the simulation before starting a sweep.").font(.caption).foregroundStyle(
                        .secondary)
                    Button("Reset to start") { model.reset() }
                }
            }
            Text(
                "Available result slots: \(SavedSimulationRun.maximumRuns - model.savedRuns.count). Intermediate case inputs are not saved as your editor's scene."
            )
            .font(.caption).foregroundStyle(.secondary)
        }.frame(width: 530, alignment: .leading).padding(20).frame(minHeight: 450, alignment: .top)
            .onAppear { masses = String(model.settings.scenario.charge.mass) }
    }

    private enum SweepInputError: LocalizedError {
        case invalidMasses
        var errorDescription: String? { "Enter comma-separated numerical masses, for example 1, 2, 5." }
    }
}
