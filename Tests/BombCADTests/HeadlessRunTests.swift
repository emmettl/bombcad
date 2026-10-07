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
            ["a", "--out", "result.json"],
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

        let model = SimulationModel(document: document)
        try model.sweep.start(.init(prefix: "Sweep", parameter: .chargeMass([0.02])))
        let deadline = ContinuousClock.now + .seconds(60)
        while model.sweep.isActive || !model.experimentIsReady {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(5))
        }
        let swept = try #require(model.savedRuns.last)
        #expect(run.name == "Headless run" && swept.name == "Sweep · 0.02 kg")
        #expect(run.inputSHA256 == swept.inputSHA256 && run.stepCount == swept.stepCount)
        #expect(run.gauges == swept.gauges && run.gauges.allSatisfy { $0.peak > 0 })
    }

    /// A structure's steps depend on how the app batches them, which follows the GPU's speed, so
    /// only completion is checked here, not equality with a sweep.
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
