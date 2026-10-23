import AppKit
import BlastCore
import BlastRender
import SwiftUI
import Testing

@testable import BombCAD

/// What landed for users after 0.6.0, captured offscreen for a look by eye (docs/native-interface-
/// review.md, 23 October 2026): the dragged charge's preview and the close calls refined, the
/// learned field option, people in the scene, a run on a Mac nearby, masonry arching and the
/// solid-brick terraced sample, and the walls' and roofs' chances. Each panel in light and dark at
/// the sidebar's 310 points, whole and at a short height; the view's own drawing once.
extension InterfaceSnapshotTests {
    private static let styles: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]
    private static let short = CGSize(width: 310, height: 580)

    private func folder(_ style: String) throws -> URL {
        let output = try #require(ProcessInfo.processInfo.environment["BOMBCAD_INTERFACE_REVIEW"])
        let folder = URL(filePath: output, directoryHint: .isDirectory).appending(path: style)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// `content` in a grouped form at the sidebar's width, whole and cut to the short height.
    private func sections<V: View>(
        _ name: String, style: String, appearance: NSAppearance.Name, short: Bool = true,
        @ViewBuilder _ content: () -> V
    ) throws {
        let folder = try folder(style)
        let form = Form { content() }.formStyle(.grouped)
        try snapshot(
            form.frame(width: 310), size: CGSize(width: 310, height: 400), appearance: appearance,
            to: folder.appending(path: "\(name).png"))
        if short {
            try snapshot(
                form.frame(width: Self.short.width, height: Self.short.height).clipped(), size: Self.short,
                appearance: appearance, to: folder.appending(path: "\(name)-short.png"), expandToFit: false)
        }
    }

    /// The view as the viewport draws it now: the hazard rings and stand-off lines, the refined
    /// buildings' outlines and the charge where it is dragged to.
    private func viewport(_ model: SimulationModel, camera: OrbitCamera, to name: String) throws {
        let renderer = try #require(model.renderer)
        let queue = try #require(model.commandQueue)
        var settings = model.renderSettings
        settings.showCharge = true
        if model.isDraggingCharge { settings.chargeAt = model.settings.chargePosition }
        renderer.settings = settings
        renderer.setLines(
            (settings.showBlastHazards ? model.blastHazardLines() : []) + model.refinedOutlines())
        renderer.pixelsPerPoint = 2
        let frame = try #require(
            renderer.snapshot(commandQueue: queue, width: 1800, height: 1000, camera: camera))
        let rep = NSBitmapImageRep(cgImage: frame.image)
        try #require(rep.representation(using: .png, properties: [:])).write(
            to: try folder("view").appending(path: "\(name).png"))
    }

    /// Six glazed buildings round a 50 kg charge, at 20 to 100 m, a fence 10 m in front of it.
    private func street() throws -> ProjectDocument {
        var scene = Scenario(
            name: "Street with a fence", domainSize: SIMD3(160, 60, 20), boxes: [],
            charge: Charge(mass: 50, position: SIMD3(20, 30, 0.5)))
        let places: [(Float, Float, BuildingUse?)] = [
            (40, 22, .office), (60, 22, nil), (90, 22, .retail), (120, 22, nil), (50, 44, nil),
            (80, 44, .office),
        ]
        for (x, y, use) in places {
            let id = try scene.addEnvelopeObject(
                BuildingEnvelope(solids: [
                    Box(min: SIMD3(x, y, 0), max: SIMD3(x + 10, y + (y < 40 ? 16 : 12), 9))
                ]))
            var construction = EnvelopeConstruction(objectID: id, source: .user, detail: "glazed")
            construction.glazing = .apartments
            construction.use = use
            scene.setEnvelopeConstruction(construction)
        }
        scene.standOffLines = [
            StandOffLine(name: "Fence", points: [SIMD2(30, 0), SIMD2(30, 60)], guardsLeft: false)
        ]
        var document = ProjectDocument(scenario: scene)
        document.runSettings?.resolution = "coarse"
        return document
    }

    @Test("Render the dragged charge's preview, the close calls refined, the walls' chances and people")
    func estimateAndPeople() async throws {
        let temporary = try TemporaryDefaults()
        defer { temporary.remove() }
        let model = SimulationModel(document: try street())
        model.learnedDefaults = temporary.defaults
        model.learnedHome = temporary.folder.appending(path: "LearnedModels/field.bcfw")
        model.setLearnedPeaks(false)
        func settle() async throws {
            while model.estimatingEnvelopeDamage || model.isLoadingInputs {
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        try await settle()
        model.showsEnvelopeDamage = true
        model.renderSettings.showBlastHazards = true
        model.envelopeColouring = .someBroken
        let overview = OrbitCamera(target: SIMD3(70, 30, 0), distance: 150, azimuth: -1.2, elevation: 0.9)
        try viewport(model, camera: overview, to: "before-estimate")
        model.quickEstimate()
        try await settle()
        // The close calls under way, then refined.
        if model.isRefiningCloseCalls {
            for (style, appearance) in Self.styles {
                try sections("estimate-refining", style: style, appearance: appearance, short: false) {
                    EnvelopeDamageSection(model: model)
                }
            }
        }
        while model.isRefiningCloseCalls { try await Task.sleep(for: .milliseconds(50)) }
        let ids = Set(model.envelopeDamage.map(\.id))
        model.inspectedEnvelope = model.refinedBuildings.first ?? model.envelopeDamage.first?.id
        for (style, appearance) in Self.styles {
            try sections("estimate-refined", style: style, appearance: appearance) {
                InspectedEnvelopeSection(model: model)
                EnvelopeDamageSection(model: model, expanded: ids)
            }
        }
        try viewport(model, camera: overview, to: "refined-outlines")
        model.inspectedEnvelope = nil

        // Coloured by the walls' chance.
        model.envelopeColouring = .wallsModerate
        for (style, appearance) in Self.styles {
            try sections("estimate-walls", style: style, appearance: appearance, short: false) {
                EnvelopeDamageSection(model: model)
            }
        }
        try viewport(model, camera: overview, to: "walls-chance")
        model.envelopeColouring = .someBroken

        // People: no baseline; pinned at night, then the evening; the counts shown; coloured by them.
        for (style, appearance) in Self.styles {
            try sections("people", style: style, appearance: appearance) { PeopleSection(model: model) }
        }
        model.occupancy.time = .night
        model.pinPeopleBaseline()
        model.occupancy.time = .evening
        model.envelopeColouring = .peopleHurt
        for (style, appearance) in Self.styles {
            try sections("people-baseline", style: style, appearance: appearance) {
                PeopleSection(model: model)
            }
            try sections("people-counts", style: style, appearance: appearance, short: false) {
                PeopleSection(model: model, showsCounts: true)
            }
        }
        model.envelopeColouring = .someBroken

        // The charge dragged across the fence: a preview, the rings following it.
        model.isPlacingCharge = true
        model.camera = OrbitCamera(target: SIMD3(22, 30, 0), distance: 80, azimuth: -1.57, elevation: 1.5)
        #expect(model.beginDrag(ndc: .zero, aspectRatio: 1, modifiers: []))
        for x: Float in [26, 30, 34] {
            model.camera = OrbitCamera(target: SIMD3(x, 30, 0), distance: 80, azimuth: -1.57, elevation: 1.5)
            model.drag(ndc: .zero, aspectRatio: 1, modifiers: [])
        }
        while model.estimatingEnvelopeDamage { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.envelopeEstimateIsPreview)
        for (style, appearance) in Self.styles {
            try sections("drag-preview", style: style, appearance: appearance) {
                EnvelopeDamageSection(model: model)
                PeopleSection(model: model)
            }
            try snapshot(
                SidebarView(model: model).frame(width: 310, height: 9000),
                size: CGSize(width: 310, height: 9000),
                appearance: appearance, to: try folder(style).appending(path: "drag-sidebar.png"),
                expandToFit: false)
        }
        try viewport(model, camera: overview, to: "drag-preview")
        model.endDrag()
        try await Task.sleep(for: .milliseconds(300))
        try await settle()
        model.cancelCloseCalls(status: nil)
        model.isPlacingCharge = false
    }

    @Test("Render the learned field option, its download dialog and its messages")
    func learnedField() async throws {
        let temporary = try TemporaryDefaults()
        defer { temporary.remove() }
        var scene = Scenario(
            name: "One building", domainSize: SIMD3(80, 40, 16), boxes: [],
            charge: Charge(mass: 20, position: SIMD3(10, 20, 0.5)))
        let id = try scene.addEnvelopeObject(
            BuildingEnvelope(solids: [Box(min: SIMD3(30, 12, 0), max: SIMD3(42, 28, 9))]))
        var construction = EnvelopeConstruction(objectID: id, source: .user, detail: "glazed")
        construction.glazing = .apartments
        scene.setEnvelopeConstruction(construction)
        var document = ProjectDocument(scenario: scene)
        document.runSettings?.resolution = "coarse"
        let model = SimulationModel(document: document)
        model.learnedDefaults = temporary.defaults
        let home = temporary.folder.appending(path: "LearnedModels/field.bcfw")
        model.learnedHome = home
        model.refinesCloseCalls = false
        model.setLearnedPeaks(false, environment: [:])
        while model.isLoadingInputs { try await Task.sleep(for: .milliseconds(20)) }
        func capture(_ name: String) throws {
            for (style, appearance) in Self.styles {
                try sections("learned-\(name)", style: style, appearance: appearance, short: false) {
                    EnvelopeDamageSection(model: model)
                }
            }
        }
        try capture("off")
        // The first-use dialog, drawn as the system's alert that SwiftUI presents for it.
        model.setLearnedPeaks(true, environment: [:])
        #expect(model.offersLearnedDownload)
        for (style, appearance) in Self.styles {
            let alert = NSAlert()
            alert.messageText = EnvelopeDamageSection.learnedDownloadTitle
            alert.informativeText = LearnedField.Release.offer
            alert.addButton(withTitle: EnvelopeDamageSection.learnedDownloadButton)
            alert.addButton(withTitle: "Cancel")
            alert.window.appearance = NSAppearance(named: appearance)
            alert.layout()
            let view = try #require(alert.window.contentView)
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(
                to: try folder(style).appending(path: "learned-download-dialog.png"))
        }
        model.declineLearnedDownload()
        try capture("declined")
        // A download under way, one that fails its check, one not found, and one cancelled.
        let source = temporary.folder.appending(path: "release.bcfw")
        try LearnedFieldOptionTests.tinyWeights().write(to: source)
        model.setLearnedPeaks(true, environment: [:])
        model.downloadLearnedWeights([
            .init(source: source, destination: home, sha256: String(repeating: "0", count: 64))
        ])
        try capture("downloading")
        await model.learnedDownloadTask?.value
        try capture("checksum-failed")
        model.setLearnedPeaks(true, environment: [:])
        model.downloadLearnedWeights(
            [
                .init(
                    source: temporary.folder.appending(path: "missing.bcfw"), destination: home,
                    sha256: String(repeating: "0", count: 64))
            ])
        await model.learnedDownloadTask?.value
        try capture("download-failed")
        model.setLearnedPeaks(true, environment: [:])
        model.downloadLearnedWeights([
            .init(source: source, destination: home, sha256: String(repeating: "0", count: 64))
        ])
        model.cancelLearnedDownload()
        await model.learnedDownloadTask?.value
        try capture("cancelled")
        // A corrupt file where the weights belong: the estimate says so and goes on without it.
        try FileManager.default.createDirectory(
            at: home.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("BCFW not really weights".utf8).write(to: home)
        model.setLearnedPeaks(true, environment: [:])
        #expect(model.quickEstimateLearnedPeaks)
        model.quickEstimate()
        while model.estimatingEnvelopeDamage { try await Task.sleep(for: .milliseconds(20)) }
        try capture("corrupt")
        // And well-formed weights (a stand-in's), with the option's standing.
        try FileManager.default.removeItem(at: home)
        try LearnedFieldOptionTests.tinyWeights().write(to: home)
        model.learnedNetwork = nil
        model.learnedEstimator = nil
        model.quickEstimate()
        while model.estimatingEnvelopeDamage { try await Task.sleep(for: .milliseconds(20)) }
        try capture("on")
        model.setLearnedPeaks(false, environment: [:])
    }

    @Test("Render a run on a Mac nearby: the picker, the overlay's states and the kept run")
    func remoteRun() throws {
        let saved = NearbyWorkers.store
        defer { NearbyWorkers.store = saved }
        let store = MemoryPairingStore(name: "Laptop")
        try store.keep(.init(peer: .init(id: UUID(), name: "Studio"), key: Data(count: 32)))
        NearbyWorkers.store = store
        var document = ProjectDocument(scenario: ScenarioPreset.openGround.scenario)
        document.runSettings?.resolution = "coarse"
        var local = try SavedRunTests().fixture(name: "Run 1")
        local.capturedAt = Date(timeIntervalSince1970: 1_791_546_000)
        var remote = try SavedRunTests().fixture(name: "On Studio")
        remote.capturedAt = Date(timeIntervalSince1970: 1_791_546_600)
        document.savedRuns = [local, remote]
        let model = SimulationModel(document: document)
        model.runHost = NearbyWorkers.host("Studio")
        for (style, appearance) in Self.styles {
            try sections("run-on", style: style, appearance: appearance, short: false) {
                Section("Run") { RunOnPicker(model: model) }
            }
            try snapshot(
                SidebarView(model: model).frame(width: Self.short.width, height: Self.short.height).clipped(),
                size: Self.short, appearance: appearance,
                to: try folder(style).appending(path: "run-on-sidebar-short.png"), expandToFit: false)
            try snapshot(
                RunComparisonView(model: model), size: CGSize(width: 920, height: 640),
                appearance: appearance,
                to: try folder(style).appending(path: "run-on-kept.png"))
        }

        var sent = document
        sent.savedRuns = []
        let inputs = try HeadlessRun.inputs(
            for: sent, options: HeadlessRun.Options(project: URL(filePath: "/dev/null")))
        let job = WatchJob(
            id: UUID(), name: "On Studio", project: SweepWorkerArchive(try sent.makeArchive()),
            frameInterval: 1,
            view: ViewSpec(sceneStride: 2), keepsRunning: true, asApp: true)
        let run = RemoteRun(
            host: NearbyWorkers.host("Studio"), name: "On Studio", scenario: inputs.scenario, inputs: inputs,
            job: job)
        run.sentSettings = model.settings
        run.link = "Studio over Wi-Fi"
        run.device = "Apple M4 Max"
        run.fraction = 0.42
        run.framesShown = 37
        run.bytesReceived = 37 * 180_000
        run.projectBytes = (sent: 41_000, reused: 0)
        model.remoteRun = run
        let error = NSError(domain: NSPOSIXErrorDomain, code: 57)
        let states: [(String, () -> Void)] = [
            ("connecting", { run.phase = .connecting }),
            ("running", { run.phase = .running }),
            ("paused", { run.paused = true }),
            (
                "paused-edited",
                {
                    model.settings.chargePosition.x += 1
                }
            ),
            (
                "lost",
                {
                    run.paused = false
                    run.phase = .lost(
                        "The connection to \(run.macName) dropped (\(error.localizedDescription)). The run carries on there."
                    )
                }
            ),
            ("waiting", { run.phase = .waiting }),
            (
                "finished",
                {
                    run.summary = run.describe(nil)
                    run.phase = .finished
                }
            ),
            ("failed", { run.phase = .failed("The GPU there ran out of memory.") }),
            ("stopped", { run.phase = .stopped }),
        ]
        for (name, apply) in states {
            apply()
            for (style, appearance) in Self.styles {
                try snapshot(
                    RemoteRunOverlay(model: model, remote: run).padding(12).frame(
                        width: 600, alignment: .leading),
                    size: CGSize(width: 600, height: 60), appearance: appearance,
                    to: try folder(style).appending(path: "remote-\(name).png"))
            }
        }
        model.remoteRun = nil
    }

    @Test("Render masonry arching in the construction editor and the solid-brick terraced sample")
    func archingAndTerraces() async throws {
        var scene = Scenario(
            name: "Brick terrace", domainSize: SIMD3(60, 40, 16), boxes: [],
            charge: Charge(mass: 25, position: SIMD3(10, 20, 0.5)))
        let id = try scene.addEnvelopeObject(
            BuildingEnvelope(solids: [Box(min: SIMD3(25, 10, 0), max: SIMD3(34, 30, 8))]))
        var construction = EnvelopeConstruction(
            objectID: id, walls: .unreinforcedMasonry, wallThicknessM: 0.215, source: .user,
            detail: "solid brick")
        construction.masonryArching = true
        scene.setEnvelopeConstruction(construction)
        var document = ProjectDocument(scenario: scene)
        document.runSettings?.resolution = "coarse"
        let model = SimulationModel(document: document)
        let original = ProjectDocument(model: model)
        for (style, appearance) in Self.styles {
            try sections("arching", style: style, appearance: appearance) {
                Section("Exposure-only buildings") {
                    EnvelopeConstructionEditor(model: model, id: id, isExpanded: true)
                }
            }
            try snapshot(
                EditorView(model: model).frame(width: Self.short.width, height: Self.short.height).clipped(),
                size: Self.short, appearance: appearance,
                to: try folder(style).appending(path: "arching-editor-short.png"), expandToFit: false)
        }
        #expect(ProjectDocument(model: model) == original)

        var terraces = ProjectDocument(scenario: ScenarioPreset.terracedHouses.scenario)
        terraces.runSettings?.resolution = "coarse"
        let row = SimulationModel(document: terraces)
        while row.isLoadingInputs { try await Task.sleep(for: .milliseconds(50)) }
        for (style, appearance) in Self.styles {
            let folder = try folder(style)
            try snapshot(
                SidebarView(model: row).frame(width: 310, height: 9000),
                size: CGSize(width: 310, height: 9000),
                appearance: appearance, to: folder.appending(path: "terraced-run.png"), expandToFit: false)
            try snapshot(
                SidebarView(model: row).frame(width: Self.short.width, height: Self.short.height).clipped(),
                size: Self.short, appearance: appearance,
                to: folder.appending(path: "terraced-run-short.png"),
                expandToFit: false)
            try snapshot(
                EditorView(model: row).frame(width: 310, height: 3200),
                size: CGSize(width: 310, height: 3200),
                appearance: appearance, to: folder.appending(path: "terraced-edit.png"), expandToFit: false)
        }
    }
}
