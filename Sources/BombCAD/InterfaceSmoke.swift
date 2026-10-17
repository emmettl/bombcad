import AppKit
import BlastCore
import SwiftUI

/// `BombCAD interface-smoke`: opens a new document as New Document does and draws its window and
/// sidebar offscreen, then switches the scene's source between a charge and a gas cloud as the
/// Source menu does, drawing after each switch, so that every view reads its bindings with the
/// gas cloud there and gone. Run from inside the packaged app by `make app-smoke` and the
/// release: a view that cannot draw a state a menu leads to stops it here, not in a user's hands.
@MainActor
enum InterfaceSmoke {
    static func main() -> Int32 {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let model = SimulationModel(document: ProjectDocument.newProject())
        let views: [(String, AnyView, CGSize)] = [
            ("window", AnyView(ContentView(model: model)), CGSize(width: 1440, height: 920)),
            ("sidebar", AnyView(SidebarView(model: model)), CGSize(width: 310, height: 6000)),
        ]
        let hosts = views.map { name, view, size -> (String, NSHostingView<AnyView>, NSWindow) in
            let host = NSHostingView(rootView: view)
            host.frame = CGRect(origin: .zero, size: size)
            let window = NSWindow(
                contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            return (name, host, window)
        }
        defer { for (_, _, window) in hosts { window.close() } }
        func draw(_ step: String) {
            for (_, host, window) in hosts {
                window.layoutIfNeeded()
                host.layoutSubtreeIfNeeded()
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                }
            }
            print("interface-smoke: drew \(step)")
        }
        draw("a new document")
        let charge = model.settings.scenario
        for round in 1...2 {
            model.settings.scenario.deflagration = SourceKindSection.defaultCloud(for: charge)
            draw("a gas cloud (\(round))")
            model.settings.scenario.deflagration = nil
            draw("the charge again (\(round))")
        }
        print("interface-smoke: passed")
        return 0
    }
}
