import BlastCore
import BlastRender
import DocumentKit
import Foundation
import Metal
import SceneView
import Testing

@testable import BombCAD

@MainActor @Suite("Craters and ground types in the app and headless runs", .serialized, .hangLimit)
struct CraterAppTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "crater-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Half a kilogram on the ground in an 8 m domain.
    private func document(ground: GroundType? = nil) -> ProjectDocument {
        var scene = Scenario(
            name: "Crater", domainSize: SIMD3(8, 8, 4), boxes: [],
            charge: Charge(mass: 0.5, position: SIMD3(4, 4, 0)))
        scene.gauges = [Gauge("Near", at: SIMD3(6, 4, 0.5))]
        var document = ProjectDocument(scenario: scene)
        document.runSettings?.resolution = "coarse"
        document.runSettings?.duration = 0.004
        document.runSettings?.ground = ground
        return document
    }

    private func waitUntil(_ model: SimulationModel, _ condition: () -> Bool) async throws {
        while !condition() {
            try #require(model.errorMessage == nil)
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("The ground type is saved, left out for rigid ground, and keeps old fingerprints")
    func saved() throws {
        let rigid = document()
        #expect(rigid.runSettings?.ground == nil)
        let json = try String(decoding: JSONEncoder().encode(rigid.runSettings!), as: UTF8.self)
        #expect(!json.contains("ground\""))
        var soil = document(ground: .glacialSoil)
        soil.runSettings?.waterTable = 1.5
        let reopened = try ProjectDocument(archive: soil.makeArchive())
        #expect(reopened.runSettings?.ground == .glacialSoil && reopened.runSettings?.waterTable == 1.5)
        // The ground changes the air, so it is in the fingerprint; rigid ground leaves it as it was.
        let plain = try SavedSimulationRun.fingerprint(rigid.scenario, settings: rigid.runSettings!)
        let soft = try SavedSimulationRun.fingerprint(soil.scenario, settings: soil.runSettings!)
        #expect(plain != soft)
        // The craters follow from the scene and the settings alone.
        #expect(rigid.runSettings!.craters(over: rigid.scenario).isEmpty)
        let crater = try #require(soil.runSettings!.craters(over: soil.scenario).first)
        #expect(crater.ground == .glacialSoil && crater.apparentRadius > 0.3)
    }

    @Test("--ground takes a ground type, which also sets the debris's bed")
    func options() throws {
        let options = try HeadlessRun.Options.parse(["a.bombcad", "--ground", "saturated"])
        #expect(
            options.groundType == .saturated && options.ground == .some(GroundType.saturated.debrisModulus))
        let rigid = try HeadlessRun.Options.parse(["a.bombcad", "--ground", "rigid"])
        #expect(rigid.groundType == .rigid && rigid.ground == .some(nil))
        #expect(throws: ProjectFileError.self) {
            try HeadlessRun.Options.parse(["a.bombcad", "--ground", "mud"])
        }
        let inputs = try HeadlessRun.inputs(for: document(), options: options)
        #expect(inputs.settings.ground == .saturated && inputs.settings.groundStiffness == 15e6)
        // Saturated soil brings its water table at the surface; --water-table moves it or sends it deep.
        #expect(inputs.settings.waterTable == 0)
        let lowered = try HeadlessRun.Options.parse([
            "a.bombcad", "--ground", "saturated", "--water-table", "2.5",
        ])
        #expect(try HeadlessRun.inputs(for: document(), options: lowered).settings.waterTable == 2.5)
        let deep = try HeadlessRun.Options.parse([
            "a.bombcad", "--ground", "saturated", "--water-table", "deep",
        ])
        #expect(try HeadlessRun.inputs(for: document(), options: deep).settings.waterTable == nil)
        #expect(throws: ProjectFileError.self) {
            try HeadlessRun.Options.parse(["a.bombcad", "--water-table", "-1"])
        }
        // A water table on rigid ground means nothing and is dropped.
        let rigidWet = try HeadlessRun.Options.parse(["a.bombcad", "--water-table", "1"])
        #expect(try HeadlessRun.inputs(for: document(), options: rigidWet).settings.waterTable == nil)
    }

    @Test("A headless run on soil prints the crater and puts it in the scene and the CSV")
    func headless() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = folder.appending(path: "crater.bombcad")
        try document().makeArchive().fileWrapper().write(to: project, originalContentsURL: nil)
        let usd = folder.appending(path: "crater.usda")
        let csv = folder.appending(path: "crater.csv")
        let result = try await HeadlessRun.execute(
            HeadlessRun.Options.parse([
                project.path, "--ground", "alluvium", "--usd", usd.path, "--csv", csv.path,
            ]))
        #expect(result.run.settings.ground == .alluvium)
        let summary = HeadlessRun.summary(result.run, wallSeconds: 1)
        #expect(summary.contains("Crater in dry alluvium: "))
        let text = try String(contentsOf: usd, encoding: .utf8)
        // No structure or volumes, so the run takes no frames and the crater is there throughout.
        #expect(text.contains("def Mesh \"Crater\""))
        #expect(text.contains("bombcad:label = \"Crater in dry alluvium"))
        // The flat ground is left open under the crater's patch.
        let ground = try #require(text.range(of: "def Mesh \"Ground\"")).upperBound
        let counts = try #require(text[ground...].range(of: "faceVertexCounts = [")).upperBound
        let faces = text[counts...].prefix { $0 != "]" }.split(separator: ",").count
        #expect(faces == 8)
        let rows = try String(contentsOf: csv, encoding: .utf8)
        #expect(rows.contains("\"Crater apparent diameter\"") && rows.contains("\"Crater lip height\""))
    }

    @Test("On soil the app's run takes less energy into the air, and draws the crater once it ends")
    func app() async throws {
        let rigid = SimulationModel(document: document(), playbackSpeed: .unlimited)
        let soil = SimulationModel(document: document(ground: .clay), playbackSpeed: .unlimited)
        for model in [rigid, soil] {
            try await waitUntil(model) { model.experimentIsReady }
            #expect(model.craters.isEmpty, "A crater forms after the blast, so none before the run ends.")
            model.run()
            try await waitUntil(model) { !model.isRunning && !model.hasPendingGPUWork }
        }
        #expect(rigid.craters.isEmpty && soil.craters.count == 1)
        #expect(soil.settings.ground == .clay)
        try rigid.keepRun(named: "Rigid")
        try soil.keepRun(named: "Clay")
        let near = { (model: SimulationModel) in model.savedRuns.last!.gauges[0].peak }
        // 0.9 of the energy: the peak a few percent lower, as a smaller charge's is.
        #expect(near(soil) < near(rigid) && near(soil) > 0.85 * near(rigid))
        // Reset clears the crater with the run.
        soil.reset()
        try await waitUntil(soil) { soil.experimentIsReady }
        #expect(soil.craters.isEmpty)
    }

    @Test("A replay draws the crater as dug by the frame's time, and scrubbed back fills it in again")
    func replayed() async throws {
        let model = SimulationModel(document: document(ground: .clay), playbackSpeed: .unlimited)
        model.recordsTimelines = true
        try await waitUntil(model) { model.experimentIsReady }
        model.run()
        try await waitUntil(model) {
            !model.isRunning && !model.hasPendingGPUWork && model.recentTimeline != nil
        }
        let crater = try #require(model.craters.first)
        // 4 ms is far short of the crater's formation time, so live it is drawn whole at the end,
        // as before, and never while the run went on.
        #expect(crater.formedAt > 0.1 && model.shownCraters == [crater])
        try model.keepRun(named: "Clay")
        let run = try #require(model.savedRuns.last)
        defer { if let recent = model.recentTimeline { try? FileManager.default.removeItem(at: recent) } }
        // The kept run's craters, from its own scene and settings.
        model.replay(run)
        let playback = try #require(model.playback)
        #expect(playback.craters == [crater] && run.settings.craters(over: run.scenario) == [crater])
        var last: Float = 0
        for n in 0..<playback.count {
            try playback.show(n)
            let shown = model.shownCraters
            let expected = crater.grown(atTime: Float(playback.time))
            #expect(shown == (expected.map { [$0] } ?? []), "\(playback.time) s")
            // The first frame is the mapped start's, just after the blast: a small bowl already.
            if playback.time == 0 { #expect(shown.isEmpty, "Nothing before the blast.") }
            let radius = shown.first?.apparentRadius ?? 0
            #expect(radius >= last)
            last = radius
        }
        // Part-dug at the end of a run shorter than its formation time.
        #expect(last > 0 && last < crater.apparentRadius)
        // Scrubbed back to the start (the mapped start's first frame), the bowl is as small as it
        // began; to the middle, between.
        playback.seek(to: 0)
        let first = crater.grown(atTime: Float(playback.time))?.apparentRadius ?? 0
        #expect(
            model.shownCraters.first?.apparentRadius ?? 0 == first && first > 0 && first < last,
            "\(playback.time) s: \(first) of \(crater.apparentRadius)")
        playback.seek(to: playback.endTime / 2)
        let middle = model.shownCraters.first?.apparentRadius ?? 0
        #expect(middle >= first && middle <= last, "\(first), \(middle), \(last) at \(playback.time) s")
        model.stopReplay()
        #expect(model.playback == nil)
    }

    @Test("Drawn offscreen, the crater shaded at a time covers more ground the later it is")
    func drawnAsItGrows() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let scene = Scenario(
            name: "Open", domainSize: SIMD3(12, 12, 4), boxes: [],
            charge: Charge(mass: 100, position: SIMD3(6, 6, 0)))
        let crater = try #require(CraterEstimate.craters(of: scene, ground: .alluvium).first)
        let solver = try BlastSolver(device: device, scenario: scene, cellSize: 1)
        let renderer = try SceneRenderer(device: device)
        renderer.setScene(scene, solver: solver)
        renderer.settings.showWave = false
        renderer.settings.showCharge = false
        let camera = OrbitCamera(target: SIMD3(6, 6, 0), distance: 14, azimuth: 0.3, elevation: 1.45)
        func pixels(_ craters: [CraterEstimate]) throws -> [UInt8] {
            renderer.settings.craters = craters.map(CraterMark.init)
            let frame = try #require(
                renderer.snapshot(commandQueue: queue, width: 96, height: 96, camera: camera))
            let data = try #require(frame.image.dataProvider?.data) as Data
            return [UInt8](data)
        }
        let flat = try pixels([])
        func changed(atTime time: Float) throws -> Int {
            let shown = try pixels([crater].compactMap { $0.grown(atTime: time) })
            return zip(shown, flat).filter { abs(Int($0) - Int($1)) > 4 }.count
        }
        let end = crater.formedAt
        let counts = try [0, end / 100, end / 4, end / 2, end].map(changed(atTime:))
        #expect(counts[0] == 0, "flat at t = 0")
        for (a, b) in zip(counts, counts.dropFirst()) { #expect(b > a, "\(counts)") }
        // At the end, the crater the live view draws once the run has ended.
        #expect(try pixels([crater]) == pixels([try #require(crater.grown(atTime: end))]))
    }
}
