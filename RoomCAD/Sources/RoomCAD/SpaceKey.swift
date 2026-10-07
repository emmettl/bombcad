import AppKit
import SwiftUI

/// Toggles playback with the space bar in one window, unless text is being edited there.
///
/// A SwiftUI keyboard shortcut on space would also take the key from text fields, so this watches key
/// presses instead and passes on any it does not use.
@MainActor
final class SpaceKeyMonitor {
    /// The window whose key presses count; set by `WindowReader`.
    weak var window: NSWindow?
    private var monitor: Any?

    func start(_ action: @escaping @MainActor () -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, Self.isPlayPause(event, in: self.window) else { return event }
            action()
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// A bare space, in `window`, while nothing there is taking text.
    static func isPlayPause(_ event: NSEvent, in window: NSWindow?) -> Bool {
        guard event.type == .keyDown, event.charactersIgnoringModifiers == " ",
            event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty, !event.isARepeat,
            let window, event.window === window
        else { return false }
        return !(window.firstResponder is NSText)
    }
}

/// Reports the window a view is in.
struct WindowReader: NSViewRepresentable {
    let monitor: SpaceKeyMonitor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in monitor.window = view?.window }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if monitor.window !== view.window { monitor.window = view.window }
    }
}
