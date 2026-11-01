import AppKit
import ApplicationServices
import SwiftUI
import Testing

/// SwiftUI's accessibility tree read offscreen, from a hosted view in a window never shown.
///
/// SwiftUI builds its accessibility elements only once an assistive client has asked the app for
/// something. Here the test process is that client: it finishes launching (so that it answers the
/// accessibility API, with no Dock icon or menu bar of its own) and asks itself for its children
/// through `AXUIElementCreateApplication`, from a background thread while the main one answers.
/// The API answers only a process trusted for accessibility; the test runner is when the app that
/// started it is (Terminal, or Claude on the Studio). Elsewhere, as on the CI mini, the tree is not
/// built and `isReadable` is false. Nothing is changed in System Settings, and no window is shown.
@MainActor
enum AccessibilityTree {
    /// One element as an assistive app reads it.
    struct Element: CustomStringConvertible {
        var role: String
        var subrole: String
        var label: String
        var title: String
        var value: String
        /// What a slider's or a stepper's value is read as, when it is not the number.
        var valueDescription: String
        var help: String
        var placeholder: String
        /// The element's title element's text, as a field labelled by a row's title has.
        var titledBy: String
        /// The labels of the elements it sits in, outermost first, and the last text read before it:
        /// where to find it.
        var path: [String]
        var lastText: String
        /// The text read within it, which names a row of a list.
        var within: String

        /// What VoiceOver speaks for it before its value.
        var name: String {
            for candidate in [label, title, titledBy, placeholder]
            where !candidate.trimmingCharacters(in: .whitespaces).isEmpty {
                return candidate
            }
            return ""
        }

        /// Its value as VoiceOver reads it: the description where there is one.
        var read: String { valueDescription.isEmpty ? value : valueDescription }

        var description: String {
            let place = (path.filter { !$0.isEmpty } + (lastText.isEmpty ? [] : ["after “\(lastText)”"]))
                .joined(separator: " ▸ ")
            return
                "\(role)\(subrole.isEmpty ? "" : "/\(subrole)") “\(name)” value “\(read.prefix(40))” at \(place)"
        }
    }

    /// Roles a person acts on, each of which must be named.
    static let controls: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXSlider",
        "AXIncrementor", "AXTextField", "AXTextArea", "AXComboBox", "AXDisclosureTriangle", "AXLink",
        "AXColorWell", "AXSegmentedControl", "AXStepper",
    ]

    nonisolated static var isReadable: Bool { AXIsProcessTrusted() }

    private static var launched = false

    /// Asks the app for its children as an assistive client would, which turns SwiftUI's tree on.
    static func ask() async {
        if !launched {
            launched = true
            let app = NSApplication.shared
            if app.activationPolicy() != .prohibited { app.setActivationPolicy(.prohibited) }
            app.finishLaunching()
        }
        let pid = getpid()
        await Task.detached {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 5)
            var children: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &children)
        }.value
    }

    /// `view` hosted at `width` (and `height`, or its fitting height), and its elements read.
    static func elements<V: View>(of view: V, width: CGFloat, height: CGFloat? = nil) async -> [Element] {
        await ask()
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        host.frame = CGRect(x: 0, y: 0, width: width, height: height ?? 800)
        let window = NSWindow(
            contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        if height == nil {
            window.setContentSize(CGSize(width: width, height: max(200, host.fittingSize.height)))
            host.layoutSubtreeIfNeeded()
        }
        // Let SwiftUI build the tree it was asked for.
        await ask()
        try? await Task.sleep(for: .milliseconds(50))
        var out: [Element] = []
        var lastText = ""
        walk(host, path: [], lastText: &lastText, into: &out, depth: 0)
        return out
    }

    /// The `NSAccessibility` protocol's method for each attribute read.
    private static let methods = [
        "AXRole": "accessibilityRole", "AXSubrole": "accessibilitySubrole",
        "AXDescription": "accessibilityLabel", "AXTitle": "accessibilityTitle",
        "AXValue": "accessibilityValue", "AXValueDescription": "accessibilityValueDescription",
        "AXHelp": "accessibilityHelp", "AXPlaceholderValue": "accessibilityPlaceholderValue",
        "AXTitleUIElement": "accessibilityTitleUIElement", "AXChildren": "accessibilityChildren",
    ]

    /// An attribute of an element of either kind: by the `NSAccessibility` protocol's method, as
    /// SwiftUI's elements answer, or else by the older informal protocol, as a table's rows do.
    private static func attribute(_ node: NSObject, _ name: String) -> Any? {
        if let method = methods[name], node.responds(to: NSSelectorFromString(method)) {
            return node.perform(NSSelectorFromString(method))?.takeUnretainedValue()
        }
        let selector = NSSelectorFromString("accessibilityAttributeValue:")
        guard node.responds(to: selector) else { return nil }
        return node.perform(selector, with: name)?.takeUnretainedValue()
    }

    private static func string(_ node: NSObject, _ name: String) -> String {
        guard let value = attribute(node, name) else { return "" }
        if let text = value as? String { return text }
        if let text = value as? NSAttributedString { return text.string }
        return "\(value)"
    }

    /// Reads `node` and what it holds into `out`; returns the text read within it.
    @discardableResult
    private static func walk(
        _ node: NSObject, path: [String], lastText: inout String, into out: inout [Element], depth: Int
    ) -> String {
        guard depth < 80 else { return "" }
        let role = string(node, "AXRole")
        var element = Element(
            role: role, subrole: string(node, "AXSubrole"), label: string(node, "AXDescription"),
            title: string(node, "AXTitle"), value: string(node, "AXValue"),
            valueDescription: string(node, "AXValueDescription"), help: string(node, "AXHelp"),
            placeholder: string(node, "AXPlaceholderValue"),
            titledBy: (attribute(node, "AXTitleUIElement") as? NSObject).map {
                let label = string($0, "AXDescription")
                return label.isEmpty ? string($0, "AXValue") : label
            } ?? "",
            path: path, lastText: lastText, within: "")
        let index = out.count
        out.append(element)
        var text = ""
        if role == "AXStaticText" || role == "AXHeading" {
            text = element.name.isEmpty ? element.value : element.name
            if !text.isEmpty { lastText = String(text.prefix(50)) }
        } else {
            text = element.name
        }
        let children = (attribute(node, "AXChildren") as? [Any]) ?? []
        let inner = path + [role == "AXGroup" || role == "AXHeading" || role == "AXList" ? element.name : ""]
        for child in children {
            if let child = child as? NSObject {
                let read = walk(child, path: inner, lastText: &lastText, into: &out, depth: depth + 1)
                if !read.isEmpty { text += (text.isEmpty ? "" : " ") + read }
            }
        }
        element.within = String(text.prefix(80))
        out[index] = element
        return text
    }

    /// Controls whose name says a part of itself twice, as a field with a hidden title and an
    /// accessibility label reads both ("Corner X (m), Block 1, corner X (m)"), or a group's name
    /// takes in a button's inside it ("Crate, Duplicate Crate").
    static func repeating(_ elements: [Element]) -> [Element] {
        elements.filter { element in
            guard controls.contains(element.role) else { return false }
            let parts = element.name.components(separatedBy: ", ").map {
                $0.trimmingCharacters(in: .whitespaces).lowercased()
            }
            return parts.indices.contains { i in
                parts.indices.contains { j in
                    i != j && parts[i].count >= 3
                        && parts[j].range(
                            of: "(?<![\\w])\(NSRegularExpression.escapedPattern(for: parts[i]))(?![\\w])",
                            options: .regularExpression) != nil
                }
            }
        }
    }

    /// Sliders that read only their number, not the value shown beside them with its unit.
    static func bareSliders(_ elements: [Element]) -> [Element] {
        elements.filter { $0.role == "AXSlider" && $0.valueDescription.isEmpty }
    }

    /// The controls with no name, and the images with none (or only a symbol's file name).
    static func unnamed(_ elements: [Element]) -> [Element] {
        elements.filter { element in
            if controls.contains(element.role) {
                // A slider's thumb and a stepper's arrows are named by the control they belong to.
                // A scroll bar's page areas are named by the scroll bar.
                if element.role == "AXIncrementor"
                    || ["AXIncrementArrow", "AXDecrementArrow", "AXIncrementPage", "AXDecrementPage"]
                        .contains(element.subrole)
                {
                    return false
                }
                return element.name.isEmpty
            }
            if element.role == "AXRow" || element.role == "AXCell" {
                return element.within.isEmpty
            }
            if element.role == "AXImage" {
                return element.name.isEmpty || element.name.contains(".")
            }
            return false
        }
    }
}
