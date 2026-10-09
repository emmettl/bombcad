import BlastCore
import DocumentKit
import Foundation
import Testing

@testable import BombCAD

@MainActor @Suite("A run feeding several models, here or on other Macs", .serialized)
struct ConsumerFanOutTests {
    private func document() -> ProjectDocument {
        var scene = Scenario(
            name: "Fan-out", domainSize: SIMD3(repeating: 8),
            boxes: [Box(min: SIMD3(6, 3, 0), max: SIMD3(7, 5, 3))],
            charge: Charge(mass: 0.05, position: SIMD3(3, 4, 1)))
        scene.gauges = [Gauge("Near", at: SIMD3(4, 4, 1))]
        var document = ProjectDocument(scenario: scene)
        document.runSettings?.resolution = "coarse"
        document.runSettings?.duration = 0.006
        return document
    }

    private var fragments: FragmentSpec {
        var spec = FragmentSpec()
        spec.casingMass = 0.05
        spec.count = 200
        spec.tracers = 30
        spec.tracerRegion = Box(min: SIMD3(2, 3, 0.5), max: SIMD3(4, 5, 2))
        return spec
    }

    private var thermal: ThermalSpec {
        var spec = ThermalSpec()
        spec.luminousTemperature = 1000
        spec.samples = 16
        return spec
    }

    private var ground: GroundShockSpec {
        var spec = GroundShockSpec()
        spec.line = .init(from: SIMD2(2.5, 4), to: SIMD2(5.5, 4), count: 4)
        spec.points = [SIMD2(6.75, 6.75)]
        spec.depths = [0, 1]
        return spec
    }

    private func options(_ consumers: [String: String] = [:]) -> HeadlessRun.Options {
        var options = HeadlessRun.Options(project: URL(filePath: "/dev/null"))
        options.name = "Fan-out"
        options.fragments = fragments
        options.thermal = thermal
        options.groundShock = ground
        options.consumers = consumers
        return options
    }

    @Test("--consumer places each model, a bare place being the fragments'")
    func parsing() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "fan-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = [
            "fragments": try JSONEncoder().encode(fragments), "thermal": try JSONEncoder().encode(thermal),
            "ground": try JSONEncoder().encode(ground),
        ]
        for (name, data) in files { try data.write(to: folder.appending(path: "\(name).json")) }
        func parse(_ extra: [String], with specs: [String] = ["fragments", "thermal", "ground-shock"]) throws
            -> HeadlessRun.Options
        {
            let flags = specs.flatMap { flag in
                [
                    "--\(flag)",
                    folder.appending(path: "\(flag == "ground-shock" ? "ground" : flag).json").path,
                ]
            }
            return try HeadlessRun.Options.parse(["project.bombcad"] + flags + extra)
        }
        #expect(try parse([]).consumers.isEmpty)
        #expect(try parse([]).place("thermal") == "local")
        #expect(try parse(["--consumer", "scrimply-ci-tb"]).consumers == ["fragments": "scrimply-ci-tb"])
        let placed = try parse(["--consumer", "fragments=local, thermal=mini.local,ground=studio"])
        #expect(placed.consumers == ["fragments": "local", "thermal": "mini.local", "ground": "studio"])
        for bad in ["smoke=mini", "thermal=mini,thermal=studio", "thermal=-oProxyCommand=x", "thermal="] {
            #expect(throws: ProjectFileError.self, "\(bad)") { try parse(["--consumer", bad]) }
        }
        // A model must be asked for to be placed.
        #expect(throws: ProjectFileError.self) {
            try parse(["--consumer", "ground=mini"], with: ["fragments", "thermal"])
        }
    }

    @Test("Each model comes to the same result here or on workers, two sharing one")
    func placement() async throws {
        let here = try await HeadlessRun.perform(document(), options: options())
        #expect(here.streams.count == 3 && here.streams.allSatisfy { $0.contains(" here: ") })
        let (first, firstServer) = localWorker(name: "first")
        let (second, secondServer) = localWorker(name: "second")
        var connected: [String] = []
        let there = try await HeadlessRun.perform(
            document(), options: options(["fragments": "first", "thermal": "second", "ground": "second"]),
            connect: { host in
                connected.append(host)
                let client = host == "first" ? first : second
                _ = try await client.start()
                return client
            })
        // One connection to each Mac, shared by the models on it, and let go at the end.
        #expect(connected.sorted() == ["first", "second"])
        await firstServer.value
        await secondServer.value

        #expect(there.run.gauges == here.run.gauges && there.run.stepCount == here.run.stepCount)
        #expect(there.fragments == here.fragments && there.fragments?.frames.count == 7)
        #expect(there.thermal == here.thermal && (there.thermal?.fireball.count ?? 0) == 7)
        var groundThere = try #require(there.ground)
        var groundHere = try #require(here.ground)
        #expect(groundThere.frames == 7)
        // Only what feeding it cost the run differs.
        groundThere.seconds = 0
        groundHere.seconds = 0
        #expect(groundThere == groundHere)
        #expect(there.streams.count == 3)
        #expect(there.streams[0].hasPrefix("Fragments on first: 7 frames"))
        #expect(there.streams[1].hasPrefix("Thermal radiation on second: 7 frames"))
        #expect(there.streams[2].hasPrefix("Ground shock on second: 7 frames"))
    }

    @Test("A run whose other Mac drops carries its models on here, and says so")
    func recovery() async throws {
        var options = options(["thermal": "flaky", "ground": "flaky"])
        options.fragments = nil
        var local = options
        local.consumers = [:]
        let here = try await HeadlessRun.perform(document(), options: local)
        let there = try await HeadlessRun.perform(
            document(), options: options,
            connect: { _ in
                let worker = flakyWorker(dropAfter: 5)
                _ = try await worker.start()
                return worker
            })
        #expect(there.thermal == here.thermal && there.run.gauges == here.run.gauges)
        var groundThere = try #require(there.ground)
        var groundHere = try #require(here.ground)
        groundThere.seconds = 0
        groundHere.seconds = 0
        #expect(groundThere == groundHere)
        #expect(there.streams.count == 2 && there.streams.allSatisfy { $0.contains("here after frame") })
    }
}
