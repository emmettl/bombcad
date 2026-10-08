import AcousticCore
import AppKit
import CoreGraphics
import Foundation
import RoomDocument
import SceneRender
import SceneView
import Testing
import simd

@testable import RoomCAD

@MainActor
@Suite("RoomCAD editor")
struct RoomCADTests {
    static var settings: RoomResponseSettings {
        RoomResponseSettings(
            room: ShoeboxRoom(size: [5, 4, 3], material: .uniform(0.4, name: "Test")),
            source: RoomPoint(name: "Source", position: [1.3, 1.1, 1.2]),
            receivers: [RoomPoint(name: "Listener", position: [3.7, 2.9, 1.6])],
            duration: 0.15, maximumReflectionOrder: 30)
    }

    @Test("Generating delivers a response for the current settings and summarizes it")
    func generate() async throws {
        let editor = RoomEditor()
        var project = RoomProject(settings: Self.settings)
        editor.generate(project.settings) { project.result = $0 }
        #expect(editor.isGenerating)
        await editor.finished()
        #expect(!editor.isGenerating)
        #expect(editor.message == nil)
        #expect(project.isResultCurrent)
        #expect(editor.summary?.channels.count == 1)
    }

    @Test("Automatic regeneration can ask for a preview, which a full-quality run then replaces")
    func previewThenFull() async throws {
        let editor = RoomEditor()
        var project = RoomProject(settings: Self.settings)
        await editor.regenerate(project.settings, quality: .preview, after: .zero) { project.result = $0 }
        await editor.finished()
        #expect(project.isResultCurrent && !project.isResultFinal)
        await editor.regenerate(project.settings, quality: .full, after: .zero) { project.result = $0 }
        await editor.finished()
        #expect(project.isResultFinal)
    }

    @Test("Invalid settings are reported instead of generated")
    func invalid() async {
        let editor = RoomEditor()
        var settings = Self.settings
        settings.source.position.z = 4
        var delivered = false
        editor.generate(settings) { _ in delivered = true }
        await editor.finished()
        #expect(!delivered)
        #expect(editor.message?.contains("Source") == true)
    }

    @Test("Cancelling stops a long generation without delivering it")
    func cancel() async {
        let editor = RoomEditor()
        var settings = Self.settings
        settings.duration = 4
        settings.maximumReflectionOrder = 400
        var delivered = false
        let start = Date()
        editor.generate(settings) { _ in delivered = true }
        editor.cancel()
        #expect(!editor.isGenerating)
        await editor.finished()
        #expect(!delivered)
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test("A newer generation replaces one in progress")
    func replaces() async {
        let editor = RoomEditor()
        var first = Self.settings
        first.duration = 4
        first.maximumReflectionOrder = 400
        var names: [String] = []
        editor.generate(first) { _ in names.append("first") }
        editor.generate(Self.settings) { _ in names.append("second") }
        await editor.finished()
        #expect(names == ["second"])
    }

    @Test("Automatic regeneration waits for changes to settle and generates only the latest settings")
    func debounced() async {
        let editor = RoomEditor()
        var delivered: [Double] = []
        var first = Self.settings
        first.duration = 0.1
        let superseded = Task {
            await editor.regenerate(first, after: .milliseconds(300)) {
                delivered.append($0.settings.duration)
            }
        }
        // A newer change cancels the wait, as SwiftUI does when a task's identity changes.
        superseded.cancel()
        await superseded.value
        await editor.regenerate(Self.settings, after: .milliseconds(50)) {
            delivered.append($0.settings.duration)
        }
        #expect(editor.isGenerating)
        await editor.finished()
        #expect(delivered == [Self.settings.duration])
    }

    @Test(
        "A change cancels a run for older settings at once, and repeats of the running settings are ignored")
    func supersedes() async {
        let editor = RoomEditor()
        // Points get new identities on each access, so keep one copy.
        let current = Self.settings
        var slow = current
        slow.duration = 4
        slow.maximumReflectionOrder = 400
        var delivered: [Double] = []
        editor.generate(slow) { delivered.append($0.settings.duration) }
        await editor.regenerate(current, after: .zero) { delivered.append($0.settings.duration) }
        #expect(editor.generatingSettings == current)
        // Asking again for what is running does not restart it.
        await editor.regenerate(current, after: .zero) { _ in delivered.append(-1) }
        await editor.finished()
        #expect(delivered == [current.duration])
    }

    @Test("Automatic regeneration skips invalid settings and results that arrived during the wait")
    func skips() async {
        let editor = RoomEditor()
        var invalid = Self.settings
        invalid.receivers[0].position.x = 99
        await editor.regenerate(invalid, after: .zero) { _ in }
        #expect(!editor.isGenerating)
        await editor.regenerate(Self.settings, after: .zero, needed: { false }, deliver: { _ in })
        #expect(!editor.isGenerating)
    }

    @Test("Drawing coordinates map to the room and dragged points stay inside it")
    func layout() {
        let size: SIMD3<Double> = [8, 6, 3]
        let plan = RoomLayout(projection: .plan, size: size, bounds: CGSize(width: 500, height: 400))
        let rect = plan.roomRect
        #expect(abs(rect.width / rect.height - 8.0 / 6.0) < 1e-9)
        #expect(rect.minX >= RoomLayout.padding - 1e-9 && rect.minY >= RoomLayout.padding - 1e-9)
        let point: SIMD3<Double> = [2.25, 4.5, 1.2]
        let moved = plan.moved([0, 0, 1.2], to: plan.point(point))
        #expect(abs(moved.x - 2.25) < 0.006 && abs(moved.y - 4.5) < 0.006 && moved.z == 1.2)
        // y increases up the page.
        #expect(plan.point([1, 5, 0]).y < plan.point([1, 1, 0]).y)
        let clamped = plan.moved(point, to: CGPoint(x: -100, y: 1000))
        #expect(clamped.x == 0.05 && clamped.y == 0.05)

        let section = RoomLayout(projection: .elevation, size: size, bounds: CGSize(width: 500, height: 400))
        let raised = section.moved(point, to: section.point([3, 0, 2.5]))
        #expect(abs(raised.z - 2.5) < 0.006 && raised.y == 4.5)
    }
}

@MainActor
@Suite("RoomCAD audition player")
struct AuditionPlayerTests {
    @Test("A chosen clip is shown alone until a response is prepared, then dry and wet span clip and tail")
    func preparing() async throws {
        let player = AuditionPlayer()
        player.prepareClips(sampleRate: 48_000)
        let clip = try #require(player.clip)
        #expect(player.dryOverview?.duration == clip.duration)
        #expect(player.wetOverview == nil)

        let result = try await RoomResponseGenerator.generate(RoomCADTests.settings)
        player.prepare(result)
        // A second request for the same room joins the first.
        player.prepare(result, thenPlay: false)
        #expect(player.isPreparing)
        await player.preparationFinished()
        #expect(!player.isPreparing)
        #expect(!player.isPlaying)
        let expected = clip.duration + Double(result.response.frameCount - 1) / 48_000
        #expect(abs((player.wetOverview?.duration ?? 0) - expected) < 1e-9)
        #expect(player.dryOverview?.duration == player.wetOverview?.duration)
    }

    @Test("Seeking while paused moves the playhead within the clip")
    func seeking() throws {
        let player = AuditionPlayer()
        try player.prepareImmediately(try RoomResponseGenerator.generate(RoomCADTests.settings))
        player.seek(to: 1.25)
        #expect(player.playhead == 1.25)
        #expect(player.currentTime() == 1.25)
        player.seek(to: 1_000)
        #expect(player.playhead == player.duration)
        player.seek(to: -3)
        #expect(player.playhead == 0)
    }

    @Test("Choosing another clip resets the playhead and shows that clip")
    func choosingClips() async throws {
        let player = AuditionPlayer()
        let result = try await RoomResponseGenerator.generate(RoomCADTests.settings)
        try player.prepareImmediately(result)
        player.seek(to: 2)
        let other = try #require(player.clips.first { $0.id == "noise-burst" })
        player.clipID = other.id
        player.clipSelected(result)
        #expect(player.playhead == 0)
        #expect(player.dryOverview?.duration == other.duration)
        await player.preparationFinished()
        #expect(player.wetOverview != nil)
        #expect(!player.isPlaying)
    }

    @Test("Switching loudness matching changes the wet lane's level, not its length")
    func matching() throws {
        let player = AuditionPlayer()
        try player.prepareImmediately(try RoomResponseGenerator.generate(RoomCADTests.settings))
        let matched = try #require(player.wetOverview)
        player.matchLoudness = false
        let physical = try #require(player.wetOverview)
        #expect(matched.duration == physical.duration)
        #expect(matched.maximum != physical.maximum)
    }
}

@MainActor
@Suite("RoomCAD space bar")
struct SpaceKeyTests {
    private func key(
        _ characters: String, in window: NSWindow, modifiers: NSEvent.ModifierFlags = [],
        repeated: Bool = false
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: repeated,
            keyCode: characters == " " ? 49 : 0)!
    }

    @Test("A bare space in the editor's window toggles playback; anything else passes through")
    func filter() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
            backing: .buffered,
            defer: false)
        let other = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
            backing: .buffered,
            defer: false)
        #expect(SpaceKeyMonitor.isPlayPause(key(" ", in: window), in: window))
        #expect(!SpaceKeyMonitor.isPlayPause(key(" ", in: window, modifiers: .command), in: window))
        #expect(!SpaceKeyMonitor.isPlayPause(key(" ", in: window, repeated: true), in: window))
        #expect(!SpaceKeyMonitor.isPlayPause(key("a", in: window), in: window))
        #expect(!SpaceKeyMonitor.isPlayPause(key(" ", in: other), in: window))
        #expect(!SpaceKeyMonitor.isPlayPause(key(" ", in: window), in: nil))

        // While a text field is being edited, space types a space.
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 24))
        window.contentView?.addSubview(field)
        window.makeFirstResponder(field)
        #expect(window.firstResponder is NSText)
        #expect(!SpaceKeyMonitor.isPlayPause(key(" ", in: window), in: window))
    }

    @Test("A new window's text field gives up the keyboard so the space bar plays")
    func initialFocus() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
            backing: .buffered,
            defer: false)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 24))
        window.contentView?.addSubview(field)
        window.makeFirstResponder(field)
        #expect(window.firstResponder is NSText)
        let monitor = SpaceKeyMonitor()
        let sink = WindowReader.FocusSink()
        sink.monitor = monitor
        window.contentView?.addSubview(sink)
        try await Task.sleep(for: .milliseconds(50))
        #expect(monitor.window === window)
        #expect(window.firstResponder === sink)
        #expect(SpaceKeyMonitor.isPlayPause(key(" ", in: window), in: window))
    }
}

@Test("The diagnostics say where the wave solver's runs went")
func waveEngines() {
    #expect(DiagnosticsList.engines(runs: 2, gpu: 2) == "2 runs on the GPU")
    #expect(DiagnosticsList.engines(runs: 1, gpu: 0) == "1 run on the CPU")
    #expect(DiagnosticsList.engines(runs: 3, gpu: 1) == "3 runs, 1 on the GPU and 2 on the CPU")
}

@Test("Generation progress reads as the stage and a percentage")
@MainActor
func progressText() {
    #expect(RoomEditor.describe((nil, 0)) == nil)
    #expect(RoomEditor.describe((.rays, 0.404)) == "Tracing rays 40%")
    #expect(RoomEditor.describe((.waveSolver, 1)) == "Wave solver 100%")
}

@MainActor
@Test("Fitting absorption applies a room that meets the target and reports how far it scaled")
func fitAbsorption() async throws {
    var settings = RoomProject.starter
    settings.lowFrequencyModel = false
    settings.duration = 1.2
    // Quick enough for a test: few image sources, the rays carry the rest.
    settings.maximumReflectionOrder = 8
    settings.diffuseRays = 5_000
    let fitter = AbsorptionFitter()
    fitter.fit(settings, to: Array(repeating: nil, count: 8)) { _ in Issue.record("Nothing to fit") }
    #expect(fitter.status == "Enter a target time in at least one band.")
    var fitted: ShoeboxRoom?
    fitter.fit(settings, to: [nil, nil, nil, 0.5, 0.5, nil, nil, nil]) { fitted = $0 }
    #expect(fitter.isRunning)
    while fitter.isRunning { try await Task.sleep(for: .milliseconds(50)) }
    let room = try #require(fitted)
    // The starter living room decays faster than 0.5 s, so the fit takes absorption away in the
    // bands asked for and leaves the others.
    #expect(room.floor.absorption[4] < settings.room.floor.absorption[4])
    #expect(room.floor.absorption[6] == settings.room.floor.absorption[6])
    let status = try #require(fitter.status)
    #expect(status.hasPrefix("Absorption scaled ×0."), "\(status)")
    #expect(status.hasSuffix("of the targets."))
}

@MainActor
@Test(
    "The 3D scene covers the room's surfaces once, colours them by material, and a click selects what it hits"
)
func roomScene() throws {
    var settings = RoomProject.starter
    settings.openings = [Opening(name: "Door", surface: .north, centre: [2, 1], size: [0.9, 2])]
    settings.room.fittings = [RoomInspector.seating(in: settings.room.size)]
    let scene = RoomScene(settings: settings)
    // The triangles' area is the room's surface area.
    var area = 0.0
    var vertices = scene.geometry.solid.makeIterator()
    while let a = vertices.next(), let b = vertices.next(), let c = vertices.next() {
        guard a.pick < 6 else { continue }
        area += Double(simd_length(simd_cross(b.point - a.point, c.point - a.point))) / 2
    }
    #expect(abs(area / settings.room.surfaceArea - 1) < 1e-4)
    #expect(scene.names == ["West wall", "East wall", "South wall", "North wall", "Floor", "Ceiling"])
    // Walls of one material share a colour.
    let colours = Dictionary(grouping: scene.geometry.solid.filter { $0.pick < 6 }, by: \.pick).mapValues {
        $0[0].colour
    }
    #expect(colours[0] == colours[1] || settings.room.west != settings.room.east)
    // The door lies on the north wall, just inside it.
    let door = try #require(RoomScene.corners(of: settings.openings[0], in: settings.room))
    #expect(door.allSatisfy { abs($0.y - (settings.room.size.y - 0.01)) < 1e-12 })

    // From above the middle of the room, through the ceiling, which is seen from behind: the seating
    // zone, translucent but selectable, is hit before the floor.
    let viewport = RoomViewport()
    viewport.show(settings)
    let size = SIMD3<Float>(settings.room.size)
    viewport.camera = OrbitCamera(
        target: SIMD3(size.x * 0.55, size.y * 0.5, 0), distance: 20, azimuth: 0, elevation: 1.55)
    viewport.click(ndc: [0, 0], aspectRatio: 1)
    #expect(viewport.selected == .zone(0))
    #expect(viewport.caption?.hasPrefix("Seating: ") == true)
    // Beside the zone, the floor.
    viewport.camera.target = SIMD3(size.x * 0.1, size.y * 0.5, 0)
    viewport.click(ndc: [0, 0], aspectRatio: 1)
    #expect(viewport.selected == .surface(4))
    #expect(viewport.caption?.hasPrefix("Floor: ") == true)
    // Clicking the source.
    let source = SIMD3<Float>(settings.source.position)
    viewport.camera = OrbitCamera(target: source, distance: 4, azimuth: 0.3, elevation: 0.4)
    viewport.click(ndc: [0, 0], aspectRatio: 1)
    #expect(viewport.selected == .source)
    // A room with fewer receivers drops a selection that no longer exists.
    viewport.select(.receiver(1))
    settings.receivers.removeLast()
    viewport.show(settings)
    #expect(viewport.selected == nil)
    #expect(RoomScene.Item(pick: RoomScene.Item.zone(2).pick) == .zone(2))
    // The framing keeps every corner of a long hall in view.
    let camera = RoomViewport.framing([40, 20, 12], aspectRatio: 2)
    let projection = MeshRenderer.viewProjection(camera, aspectRatio: 2)
    for i in 0..<8 {
        let corner = SIMD3<Float>(i & 1 == 0 ? 0 : 40, i & 2 == 0 ? 0 : 20, i & 4 == 0 ? 0 : 12)
        let clip = projection * SIMD4(corner, 1)
        #expect(abs(clip.x / clip.w) <= 0.85 && abs(clip.y / clip.w) <= 0.85)
    }
}

@Test("Surfaces are numbered alike for boxes, plans and meshes, and a material set on one lands there")
func surfaceMaterials() throws {
    let carpet = SurfaceMaterial.uniform(0.3, name: "Carpet")
    let box = RoomProject.starter
    let plan = try #require(RoomPresets.all.first { $0.id == "l-shaped-living-room" }).applied(to: box)
    let hall = try #require(RoomPresets.all.first { $0.id == "raked-auditorium" }).applied(to: box)
    for settings in [box, plan, hall] {
        let count = RoomScene.surfaces(of: settings.room).mesh.materials.count
        for index in 0..<count {
            #expect(
                settings.surfaceMaterial(index) == RoomScene.surfaces(of: settings.room).mesh.materials[index]
            )
        }
        #expect(settings.surfaceMaterial(count) == nil)
        let edited = settings.settingSurfaceMaterial(count - 1, to: carpet)
        #expect(edited.surfaceMaterial(count - 1) == carpet)
        #expect(RoomScene.surfaces(of: edited.room).mesh.materials[count - 1] == carpet)
        #expect(edited.surfaceMaterial(0) == settings.surfaceMaterial(0))
    }
    // The box's last surface is the ceiling; the plan's, its ceiling after the walls and floor.
    #expect(box.settingSurfaceMaterial(5, to: carpet).room.ceiling == carpet)
    #expect(plan.settingSurfaceMaterial(7, to: carpet).room.ceiling == carpet)
}

@MainActor
@Test("Dragging the source moves it across the room at its height, or with Option up and down, never out")
func dragPoint() throws {
    let settings = RoomProject.starter
    let viewport = RoomViewport()
    var edits: [RoomResponseSettings] = []
    viewport.onEdit = { edits.append($0) }
    viewport.show(settings)
    let source = SIMD3<Float>(settings.source.position)
    viewport.camera = OrbitCamera(target: source, distance: 4, azimuth: 0.3, elevation: 0.6)
    // A press on the floor is not a drag.
    #expect(!viewport.beginDrag(ndc: [0, -0.95], aspectRatio: 1, modifiers: []))
    #expect(viewport.beginDrag(ndc: [0, 0], aspectRatio: 1, modifiers: []))
    #expect(viewport.selected == .source)
    viewport.drag(ndc: [0.15, 0], aspectRatio: 1, modifiers: [])
    let moved = try #require(edits.last).source.position
    #expect(moved.z == settings.source.position.z)
    #expect(simd_distance(moved, settings.source.position) > 0.1)
    viewport.drag(ndc: [0.15, 0.2], aspectRatio: 1, modifiers: .vertical)
    let raised = try #require(edits.last).source.position
    #expect(raised.x == moved.x && raised.y == moved.y && raised.z > moved.z)
    // Far beyond the walls: the move is refused and the source stays inside.
    let count = edits.count
    viewport.drag(ndc: [0.99, -0.99], aspectRatio: 1, modifiers: [])
    viewport.drag(ndc: [-0.99, 0.99], aspectRatio: 1, modifiers: .vertical)
    viewport.endDrag()
    for edit in edits[count...] { #expect(edit.room.contains(edit.source.position)) }
    #expect(settings.moving(.source, to: [-1, 1, 1]) == settings)
    #expect(settings.moving(.source, to: [1.234, 1.5, 1.2]).source.position == [1.23, 1.5, 1.2])
}

@Test("An OBJ file becomes the room, and points left outside it move to roomy spots inside")
func importModel() throws {
    // A 20 × 10 × 6 m hall, drawn in centimetres with y up, faces pointing out, floor and ceiling named.
    let obj = """
        v 0 0 0
        v 2000 0 0
        v 0 0 -1000
        v 2000 0 -1000
        v 0 600 0
        v 2000 600 0
        v 0 600 -1000
        v 2000 600 -1000
        usemtl Walls
        f 1 5 7 3
        f 2 4 8 6
        f 1 2 6 5
        f 3 7 8 4
        usemtl Floor
        f 1 3 4 2
        usemtl Ceiling
        f 5 6 8 7
        """
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).obj")
    try Data(obj.utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let model = try PendingModel(url: url)
    #expect(model.polygons.count == 6)
    #expect(model.polygons.map(\.name) == ["Walls", "Walls", "Walls", "Walls", "Floor", "Ceiling"])
    let (room, _) = try RoomImport.room(
        from: model.polygons, scale: ModelUnit.centimetres.metres, yUp: true,
        material: .uniform(0.1, name: "Plaster"))
    #expect(simd_distance(room.size, [20, 10, 6]) < 1e-6)

    var settings = RoomProject.starter
    settings.openings = [Opening(name: "Door", surface: .north, centre: [2, 1], size: [0.9, 2])]
    // The starter room's points are inside the hall too, so they stay.
    #expect(settings.replacingRoom(with: room).source.position == settings.source.position)
    // Points outside a smaller room, 4 × 2 × 1.2 m, move inside, at least 0.3 m from every surface.
    let small = try RoomImport.room(
        from: model.polygons, scale: 0.002, yUp: true, material: .uniform(0.1, name: "Plaster")
    ).room
    let placed = settings.replacingRoom(with: small)
    #expect(placed.openings.isEmpty)
    for point in [placed.source] + placed.receivers {
        #expect(small.contains(point.position) && small.clearance(point.position) >= 0.3, "\(point.position)")
    }
    #expect(simd_distance(placed.source.position, placed.receivers[0].position) > 0.5)
    try placed.validate()
}

@Test("Zones move and resize within the room without overlapping; openings stay within their surface")
func zoneAndOpeningEdits() throws {
    var settings = RoomProject.starter
    let size = settings.room.size
    settings.room.fittings = [
        FittingZone(
            name: "A", low: [1, 1, 0], high: [2, 2, 1], density: 0.5,
            absorption: Array(repeating: 0, count: 8)),
        FittingZone(
            name: "B", low: [3, 1, 0], high: [4, 2, 1], density: 0.5,
            absorption: Array(repeating: 0, count: 8)),
    ]
    settings.openings = [Opening(name: "Door", surface: .north, centre: [1, 1], size: [0.9, 2])]
    // Moving stops at the walls, and keeps the zone's size.
    let moved = settings.movingZone(0, by: [-5, 0.5, 0]).room.fittings![0]
    #expect(moved.low == [0, 1.5, 0] && moved.high == [1, 2.5, 1])
    // A move onto the other zone is refused.
    #expect(settings.movingZone(0, by: [1.5, 0, 0]) == settings)
    // Touching is allowed.
    #expect(settings.movingZone(0, by: [1, 0, 0]).room.fittings![0].high.x == 3)
    // Resizing moves the nearest footprint corner, or the top.
    let wider = settings.resizingZone(0, toward: [0.5, 2.7, 0.3], vertical: false).room.fittings![0]
    #expect(wider.low == [0.5, 1, 0] && wider.high == [2, 2.7, 1])
    #expect(
        settings.resizingZone(0, toward: [1.5, 1.5, 9], vertical: true).room.fittings![0].high.z == size.z)
    // Never smaller than 10 cm.
    let thin = settings.resizingZone(0, toward: [1.99, 1.5, 0], vertical: false).room.fittings![0]
    #expect(abs(thin.high.x - thin.low.x - 0.1) < 1e-9 || abs(thin.high.x - 1.99) < 1e-9)
    // An opening moves over its wall, held inside it, and resizes from its nearest corner.
    let slid = settings.movingOpening(0, to: [100, -3]).openings[0]
    #expect(slid.centre == [size.x - 0.45, 1])
    let taller = settings.resizingOpening(0, toward: [1.6, 2.2]).openings[0]
    #expect(abs(taller.centre.x - (0.55 + 1.6) / 2) < 1e-9 && abs(taller.size.y - 2.2) < 1e-9)
    try settings.movingOpening(0, to: [100, -3]).validate()
}

@MainActor
@Test("Dragging a zone moves it, Command-dragging resizes it, and an opening slides along its wall")
func dragZoneAndOpening() throws {
    var settings = RoomProject.starter
    let size = settings.room.size
    settings.room.fittings = [
        FittingZone(
            name: "Rug", low: [1, 1, 0], high: [2.5, 2, 0.2], density: 0.5,
            absorption: Array(repeating: 0, count: 8))
    ]
    settings.openings = [Opening(name: "Window", surface: .ceiling, centre: [3, 2], size: [1, 1])]
    let viewport = RoomViewport()
    var edits: [RoomResponseSettings] = []
    viewport.onEdit = { edits.append($0) }
    viewport.show(settings)
    // Looking straight down on the rug.
    viewport.camera = OrbitCamera(target: [1.75, 1.5, 0.2], distance: 6, azimuth: 0, elevation: 1.55)
    #expect(viewport.beginDrag(ndc: [0, 0], aspectRatio: 1, modifiers: []))
    #expect(viewport.selected == .zone(0))
    viewport.drag(ndc: [0.1, 0], aspectRatio: 1, modifiers: [])
    let moved = try #require(edits.last?.room.fittings?.first)
    #expect(moved.low.z == 0 && simd_distance(moved.high - moved.low, [1.5, 1, 0.2]) < 1e-9)
    #expect(moved.low != [1, 1, 0])
    viewport.drag(ndc: [0.3, 0.3], aspectRatio: 1, modifiers: .resize)
    let resized = try #require(edits.last?.room.fittings?.first)
    #expect(simd_distance(resized.high - resized.low, [1.5, 1, 0.2]) > 0.05)
    viewport.endDrag()
    // From above, through the ceiling, which is seen from behind: the ceiling window, selectable from
    // either side, slides over the ceiling and resizes from its nearest corner.
    viewport.camera = OrbitCamera(target: [3, 2, Float(size.z)], distance: 3, azimuth: 0, elevation: 1.55)
    #expect(viewport.beginDrag(ndc: [0, 0], aspectRatio: 1, modifiers: []))
    #expect(viewport.selected == .opening(0))
    viewport.drag(ndc: [0.2, 0.1], aspectRatio: 1, modifiers: [])
    let slid = try #require(edits.last?.openings.first)
    #expect(slid.centre != [3, 2] && slid.size == [1, 1])
    // Well outside the window, beyond one of its corners.
    viewport.drag(ndc: [0.9, 0.9], aspectRatio: 1, modifiers: .resize)
    let grown = try #require(edits.last?.openings.first)
    #expect(grown.size.x > 1 && grown.size.y > 1)
    viewport.endDrag()
    try #require(edits.last).validate()
}

@Test(
    "Pushing a wall out or in resizes a box or a plan, keeping what is inside in place against the far walls")
func pushSurfaces() throws {
    var box = RoomProject.starter
    box.room.fittings = [RoomInspector.seating(in: box.room.size)]
    box.openings = [Opening(name: "Door", surface: .north, centre: [2, 1], size: [0.9, 2])]
    let size = box.room.size
    // The east wall out by half a metre: only the size changes.
    let east = try #require(box.pushingSurface(1, by: 0.5))
    #expect(east.room.size == size + [0.5, 0, 0] && east.source == box.source)
    // The west wall out: everything shifts east with it, so it stays put against the east wall.
    let west = try #require(box.pushingSurface(0, by: 0.5))
    #expect(west.room.size.x == size.x + 0.5)
    #expect(west.source.position == box.source.position + [0.5, 0, 0])
    #expect(west.room.fittings![0].low.x == box.room.fittings![0].low.x + 0.5)
    #expect(west.openings[0].centre == [2.5, 1])
    // The ceiling down: lower, the floor where it was.
    #expect(try #require(box.pushingSurface(5, by: -0.3)).room.size.z == size.z - 0.3)
    // Pulled in past the source, or below half a metre: refused.
    #expect(box.pushingSurface(1, by: -(size.x - 0.3)) == nil)
    // A plan's wall moves with its two corners; the plan grows past the origin and everything shifts.
    let l = try #require(RoomPresets.all.first { $0.id == "l-shaped-living-room" }).applied(to: box)
    let wall = 0
    let pushed = try #require(l.pushingSurface(wall, by: 0.4))
    let plan = try #require(pushed.room.plan)
    #expect(plan.corners.allSatisfy { $0.x >= 0 && $0.y >= 0 })
    #expect(abs(plan.area - l.room.plan!.area - 0.4 * l.room.plan!.length(wall)) < 1e-9)
    #expect(abs(simd_distance(pushed.source.position, l.source.position) - 0.4) < 1e-9)
    // A mesh's shape is not edited this way.
    let hall = try #require(RoomPresets.all.first { $0.id == "raked-auditorium" }).applied(to: box)
    #expect(hall.pushingSurface(0, by: 0.5) == nil)
}

@MainActor
@Test("Command-dragging a wall in the 3D view pushes it, and the camera stays where it was")
func dragWall() throws {
    let settings = RoomProject.starter
    let viewport = RoomViewport()
    var edits: [RoomResponseSettings] = []
    viewport.onEdit = { edits.append($0) }
    viewport.show(settings)
    let size = SIMD3<Float>(settings.room.size)
    // From the south, looking north, with the east wall on the right.
    viewport.camera = OrbitCamera(
        target: [size.x * 0.6, size.y * 0.5, size.z * 0.5], distance: 8, azimuth: -.pi / 2, elevation: 0.2)
    let camera = viewport.camera
    let x = try #require(
        stride(from: Float(0), to: 0.95, by: 0.01).first { x in
            let ray = viewport.camera.ray(ndc: [x, 0], aspectRatio: 1)
            return viewport.scene?.geometry.pick(origin: ray.origin, direction: ray.direction) == 1
        })
    // Without Command a press on a wall orbits.
    #expect(!viewport.beginDrag(ndc: [x + 0.02, 0], aspectRatio: 1, modifiers: []))
    #expect(viewport.beginDrag(ndc: [x + 0.02, 0], aspectRatio: 1, modifiers: .resize))
    #expect(viewport.selected == .surface(1))
    viewport.drag(ndc: [x + 0.15, 0], aspectRatio: 1, modifiers: .resize)
    viewport.endDrag()
    let pushed = try #require(edits.last)
    #expect(pushed.room.size.x > settings.room.size.x + 0.1)
    #expect(pushed.room.size.y == settings.room.size.y)
    #expect(viewport.camera == camera)
}
