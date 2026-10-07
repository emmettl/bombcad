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
        ] {
            #expect(throws: ProjectFileError.self) { try HeadlessRun.Options.parse(arguments) }
        }
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
        let run = try await HeadlessRun.execute(HeadlessRun.Options.parse([project.path, "--mass", "50"]))

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
            ]))
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
            HeadlessRun.Options.parse([project.path, "--usd", scene.path, "--frame-interval", "2"]))
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
            ]))
        // 0, 2 and 4 ms.
        let files = try FileManager.default.contentsOfDirectory(atPath: volumes.path).sorted()
        #expect(files == ["blast.0000.vdb", "blast.0001.vdb", "blast.0002.vdb"])
        let text = try String(contentsOf: usd, encoding: .utf8)
        #expect(text.contains("def Volume \"Blast\""))
        #expect(text.contains("rel field:overpressure = </Scene/Blast/overpressure>"))
        #expect(text.contains("2: @./air.volumes/blast.0002.vdb@,"))
        #expect(!text.contains("def Mesh \"Structure\""))
        // Each frame is an OpenVDB file, and the blast has moved on between them.
        let first = try Data(contentsOf: volumes.appending(path: "blast.0000.vdb"))
        let later = try Data(contentsOf: volumes.appending(path: "blast.0001.vdb"))
        #expect(first.prefix(4) == Data([0x20, 0x42, 0x44, 0x56]) && later.prefix(4) == first.prefix(4))
        #expect(later != first)
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
            try await HeadlessRun.execute(HeadlessRun.Options.parse([project.path, "--out", out.path]))
        }
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }
}
