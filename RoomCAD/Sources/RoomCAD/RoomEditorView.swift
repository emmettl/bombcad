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

    private var project: RoomProject { document.project }

    var body: some View {
        HSplitView {
            VSplitView {
                HStack(spacing: 0) {
                    drawing(.plan)
                    Divider()
                    drawing(.elevation)
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
            if let message = validationMessage ?? editor.message {
                Label(message, systemImage: "exclamationmark.circle").foregroundStyle(.red).font(.callout)
            }
            if let result = project.result, let summary = editor.summary {
                HStack(alignment: .top, spacing: 16) {
                    EnvelopeChart(summary: summary).frame(minWidth: 260)
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
            Text("Generating…").foregroundStyle(.secondary)
        } else if project.result != nil {
            if project.isResultCurrent {
                Text("Up to date").foregroundStyle(.green)
            } else {
                Text("Out of date: the inputs have changed since it was generated").foregroundStyle(.orange)
            }
            if !project.retainsResult {
                Text("Too large to keep in the document").foregroundStyle(.secondary)
            }
        }
    }

    private func generate() {
        editor.generate(project.settings) { result in
            document.project.result = result
        }
    }

    private func exportWAV() {
        guard let result = project.result else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        let base = fileURL?.deletingPathExtension().lastPathComponent ?? "Room"
        let suffix = result.settings.content == .reflectionsOnly ? "reflections" : "response"
        panel.nameFieldStringValue = "\(base) \(suffix).wav"
        panel.message = "The response's description is saved beside it as JSON."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try project.export.conditioned(result).write(wav: url)
        } catch {
            editor.message = "Export failed: \(error.localizedDescription)"
        }
    }
}
