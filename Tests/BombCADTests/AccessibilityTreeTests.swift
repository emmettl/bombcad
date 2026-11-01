import AppKit
import BlastCore
import SwiftUI
import Testing

@testable import BombCAD

/// Every control in the app's panels named, and every image, as an assistive app reads them
/// (emmettl/bombcad-work#27; docs/native-interface-review.md, 1 November 2026). The panels are
/// hosted offscreen in the states the interface review captures, and their accessibility trees
/// read through `AccessibilityTree`; where the test runner may not use the accessibility API, the
/// suite does not run and `AccessibilityLabelTests` holds what the sources can.
@MainActor
@Suite("Accessibility tree", .serialized, .hangLimit, .enabled(if: AccessibilityTree.isReadable))
struct AccessibilityTreeTests {
    /// The panel's unnamed controls and images, printed with where they are.
    func expectNamed<V: View>(
        _ name: String, width: CGFloat = 310, height: CGFloat? = nil, _ view: V,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> [AccessibilityTree.Element] {
        let elements = await AccessibilityTree.elements(of: view, width: width, height: height)
        #expect(
            elements.count(where: { AccessibilityTree.controls.contains($0.role) }) > 0,
            "\(name): no controls read", sourceLocation: sourceLocation)
        let unnamed = AccessibilityTree.unnamed(elements)
        if ProcessInfo.processInfo.environment["BOMBCAD_AX_DUMP"] != nil {
            print("AX \(name)\n" + elements.map { "  \($0)" }.joined(separator: "\n"))
        }
        func list(_ found: [AccessibilityTree.Element]) -> String {
            found.map { "  \($0)" }.joined(separator: "\n")
        }
        #expect(
            unnamed.isEmpty, "\(name): \(unnamed.count) unnamed\n\(list(unnamed))",
            sourceLocation: sourceLocation)
        let repeating = AccessibilityTree.repeating(elements)
        #expect(
            repeating.isEmpty, "\(name): \(repeating.count) say a part twice\n\(list(repeating))",
            sourceLocation: sourceLocation)
        let bare = AccessibilityTree.bareSliders(elements)
        #expect(
            bare.isEmpty, "\(name): \(bare.count) sliders read as a bare number\n\(list(bare))",
            sourceLocation: sourceLocation)
        return elements
    }

    @Test("The Run sidebar with every section, and the gas room's")
    func runSidebar() async throws {
        for (name, document) in [
            ("every section", try InterfaceSnapshotTests().everySection()),
            ("gas room", InterfaceSnapshotTests().gasRoom()),
        ] {
            let model = SimulationModel(document: document)
            _ = await expectNamed("Run sidebar, \(name)", SidebarView(model: model))
        }
    }

    @Test("The Edit tab, with a gauge, a block and nothing chosen")
    func editTab() async throws {
        let model = SimulationModel(document: try InterfaceSnapshotTests().everySection())
        model.selection = .gauge(0)
        _ = await expectNamed("Edit, gauge", EditorView(model: model))
        if let id = model.settings.scenario.fixedObjects.first?.id {
            model.selection = .block(id)
            _ = await expectNamed("Edit, block", EditorView(model: model))
        }
        model.selection = nil
        _ = await expectNamed("Edit", EditorView(model: model))
        var document = ProjectDocument(scenario: try StructureEditingTests().layout())
        document.runSettings?.resolution = "coarse"
        let linked = SimulationModel(document: document)
        linked.selection = .part(try #require(linked.structuralParts.first).id)
        _ = await expectNamed("Edit, linked part", EditorView(model: linked))
    }

    @Test("The main window: viewport overlays, replay bar and chart")
    func mainWindow() async throws {
        var document = ProjectDocument(scenario: ScenarioPreset.openGround.scenario)
        document.runSettings?.resolution = "coarse"
        document.savedRuns = [try SavedRunTests().fixture(), try SavedRunTests().fixture(name: "Second run")]
        let model = SimulationModel(document: document)
        let window = await expectNamed("Main window", width: 1200, height: 800, ContentView(model: model))
        // The view, which draws with Metal, by a summary; its legend by its scale; its chart by
        // what it plots; the time and state as one line.
        let view = try #require(window.first { $0.name == "3D view" })
        #expect(
            view.read.hasPrefix("Open ground, 64 × 64 × 32 m; 100 kg of TNT at 32, 32, 0.0 m"), "\(view.read)"
        )
        #expect(view.read.contains("t = 0.0 ms, ready"), "\(view.read)")
        #expect(!view.help.isEmpty)
        #expect(
            window.contains {
                $0.name == "Colour scale: Peak overpressure (kPa)" && $0.read.hasPrefix("Logarithmic, from")
            })
        #expect(window.contains { $0.role == "AXStaticText" && $0.value == "t = 0.0 ms, Ready" })
        let chart = await expectNamed("Chart", width: 900, height: 260, GaugeChartView(model: model))
        #expect(
            chart.contains {
                $0.name == "Overpressure at the gauges against time" && $0.read == "No samples yet"
            })
        // A gauge's peak and its name read together.
        #expect(chart.contains { $0.role == "AXStaticText" && $0.value == "5 m, no peak yet" })
    }

    @Test("Sheets and windows: comparison, export, sweep, import, help, settings, New District")
    func sheets() async throws {
        var document = ProjectDocument(scenario: ScenarioPreset.openGround.scenario)
        document.runSettings?.resolution = "coarse"
        document.savedRuns = [try SavedRunTests().fixture(), try SavedRunTests().fixture(name: "Second run")]
        let model = SimulationModel(document: document)
        _ = await expectNamed("Compare Runs", width: 920, height: 640, RunComparisonView(model: model))
        _ = await expectNamed("Export for Rendering", width: 440, RenderExportView(model: model))
        _ = await expectNamed("Parameter Sweep", width: 520, ParameterSweepView(model: model))
        _ = await expectNamed("Help", width: 900, height: 640, HelpView())
        _ = await expectNamed(
            "Infer Charge", width: 600,
            ChargeInferenceView(model: model, inference: ChargeInferenceModel()))
        let planner = SimulationModel(document: try ProtectionPlannerTests.document())
        _ = await expectNamed(
            "Protective Design", width: 700,
            ProtectionPlannerView(model: planner, planner: planner.protectionPlanner))

        var layout = ProjectDocument(scenario: try StructureEditingTests().layout())
        layout.runSettings?.resolution = "coarse"
        let importing = SimulationModel(document: layout)
        let imported = try #require(importing.settings.scenario.importedModels?.first)
        _ = await expectNamed(
            "Import Model", width: 1100, height: 760,
            ModelImportView(
                mesh: imported.source, filename: "named-parts.obj", existing: imported, model: importing))
        let open = try ImportedMesh.inspect(
            data: Data("v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3".utf8), fileExtension: "obj")
        _ = await expectNamed(
            "Import repair", width: 560, ImportRecoveryView(filename: "open.obj", inspection: open) { _ in })

        let temporary = try TemporaryDefaults()
        defer { temporary.remove() }
        _ = await expectNamed("Settings", width: 480, AppSettingsView().defaultAppStorage(temporary.defaults))
        let district = try NewDistrictTests().model()
        await district.lay()
        _ = await expectNamed("New District", width: 620, NewDistrictView(model: district))
    }

    @Test("Envelope damage, people and the fire after the blast on a glazed street")
    func envelopesAndFire() async throws {
        let (document, ids) = try FireAfterBlastTests.street()
        let model = SimulationModel(document: document)
        model.refinesCloseCalls = false
        try await FireAfterBlastTests().settle(model)
        model.quickEstimate()
        try await FireAfterBlastTests().settle(model)
        model.showsEnvelopeDamage = true
        model.inspectedEnvelope = ids[1]
        _ = await expectNamed(
            "Envelope damage", Form { EnvelopeDamageSection(model: model) }.formStyle(.grouped))
        _ = await expectNamed("People", Form { PeopleSection(model: model) }.formStyle(.grouped))
        _ = await expectNamed("Fire, no seeds", Form { FireSection(model: model) }.formStyle(.grouped))
        model.toggleFireSeed(ids[0])
        try await FireAfterBlastTests().settle(model)
        model.envelopeColouring = .fire
        _ = await expectNamed("Fire", Form { FireSection(model: model) }.formStyle(.grouped))
        _ = await expectNamed("Run sidebar, street", SidebarView(model: model))
    }

    @Test("A run on a Mac nearby: the picker and the overlay")
    func remoteRun() async throws {
        let saved = NearbyWorkers.store
        defer { NearbyWorkers.store = saved }
        let store = MemoryPairingStore(name: "Laptop")
        try store.keep(.init(peer: .init(id: UUID(), name: "Studio"), key: Data(count: 32)))
        NearbyWorkers.store = store
        var document = ProjectDocument(scenario: ScenarioPreset.openGround.scenario)
        document.runSettings?.resolution = "coarse"
        let model = SimulationModel(document: document)
        model.runHost = NearbyWorkers.host("Studio")
        _ = await expectNamed(
            "Run on", Form { Section("Run") { RunOnPicker(model: model) } }.formStyle(.grouped))
        let inputs = try HeadlessRun.inputs(
            for: document, options: HeadlessRun.Options(project: URL(filePath: "/dev/null")))
        let job = WatchJob(
            id: UUID(), name: "On Studio", project: SweepWorkerArchive(try document.makeArchive()),
            frameInterval: 1, view: ViewSpec(sceneStride: 2), keepsRunning: true, asApp: true)
        let run = RemoteRun(
            host: NearbyWorkers.host("Studio"), name: "On Studio", scenario: inputs.scenario, inputs: inputs,
            job: job)
        run.sentSettings = model.settings
        model.remoteRun = run
        for (name, apply) in [
            ("running", { run.phase = .running }), ("paused", { run.paused = true }),
            (
                "lost",
                {
                    run.paused = false
                    run.phase = .lost("The connection dropped.")
                }
            ),
            ("finished", { run.phase = .finished }),
        ] as [(String, () -> Void)] {
            apply()
            _ = await expectNamed("Remote \(name)", width: 600, RemoteRunOverlay(model: model, remote: run))
        }
        model.remoteRun = nil
    }
}
