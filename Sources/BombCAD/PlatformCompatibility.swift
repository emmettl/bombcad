import SwiftUI

// What the app's views ask of the Mac that an iPad has otherwise (emmettl/bombcad-work#43): the
// target also builds for iPadOS, where BombCAD is the viewer of runs kept on a Mac nearby.
extension View {
    /// A checkbox on the Mac; on an iPad, which has none, its own switch.
    @ViewBuilder func checkboxToggleStyle() -> some View {
        #if os(macOS)
            toggleStyle(.checkbox)
        #else
            self
        #endif
    }
}

extension Color {
    /// A window's background, and a text field's.
    static var windowBackground: Color {
        #if os(macOS)
            Color(nsColor: .windowBackgroundColor)
        #else
            Color(uiColor: .systemBackground)
        #endif
    }

    static var textBackground: Color {
        #if os(macOS)
            Color(nsColor: .textBackgroundColor)
        #else
            Color(uiColor: .secondarySystemBackground)
        #endif
    }
}
