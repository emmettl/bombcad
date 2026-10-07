import BlastCore
import DocumentKit
import Foundation
import Testing

@testable import BombCAD

@Suite("Saved simulation runs")
struct SavedRunTests {
    func fixture(name: String = "Baseline") throws -> SavedSimulationRun {
        var scenario = try StructureEditingTests().layout()
        scenario.gauges = [Gauge("Pressure", at: SIMD3(5, 4, 1)), Gauge("Pressure", at: SIMD3(5, 4, 1))]
        var settings = ProjectDocument(scenario: scenario).runSettings!
        settings.duration = 0.01
        settings.resolution = "coarse"
        return SavedSimulationRun(
            name: name, appVersion: "test", deviceName: "test device",
            scenario: scenario, settings: settings,
            inputSHA256: try SavedSimulationRun.fingerprint(scenario, settings: settings),
            elapsedTime: 0.01, stepCount: 20,
            gauges: SavedSimulationRun.Gauge.keys(scenario.gauges).map {
                .init(
                    key: $0,
                    points: [
                        .init(time: 0.001, value: -3), .init(time: 0.005, value: 10),
                        .init(time: 0.01, value: 2),
                    ])
            },
            structure: .init(
                points: [.init(time: 0.005, value: 1), .init(time: 0.01, value: 2)],
                failedFraction: 0.1, maximumDamage: 0.5))
    }

    @Test("Historical inputs embed their source once and reopen independently of the editor scene")
    func portableHistory() throws {
        let baseline = try fixture()
        var changed = try fixture(name: "More charge")
        // Keep the same imported instance identity and source for both historical runs.
        changed.scenario = baseline.scenario
        changed.scenario.charge.mass = 1
        changed.inputSHA256 = try SavedSimulationRun.fingerprint(changed.scenario, settings: changed.settings)
        var document = ProjectDocument(scenario: ScenarioPreset.openGround.scenario)
        document.savedRuns = [baseline, changed]
        let archive = try document.makeArchive()
        #expect(archive.manifest.assets.count == 1)
        let paths = archive.files.keys.filter { $0.hasPrefix("results/runs/") }
        #expect(paths.count == 2)
        #expect(
            paths.allSatisfy {
                !String(decoding: archive.files[$0]!, as: UTF8.self).contains("\"triangles\"")
            })
        let restored = try ProjectDocument(archive: archive)
        #expect(restored.savedRuns == document.savedRuns)
        #expect(restored.savedRuns[0].inputSHA256 != restored.savedRuns[1].inputSHA256)
        #expect(restored.savedRuns[0].gauges[0].peak == 10)
        #expect(restored.savedRuns[0].structure?.peak == 2)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("Original.bombcad")
        let moved = folder.appendingPathComponent("Moved.bombcad")
        try archive.fileWrapper().write(to: original, options: .atomic, originalContentsURL: nil)
        try FileManager.default.moveItem(at: original, to: moved)
        #expect(try ProjectDocument.read(from: moved).savedRuns == document.savedRuns)
    }

    @Test("Removing runs removes their owned result files while preserving optional user data")
    func removal() throws {
        var document = ProjectDocument()
        document.savedRuns = [try fixture()]
        var archive = try document.makeArchive()
        archive.files["results/notes.txt"] = Data("Keep this".utf8)
        document = try ProjectDocument(archive: archive)
        document.savedRuns = []
        let saved = try document.makeArchive()
        #expect(saved.files["results/runs.json"] == nil)
        #expect(!saved.files.keys.contains { $0.hasPrefix("results/runs/") })
        #expect(saved.files["results/notes.txt"] == archive.files["results/notes.txt"])
        #expect(try ProjectDocument(archive: saved).savedRuns.isEmpty)
    }

    @Test("Invalid fingerprints, histories, identities, versions and missing records are rejected")
    func validation() throws {
        let original = try fixture()
        var run = original
        run.inputSHA256 = String(repeating: "0", count: 64)
        #expect(throws: ProjectFileError.self) { try run.validate() }
        run = original
        run.gauges[0].points[1].time = run.gauges[0].points[0].time
        #expect(throws: ProjectFileError.self) { try run.validate() }
        run = original
        run.gauges[0].key.position.x += 1
        #expect(throws: ProjectFileError.self) { try run.validate() }
        run = original
        run.gauges[0].points = Array(
            repeating: .init(time: 0, value: 1), count: SavedSimulationRun.maximumSamples + 1)
        #expect(throws: ProjectFileError.self) { try run.validate() }
        var document = ProjectDocument()
        document.savedRuns = [original]
        var archive = try document.makeArchive()
        let path = "results/runs/\(original.id.uuidString.lowercased()).json"
        archive.files.removeValue(forKey: path)
        #expect(throws: ProjectFileError.self) { try ProjectDocument(archive: archive) }
        archive = try document.makeArchive()
        var index = try #require(
            JSONSerialization.jsonObject(with: archive.files["results/runs.json"]!) as? [String: Any])
        index["encodingVersion"] = 99
        archive.files["results/runs.json"] = try JSONSerialization.data(withJSONObject: index)
        #expect(throws: ProjectFileError.self) { try ProjectDocument(archive: archive) }
        document.savedRuns = [original, original]
        #expect(throws: ProjectFileError.self) { try document.makeArchive() }
    }

    @Test(
        "Gauge matching distinguishes moved gauges and duplicate occurrences; plotting retains both extremes")
    func matchingAndPlotting() throws {
        let run = try fixture(name: "Quoted, \"run\"")
        #expect(run.gauges[0].key != run.gauges[1].key)
        var moved = run.gauges[0].key
        moved.position.x += 0.25
        #expect(moved != run.gauges[0].key)
        var points = (0..<2000).map { SavedSimulationRun.Point(time: Double($0) / 200_000, value: 0) }
        points[500].value = 100
        points[501].value = -90
        let plot = SavedSimulationRun.plotPoints(points)
        #expect(plot.count <= 600)
        #expect(plot.contains { $0.value == 100 } && plot.contains { $0.value == -90 })
        #expect(zip(plot, plot.dropFirst()).allSatisfy { $0.time < $1.time })
        #expect(run.csv().contains("\"Quoted, \"\"run\"\"\""))
        #expect(run.csv().contains(",10.0,kPa"))
    }
}

@MainActor @Suite("Completed run capture", .serialized)
struct CompletedRunCaptureTests {
    private func document() -> ProjectDocument {
        var scenario = Scenario(
            name: "Small run", domainSize: SIMD3(repeating: 4), boxes: [],
            charge: Charge(mass: 0.01, position: SIMD3(2, 2, 1)))
        scenario.gauges = [Gauge("Near", at: SIMD3(2.5, 2, 1))]
        var document = ProjectDocument(scenario: scenario)
        document.runSettings?.resolution = "coarse"
        document.runSettings?.duration = 0.003
        return document
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition() {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("Only explicit capture dirties a project; completed data survive reset, edits and reopening")
    func captureAndReopen() async throws {
        let session = ProjectSession(document: document())
        let model = session.model
        #expect(!model.canKeepRun)
        #expect(throws: ProjectFileError.self) { try model.keepRun(named: "Too early") }
        let before = session.snapshot
        model.speed = .unlimited
        model.run()
        try await waitUntil { !model.isRunning }
        #expect(model.canKeepRun)
        #expect(session.snapshot == before)
        try model.keepRun(named: "Baseline")
        #expect(session.snapshot != before)
        let run = try #require(model.savedRuns.first)
        #expect(run.gauges[0].points.count > 0)
        #expect(run.elapsedTime >= run.settings.duration - 1e-9)
        #expect(throws: ProjectFileError.self) { try model.keepRun(named: "baseline") }
        // Changing the stop target after completion must not rewrite the completed run's target.
        model.duration = 0.01
        try model.keepRun(named: "Same completed data")
        #expect(model.savedRuns[1].settings.duration == 0.003)
        model.settings.scenario.charge.mass = 0.02
        #expect(!model.canKeepRun)
        model.settingsChanged()
        try await waitUntil { model.time == 0 }
        #expect(model.savedRuns[0] == run)
        model.renameRun(id: run.id, name: "First run")
        #expect(model.savedRuns[0].name == "First run")
        let restored = try ProjectDocument(archive: session.snapshot.makeArchive())
        let other = ProjectSession(document: restored)
        #expect(other.model.savedRuns == restored.savedRuns)
        #expect(!other.model.canKeepRun && other.model.time == 0)
        model.removeRun(id: run.id)
        model.restoreRun(run)
        #expect(model.savedRuns.contains { $0.id == run.id })
    }

    @Test("A changed run keeps distinct inputs and measurement data without replacing its reference")
    func twoRuns() async throws {
        let model = SimulationModel(document: document(), playbackSpeed: .unlimited)
        model.run()
        try await waitUntil { !model.isRunning }
        try model.keepRun(named: "Small charge")
        let first = model.savedRuns[0]
        model.settings.scenario.charge.mass = 0.03
        model.settingsChanged()
        try await waitUntil { model.time == 0 }
        model.run()
        try await waitUntil { !model.isRunning }
        try model.keepRun(named: "Larger charge")
        #expect(model.savedRuns[0] == first)
        #expect(model.savedRuns[1].inputSHA256 != first.inputSHA256)
        #expect(model.savedRuns[1].gauges[0].key == first.gauges[0].key)
        #expect(model.savedRuns[1].gauges[0].points != first.gauges[0].points)
        _ = try ProjectDocument(model: model).makeArchive()
    }

    @Test("Structural capture has a simulation-time sampling cadence even at unlimited playback")
    func structuralHistory() async throws {
        var document = ProjectDocument(scenario: try StructureEditingTests().layout())
        document.runSettings?.resolution = "coarse"
        document.runSettings?.duration = 0.003
        let model = SimulationModel(document: document, playbackSpeed: .unlimited)
        model.run()
        try await waitUntil { !model.isRunning }
        try model.keepRun(named: "Structural response")
        let response = try #require(model.savedRuns.first?.structure)
        #expect(response.points.count == 4)
        for (index, point) in response.points.enumerated() {
            #expect(abs(point.time - Double(index) * 0.001) < 1e-8)
        }
        #expect(response.sampleInterval == 0.001)
        #expect(
            try ProjectDocument(archive: ProjectDocument(model: model).makeArchive()).savedRuns
                == model.savedRuns)
    }
}
