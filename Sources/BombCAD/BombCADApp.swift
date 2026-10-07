import AppKit
import SwiftUI

/// `BombCAD run …` runs a project without a window (see `HeadlessRun`); anything else opens the app.
@main
enum BombCADMain {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.first == "run" else {
            BombCADApp.main()
            return
        }
        Task { @MainActor in
            exit(await HeadlessRun.main(Array(arguments.dropFirst())))
        }
        dispatchMain()
    }
}

struct BombCADApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        DocumentGroup(newDocument: ProjectDocument.newProject()) { file in
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

        Settings {
            AppSettingsView()
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
}
