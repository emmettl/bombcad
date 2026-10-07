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

/// Reports the window a view is in, and keeps keyboard focus off text fields when it opens.
///
/// macOS gives a new window's first text field the keyboard, which would make the space bar type into
/// it. The view this places is focusable and takes the keyboard instead.
struct WindowReader: NSViewRepresentable {
    let monitor: SpaceKeyMonitor

    func makeNSView(context: Context) -> FocusSink {
        let view = FocusSink()
        view.monitor = monitor
        return view
    }

    func updateNSView(_ view: FocusSink, context: Context) {
        if monitor.window !== view.window { monitor.window = view.window }
    }

    final class FocusSink: NSView {
        weak var monitor: SpaceKeyMonitor?
        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            monitor?.window = window
            window.initialFirstResponder = self
            // After SwiftUI has set up the window's views.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window,
                    window.firstResponder is NSText || window.firstResponder === window
                else { return }
                window.makeFirstResponder(self)
            }
        }
    }
}

extension View {
    /// Ends text editing when Return is pressed, so the space bar plays again.
    func endsEditingOnSubmit() -> some View {
        onSubmit { NSApp.keyWindow?.makeFirstResponder(nil) }
    }
}

/// Ends any text editing in the key window, as clicking a drawing should.
@MainActor
func endTextEditing() {
    if let window = NSApp.keyWindow, window.firstResponder is NSText { window.makeFirstResponder(nil) }
}
