import Observation
import SwiftUI

/// Owns one simulation per document window. Only persisted inputs participate in change tracking.
@MainActor
@Observable
final class ProjectSession {
    let model: SimulationModel

    init(document: ProjectDocument, preferences: AppPreferences = .load()) {
        model = SimulationModel(document: document, playbackSpeed: preferences.playbackSpeed)
    }

    var snapshot: ProjectDocument { ProjectDocument(model: model) }

    /// Native document undo/revert can replace the binding; our own published edits need no reload.
    func receive(_ document: ProjectDocument) {
        guard document != snapshot else { return }
        model.open(document)
    }
}

struct ProjectEditor: View {
    @Binding var document: ProjectDocument
    @State private var session: ProjectSession?

    var body: some View {
        Group {
            if let session {
                ContentView(model: session.model)
                    .focusedSceneValue(\.simulationModel, session.model)
            } else {
                ProgressView("Opening project…")
            }
        }
        .frame(minWidth: 1000, minHeight: 640)
        .task {
            // Defer expensive GPU construction until this window actually appears.
            if session == nil { session = ProjectSession(document: document) }
        }
        .onChange(of: session?.snapshot) { _, snapshot in
            if let snapshot, snapshot != document { document = snapshot }
        }
        .onChange(of: document) { _, incoming in session?.receive(incoming) }
    }
}

private struct SimulationModelFocusKey: FocusedValueKey {
    typealias Value = SimulationModel
}

extension FocusedValues {
    var simulationModel: SimulationModel? {
        get { self[SimulationModelFocusKey.self] }
        set { self[SimulationModelFocusKey.self] = newValue }
    }
}

struct SimulationCommands: Commands {
    @FocusedValue(\.simulationModel) private var model

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button("Undo Edit") { model?.undo() }
                .keyboardShortcut("z")
                .disabled(model?.canUndo != true)
            Button("Redo Edit") { model?.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(model?.canRedo != true)
        }
        CommandMenu("Simulation") {
            Button(model?.isRunning == true ? "Pause" : "Run") { model?.toggleRun() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(model == nil)
            Button("Reset") { model?.reset() }
                .keyboardShortcut("r")
                .disabled(model == nil)
            Button("Reset Camera") { model?.resetCamera() }
                .keyboardShortcut("0")
                .disabled(model == nil)
        }
    }
}
