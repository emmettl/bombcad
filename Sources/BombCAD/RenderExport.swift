import AppKit
import BlastCore
import DocumentKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Exporting the project's run for rendering elsewhere, from the app: the same run and files as
/// `BombCAD run --usd --vdb`, made from a copy of the project in the background, so the window
/// carries on as it was.
@MainActor
@Observable
final class RenderExport {
    enum State: Equatable {
        case idle
        /// The fraction of the simulated time reached.
        case running(Double)
        case finished(URL, frames: Int)
        case failed(String)
    }

    private(set) var state = State.idle
    /// Whole milliseconds of simulated time between frames.
    var frameInterval = 10
    /// The volumes' grids; none, and no volumes are written.
    var fields: Set<String> = Set(BlastSolver.defaultVolumeFields)
    /// Fly the project's fragments into the scene, if it has any.
    var includesFragments = true
    @ObservationIgnored private var task: Task<Void, Never>?

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    /// Where the volumes go: a folder beside the scene, named after it.
    static func volumes(for scene: URL) -> URL {
        scene.deletingPathExtension().appendingPathExtension("volumes")
    }

    /// Runs `document` and writes the scene to `scene`, replacing a file there, which the save
    /// panel has already asked about.
    func start(_ document: ProjectDocument, to scene: URL) {
        guard !isRunning else { return }
        var document = document
        // The run is kept only in this copy; the project's saved runs must not fill it.
        document.savedRuns = []
        var options = HeadlessRun.Options(project: scene)
        options.usd = scene
        options.frameInterval = frameInterval
        let grids = BlastSolver.volumeFields.filter(fields.contains)
        if !grids.isEmpty {
            options.vdb = Self.volumes(for: scene)
            options.vdbFields = grids
        }
        if includesFragments { options.fragments = document.fragments }
        state = .running(0)
        task = Task {
            do {
                if let folder = options.vdb, FileManager.default.fileExists(atPath: folder.path) {
                    throw ProjectFileError.invalid(
                        "\(folder.lastPathComponent) already exists beside the scene; choose another name.")
                }
                if FileManager.default.fileExists(atPath: scene.path) {
                    try FileManager.default.removeItem(at: scene)
                }
                let result = try await HeadlessRun.perform(document, options: options) {
                    [weak self] fraction in
                    self?.state = .running(fraction)
                }
                let interval = Double(frameInterval) / 1000
                let frames = Int((result.run.elapsedTime / interval + 1e-6).rounded(.down)) + 1
                state = .finished(scene, frames: frames)
            } catch is CancellationError {
                state = .idle
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() { task?.cancel() }
}

/// The sheet behind File ▸ Export for Rendering….
struct RenderExportView: View {
    let model: SimulationModel
    @State private var export = RenderExport()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export for Rendering").font(.headline)
            Text(
                "Runs this project again in the background and writes a USD scene, with the air as OpenVDB volumes beside it, for rendering in Blender or another renderer."
            )
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                Stepper(value: $export.frameInterval, in: 1...100) {
                    LabeledContent("A frame every", value: "\(export.frameInterval) ms")
                }
                LabeledContent("Volumes") {
                    VStack(alignment: .leading) {
                        ForEach(BlastSolver.volumeFields, id: \.self) { field in
                            Toggle(Self.title(field), isOn: binding(field))
                        }
                    }
                }
                if model.fragmentSpec != nil {
                    LabeledContent("Fragments") {
                        Toggle("Fly them into the scene", isOn: $export.includesFragments)
                    }
                }
            }
            .disabled(export.isRunning)
            Text(estimate).font(.caption).foregroundStyle(.secondary)
            status
            HStack {
                Spacer()
                if export.isRunning {
                    Button("Cancel") { export.cancel() }
                } else {
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Export…") { choose() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 440)
        .onDisappear { export.cancel() }
    }

    @ViewBuilder private var status: some View {
        switch export.state {
        case .idle:
            EmptyView()
        case .running(let fraction):
            ProgressView(value: fraction) { Text("Running and writing frames…").font(.caption) }
        case .finished(let url, let frames):
            HStack {
                Text("Wrote \(frames) frames to \(url.lastPathComponent).").font(.callout)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        case .failed(let message):
            Text(message).font(.callout).foregroundStyle(.red)
        }
    }

    private var estimate: String {
        let frames = Int(model.duration * 1000) / export.frameInterval + 1
        let grids = export.fields.count
        guard grids > 0 else { return "\(frames) frames of the scene, without volumes." }
        return
            "\(frames) frames. Volumes take up to tens of megabytes a frame on a medium grid, peak and impulse the most."
    }

    private func binding(_ field: String) -> Binding<Bool> {
        Binding(
            get: { export.fields.contains(field) },
            set: { if $0 { export.fields.insert(field) } else { export.fields.remove(field) } })
    }

    static func title(_ field: String) -> String {
        switch field {
        case "overpressure": "Overpressure now"
        case "shock": "Shock fronts (pressure gradient)"
        case "peak": "Peak overpressure so far"
        case "impulse": "Impulse so far"
        default: field
        }
    }

    private func choose() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "usda") ?? .data]
        panel.nameFieldStringValue = model.settings.scenario.name + ".usda"
        panel.message = "The volumes go in a folder beside the scene."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        export.start(ProjectDocument(model: model), to: url)
    }
}
