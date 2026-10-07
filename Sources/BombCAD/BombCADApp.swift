import AppKit
import SwiftUI

@main
struct BombCADApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        DocumentGroup(newDocument: ProjectDocument()) { file in
            ProjectEditor(document: file.$document)
        }
        .defaultSize(width: 1440, height: 920)
        .commands {
            SimulationCommands()
            HelpCommands()
        }

        Window("BombCAD Help", id: "help") {
            HelpView()
        }
        .defaultSize(width: 780, height: 620)
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // When launched with `swift run` there is no app bundle, so ask for a regular
        // foreground app explicitly.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
