import AppKit
import SwiftUI

@main
struct BombCADApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = SimulationModel()

    var body: some Scene {
        WindowGroup("BombCAD") {
            ContentView(model: model)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .defaultSize(width: 1440, height: 920)
        .commands {
            // Undo works on whole layout edits rather than on keystrokes in a field.
            CommandGroup(replacing: .undoRedo) {
                Button("Undo Edit") { model.undo() }
                    .keyboardShortcut("z")
                    .disabled(!model.canUndo)
                Button("Redo Edit") { model.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!model.canRedo)
            }
            CommandMenu("Simulation") {
                Button(model.isRunning ? "Pause" : "Run") { model.toggleRun() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("Reset") { model.reset() }
                    .keyboardShortcut("r")
                Button("Reset Camera") { model.resetCamera() }
                    .keyboardShortcut("0")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // When launched with `swift run` there is no app bundle, so ask for a regular
        // foreground app explicitly.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
