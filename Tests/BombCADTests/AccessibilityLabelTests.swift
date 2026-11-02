import Foundation
import Testing

@testable import BombCAD

/// What the 18 October real-screen review found alike, bare or out of keyboard reach
/// (docs/native-interface-review.md), held in the sources: offscreen, a hosted form's rows build no
/// accessibility elements to read, so the labels themselves are checked on screen at each review
/// and their wiring here, as RenderLayoutTests reads the shaders.
@Suite("Accessibility labels")
struct AccessibilityLabelTests {
    static let folder = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "Sources/BombCAD")

    static func source(_ name: String) throws -> String {
        try String(contentsOf: folder.appending(path: name), encoding: .utf8)
    }

    @Test("Every icon-only Remove or Duplicate button names what it acts on")
    func iconButtonsNameTheirObject() throws {
        var bare: [String] = []
        for file in try FileManager.default.contentsOfDirectory(atPath: Self.folder.path())
        where file.hasSuffix(".swift") {
            let lines = try Self.source(file).components(separatedBy: "\n")
            for (index, line) in lines.enumerated()
            where line.contains("Button(\"Remove\", systemImage:")
                || line.contains("Button(\"Duplicate\", systemImage:")
            {
                // Icon-only within the button's few lines, and then labelled with a name.
                let after = lines[index..<min(index + 6, lines.count)].joined(separator: "\n")
                guard after.contains(".labelStyle(.iconOnly)") else { continue }
                if after.range(
                    of: #"\.accessibilityLabel\("(Remove|Duplicate) [^"]*\\\("#, options: .regularExpression)
                    == nil
                {
                    bare.append("\(file):\(index + 1)")
                }
            }
        }
        #expect(bare.isEmpty, "\(bare)")
    }

    @Test("Fields that share a row's label say which they are")
    func fieldsSayWhichTheyAre() throws {
        // Domain ▸ Extent's three fields; a box's corner and size and a gauge's position, with its
        // name; the advisor's target as its picker reads. The hidden-title fields are named by
        // their title alone (1 November 2026: with a label as well they read both).
        #expect(
            try Self.source("SidebarView.swift").contains(
                ".accessibilityLabel(\"Extent \\([\"X\", \"Y\", \"Z\"][axis]) (m)\")"))
        let editor = try Self.source("EditorView.swift")
        #expect(
            editor.contains(
                "\"\\(title), \\(field.prefix(1).lowercased() + field.dropFirst())\", value: value,"))
        #expect(editor.contains("\"\\(gauge.name), position \\([\"X\", \"Y\", \"Z\"][axis]) (m)\","))
        #expect(editor.contains(".accessibilityLabel(\"Remove gauge \\(gauge.name)\")"))
        let advisor = try Self.source("RunAdvice.swift")
        #expect(advisor.contains("\"\\(quantity.title) (%)\", value: $percent,"))
        #expect(advisor.contains("\"\\(quantity.title) (min)\", value: $minutes,"))
    }

    @Test("Each sheet opens with a field focused")
    func sheetsOpenInAField() throws {
        for file in [
            "RenderExport.swift", "ParameterSweepView.swift", "RunComparisonView.swift",
            "ModelImportView.swift",
        ] {
            let source = try Self.source(file)
            #expect(source.contains(".defaultFocus(") && source.contains(".focused("), "\(file)")
        }
        // The render export's interval is a field beside its stepper, which Tab reaches.
        #expect(try Self.source("RenderExport.swift").contains("TextField(\"A frame every (ms)\""))
    }

    @Test("The menus reach what only the toolbar and the chart's buttons did")
    func menusReachThePanels() throws {
        let commands = try Self.source("ProjectEditor.swift")
        for item in [
            "Import Model…", "Export Results as CSV…", "Keep Run…", "Compare Runs…", "Parameter Sweep…",
        ] {
            #expect(commands.contains("Button(\"\(item)\")"), "\(item)")
        }
        // Each request has a view that answers it.
        #expect(try Self.source("ContentView.swift").contains(".onChange(of: model.requestsModelImport)"))
        let chart = try Self.source("GaugeChartView.swift")
        #expect(
            chart.contains(".onChange(of: model.requestsKeptRun)")
                && chart.contains(".onChange(of: model.requestsResultsExport)"))
        #expect(chart.contains("$model.showsParameterSweep") && chart.contains("$model.showsRunComparison"))
    }
    /// Every Swift file of the app, by name, as lines.
    static func sources() throws -> [(String, [String])] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path()).sorted()
            .filter { $0.hasSuffix(".swift") }
            .map { ($0, try source($0).components(separatedBy: "\n")) }
    }

    // What the offscreen pass of 1 November 2026 found (emmettl/bombcad-work#27), held here where the
    // accessibility tree cannot be read (`AccessibilityTreeTests` reads it where it can).

    @Test("A control whose title is hidden is named by its title, not by a label read after it")
    func hiddenTitlesName() throws {
        // A hidden title and an accessibility label are both read: "Corner X (m), Block 1, corner X (m)".
        let control = try Regex(
            #"^\s*(TextField|SecureField|Picker|Toggle|Slider|Stepper|Button|Menu|Text)\("#)
        var doubled: [String] = []
        for (file, lines) in try Self.sources() {
            for (index, line) in lines.enumerated() where line.contains(".accessibilityLabel(") {
                var back = index
                while back > 0, back > index - 12, lines[back].firstMatch(of: control) == nil { back -= 1 }
                if lines[back...index].contains(where: { $0.contains(".labelsHidden()") }) {
                    doubled.append("\(file):\(index + 1)")
                }
            }
        }
        #expect(doubled.isEmpty, "\(doubled)")
    }

    @Test("Pickers are named, and buttons and menus drawn as a symbol alone")
    func iconsAndPickersNamed() throws {
        var bare: [String] = []
        for (file, lines) in try Self.sources() {
            for (index, line) in lines.enumerated() {
                if line.contains("Picker(\"\"") { bare.append("\(file):\(index + 1) picker") }
                // `} label: {`, a symbol alone, `}`: then named within a few lines.
                guard line.hasSuffix("label: {"), index + 2 < lines.count,
                    lines[index + 1].trimmingCharacters(in: .whitespaces).hasPrefix("Image(systemName:"),
                    lines[index + 2].trimmingCharacters(in: .whitespaces) == "}"
                else { continue }
                let after = lines[(index + 2)..<min(index + 8, lines.count)].joined(separator: "\n")
                if !after.contains(".accessibilityLabel(") { bare.append("\(file):\(index + 1)") }
            }
        }
        #expect(bare.isEmpty, "\(bare)")
    }

    @Test("Sliders are named")
    func slidersNamed() throws {
        var bare: [String] = []
        for (file, lines) in try Self.sources() {
            for (index, line) in lines.enumerated()
            where line.contains("Slider(") && !line.contains("LabeledSlider(") {
                if line.contains("struct ") { continue }
                let span = lines[index..<min(index + 14, lines.count)].joined(separator: "\n")
                // A label closure, `Slider(...) { Text(...) }`, or an accessibility label.
                if span.range(of: #"\)\s*\{\s*\n?\s*Text\("#, options: .regularExpression) == nil
                    && !span.contains(".accessibilityLabel(")
                {
                    bare.append("\(file):\(index + 1)")
                }
            }
        }
        #expect(bare.isEmpty, "\(bare)")
        // The titled slider reads its title and the value shown beside it.
        let sidebar = try Self.source("SidebarView.swift")
        #expect(
            sidebar.contains(
                "Slider(value: $value, in: range, onEditingChanged: onEditingChanged) { Text(title) }"))
        #expect(sidebar.contains(".accessibilityValue(text)"))
    }

    @Test("The 3D view, its legends and the chart are described; the camera moves from the keyboard")
    func drawingsDescribed() throws {
        let content = try Self.source("ContentView.swift")
        #expect(content.contains(".accessibilityLabel(\"3D view\")"))
        #expect(content.contains(".accessibilityValue(model.viewportSummary)"))
        #expect(content.components(separatedBy: ".accessibilityLabel(\"Colour scale: ").count - 1 == 3)
        #expect(content.contains(".accessibilityLabel(\"Colour key: ignition so far"))
        for action in ["Orbit left", "Orbit right", "Orbit up", "Orbit down", "Zoom in", "Zoom out"] {
            #expect(content.contains(".accessibilityAction(named: \"\(action)\")"), "\(action)")
        }
        let commands = try Self.source("ProjectEditor.swift").components(separatedBy: "\n")
        for (item, key) in [
            ("Orbit Left", ".leftArrow"), ("Orbit Right", ".rightArrow"), ("Orbit Up", ".upArrow"),
            ("Orbit Down", ".downArrow"), ("Zoom In", "\"=\""), ("Zoom Out", "\"-\""),
        ] {
            let line = commands.firstIndex { $0.contains("Button(\"\(item)\")") }
            #expect(
                line.map { commands[$0 + 1].contains(".keyboardShortcut(\(key)") } == true, "\(item)")
        }
        let chart = try Self.source("GaugeChartView.swift")
        #expect(chart.components(separatedBy: ".accessibilityChartDescriptor(").count - 1 == 2)
    }

    @Test("A building in the damage list can be selected without the view")
    func buildingsSelectable() throws {
        #expect(
            try Self.source("EnvelopeDamageSection.swift").contains(
                "Button(\"Select This Building\") { model.inspectedEnvelope = building.id }"))
    }

    @Test("The tree's checks find what they are for")
    @MainActor
    func treeRules() {
        func element(_ role: String, _ label: String, value: String = "", described: String = "")
            -> AccessibilityTree.Element
        {
            AccessibilityTree.Element(
                role: role, subrole: "", label: label, title: "", value: value, valueDescription: described,
                help: "", placeholder: "", titledBy: "", path: [], lastText: "", within: "")
        }
        let doubled = [
            element("AXTextField", "Corner X (m), Block 1, corner X (m)"),
            element("AXPopUpButton", "Base connection, Base connection"),
            element("AXDisclosureTriangle", "Crate, Duplicate Crate"),
        ]
        #expect(AccessibilityTree.repeating(doubled).count == 3)
        let fine = [
            element("AXTextField", "Block 1, corner X (m)"),
            element("AXButton", "Wall, front, 20.90, 21.00, 1.53 m"),
            element("AXDisclosureTriangle", "Crate"),
        ]
        #expect(AccessibilityTree.repeating(fine).isEmpty)
        #expect(
            AccessibilityTree.unnamed([element("AXButton", ""), element("AXImage", "chevron.right")]).count
                == 2)
        #expect(AccessibilityTree.unnamed(fine).isEmpty)
        #expect(AccessibilityTree.bareSliders([element("AXSlider", "TNT", value: "1.69")]).count == 1)
        #expect(
            AccessibilityTree.bareSliders([element("AXSlider", "TNT", value: "1.69", described: "50 kg")])
                .isEmpty)
    }

    @Test("The Charge from the Damage panel names its controls, its chart and its key, and the menu opens it")
    func chargeMarkingLabels() throws {
        let panel = try Self.source("ChargeMarkingView.swift")
        for wanted in [
            ".accessibilityLabel(\"Close the Charge from the Damage panel\")",
            "Picker(\"Mark a building as\"", ".accessibilityLabel(\"Yield chart\")",
            ".accessibilityLabel(\"Colour key: the charge's place\")", ".accessibilityLabel(\"Result: ",
        ] {
            #expect(panel.contains(wanted), "\(wanted)")
        }
        #expect(try Self.source("ProjectEditor.swift").contains("\"Read the Charge from the Damage…\""))
    }
}
