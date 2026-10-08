import AcousticCore
import AppKit
import RoomDocument
import SwiftUI
import UniformTypeIdentifiers

/// One document window: drawings, results and the inspector.
struct RoomEditorView: View {
    @Binding var document: RoomCADFile
    let fileURL: URL?
    @State private var editor = RoomEditor()
    @State private var player = AuditionPlayer()
    /// Play as soon as a response arrives; set when Play is pressed before there is one.
    @State private var playWhenGenerated = false
    @State private var spaceKey = SpaceKeyMonitor()
    @State private var chart = Chart.envelope
    @State private var view = RoomView.drawings

    enum Chart { case envelope, spectrum, early }
    enum RoomView { case drawings, threeD }

    private var project: RoomProject { document.project }

    /// How long the inputs must stay the same before a preview is refined to full quality.
    static let refinementDelay = Duration.seconds(1.5)

    private struct Refinement: Equatable {
        var settings: RoomResponseSettings
        var needed: Bool
    }

    var body: some View {
        HSplitView {
            VSplitView {
                VStack(spacing: 4) {
                    Picker("View", selection: $view) {
                        Text("Plan and Section").tag(RoomView.drawings)
                        Text("3D").tag(RoomView.threeD)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 240)
                    .padding(.top, 6)
                    switch view {
                    case .drawings:
                        HStack(spacing: 0) {
                            drawing(.plan)
                            Divider()
                            drawing(.elevation)
                        }
                    case .threeD:
                        RoomView3D(settings: project.settings)
                    }
                }
                .frame(minHeight: 260)
                results
                    .frame(minHeight: 220)
            }
            .frame(minWidth: 560)
            RoomInspector(project: $document.project)
                .frame(minWidth: 300, idealWidth: 340, maxWidth: 440)
        }
        .toolbar {
            ToolbarItemGroup {
                if editor.isGenerating {
                    ProgressView().controlSize(.small)
                    if let text = editor.progressText {
                        Text(text).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Button("Cancel", systemImage: "stop.fill") { editor.cancel() }
                        .keyboardShortcut(".", modifiers: .command)
                } else {
                    Button("Generate", systemImage: "waveform") { generate() }
                        .keyboardShortcut("r", modifiers: .command)
                        .disabled(validationMessage != nil)
                }
                Button("Export WAV…", systemImage: "square.and.arrow.up") { exportWAV() }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(project.result == nil)
            }
        }
        .background(WindowReader(monitor: spaceKey))
        .onAppear { spaceKey.start { togglePlayback() } }
        .onDisappear {
            spaceKey.stop()
            editor.cancel()
            player.stop()
        }
        // Keep the response up to date: a quick preview shortly after the inputs change, then, once they
        // have stayed the same for a moment, the full-quality response.
        .task(id: project.settings) {
            guard !project.isResultCurrent else { return }
            await editor.regenerate(
                project.settings, quality: .preview, needed: { !project.isResultCurrent }, deliver: deliver)
        }
        .task(
            id: Refinement(
                settings: project.settings, needed: project.isResultCurrent && !project.isResultFinal)
        ) {
            guard project.isResultCurrent, !project.isResultFinal else { return }
            await editor.regenerate(
                project.settings, quality: .full, after: Self.refinementDelay,
                needed: { project.isResultCurrent && !project.isResultFinal }, deliver: deliver)
        }
        // Show the clip through the current room as soon as there is one.
        .task(id: project.result?.settings) {
            if let result = project.result { player.prepare(result) }
        }
        .task(id: project.result?.response.metadata.frameCount) {
            if editor.summary == nil { editor.summarize(project.result) }
        }
    }

    private var validationMessage: String? {
        do {
            try project.settings.validate()
            try project.export.validate()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func drawing(_ projection: RoomProjection) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(projection.title).font(.caption.bold()).foregroundStyle(.secondary).padding(
                [.top, .leading], 8)
            RoomDrawing(settings: $document.project.settings, projection: projection)
        }
    }

    @ViewBuilder
    private var results: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Response").font(.headline)
                status
                Spacer()
            }
            AuditionBar(
                player: player, sampleRate: project.settings.sampleRate, result: project.result,
                play: audition,
                busy: project.result == nil && validationMessage != nil)
            if let message = validationMessage ?? editor.message {
                Label(message, systemImage: "exclamationmark.circle").foregroundStyle(.red).font(.callout)
            }
            if let result = project.result, let summary = editor.summary {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("Chart", selection: $chart) {
                            Text("Envelope").tag(Chart.envelope)
                            Text("Spectrum").tag(Chart.spectrum)
                            Text("Early").tag(Chart.early)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        switch chart {
                        case .envelope: EnvelopeChart(summary: summary)
                        case .spectrum:
                            SpectrumChart(summary: summary, crossover: result.diagnostics.waveCrossover)
                        case .early: EarlyChart(summary: summary)
                        }
                    }
                    .frame(minWidth: 260)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            DecayTable(summary: summary, diagnostics: result.diagnostics)
                            DiagnosticsList(result: result)
                        }
                    }
                    .frame(width: 330)
                }
            } else if project.result == nil {
                Text("Generate a response to see its envelope and decay.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var status: some View {
        if editor.isGenerating {
            Text(project.result == nil ? "Generating…" : "Updating…").foregroundStyle(.secondary)
        } else if project.result != nil {
            if project.isResultFinal {
                Text("Up to date").foregroundStyle(.green)
            } else if project.isResultCurrent {
                Text("Preview quality; the full response follows when editing pauses").foregroundStyle(
                    .secondary)
            } else {
                Text("Out of date: the inputs have changed since it was generated").foregroundStyle(.orange)
            }
            if !project.retainsResult {
                Text("Too large to keep in the document").foregroundStyle(.secondary)
            }
        }
    }

    private func generate() {
        editor.generate(project.settings, deliver: deliver)
    }

    private func deliver(_ result: RoomResponse) {
        document.project.result = result
        // Keeps playing, from the same point, with the new room.
        player.prepare(result, thenPlay: playWhenGenerated)
        playWhenGenerated = false
    }

    /// Space bar: pause if playing, otherwise play.
    private func togglePlayback() {
        if player.isPlaying || player.isPreparing {
            player.pause()
        } else if validationMessage == nil || project.result != nil {
            audition()
        }
    }

    /// Plays at once with the latest response, even while a newer one is generated; it takes over
    /// when it arrives.
    private func audition() {
        if let result = project.result {
            player.prepare(result, thenPlay: true)
        } else {
            playWhenGenerated = true
            if !editor.isGenerating { generate() }
        }
    }

    /// Exports the full-quality response, generating it first if the current one is a preview or out of
    /// date.
    private func exportWAV() {
        guard let result = project.result else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        let base = fileURL?.deletingPathExtension().lastPathComponent ?? "Room"
        let suffix = result.settings.content == .reflectionsOnly ? "reflections" : "response"
        panel.nameFieldStringValue = "\(base) \(suffix).wav"
        panel.message = "The response's description is saved beside it as JSON."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let write = { (result: RoomResponse) in
            do {
                try project.export.conditioned(result).write(wav: url)
            } catch {
                editor.message = "Export failed: \(error.localizedDescription)"
            }
        }
        if project.isResultFinal {
            write(result)
        } else {
            editor.generate(project.settings, quality: .full) { result in
                deliver(result)
                write(result)
            }
        }
    }
}
