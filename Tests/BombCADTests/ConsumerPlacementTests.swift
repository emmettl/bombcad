import BlastCore
import DocumentKit
import Foundation
import Testing

@testable import BombCAD

@MainActor @Suite("Models fed by a run placed by what they cost", .serialized)
struct ConsumerPlacementTests {
    private static let scene = FragmentScene(
        Scenario(
            name: "Costs", domainSize: SIMD3(repeating: 8), boxes: [],
            charge: Charge(mass: 1, position: SIMD3(4, 4, 1))))
    private let thermal = ConsumerKind.thermal(ThermalSpec(), Self.scene, live: false)
    private let ground = ConsumerKind.groundShock(GroundShockSpec(), live: false)

    private func costs(
        frame: Double?, thermal here: Double? = nil, mini: Double? = nil, studio: Double? = nil,
        gpu: Bool = true
    ) -> ConsumerCosts {
        var costs = ConsumerCosts()
        costs.frameSeconds = frame
        if let here { costs.measured("thermal", kind: thermal, place: "local", seconds: here, usesGPU: gpu) }
        if let mini { costs.measured("thermal", kind: thermal, place: "mini", seconds: mini) }
        if let studio { costs.measured("thermal", kind: thermal, place: "studio", seconds: studio) }
        return costs
    }

    private func plan(_ costs: ConsumerCosts, hosts: [String] = ["mini"]) -> [String: String] {
        ConsumerPlacement.plan(["thermal": ["local"] + hosts], kinds: ["thermal": thermal], costs: costs)
            .places
    }

    @Test("A model on this Mac's GPU goes to another Mac that keeps up with the run")
    func movesOffTheGPU() {
        // The city block: the blast 120 ms a frame, the march 50 ms here, 60 ms on a quiet mini.
        #expect(plan(costs(frame: 0.12, thermal: 0.05, mini: 0.06)) == ["thermal": "mini"])
        // A busy mini, slower than the run with the march here: it would hold the run up.
        #expect(plan(costs(frame: 0.12, thermal: 0.05, mini: 0.2)) == ["thermal": "local"])
        // Of two Macs, the one that leaves the run quickest: here the mini would hold it up.
        #expect(
            plan(costs(frame: 0.12, thermal: 0.05, mini: 0.15, studio: 0.03), hosts: ["mini", "studio"])
                == ["thermal": "studio"])
    }

    @Test("A model is kept here unless moving it saves something")
    func keepsHere() {
        // Never measured elsewhere: here.
        #expect(plan(costs(frame: 0.12, thermal: 0.05)) == ["thermal": "local"])
        // Nothing measured at all: here.
        #expect(plan(ConsumerCosts()) == ["thermal": "local"])
        // On the CPU's idle cores it costs the run nothing while it keeps up.
        #expect(plan(costs(frame: 0.12, thermal: 0.05, mini: 0.01, gpu: false)) == ["thermal": "local"])
        // But not once it is slower than the run.
        #expect(plan(costs(frame: 0.12, thermal: 0.3, mini: 0.1, gpu: false)) == ["thermal": "mini"])
        // Less than 3% saved: here.
        #expect(plan(costs(frame: 1.0, thermal: 0.02, mini: 0.05)) == ["thermal": "local"])
        // The run's own time not yet measured: only a Mac quicker than the time here moves it.
        #expect(plan(costs(frame: nil, thermal: 0.05, mini: 0.06)) == ["thermal": "local"])
        #expect(plan(costs(frame: nil, thermal: 0.05, mini: 0.03)) == ["thermal": "mini"])
    }

    @Test("Models on one Mac add up, and a model already placed stays where it is")
    func severalModels() {
        var costs = costs(frame: 0.1, thermal: 0.08, mini: 0.08)
        costs.measured("ground", kind: ground, place: "local", seconds: 0.07, usesGPU: false)
        costs.measured("ground", kind: ground, place: "mini", seconds: 0.07)
        let kinds = ["thermal": thermal, "ground": ground]
        let both = ConsumerPlacement.plan(
            ["thermal": ["local", "mini"], "ground": ["local", "mini"]], kinds: kinds, costs: costs)
        // Both on the mini would take 150 ms a frame; the thermal alone there leaves 100.
        #expect(both.places == ["thermal": "mini", "ground": "local"])
        #expect(abs(both.frameSeconds - 0.1) < 1e-9)
        // With the ground's estimate placed on the mini, the march still gains more there (150 ms
        // a frame) than here (180).
        let fixed = ConsumerPlacement.plan(
            ["thermal": ["local", "mini"], "ground": ["mini"]], kinds: kinds, costs: costs)
        #expect(fixed.places == ["thermal": "mini", "ground": "mini"])
        #expect(abs(fixed.frameSeconds - 0.15) < 1e-9)
    }

    @Test("A cost here keeps the dearer measurement, one elsewhere the newer, and other work none")
    func measurements() {
        var costs = ConsumerCosts()
        costs.measured("thermal", kind: thermal, place: "local", seconds: 0.05, usesGPU: true)
        costs.measured("thermal", kind: thermal, place: "local", seconds: 0.03)
        costs.measured("thermal", kind: thermal, place: "mini", seconds: 0.2)
        costs.measured("thermal", kind: thermal, place: "mini", seconds: 0.06)
        #expect(costs.seconds("thermal", kind: thermal, place: "local") == 0.05)
        #expect(costs.seconds("thermal", kind: thermal, place: "mini") == 0.06)
        #expect(costs.models["thermal"]?.usesGPU == true)
        var other = ThermalSpec()
        other.samples = 32
        let changed = ConsumerKind.thermal(other, Self.scene, live: false)
        #expect(costs.seconds("thermal", kind: changed, place: "mini") == nil)
        costs.measured("thermal", kind: changed, place: "mini", seconds: 0.1)
        #expect(costs.models["thermal"]?.seconds == ["mini": 0.1])
    }

    @Test("Costs are kept for each set of inputs, the latest 64")
    func store() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "costs-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ConsumerCostStore(url: url)
        #expect(store.costs(for: "a") == nil)
        for index in 0..<70 { store.record(costs(frame: Double(index)), for: "key \(index)") }
        #expect(store.costs(for: "key 69")?.frameSeconds == 69)
        #expect(store.costs(for: "key 5") == nil)
        #expect(store.costs(for: "key 6")?.frameSeconds == 6)
    }

    @Test("The probe's fireball is half a sphere on the ground, in no more voxels than are sent")
    func probeFireball() throws {
        let scenario = Scenario(
            name: "Probe", domainSize: SIMD3(64, 64, 32), boxes: [],
            charge: Charge(mass: 100, position: SIMD3(30, 29, 1)))
        let frames = ConsumerProbe.fireballs(scenario: scenario, cellSize: 0.125, radius: 9)
        #expect(frames.count == ConsumerProbe.frames)
        let cells = try #require(frames[0].cells)
        #expect(cells.fills.count <= LuminousCells.maximumVoxels && cells.voxelSize == 0.25)
        // Within a few per cent of the half sphere's volume.
        let half = 2.0 / 3 * Double.pi * pow(9, 3)
        #expect(abs(cells.volume / half - 1) < 0.05 && abs(frames[0].volume / half - 1) < 0.05)
        #expect(cells.low.z == 0)
        #expect(abs(ConsumerProbe.radius(scenario: scenario, costs: ConsumerCosts()) - 7.3) < 1e-4)
    }

    @Test("--consumer auto places the models given among this Mac and each --worker")
    func parsing() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "auto-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try JSONEncoder().encode(ThermalSpec()).write(to: folder.appending(path: "thermal.json"))
        var ground = GroundShockSpec()
        ground.line = .init(from: SIMD2(2.5, 4), to: SIMD2(5.5, 4), count: 4)
        try JSONEncoder().encode(ground).write(to: folder.appending(path: "ground.json"))
        func parse(_ extra: [String]) throws -> HeadlessRun.Options {
            try HeadlessRun.Options.parse(
                [
                    "project.bombcad", "--thermal", folder.appending(path: "thermal.json").path,
                    "--ground-shock", folder.appending(path: "ground.json").path,
                ] + extra)
        }
        let auto = try parse(["--consumer", "auto", "--worker", "mini", "--worker", "studio"])
        #expect(auto.consumers == ["thermal": "auto", "ground": "auto"])
        #expect(auto.workers == ["mini", "studio"])
        let one = try parse(["--consumer", "thermal=auto,ground=local", "--worker", "mini"])
        #expect(one.consumers == ["thermal": "auto", "ground": "local"])
        for bad in [
            ["--consumer", "auto"], ["--worker", "mini"],
            ["--consumer", "auto", "--worker", "mini", "--worker", "mini"],
            ["--consumer", "auto", "--worker", "-oProxyCommand=x"],
        ] {
            #expect(throws: ProjectFileError.self, "\(bad)") { try parse(bad) }
        }
    }

    private func document() -> ProjectDocument {
        var scene = Scenario(
            name: "Placed by cost", domainSize: SIMD3(repeating: 8),
            boxes: [Box(min: SIMD3(6, 3, 0), max: SIMD3(7, 5, 3))],
            charge: Charge(mass: 0.05, position: SIMD3(3, 4, 1)))
        scene.gauges = [Gauge("Near", at: SIMD3(4, 4, 1))]
        var document = ProjectDocument(scenario: scene)
        document.runSettings?.resolution = "coarse"
        document.runSettings?.duration = 0.006
        return document
    }

    private func options(_ consumers: [String: String], workers: [String] = []) -> HeadlessRun.Options {
        var options = HeadlessRun.Options(project: URL(filePath: "/dev/null"))
        var spec = ThermalSpec()
        spec.luminousTemperature = 1000
        spec.samples = 16
        options.thermal = spec
        var ground = GroundShockSpec()
        ground.line = .init(from: SIMD2(2.5, 4), to: SIMD2(5.5, 4), count: 4)
        ground.depths = [0, 1]
        options.groundShock = ground
        options.consumers = consumers
        options.workers = workers
        return options
    }

    @Test("A run placed by cost probes each Mac, moves what is dear here, and keeps what it measured")
    func run() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "costs-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ConsumerCostStore(url: url)
        let here = try await HeadlessRun.perform(document(), options: options([:]), costs: store)
        // Every run keeps what it measured, here the blast's frame and both models here.
        let inputs = try HeadlessRun.inputs(for: document(), options: options([:]))
        let key = try #require(ConsumerCostStore.key(inputs, frameInterval: 0.001))
        var measured = try #require(store.costs(for: key))
        #expect((measured.frameSeconds ?? 0) > 0)
        #expect(measured.models["thermal"]?.seconds["local"] != nil && measured.models["ground"] != nil)

        // Made dear here, beside a blast slow enough for another Mac to keep up with it.
        measured.frameSeconds = 10
        let thermalKind = ConsumerKind.thermal(
            options([:]).thermal!, FragmentScene(inputs.scenario), live: false)
        measured.measured("thermal", kind: thermalKind, place: "local", seconds: 5, usesGPU: true)
        store.record(measured, for: key)
        let (worker, server) = localWorker(name: "mini")
        var connected: [String] = []
        let placed = try await HeadlessRun.perform(
            document(), options: options(["thermal": "auto", "ground": "auto"], workers: ["mini", "gone"]),
            costs: store,
            connect: { host in
                connected.append(host)
                guard host == "mini" else { throw ProjectFileError.invalid("No such Mac.") }
                _ = try await worker.start()
                return worker
            })
        await server.value
        #expect(connected == ["mini", "gone"])
        #expect(placed.streams[0].hasPrefix("Placed by cost: thermal on mini"))
        #expect(placed.streams[0].contains("could not reach gone"))
        #expect(placed.streams[1].hasPrefix("Thermal radiation on mini: 7 frames"))
        #expect(placed.streams[2].hasPrefix("Ground shock here: 7 frames"))
        // The same result wherever it ran.
        #expect(placed.thermal == here.thermal && placed.run.gauges == here.run.gauges)
        // The mini's cost, as probed and then as run, is kept for the next run.
        #expect(store.costs(for: key)?.models["thermal"]?.seconds["mini"] != nil)
    }
}
