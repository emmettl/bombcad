import AppKit
import SwiftUI

/// `BombCAD run …` runs a project without a window (see `HeadlessRun`), `BombCAD sweep …` runs a
/// sweep (see `HeadlessSweep`), `BombCAD ensemble …` reruns validation cases over their uncertain
/// inputs (see `HeadlessEnsemble`), `BombCAD cloud …` follows a run's cloud again (see `HeadlessCloud`), `BombCAD worker` serves sweep cases over its standard input and output (see `SweepWorker`), `BombCAD serve`, `pair` and `nearby` share a GPU with Macs nearby (see `HeadlessNearby`), `BombCAD watch …` runs a project on another Mac and watches it from this one (see `HeadlessWatch`), `BombCAD interface-smoke` draws a new document's views offscreen through a change of source (see `InterfaceSmoke`); anything else opens the app.
@main
enum BombCADMain {
    static func main() {
        // A worker's connection that drops must fail a write, not end the process: the models it
        // ran carry on here (see `ResilientFrameConsumer`).
        signal(SIGPIPE, SIG_IGN)
        let arguments = Array(CommandLine.arguments.dropFirst())
        switch arguments.first {
        case "run":
            Task { @MainActor in
                exit(await HeadlessRun.main(Array(arguments.dropFirst())))
            }
        case "watch":
            Task { @MainActor in
                exit(await HeadlessWatch.main(Array(arguments.dropFirst())))
            }
        case "sweep":
            Task { @MainActor in
                exit(await HeadlessSweep.main(Array(arguments.dropFirst())))
            }
        case "ensemble":
            Task { @MainActor in
                exit(await HeadlessEnsemble.main(Array(arguments.dropFirst())))
            }
        case "cloud":
            exit(HeadlessCloud.main(Array(arguments.dropFirst())))
        case "interface-smoke":
            Task { @MainActor in exit(InterfaceSmoke.main()) }
        case "serve", "pair", "nearby":
            Task { @MainActor in
                exit(await HeadlessNearby.main(arguments[0], Array(arguments.dropFirst())))
            }
        case "worker":
            Task { @MainActor in
                exit(await SweepWorker.main(Array(arguments.dropFirst())))
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
            NewDistrictCommands()
            SimulationCommands()
            HelpCommands()
        }

        Window("New District", id: "new-district") {
            NewDistrictView()
        }
        .defaultSize(width: 620, height: 820)
        .windowResizability(.contentMinSize)

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
        NearbySharing.shared.restore()
    }
}
