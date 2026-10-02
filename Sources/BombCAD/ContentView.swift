import BlastCore
import BlastRender
import SwiftUI

struct ContentView: View {
    @Bindable var model: SimulationModel
    @State private var isOpening = false
    @State private var isSaving = false
    @State private var fileError: String?

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(model: model)
                .frame(width: 310)
            Divider()
            VStack(spacing: 0) {
                MetalView(model: model)
                    .overlay(alignment: .topLeading) { StatusOverlay(model: model).padding(12) }
                    .overlay(alignment: .bottomTrailing) {
                        VStack(alignment: .trailing, spacing: 8) {
                            if model.structureSummary != nil { DamageLegendView() }
                            LegendView(settings: model.renderSettings)
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
                Button("Open Layout…", systemImage: "folder") { isOpening = true }
                    .help("Open a saved layout")
                Button("Save Layout…", systemImage: "square.and.arrow.down") { isSaving = true }
                    .help("Save this layout to a file")
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
                .help("Run or pause the simulation (Space)")
                Button("Reset", systemImage: "arrow.counterclockwise") { model.reset() }
                    .help("Return to the moment before detonation (⌘R)")
            }
        }
        .onChange(of: model.settings) { model.settingsChanged() }
        .fileImporter(isPresented: $isOpening, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                model.open(try JSONDecoder().decode(Scenario.self, from: Data(contentsOf: url)))
            } catch {
                fileError = "That file is not a BombCAD layout: \(error.localizedDescription)"
            }
        }
        .fileExporter(
            isPresented: $isSaving, document: ScenarioDocument(scenario: model.settings.scenario),
            contentType: .json, defaultFilename: model.settings.scenario.name
        ) { result in
            if case .failure(let error) = result {
                fileError = "Could not save the layout: \(error.localizedDescription)"
            }
        }
        .alert(
            "Layout file",
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
            Text(statusLine)
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
