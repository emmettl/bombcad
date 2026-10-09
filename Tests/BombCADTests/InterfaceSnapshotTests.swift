import AppKit
import BlastCore
import SwiftUI
import Testing

@testable import BombCAD

@MainActor
@Suite(
    "Offscreen interface review", .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["BOMBCAD_INTERFACE_REVIEW"] != nil))
struct InterfaceSnapshotTests {
    @Test("Render isolated app panels for layout review", arguments: ["light", "dark"])
    func panels(style: String) throws {
        let output = try #require(ProcessInfo.processInfo.environment["BOMBCAD_INTERFACE_REVIEW"])
        let folder = URL(filePath: output, directoryHint: .isDirectory).appending(path: style)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var document = ProjectDocument(scenario: ScenarioPreset.openGround.scenario)
        document.runSettings?.resolution = "coarse"
        document.savedRuns = [try SavedRunTests().fixture(), try SavedRunTests().fixture(name: "Second run")]
        for index in document.savedRuns.indices {
            document.savedRuns[index].capturedAt = Date(timeIntervalSince1970: 1_791_546_000)
        }
        let model = SimulationModel(document: document)
        let original = ProjectDocument(model: model)
        let appearance: NSAppearance.Name = style == "dark" ? .darkAqua : .aqua
        try snapshot(
            ContentView(model: model), size: CGSize(width: 1200, height: 800),
            appearance: appearance, to: folder.appending(path: "editor.png"))
        try snapshot(
            RunComparisonView(model: model), size: CGSize(width: 920, height: 640),
            appearance: appearance, to: folder.appending(path: "comparison.png"))
        try snapshot(
            RenderExportView(model: model), size: CGSize(width: 440, height: 520),
            appearance: appearance, to: folder.appending(path: "export.png"))
        #expect(ProjectDocument(model: model) == original)
    }

    private func snapshot<V: View>(
        _ view: V, size: CGSize, appearance: NSAppearance.Name, to file: URL
    ) throws {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: appearance)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = host.appearance
        window.contentView = host
        defer { window.close() }
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        let fitting = host.fittingSize
        window.setContentSize(
            CGSize(width: max(size.width, fitting.width), height: max(size.height, fitting.height)))
        host.layoutSubtreeIfNeeded()
        #expect(!window.isVisible)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: file)
    }
}
