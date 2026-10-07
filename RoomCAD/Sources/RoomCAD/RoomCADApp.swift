import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--snapshot") {
            guard flag + 1 < arguments.count else {
                FileHandle.standardError.write(Data("Usage: RoomCAD --snapshot FILE.png\n".utf8))
                exit(2)
            }
            MainActor.assumeIsolated {
                exit(Snapshot.write(to: URL(fileURLWithPath: arguments[flag + 1])) ? 0 : 1)
            }
        }
        // Open a new room at launch, as document apps did before iCloud, instead of the Open panel.
        // Restored windows and documents opened from Finder still take precedence.
        UserDefaults.standard.register(defaults: ["NSShowAppCentricOpenPanelInsteadOfUntitledFile": false])
        RoomCADApp.main()
    }
}

struct RoomCADApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        DocumentGroup(newDocument: RoomCADFile()) { file in
            RoomEditorView(document: file.$document, fileURL: file.fileURL)
        }
        .defaultSize(width: 1280, height: 820)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launched with `swift run` there is no app bundle, so ask for a regular foreground app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
