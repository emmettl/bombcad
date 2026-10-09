import AppKit
import BlastCore
import BlastRender
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var model: SimulationModel
    @Environment(\.newDocument) private var newDocument
    @Environment(\.openWindow) private var openWindow
    @State private var isImportingJSON = false
    @State private var isImporting = false
    @State private var importLoader = ImportFileLoader()
    @State private var dropTargeted = false
    @State private var sourceInspectorVisible = false
    @State private var fileError: String?
    @State private var isExportingJSON = false

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(model: model)
                .disabled(model.sweep.isActive)
                .frame(width: 310)
            Divider()
            VStack(spacing: 0) {
                MetalView(model: model)
                    .dropDestination(for: URL.self) { urls, _ in
                        guard !model.sweep.isActive, urls.count == 1, !importLoader.isLoading,
                            importLoader.result == nil,
                            model.inspectedImport == nil
                        else { return false }
                        importLoader.load(urls[0])
                        return true
                    } isTargeted: {
                        dropTargeted = $0
                    }
                    .overlay {
                        if dropTargeted {
                            RoundedRectangle(cornerRadius: 12).stroke(.blue, lineWidth: 3)
                                .overlay {
                                    Text("Drop an OBJ, STL or IFC model").font(.title2).padding().background(
                                        .regularMaterial, in: .rect(cornerRadius: 8))
                                }
                                .padding(12).allowsHitTesting(false)
                        }
                    }
                    .overlay(alignment: .top) {
                        if importLoader.isLoading {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("Reading and checking \(importLoader.filename)…")
                                Button("Cancel checking") { importLoader.cancel() }.keyboardShortcut(
                                    .cancelAction)
                            }.padding(12).background(.regularMaterial, in: .rect(cornerRadius: 8)).padding(12)
                        }
                    }
                    .overlay(alignment: .topLeading) { StatusOverlay(model: model).padding(12) }
                    .overlay(alignment: .bottomLeading) {
                        ImportSelectionHint(model: model).padding(12).allowsHitTesting(false)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        VStack(alignment: .trailing, spacing: 8) {
                            if model.structureSummary != nil { DamageLegendView() }
                            if model.thermalSpec != nil, let quantity = model.renderSettings.thermal {
                                ThermalLegendView(quantity: quantity)
                            } else {
                                LegendView(settings: model.renderSettings)
                            }
                        }
                        .padding(12)
                    }
                    .overlay(alignment: .bottom) {
                        if let message = model.errorMessage {
                            Text(message)
                                .padding(10)
                                .background(.red.opacity(0.85), in: .rect(cornerRadius: 8))
                                .foregroundStyle(.white)
                                .padding(.bottom, 16)
                        }
                    }
                Divider()
                GaugeChartView(model: model)
                    .frame(height: 230)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button("Open Project…", systemImage: "folder") {
                    NSDocumentController.shared.openDocument(nil)
                }
                .help("Open a BombCAD project in its own window")
                Button("Save Project", systemImage: "square.and.arrow.down") {
                    NSApp.sendAction(#selector(NSDocument.save(_:)), to: nil, from: nil)
                }
                .help("Save this project; named projects also autosave")
                Menu {
                    Button("Save As…") {
                        NSApp.sendAction(#selector(NSDocument.saveAs(_:)), to: nil, from: nil)
                    }
                    Button("Import Layout JSON…") { isImportingJSON = true }
                    Button("Export for Rendering…") { model.showsRenderExport = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                Button("Export Layout JSON…", systemImage: "doc.text") { isExportingJSON = true }
                Button(importLoader.isLoading ? "Checking Model…" : "Import Model…", systemImage: "cube.box")
                {
                    isImporting = true
                }.disabled(importLoader.isLoading || model.sweep.isActive)
                    .help("Open one OBJ, STL or IFC model, or drop it into the viewport.")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle("Place Charge", systemImage: "scope", isOn: $model.isPlacingCharge)
                    .help("Click the ground in the view to move the charge")
                Button(
                    model.isRunning ? "Pause" : "Run",
                    systemImage: model.isRunning ? "pause.fill" : "play.fill"
                ) {
                    model.toggleRun()
                }
                .disabled(model.isLoadingInputs || model.isPreparingImports || model.sweep.isActive)
                .help("Run or pause the simulation (Space)")
                Button("Reset", systemImage: "arrow.counterclockwise") { model.reset() }
                    .help("Return to the moment before detonation (⌘R)")
                Button("Help", systemImage: "questionmark.circle") { openWindow(id: "help") }
                    .help("Open BombCAD Help")
            }
        }
        .onChange(of: model.settings) { model.settingsChanged() }
        .fileImporter(isPresented: $isImportingJSON, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                let imported = try ProjectDocument.read(from: url)
                newDocument(imported)
            } catch {
                fileError = "Could not import the layout: \(error.localizedDescription)"
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [
                UTType(filenameExtension: "obj") ?? .data, UTType(filenameExtension: "stl") ?? .data,
                UTType(filenameExtension: "ifc") ?? .data,
            ]
        ) { result in
            guard case .success(let url) = result else { return }
            importLoader.load(url)
        }
        .onChange(of: importLoader.failureID) { if let error = importLoader.error { fileError = error } }
        .sheet(
            item: Binding(
                get: { model.inspectedImport }, set: { if $0 == nil { model.inspectedImportID = nil } }),
            onDismiss: { sourceInspectorVisible = false }
        ) { imported in
            if imported.source.buildingSourceData != nil {
                IFCImportFlow(
                    mesh: imported.source, filename: imported.name, existing: imported, model: model)
            } else {
                ModelImportView(
                    mesh: imported.source, filename: imported.name, existing: imported, model: model)
            }
        }
        .sheet(
            item: Binding(
                get: { model.inspectedImport == nil && !sourceInspectorVisible ? importLoader.result : nil },
                set: { if $0 == nil { importLoader.dismissResult() } }),
            onDismiss: { importLoader.presentationDismissed() }
        ) { loaded in
            if let building = loaded.building {
                IFCImportFlow(prepared: building, filename: loaded.filename, model: model)
            } else if let mesh = loaded.inspection?.validatedMesh {
                ModelImportView(mesh: mesh, filename: loaded.filename, model: model)
            } else if let inspection = loaded.inspection {
                ImportRecoveryView(filename: loaded.filename, inspection: inspection) { url in
                    importLoader.retryAfterDismissal(url)
                }
            }
        }
        .sheet(isPresented: $model.showsRenderExport) { RenderExportView(model: model) }
        .onChange(of: model.inspectedImportID) {
            if model.inspectedImportID != nil { sourceInspectorVisible = true }
        }
        .onDisappear { importLoader.cancel() }
        .fileExporter(
            isPresented: $isExportingJSON, document: ScenarioDocument(scenario: model.settings.scenario),
            contentType: .json, defaultFilename: model.settings.scenario.name
        ) { result in
            if case .failure(let error) = result {
                fileError = "Could not export the layout: \(error.localizedDescription)"
            }
        }
        .alert(
            "File error",
            isPresented: Binding(get: { fileError != nil }, set: { if !$0 { fileError = nil } })
        ) {
            Button("OK") { fileError = nil }
        } message: {
            Text(fileError ?? "")
        }
    }

}

/// Time and playback state, drawn over the viewport.
private struct StatusOverlay: View {
    let model: SimulationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("t = \(model.time * 1000, format: .number.precision(.fractionLength(1))) ms")
                .font(.system(.title2, design: .rounded).monospacedDigit().weight(.semibold))
            Text(model.isPreparingImports ? "Resampling imported geometry…" : statusLine)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: .rect(cornerRadius: 10))
    }

    private var statusLine: String {
        if model.isRunning, model.stats.slowMotion > 0 {
            return "\(Int(model.stats.slowMotion.rounded()))× slower than real time"
        }
        if model.time == 0 { return "Ready" }
        return model.time >= model.duration - 1e-9 ? "Finished · \(model.stepCount) steps" : "Paused"
    }
}

/// Colour scale for the field painted on the ground and blocks.
private struct LegendView: View {
    let settings: RenderSettings

    // Matches `heat` in Render.metal.
    private static let stops: [Color] = [
        Color(red: 0.05, green: 0.04, blue: 0.22), Color(red: 0.30, green: 0.07, blue: 0.50),
        Color(red: 0.67, green: 0.14, blue: 0.42), Color(red: 0.92, green: 0.33, blue: 0.16),
        Color(red: 0.99, green: 0.68, blue: 0.10), Color(red: 0.99, green: 0.98, blue: 0.70),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(settings.mode.title) (\(settings.mode.unit))")
                .font(.caption.weight(.semibold))
            LinearGradient(colors: Self.stops, startPoint: .leading, endPoint: .trailing)
                .frame(width: 220, height: 10)
                .clipShape(.rect(cornerRadius: 3))
            HStack {
                ForEach(ticks.indices, id: \.self) { index in
                    Text(ticks[index])
                    if index < ticks.count - 1 { Spacer() }
                }
            }
            .font(.caption2.monospacedDigit())
            .frame(width: 220)
        }
        .padding(10)
        .background(.regularMaterial, in: .rect(cornerRadius: 10))
    }

    /// Labels at each decade of the logarithmic scale, lowest first.
    private var ticks: [String] {
        let top = Double(settings.surfaceScale)
        let decades = Int(settings.decades)
        return (0...decades).map { step in
            let value = top / pow(10, Double(decades - step))
            return value >= 10 ? String(format: "%.0f", value) : String(format: "%.1f", value)
        }
    }
}

/// Colour scale for the thermal radiation painted on the ground and blocks.
private struct ThermalLegendView: View {
    let quantity: ThermalQuantity

    // Matches `glow` in Render.metal.
    private static let stops: [Color] = [
        Color(red: 0.30, green: 0.04, blue: 0.07), Color(red: 0.62, green: 0.08, blue: 0.06),
        Color(red: 0.91, green: 0.32, blue: 0.07), Color(red: 0.99, green: 0.67, blue: 0.17),
        Color(red: 1.00, green: 0.96, blue: 0.78),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(quantity.title) so far (\(quantity.unit))")
                .font(.caption.weight(.semibold))
            LinearGradient(colors: Self.stops, startPoint: .leading, endPoint: .trailing)
                .frame(width: 220, height: 10)
                .clipShape(.rect(cornerRadius: 3))
            HStack {
                ForEach(ticks.indices, id: \.self) { index in
                    Text(ticks[index])
                    if index < ticks.count - 1 { Spacer() }
                }
            }
            .font(.caption2.monospacedDigit())
            .frame(width: 220)
        }
        .padding(10)
        .background(.regularMaterial, in: .rect(cornerRadius: 10))
    }

    /// Labels at each decade of the scale, in kJ/m² or kW/m², lowest first.
    private var ticks: [String] {
        (0...Int(ThermalQuantity.decades)).map { step in
            let value = Double(ThermalQuantity.scaleBottom) / 1000 * pow(10, Double(step))
            return value >= 1 ? String(format: "%.0f", value) : String(format: "%.1f", value)
        }
    }
}

/// Colour scale for the damage painted on the deformable structure.
private struct DamageLegendView: View {
    // Matches `structureFragment` in Render.metal.
    private static let stops: [Color] = [
        Color(red: 0.80, green: 0.79, blue: 0.76), Color(red: 0.98, green: 0.82, blue: 0.25),
        Color(red: 0.93, green: 0.42, blue: 0.12), Color(red: 0.55, green: 0.06, blue: 0.08),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Structure: damage")
                .font(.caption.weight(.semibold))
            LinearGradient(colors: Self.stops, startPoint: .leading, endPoint: .trailing)
                .frame(width: 220, height: 10)
                .clipShape(.rect(cornerRadius: 3))
            HStack {
                Text("Sound")
                Spacer()
                Text("Failing")
            }
            .font(.caption2)
            .frame(width: 220)
        }
        .padding(10)
        .background(.regularMaterial, in: .rect(cornerRadius: 10))
    }
}

private struct ImportSelectionHint: View {
    let model: SimulationModel
    var body: some View {
        if model.settings.scenario.importedModels?.contains(where: { $0.isAttached }) == true {
            Text(
                model.isPlacingCharge
                    ? "Turn off Place Charge to select imported models."
                    : model.time > 0 || model.isRunning
                        ? "Reset the simulation to select imported models."
                        : "Click an imported model to edit its source, placement and material."
            )
            .font(.caption).frame(maxWidth: 350, alignment: .leading).padding(8)
            .background(.regularMaterial, in: .rect(cornerRadius: 6))
        }
    }
}
