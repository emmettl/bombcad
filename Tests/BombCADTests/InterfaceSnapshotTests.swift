import AppKit
import BlastCore
import SwiftUI
import Testing

@testable import BombCAD

@MainActor
@Suite(
    "Offscreen interface review", .serialized, .hangLimit,
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

        try withTemporaryDefaults { store in
            try snapshot(
                AppSettingsView().defaultAppStorage(store), size: CGSize(width: 480, height: 720),
                appearance: appearance, to: folder.appending(path: "settings.png"))
        }
    }

    @Test("Render the New District window laid out on the made-up district", arguments: ["light", "dark"])
    func newDistrict(style: String) async throws {
        let output = try #require(ProcessInfo.processInfo.environment["BOMBCAD_INTERFACE_REVIEW"])
        let folder = URL(filePath: output, directoryHint: .isDirectory).appending(path: style)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let district = try NewDistrictTests().model()
        await district.lay()
        #expect(district.preview != nil)
        try snapshot(
            NewDistrictView(model: district), size: CGSize(width: 620, height: 900),
            appearance: style == "dark" ? .darkAqua : .aqua, to: folder.appending(path: "new-district.png"))
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
            StandingDetail(
                standing: model.standing, kinds: [.structuralResponse, .structuralDamage],
                value: ShownValue(measure: .peakDeflection, value: 68, unit: "mm")),
            size: CGSize(width: 380, height: 520), appearance: appearance,
            to: folder.appending(path: "standing-detail.png"))
        try snapshot(
            StandingDetail(standing: model.standing, kinds: [.peakOverpressure, .impulse]),
            size: CGSize(width: 380, height: 520), appearance: appearance,
            to: folder.appending(path: "standing-detail-air.png"))
        try snapshot(
            HStack(spacing: 8) { ForEach(EvidenceLevel.allCases, id: \.self) { StandingLabel(level: $0) } }
                .padding(12),
            size: CGSize(width: 380, height: 40), appearance: appearance,
            to: folder.appending(path: "standing-labels.png"))
        #expect(ProjectDocument(model: model) == original)

        var document = ProjectDocument(scenario: ScenarioPreset.openGround.scenario)
        var reference = try SavedRunTests().fixture()
        reference.standing = reference.derivedStanding()
        var burning = try SavedRunTests().fixture(name: "Afterburning")
        burning.settings.detailedCharge = true
        burning.inputSHA256 = try SavedSimulationRun.fingerprint(burning.scenario, settings: burning.settings)
        burning.standing = burning.derivedStanding()
        document.savedRuns = [reference, burning]
        for index in document.savedRuns.indices {
            document.savedRuns[index].capturedAt = Date(timeIntervalSince1970: 1_791_546_000)
        }
        try snapshot(
            RunComparisonView(model: SimulationModel(document: document)),
            size: CGSize(width: 920, height: 640),
            appearance: appearance, to: folder.appending(path: "standing-comparison.png"))
    }

    @Test("Render the readouts' error bands after a short run", arguments: ["light", "dark"])
    func bandedReadouts(style: String) async throws {
        let output = try #require(ProcessInfo.processInfo.environment["BOMBCAD_INTERFACE_REVIEW"])
        let folder = URL(filePath: output, directoryHint: .isDirectory).appending(path: style)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var document = ProjectDocument(scenario: ScenarioPreset.blastWall.scenario)
        document.runSettings?.resolution = "medium"
        document.runSettings?.duration = 0.03
        let model = SimulationModel(document: document, playbackSpeed: .unlimited)
        while !model.experimentIsReady {
            try await Task.sleep(for: .milliseconds(20))
        }
        model.run()
        while model.isRunning || model.time < 0.029 {
            try await Task.sleep(for: .milliseconds(20))
        }
        let appearance: NSAppearance.Name = style == "dark" ? .darkAqua : .aqua
        try snapshot(
            GaugeChartView(model: model).frame(width: 900, height: 260),
            size: CGSize(width: 900, height: 260),
            appearance: appearance, to: folder.appending(path: "standing-readout.png"))
    }

    @Test("Render envelope buildings' damage at the sidebar's width", arguments: ["light", "dark"])
    func envelopeDamage(style: String) throws {
        let output = try #require(ProcessInfo.processInfo.environment["BOMBCAD_INTERFACE_REVIEW"])
        let folder = URL(filePath: output, directoryHint: .isDirectory).appending(path: style)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var scene = try StreetInteractionStudy.make(.street)
        for object in scene.structuralObjects { try scene.useEnvelope(id: object.id) }
        var document = ProjectDocument(scenario: scene)
        document.runSettings?.resolution = "coarse"
        let model = SimulationModel(document: document)
        // Each building loaded harder than the last, the first two with a pane, so that the
        // section shows each level, glass broken and the flag.
        var loads: [EnvelopeComponentLoad] = []
        for (index, object) in scene.envelopeObjects.enumerated() {
            let peak = [3e3, 60e3, 250e3, 900e3][index]
            for component in object.envelope!.components(owner: object.id, cellSize: 0.25) {
                let pulse = (0..<800).map { bin in
                    let t = (Double(bin) + 0.5) * 1e-4
                    return t < 0.004 ? peak * (1 - t / 0.004) : 0
                }
                loads.append(
                    EnvelopeComponentLoad(
                        id: component.id, owner: object.id,
                        kind: EnvelopeComponentLoad.Kind(rawValue: component.kind.rawValue) ?? .wall,
                        region: component.region, axis: component.axis, binS: 1e-4, outerPa: pulse,
                        innerPa: []))
            }
            if index < 2, let wall = loads.last(where: { $0.owner == object.id && $0.kind == .wall }) {
                var pane = wall
                pane.id = "\(object.id)/pane/0.0"
                pane.kind = .pane
                pane.region = Box(min: wall.region.min, max: wall.region.min + SIMD3(1.5, 1.5, 1.25))
                pane.region.max[wall.axis] = wall.region.min[wall.axis] + 0.006
                loads.append(pane)
            }
        }
        model.updateEnvelopeDamage(loads: loads)
        let appearance: NSAppearance.Name = style == "dark" ? .darkAqua : .aqua
        try snapshot(
            Form { EnvelopeDamageSection(model: model) }.formStyle(.grouped).frame(width: 310),
            size: CGSize(width: 310, height: 700), appearance: appearance,
            to: folder.appending(path: "envelope-damage.png"))
    }

    /// A blast wall on a hill, with freestanding objects and every companion model in use, so
    /// that each of the Run sidebar's sections shows its settings.
    private func everySection() throws -> ProjectDocument {
        var scene = ScenarioPreset.blastWall.scenario
        scene.boxes = [Box(min: SIMD3(7, 9, 0), max: SIMD3(10, 14, 3))]
        scene.rigidObjects = [
            try RigidObjectDefinition(
                name: "Crate", shape: .box(size: SIMD3(1, 1, 1)), position: SIMD3(25, 19, 0.5), mass: 200)
        ]
        scene.rigidCars = [try .saloon(position: SIMD3(27, 25, 0))]
        scene.replaceTerrain(
            with: .hill(domain: scene.domainSize, spacing: 0.5, centre: SIMD2(29, 21), height: 2, radius: 4))
        var document = ProjectDocument(scenario: scene)
        document.runSettings?.resolution = "coarse"
        // As the sections' switches set them, with a line of points a choice does not offer.
        document.fragments = FragmentSection.defaultSpec(for: scene)
        document.thermal = ThermalSpec()
        document.cloud = CloudSpec()
        var ground = GroundShockSection.defaultSpec(for: scene)
        ground.line?.count = 12
        document.groundShock = ground
        return document
    }

    @Test(
        "Open faces too near a structure are warned of in the Domain section", arguments: ["light", "dark"])
    func tightFaces(style: String) throws {
        let output = try #require(ProcessInfo.processInfo.environment["BOMBCAD_INTERFACE_REVIEW"])
        let folder = URL(filePath: output, directoryHint: .isDirectory).appending(path: style)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var scene = ScenarioPreset.blastWall.scenario
        let wall = try #require(scene.structure?.solids.first)
        // The top just over the wall, far nearer than 4 m/kg^(1/3).
        scene.domainSize.z = wall.max.z + 0.5
        #expect(scene.tightFacesNote != nil)
        // With the far faces alone near, the choice to widen to the rule and its price; with the
        // charge brought near x = 0 as well, the face widening cannot clear named beneath it.
        var origin = scene
        origin.charge.position.x = 3
        for (name, scene) in [("run-tight-faces.png", scene), ("run-tight-faces-origin.png", origin)] {
            var document = ProjectDocument(scenario: scene)
            document.runSettings?.resolution = "coarse"
            let model = SimulationModel(document: document)
            #expect(model.wideningToTheRule != nil)
            try snapshot(
                SidebarView(model: model).frame(width: 310, height: 6000),
                size: CGSize(width: 310, height: 6000),
                appearance: style == "dark" ? .darkAqua : .aqua,
                to: folder.appending(path: name),
                expandToFit: false)
        }
    }

    /// A methane cloud in a vented room.
    private func gasRoom() -> ProjectDocument {
        var scene = Scenario(
            name: "Vented room", domainSize: SIMD3(8, 6, 4), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(1, 1, 1)))
        scene.deflagration = Deflagration(
            gas: .methane, region: Box(min: SIMD3(0.5, 0.5, 0), max: SIMD3(4, 4, 2.5)),
            ignition: SIMD3(1, 1, 1))
        scene.ventPanels = [
            VentPanel(box: Box(min: SIMD3(3.9, 1, 1), max: SIMD3(4, 2, 2)), releasePressure: 5000)
        ]
        var document = ProjectDocument(scenario: scene)
        document.runSettings?.resolution = "coarse"
        return document
    }

    @Test("Render the Infer Charge sheet empty and with a posterior", arguments: ["light", "dark"])
    func chargeInference(style: String) async throws {
        let output = try #require(ProcessInfo.processInfo.environment["BOMBCAD_INTERFACE_REVIEW"])
        let folder = URL(filePath: output, directoryHint: .isDirectory).appending(path: style)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let appearance: NSAppearance.Name = style == "dark" ? .darkAqua : .aqua
        let model = SimulationModel(document: ProjectDocument(scenario: ScenarioPreset.openGround.scenario))
        let original = ProjectDocument(model: model)
        let inference = ChargeInferenceModel()
        try snapshot(
            ChargeInferenceView(model: model, inference: inference), size: CGSize(width: 600, height: 560),
            appearance: appearance, to: folder.appending(path: "infer-charge-empty.png"))
        inference.setObservers(ChargeInferenceSheetTests.observers(), file: "made-up.csv")
        inference.infersOffset = true
        inference.steps = 600
        inference.run()
        while inference.isRunning { try await Task.sleep(for: .milliseconds(20)) }
        #expect(inference.result != nil)
        try snapshot(
            ChargeInferenceView(model: model, inference: inference).frame(height: 1100),
            size: CGSize(width: 600, height: 1100), appearance: appearance,
            to: folder.appending(path: "infer-charge.png"))
        #expect(ProjectDocument(model: model) == original)
    }

    @Test("Render the Protective Design sheet empty and with plans", arguments: ["light", "dark"])
    func protectivePlanner(style: String) async throws {
        let output = try #require(ProcessInfo.processInfo.environment["BOMBCAD_INTERFACE_REVIEW"])
        let folder = URL(filePath: output, directoryHint: .isDirectory).appending(path: style)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let appearance: NSAppearance.Name = style == "dark" ? .darkAqua : .aqua
        let model = SimulationModel(document: try ProtectionPlannerTests.document())
        let original = ProjectDocument(model: model)
        let planner = ProtectionPlannerModel()
        try snapshot(
            ProtectionPlannerView(model: model, planner: planner), size: CGSize(width: 640, height: 560),
            appearance: appearance, to: folder.appending(path: "protective-design-empty.png"))
        planner.draws = 2
        planner.search(model.settings.scenario, cellSize: model.settings.resolution.cellSize)
        while planner.isRunning { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!planner.plans.isEmpty)
        try snapshot(
            ProtectionPlannerView(model: model, planner: planner).frame(height: 900),
            size: CGSize(width: 640, height: 900), appearance: appearance,
            to: folder.appending(path: "protective-design.png"))
        #expect(ProjectDocument(model: model) == original)
    }

    @Test("Render the replay bar offering a recording and scrubbing one", arguments: ["light", "dark"])
    func replayBar(style: String) async throws {
        let output = try #require(ProcessInfo.processInfo.environment["BOMBCAD_INTERFACE_REVIEW"])
        let folder = URL(filePath: output, directoryHint: .isDirectory).appending(path: style)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let appearance: NSAppearance.Name = style == "dark" ? .darkAqua : .aqua
        let kept = try SavedRunTests().fixture()
        var document = ProjectDocument(scenario: kept.scenario)
        document.runSettings = kept.settings
        let model = SimulationModel(document: document, playbackSpeed: .unlimited)
        model.recordsTimelines = true
        while !model.experimentIsReady { try await Task.sleep(for: .milliseconds(5)) }
        model.run()
        while model.isRunning || model.hasPendingGPUWork || model.recentTimeline == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        let size = CGSize(width: 900, height: 44)
        try snapshot(
            TimelineBar(model: model).frame(width: size.width), size: size, appearance: appearance,
            to: folder.appending(path: "replay-offered.png"))
        model.replay(nil)
        model.playback?.seek(to: model.time / 2)
        try snapshot(
            TimelineBar(model: model).frame(width: size.width), size: size, appearance: appearance,
            to: folder.appending(path: "replay-scrubbing.png"))
        model.stopReplay()
        if let recent = model.recentTimeline { try? FileManager.default.removeItem(at: recent) }
    }

    @Test("Render the panels not yet reviewed, whole and at a short height", arguments: ["light", "dark"])
    func remainingPanels(style: String) throws {
        let output = try #require(ProcessInfo.processInfo.environment["BOMBCAD_INTERFACE_REVIEW"])
        let folder = URL(filePath: output, directoryHint: .isDirectory).appending(path: style)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let appearance: NSAppearance.Name = style == "dark" ? .darkAqua : .aqua
        let short = CGSize(width: 310, height: 580)
        for (name, document) in [("every-section", try everySection()), ("gas-room", gasRoom())] {
            let model = SimulationModel(document: document)
            let original = ProjectDocument(model: model)
            // The whole Run sidebar, tall enough to show every row, and at the short height.
            try snapshot(
                SidebarView(model: model).frame(width: 310, height: 6000),
                size: CGSize(width: 310, height: 6000),
                appearance: appearance, to: folder.appending(path: "run-\(name).png"), expandToFit: false)
            try snapshot(
                SidebarView(model: model).frame(width: short.width, height: short.height).clipped(),
                size: short,
                appearance: appearance, to: folder.appending(path: "run-\(name)-short.png"),
                expandToFit: false)
            #expect(ProjectDocument(model: model) == original)
        }
        // The Edit tab with a gauge, a block and a freestanding object chosen.
        let model = SimulationModel(document: try everySection())
        let original = ProjectDocument(model: model)
        model.selection = .gauge(0)
        try snapshot(
            EditorView(model: model).frame(width: 310, height: 3200), size: CGSize(width: 310, height: 3200),
            appearance: appearance, to: folder.appending(path: "edit-gauge.png"), expandToFit: false)
        if let id = model.settings.scenario.fixedObjects.first?.id {
            model.selection = .block(id)
            try snapshot(
                EditorView(model: model).frame(width: 310, height: 3200),
                size: CGSize(width: 310, height: 3200),
                appearance: appearance, to: folder.appending(path: "edit-block.png"), expandToFit: false)
        }
        model.selection = nil
        try snapshot(
            EditorView(model: model).frame(width: short.width, height: short.height).clipped(), size: short,
            appearance: appearance, to: folder.appending(path: "edit-short.png"), expandToFit: false)
        // Sheets: a sweep, and a file that cannot be imported.
        try snapshot(
            ParameterSweepView(model: model), size: CGSize(width: 520, height: 420), appearance: appearance,
            to: folder.appending(path: "sweep.png"))
        let open = try ImportedMesh.inspect(
            data: Data("v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3".utf8), fileExtension: "obj")
        try snapshot(
            ImportRecoveryView(filename: "open.obj", inspection: open) { _ in },
            size: CGSize(width: 560, height: 420),
            appearance: appearance, to: folder.appending(path: "import-recovery.png"))
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
        // A capture taller than a screen also in parts of about one, overlapping, to read.
        guard host.bounds.height > 1100, let image = bitmap.cgImage else { return }
        let scale = CGFloat(image.height) / host.bounds.height
        let part = 900 * scale
        var top: CGFloat = 0
        var index = 1
        while top < CGFloat(image.height) {
            let rect = CGRect(
                x: 0, y: top, width: CGFloat(image.width), height: min(part, CGFloat(image.height) - top))
            let piece = try #require(image.cropping(to: rect))
            let rep = NSBitmapImageRep(cgImage: piece)
            let name = file.deletingPathExtension().lastPathComponent + "-part\(index).png"
            try #require(rep.representation(using: .png, properties: [:])).write(
                to: file.deletingLastPathComponent().appending(path: name))
            top += part - 60 * scale
            index += 1
        }
    }
}
