import Foundation
import Testing

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
        // name; the advisor's target as its picker reads.
        #expect(
            try Self.source("SidebarView.swift").contains(
                ".accessibilityLabel(\"Extent \\([\"X\", \"Y\", \"Z\"][axis]) (m)\")"))
        let editor = try Self.source("EditorView.swift")
        #expect(
            editor.contains(
                ".accessibilityLabel(\"\\(title), \\(field.prefix(1).lowercased() + field.dropFirst())\")"))
        #expect(
            editor.contains(
                ".accessibilityLabel(\"\\(gauge.name), position \\([\"X\", \"Y\", \"Z\"][axis]) (m)\")"))
        #expect(editor.contains(".accessibilityLabel(\"Remove gauge \\(gauge.name)\")"))
        let advisor = try Self.source("RunAdvice.swift")
        #expect(advisor.contains(".accessibilityLabel(\"\\(quantity.title) (%)\")"))
        #expect(advisor.contains(".accessibilityLabel(\"\\(quantity.title) (min)\")"))
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
}
