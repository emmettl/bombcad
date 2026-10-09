import AppKit
import SwiftUI

/// `BombCAD run …` runs a project without a window (see `HeadlessRun`), `BombCAD sweep …` runs a
/// sweep (see `HeadlessSweep`), `BombCAD cloud …` follows a run's cloud again (see `HeadlessCloud`), `BombCAD worker` serves sweep cases over its standard input and output (see `SweepWorker`); anything else opens the app.
@main
enum BombCADMain {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        switch arguments.first {
        case "run":
            Task { @MainActor in
                exit(await HeadlessRun.main(Array(arguments.dropFirst())))
            }
        case "sweep":
            Task { @MainActor in
                exit(await HeadlessSweep.main(Array(arguments.dropFirst())))
            }
        case "cloud":
            exit(HeadlessCloud.main(Array(arguments.dropFirst())))
        case "worker":
            Task { @MainActor in
                exit(await SweepWorker.main())
            }
        default:
            AppPreferences.migrate()
            BombCADApp.main()
            return
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
