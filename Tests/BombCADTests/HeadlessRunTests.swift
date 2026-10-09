import BlastCore
import DocumentKit
import Foundation
import Testing

@testable import BombCAD

@Suite("Headless run options")
struct HeadlessRunOptionTests {
    @Test("Options parse, and unknown, repeated or invalid ones are refused")
    func parsing() throws {
        let options = try HeadlessRun.Options.parse([
            "a.bombcad", "--name", "Case", "--resolution", "fine", "--mass", "2.5", "--duration", "0.05",
        ])
        #expect(options.project.lastPathComponent == "a.bombcad" && options.name == "Case")
        #expect(options.resolution == .fine && options.mass == 2.5 && options.duration == 0.05)
        for arguments in [
            [], ["a", "b"], ["a", "--bogus", "1"], ["a", "--mass"], ["a", "--mass", "1", "--mass", "2"],
            ["a", "--resolution", "huge"], ["a", "--mass", "lots"], ["a", "--duration", "0"],
            ["a", "--out", "result.json"], ["a", "--frame-interval", "2"], ["a", "--usd", "scene.usdc"],
            ["a", "--usd", "scene.usda", "--frame-interval", "0.5"],
            ["a", "--vdb", FileManager.default.temporaryDirectory.path],
            ["a", "--vdb-fields", "peak"], ["a", "--vdb", "v", "--vdb-fields", "peak,density"],
            ["a", "--vdb", "v", "--vdb-fields", "peak,peak"], ["a", "--vdb", "v", "--vdb-fields", ""],
        ] {
            #expect(throws: ProjectFileError.self) { try HeadlessRun.Options.parse(arguments) }
        }
        #expect(try HeadlessRun.Options.parse(["a", "--vdb", "v"]).vdbFields == ["overpressure", "shock"])
        #expect(
            try HeadlessRun.Options.parse(["a", "--vdb", "v", "--vdb-fields", "peak, impulse"]).vdbFields
                == ["peak", "impulse"])
        let existing = FileManager.default.temporaryDirectory.path
        #expect(throws: ProjectFileError.self) { try HeadlessRun.Options.parse(["a", "--csv", existing]) }
    }

    @Test("Default names avoid the project's saved runs")
    func names() throws {
        var run = try SavedRunTests().fixture(name: "headless RUN")
        #expect(HeadlessRun.defaultName(avoiding: []) == "Headless run")
        #expect(HeadlessRun.defaultName(avoiding: [run]) == "Headless run 2")
        run.name = "Headless run 2"
        #expect(
            HeadlessRun.defaultName(avoiding: [try SavedRunTests().fixture(name: "Headless run"), run])
                == "Headless run 3")
    }
}

@MainActor @Suite("Headless runs", .serialized)
struct HeadlessRunTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "headless-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ document: ProjectDocument, to url: URL) throws {
        try document.makeArchive().fileWrapper().write(to: url, originalContentsURL: nil)
    }

    @Test("An air-only run matches the same case swept in the app, to the last bit")
    func matchesSweep() async throws {
        var scene = Scenario(
            name: "Air only", domainSize: SIMD3(repeating: 4), boxes: [],
            charge: Charge(mass: 0.01, position: SIMD3(2, 2, 1)))
        scene.gauges = [Gauge("Near", at: SIMD3(2.5, 2, 1)), Gauge("Far", at: SIMD3(3.5, 3, 1))]
        var document = ProjectDocument(scenario: scene)
        document.runSettings?.resolution = "coarse"
        document.runSettings?.duration = 0.004
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = folder.appending(path: "air.bombcad")
        try write(document, to: project)
        let run = try await HeadlessRun.execute(HeadlessRun.Options.parse([project.path, "--mass", "0.02"]))
            .run

        let swept = try await sweep(document, mass: 0.02)
        #expect(run.name == "Headless run" && swept.name == "Sweep · 0.02 kg")
        #expect(run.inputSHA256 == swept.inputSHA256 && run.stepCount == swept.stepCount)
        #expect(run.gauges == swept.gauges && run.gauges.allSatisfy { $0.peak > 0 })
    }

    /// Sweeps `document` in the app over the one charge `mass`, and returns the run it saves.
    private func sweep(_ document: ProjectDocument, mass: Float) async throws -> SavedSimulationRun {
        let model = SimulationModel(document: document)
        try model.sweep.start(.init(prefix: "Sweep", parameter: .chargeMass([mass])))
        let deadline = ContinuousClock.now + .seconds(120)
        while model.sweep.isActive || !model.experimentIsReady {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(5))
        }
        return try #require(model.savedRuns.last)
    }

    /// The app batches a structure's steps to suit the GPU's speed, but the solver takes every
    /// decision that changes a step at checkpoints of the step count, so the runs still agree.
    @Test("A structural run matches the same case swept in the app, to the last bit")
    func matchesSweepWithStructure() async throws {
        var document = ProjectDocument(scenario: ScenarioPreset.blastWall.scenario)
        document.runSettings?.resolution = "coarse"
        document.runSettings?.duration = 0.015
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = folder.appending(path: "wall.bombcad")
        try write(document, to: project)
        let run = try await HeadlessRun.execute(HeadlessRun.Options.parse([project.path, "--mass", "50"])).run

        let swept = try await sweep(document, mass: 50)
        #expect(run.inputSHA256 == swept.inputSHA256 && run.stepCount == swept.stepCount)
        #expect(run.elapsedTime == swept.elapsedTime)
        #expect(run.gauges == swept.gauges && run.gauges.allSatisfy { $0.peak > 0 })
        #expect(run.structure == swept.structure && run.structure.map { !$0.points.isEmpty } == true)
    }

    @Test("A structural run is added to a copy of the project, which itself is left untouched")
    func structuralRun() async throws {
        let kept = try SavedRunTests().fixture()
        var document = ProjectDocument(scenario: kept.scenario)
        document.runSettings = kept.settings
        document.savedRuns = [kept]
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = folder.appending(path: "in.bombcad")
        try write(document, to: project)
        let before = try ProjectArchive.read(from: project)

        let run = try await HeadlessRun.execute(
            HeadlessRun.Options.parse([
                project.path, "--name", "Half a kilo", "--mass", "0.5",
                "--out", folder.appending(path: "out.bombcad").path,
                "--csv", folder.appending(path: "out.csv").path,
            ])
        ).run
        #expect(run.scenario.charge.mass == 0.5 && run.elapsedTime >= kept.settings.duration - 1e-9)
        #expect(run.structure.map { !$0.points.isEmpty } == true)

        #expect(try ProjectArchive.read(from: project) == before)
        let written = try ProjectDocument.read(from: folder.appending(path: "out.bombcad"))
        #expect(written.scenario == document.scenario && written.runSettings == document.runSettings)
        #expect(written.savedRuns.map(\.name) == ["Baseline", "Half a kilo"])
        #expect(written.savedRuns.last == run)
        let csv = try String(contentsOf: folder.appending(path: "out.csv"), encoding: .utf8)
        #expect(csv == run.csv())
    }

    @Test("A structural run exports its surface every frame interval")
    func usdExport() async throws {
        let kept = try SavedRunTests().fixture()
        var document = ProjectDocument(scenario: kept.scenario)
        document.runSettings = kept.settings
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = folder.appending(path: "in.bombcad")
        try write(document, to: project)
        let scene = folder.appending(path: "scene.usda")
        let run = try await HeadlessRun.execute(
            HeadlessRun.Options.parse([project.path, "--usd", scene.path, "--frame-interval", "2"])
        ).run
        #expect(run.elapsedTime >= 0.01 - 1e-9 && run.structure != nil)
        // 0, 2, … 10 ms.
        let text = try String(contentsOf: scene, encoding: .utf8)
        #expect(text.contains("endTimeCode = 5\n") && text.contains("simulatedSecondsPerFrame = 0.002"))
        let points = try #require(text.range(of: "points.timeSamples"))
        #expect(
            text[points.upperBound...].contains("\n            5: [(")
                && !text[points.upperBound...].contains("\n            6: "))
        #expect(text.contains("def Camera \"Camera\""))
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == [
                "in.bombcad", "scene.usda",
            ])
    }

    @Test("An air-only run writes a volume a frame, which the USD scene reads")
    func volumeExport() async throws {
        var scene = Scenario(
            name: "Air only", domainSize: SIMD3(repeating: 4), boxes: [],
            charge: Charge(mass: 0.01, position: SIMD3(2, 2, 1)))
        scene.gauges = [Gauge("Near", at: SIMD3(2.5, 2, 1))]
        var document = ProjectDocument(scenario: scene)
        document.runSettings?.resolution = "coarse"
        document.runSettings?.duration = 0.004
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = folder.appending(path: "air.bombcad")
        try write(document, to: project)
        let usd = folder.appending(path: "air.usda")
        let volumes = folder.appending(path: "air.volumes")
        _ = try await HeadlessRun.execute(
            HeadlessRun.Options.parse([
                project.path, "--usd", usd.path, "--vdb", volumes.path, "--frame-interval", "2",
                "--vdb-fields", "overpressure,peak,impulse",
            ])
        ).run
        // 0, 2 and 4 ms.
        let files = try FileManager.default.contentsOfDirectory(atPath: volumes.path).sorted()
        #expect(files == ["blast.0000.vdb", "blast.0001.vdb", "blast.0002.vdb"])
        let text = try String(contentsOf: usd, encoding: .utf8)
        #expect(text.contains("def Volume \"Blast\""))
        #expect(text.contains("rel field:overpressure = </Scene/Blast/overpressure>"))
        #expect(text.contains("rel field:impulse = </Scene/Blast/impulse>") && !text.contains("field:shock"))
        #expect(text.contains("2: @./air.volumes/blast.0002.vdb@,"))
        #expect(!text.contains("def Mesh \"Structure\""))
        // Each frame is an OpenVDB file, and the blast has moved on between them.
        let first = try Data(contentsOf: volumes.appending(path: "blast.0000.vdb"))
        let later = try Data(contentsOf: volumes.appending(path: "blast.0001.vdb"))
        #expect(first.prefix(4) == Data([0x20, 0x42, 0x44, 0x56]) && later.prefix(4) == first.prefix(4))
        #expect(later != first)
        let names = String(decoding: later, as: UTF8.self)
        #expect(names.contains("peak") && names.contains("impulse") && !names.contains("shock"))
    }

    @Test("The fireball's radiation is reckoned frame by frame, into the scene and a JSON file")
    func thermal() async throws {
        var scene = Scenario(
            name: "Hot", domainSize: SIMD3(repeating: 4),
            boxes: [Box(min: SIMD3(3, 1, 0), max: SIMD3(4, 3, 2))],
            charge: Charge(mass: 0.5, position: SIMD3(2, 2, 1)))
        scene.gauges = [Gauge("Near", at: SIMD3(2.5, 2, 1))]
        var document = ProjectDocument(scenario: scene)
        document.runSettings?.resolution = "coarse"
        document.runSettings?.duration = 0.004
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = folder.appending(path: "hot.bombcad")
        try write(document, to: project)
        // A low threshold: on 0.5 m cells the charge's gas is spread thin and only a few hundred
        // kelvin above ambient.
        let spec = folder.appending(path: "thermal.json")
        try Data(#"{"luminousTemperature": 500, "groundSpacing": 1, "surfaceSpacing": 0.5}"#.utf8).write(
            to: spec)
        let usd = folder.appending(path: "hot.usda")
        let results = folder.appending(path: "thermal-results.json")
        #expect(throws: ProjectFileError.self) {
            try HeadlessRun.Options.parse([project.path, "--thermal-results", results.path])
        }
        let result = try await HeadlessRun.execute(
            HeadlessRun.Options.parse([
                project.path, "--thermal", spec.path, "--thermal-results", results.path, "--usd", usd.path,
            ]))
        let thermal = try #require(result.thermal)
        // Frames at 0 to 4 ms.
        #expect(
            thermal.fireball.count == 5 && thermal.fireball.contains { $0.volume > 0 },
            "\(thermal.fireball.map { ($0.time, $0.volume, $0.temperature) })")
        #expect(thermal.receivers.contains { $0.surface == "block 0" })
        #expect(thermal.fluence.contains { $0 > 0 } && thermal.fluence.count == thermal.receivers.count)
        let saved = try JSONDecoder().decode(ThermalResult.self, from: Data(contentsOf: results))
        #expect(saved == thermal)
        let text = try String(contentsOf: usd, encoding: .utf8)
        #expect(text.contains("def Points \"Thermal\"") && text.contains("float[] primvars:fluence = ["))
    }

    @Test("The hot gas left at the end is handed over to the cloud, into the scene and a JSON file")
    func cloud() async throws {
        var scene = Scenario(
            name: "Cloud", domainSize: SIMD3(repeating: 4), boxes: [],
            charge: Charge(mass: 0.5, position: SIMD3(2, 2, 1)))
        scene.gauges = [Gauge("Near", at: SIMD3(2.5, 2, 1))]
        var document = ProjectDocument(scenario: scene)
        document.runSettings?.resolution = "coarse"
        document.runSettings?.duration = 0.004
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = folder.appending(path: "cloud.bombcad")
        try write(document, to: project)
        // On 0.5 m cells the charge's gas is spread thin and only a few hundred kelvin above
        // ambient.
        let spec = folder.appending(path: "cloud.json")
        try Data(#"{"handOverTemperature": 400, "duration": 30, "frameInterval": 3, "windSpeed": 5}"#.utf8)
            .write(
                to: spec)
        let usd = folder.appending(path: "cloud.usda")
        let results = folder.appending(path: "cloud-results.json")
        #expect(throws: ProjectFileError.self) {
            try HeadlessRun.Options.parse([project.path, "--cloud-results", results.path])
        }
        let result = try await HeadlessRun.execute(
            HeadlessRun.Options.parse([
                project.path, "--cloud", spec.path, "--cloud-results", results.path, "--usd", usd.path,
            ]))
        let cloud = try #require(result.cloud)
        #expect(abs(cloud.handOver.time - 0.004) < 1e-9 && cloud.handOver.mass > 0, "\(cloud.handOver)")
        #expect(cloud.handOver.chargeMass == 0.5 && (cloud.samples.first?.water ?? 0) > 0)
        #expect(abs((cloud.samples.last?.time ?? 0) - 30.004) < 1e-9)
        #expect((cloud.samples.last?.height ?? 0) > Double(cloud.handOver.centre.z))
        // Blown along x, the wind's default direction.
        #expect((cloud.samples.last?.position.x ?? 0) > Double(cloud.handOver.centre.x) + 50)
        let saved = try JSONDecoder().decode(CloudResult.self, from: Data(contentsOf: results))
        #expect(saved.samples == cloud.samples && saved.handOver == cloud.handOver)
        // Followed again over Las Vegas on a June afternoon, without running the blast again.
        let afternoon = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Samples/Soundings/las-vegas-2024-06-16-00z.csv")
        #expect(throws: ProjectFileError.self) {
            try HeadlessRun.Options.parse([project.path, "--sounding", afternoon.path])
        }
        let still = folder.appending(path: "still.json")
        try Data(#"{"duration": 30}"#.utf8).write(to: still)
        let again = folder.appending(path: "again.json")
        #expect(
            HeadlessCloud.main([
                results.path, "--cloud", still.path, "--sounding", afternoon.path, "--cloud-results",
                again.path,
            ]) == 0)
        let followed = try JSONDecoder().decode(CloudResult.self, from: Data(contentsOf: again))
        #expect(followed.handOver == cloud.handOver && followed.spec.sounding?.levels.count == 94)
        // The run's own description has a wind, which a sounding brings for itself.
        #expect(HeadlessCloud.main([results.path, "--sounding", afternoon.path]) == 1)
        // The cloud reads only the end of the run, which stops nowhere else on its account.
        let plain = try await HeadlessRun.execute(HeadlessRun.Options.parse([project.path])).run
        #expect(plain.stepCount == result.run.stepCount && plain.gauges == result.run.gauges)
        // Without a structure or volumes, the run makes no frames of its own: the cloud's eleven
        // start the timeline.
        let text = try String(contentsOf: usd, encoding: .utf8)
        #expect(
            text.contains("def Sphere \"Cloud\"") && text.contains("endTimeCode = 10\n"),
            "\(text.prefix(600))")
    }

    @Test("A project with no room for another run is refused before running")
    func fullProject() async throws {
        let runs = try (0..<SavedSimulationRun.maximumRuns).map {
            try SavedRunTests().fixture(name: "Run \($0)")
        }
        var document = ProjectDocument(scenario: runs[0].scenario)
        document.runSettings = runs[0].settings
        document.savedRuns = runs
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = folder.appending(path: "full.bombcad")
        try write(document, to: project)
        let out = folder.appending(path: "out.bombcad")
        await #expect(throws: ProjectFileError.self) {
            try await HeadlessRun.execute(HeadlessRun.Options.parse([project.path, "--out", out.path])).run
        }
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }
}
