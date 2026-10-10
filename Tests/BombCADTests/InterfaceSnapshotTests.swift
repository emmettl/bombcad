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

    @Test("Render editing and import panels without changing the project", arguments: ["light", "dark"])
    func editingPanels(style: String) throws {
        let output = try #require(ProcessInfo.processInfo.environment["BOMBCAD_INTERFACE_REVIEW"])
        let folder = URL(filePath: output, directoryHint: .isDirectory).appending(path: style)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var document = ProjectDocument(scenario: try StructureEditingTests().layout())
        document.runSettings?.resolution = "coarse"
        let model = SimulationModel(document: document)
        let first = try #require(model.structuralParts.first)
        model.selection = .part(first.id)
        let original = ProjectDocument(model: model)
        let appearance: NSAppearance.Name = style == "dark" ? .darkAqua : .aqua
        try snapshot(
            EditorView(model: model).frame(width: 310), size: CGSize(width: 310, height: 800),
            appearance: appearance, to: folder.appending(path: "layout-editing.png"))
        let imported = try #require(model.settings.scenario.importedModels?.first)
        try snapshot(
            ModelImportView(
                mesh: imported.source, filename: "named-parts.obj", existing: imported, model: model),
            size: CGSize(width: 1100, height: 760), appearance: appearance,
            to: folder.appending(path: "import-editing.png"))
        try snapshot(
            HelpView(), size: CGSize(width: 900, height: 640), appearance: appearance,
            to: folder.appending(path: "help.png"))
        #expect(ProjectDocument(model: model) == original)

        let suite = "dev.bombcad.interface-review.\(UUID())"
        let store = try #require(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        try snapshot(
            AppSettingsView().defaultAppStorage(store), size: CGSize(width: 480, height: 640),
            appearance: appearance, to: folder.appending(path: "settings.png"))
    }

    @Test("Review the editor at fixed viewport sizes", arguments: ["light", "dark"])
    func constrainedPanels(style: String) throws {
        let output = try #require(ProcessInfo.processInfo.environment["BOMBCAD_INTERFACE_REVIEW"])
        let folder = URL(filePath: output, directoryHint: .isDirectory).appending(path: style)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var document = ProjectDocument(
            scenario: Scenario(
                name: "Minimum window review", domainSize: SIMD3(repeating: 6), boxes: [],
                charge: Charge(mass: 0, position: SIMD3(3, 3, 1))))
        document.runSettings?.resolution = "coarse"
        let model = SimulationModel(document: document)
        let original = ProjectDocument(model: model)
        let appearance: NSAppearance.Name = style == "dark" ? .darkAqua : .aqua
        let minimum = CGSize(width: 1000, height: 640)
        try snapshot(
            ContentView(model: model).frame(width: minimum.width, height: minimum.height).clipped(),
            size: minimum, appearance: appearance, to: folder.appending(path: "editor-minimum.png"),
            expandToFit: false)
        let sidebar = CGSize(width: 310, height: 580)
        try snapshot(
            EditorView(model: model).frame(width: sidebar.width, height: sidebar.height).clipped(),
            size: sidebar, appearance: appearance, to: folder.appending(path: "layout-editing-short.png"),
            expandToFit: false)
        #expect(ProjectDocument(model: model) == original)
    }

    @Test("Render the standing of results beside them and in detail", arguments: ["light", "dark"])
    func standing(style: String) throws {
        let output = try #require(ProcessInfo.processInfo.environment["BOMBCAD_INTERFACE_REVIEW"])
        let folder = URL(filePath: output, directoryHint: .isDirectory).appending(path: style)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = SimulationModel(document: ProjectDocument(scenario: ScenarioPreset.blastWall.scenario))
        model.thermalSpec = ThermalSpec()
        model.cloudSpec = CloudSpec()
        model.groundShockSpec = GroundShockSection.defaultSpec(for: model.settings.scenario)
        let original = ProjectDocument(model: model)
        let appearance: NSAppearance.Name = style == "dark" ? .darkAqua : .aqua
        try snapshot(
            SidebarView(model: model).frame(width: 340), size: CGSize(width: 340, height: 900),
            appearance: appearance, to: folder.appending(path: "standing-sidebar.png"))
        try snapshot(
            Form { SceneStandingSection(model: model) }.formStyle(.grouped).frame(width: 340),
            size: CGSize(width: 340, height: 420), appearance: appearance,
            to: folder.appending(path: "standing-summary.png"))
        try snapshot(
            StandingDetail(standing: model.standing, kinds: [.structuralResponse, .structuralDamage]),
            size: CGSize(width: 380, height: 520), appearance: appearance,
            to: folder.appending(path: "standing-detail.png"))
        try snapshot(
            HStack(spacing: 8) { ForEach(EvidenceLevel.allCases, id: \.self) { StandingLabel(level: $0) } }
                .padding(12),
            size: CGSize(width: 380, height: 40), appearance: appearance,
            to: folder.appending(path: "standing-labels.png"))
        #expect(ProjectDocument(model: model) == original)
    }

    private func snapshot<V: View>(
        _ view: V, size: CGSize, appearance: NSAppearance.Name, to file: URL,
        expandToFit: Bool = true
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
        if expandToFit {
            let fitting = host.fittingSize
            window.setContentSize(
                CGSize(width: max(size.width, fitting.width), height: max(size.height, fitting.height)))
        } else {
            #expect(host.bounds.size == size)
        }
        host.layoutSubtreeIfNeeded()
        #expect(!window.isVisible)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: file)
    }
}
