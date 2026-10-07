import BlastCore
import BlastRender
import SwiftUI

struct SidebarView: View {
    @Bindable var model: SimulationModel
    @State private var tab = Tab.run

    private enum Tab: String, CaseIterable {
        case run = "Run"
        case edit = "Edit layout"
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            switch tab {
            case .run: runForm
            case .edit: EditorView(model: model)
            }
        }
        .onChange(of: tab) {
            if case .imported = model.selection, tab == .edit { return }
            model.selection = nil
        }
        .onChange(of: model.selection) { if case .imported = model.selection { tab = .edit } }
    }

    private var runForm: some View {
        Form {
            Section("Scenario") {
                Picker(
                    "Layout", selection: Binding(get: { model.settings.preset }, set: { model.select($0) })
                ) {
                    ForEach(ScenarioPreset.allCases) { Text($0.title).tag($0) }
                }
                Picker("Grid", selection: $model.settings.resolution) {
                    ForEach(Resolution.allCases) { Text($0.title).tag($0) }
                }
                if let grid = model.grid {
                    LabeledContent("Cells", value: cellSummary(grid))
                    LabeledContent(
                        "GPU memory", value: String(format: "%.2f GB", Double(model.memoryFootprint) / 1e9))
                }
            }

            if let imports = model.settings.scenario.importedModels, !imports.isEmpty {
                Section("Imported geometry") {
                    if model.isPreparingImports { ProgressView("Resampling…") }
                    ForEach(imports) { imported in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(imported.name).font(.headline)
                            if !imported.isAttached {
                                Text("Detached geometry; source retained for inspection.").font(.caption)
                            } else if !imported.preview.diagnostics.isEmpty
                                || imported.preview.diagnosticsTruncated
                            {
                                Label(
                                    "\(imported.preview.diagnosticsTruncated ? "At least " : "")\(imported.preview.diagnostics.count) approximate affected regions at \(imported.preview.cellSize, format:.number) m sampling. Inspect before running.",
                                    systemImage: "exclamationmark.triangle"
                                ).font(.caption).foregroundStyle(.orange)
                            } else {
                                Text(
                                    "Sampled at \(imported.preview.cellSize, format:.number) m. Compare finer grids to assess accuracy."
                                ).font(.caption)
                            }
                            Button("Inspect source and warnings…") { model.inspectImport(id: imported.id) }
                        }
                    }
                }
            }

            Section("Charge") {
                // Logarithmic slider: 1 kg to 2 tonnes.
                LabeledSlider(
                    title: "TNT equivalent",
                    value: Binding(
                        get: { log10(Double(model.settings.chargeMass)) },
                        set: { model.settings.chargeMass = Float(pow(10, $0).rounded()) }),
                    range: 0...3.3,
                    text: "\(Int(model.settings.chargeMass)) kg")
                Toggle("Afterburning and hot air", isOn: $model.settings.detailedCharge)
                    .help(
                        "Burns the charge's products in the air they mix with, and lets hot air store energy "
                            + "in molecular vibration. Closer to tests of charges in rooms and in the open; "
                            + "about twice as slow.")
                Toggle("Sharpen shocks", isOn: $model.settings.sharpShocks)
                    .help(
                        "Refines the air twice over where the shock is, so that peak pressures and the loads "
                            + "on walls come out close to those of the next finer resolution, at a fraction of its "
                            + "cost.")
                LabeledSlider(
                    title: "X", value: axisBinding(\.x), range: 1...Double(model.domainSize.x - 1),
                    text: metres(model.settings.chargePosition.x))
                LabeledSlider(
                    title: "Y", value: axisBinding(\.y), range: 1...Double(model.domainSize.y - 1),
                    text: metres(model.settings.chargePosition.y))
                LabeledSlider(
                    title: "Height", value: axisBinding(\.z), range: 0...Double(model.domainSize.z / 2),
                    text: metres(model.settings.chargePosition.z))
                if model.chargeIsBlocked {
                    Label(
                        "The charge is inside a block or wall and will release no energy.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }

            if let summary = model.structureSummary {
                Section("Structure") {
                    Picker(
                        "Material",
                        selection: Binding(
                            get: { model.settings.material }, set: { model.setStructureMaterial($0) })
                    ) {
                        ForEach(StructureMaterial.presets, id: \.self) { Text($0.name).tag($0) }
                        if !StructureMaterial.presets.contains(model.settings.material) {
                            Text("Custom: \(model.settings.material.name)").tag(model.settings.material)
                        }
                    }
                    LabeledContent("Elements", value: "\(summary.activeElements + summary.erodedElements)")
                    LabeledContent(
                        "Failed",
                        value: String(
                            format: "%d (%.1f%%)", summary.erodedElements, summary.erodedFraction * 100))
                    LabeledContent(
                        "Deflection now", value: String(format: "%.0f mm", summary.maxDisplacement * 1000))
                    LabeledContent("Largest so far", value: String(format: "%.0f mm", model.peakDeflection))
                    LabeledContent(
                        "Worst damage", value: String(format: "%.0f%%", min(summary.maxDamage, 1) * 100))
                    LabeledContent("Substeps per air step", value: "up to \(model.structureSubsteps)")
                }
                .monospacedDigit()
            }

            Section("Playback") {
                Picker("Speed", selection: $model.speed) {
                    ForEach(PlaybackSpeed.allCases) { Text($0.title).tag($0) }
                }
                LabeledSlider(
                    title: "Stop after", value: $model.duration, range: 0.02...3,
                    text: "\(Int((model.duration * 1000).rounded())) ms")
            }

            Section("Display") {
                Picker("Surfaces", selection: $model.renderSettings.mode) {
                    ForEach(DisplayMode.allCases) { Text($0.title).tag($0) }
                }
                if model.renderSettings.mode == .impulse {
                    Picker("Scale maximum", selection: $model.renderSettings.impulseScale) {
                        ForEach([100, 300, 1000, 3000, 10000] as [Float], id: \.self) {
                            Text("\(Int($0)) kPa·ms").tag($0)
                        }
                    }
                } else {
                    Picker("Scale maximum", selection: $model.renderSettings.pressureScale) {
                        ForEach([30, 100, 300, 1000, 3000] as [Float], id: \.self) {
                            Text("\(Int($0)) kPa").tag($0)
                        }
                    }
                }
                Toggle("Blast wave in air", isOn: $model.renderSettings.showWave)
                if model.renderSettings.showWave {
                    LabeledSlider(
                        title: "Wave opacity",
                        value: Binding(
                            get: { Double(model.renderSettings.waveOpacity) },
                            set: { model.renderSettings.waveOpacity = Float($0) }),
                        range: 0.05...1.5,
                        text: String(format: "%.2f", model.renderSettings.waveOpacity))
                }
            }

            Section("Solver") {
                LabeledContent(
                    "Throughput",
                    value: String(format: "%.2f G cells/s", model.stats.cellUpdatesPerSecond / 1e9))
                LabeledContent("Step rate", value: "\(Int(model.stats.stepsPerSecond)) steps/s")
                LabeledContent("Time step", value: String(format: "%.0f µs", model.stats.timeStep * 1e6))
                LabeledContent("Steps taken", value: "\(model.stepCount)")
            }
            .monospacedDigit()
        }
        .formStyle(.grouped)
    }

    private func axisBinding(_ axis: WritableKeyPath<SIMD3<Float>, Float>) -> Binding<Double> {
        Binding(
            get: { Double(model.settings.chargePosition[keyPath: axis]) },
            // Snap to 0.25 m so the charge stays aligned with every grid resolution.
            set: { model.settings.chargePosition[keyPath: axis] = Float(($0 * 4).rounded() / 4) })
    }

    private func metres(_ value: Float) -> String { String(format: "%.2f m", value) }

    private func cellSummary(_ grid: BlastCore.Grid) -> String {
        String(format: "%d × %d × %d = %.1f M", grid.nx, grid.ny, grid.nz, Double(grid.cellCount) / 1e6)
    }
}

/// A slider with its title and current value on the line above it.
struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(text)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
                .labelsHidden()
        }
    }
}
