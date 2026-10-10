import BlastCore
import DocumentKit
import Foundation
import Testing

@testable import BombCAD

@Suite("Standing carried with results")
struct StandingRunTests {
    @Test("A kept run's standing saves and reopens; runs kept before it open as not recorded")
    func savedStanding() throws {
        var recorded = try SavedRunTests().fixture()
        recorded.standing = recorded.derivedStanding()
        let old = try SavedRunTests().fixture(name: "Old run")
        var document = ProjectDocument(scenario: ScenarioPreset.openGround.scenario)
        document.savedRuns = [recorded, old]
        let archive = try document.makeArchive()
        let oldRecord = try #require(
            archive.files["results/runs/\(old.id.uuidString.lowercased()).json"].map {
                String(decoding: $0, as: UTF8.self)
            })
        #expect(!oldRecord.contains("\"standing\""))
        let restored = try ProjectDocument(archive: archive)
        #expect(restored.savedRuns[0].standing == recorded.standing)
        #expect(restored.savedRuns[0].standing?[.structuralResponse] != nil)
        #expect(restored.savedRuns[1].standing == nil)
        // The fingerprint covers inputs only.
        #expect(
            recorded.inputSHA256
                == (try SavedSimulationRun.fingerprint(recorded.scenario, settings: recorded.settings)))
    }

    @Test("Comparison names the runs whose standing differs from the reference's")
    func comparisonWarnings() throws {
        var reference = try SavedRunTests().fixture()
        reference.standing = reference.derivedStanding()
        var same = try SavedRunTests().fixture(name: "Same")
        same.standing = same.derivedStanding()
        var burning = try SavedRunTests().fixture(name: "Burning")
        burning.settings.detailedCharge = true
        burning.standing = burning.derivedStanding()
        let unrecorded = try SavedRunTests().fixture(name: "Unrecorded")
        #expect([reference, same].standingDifferences(from: reference).isEmpty)
        let differences = [reference, same, burning, unrecorded].standingDifferences(from: reference)
        #expect(!differences.isEmpty)
        #expect(differences.allSatisfy { $0.hasPrefix("Burning · ") })
        #expect(differences.contains { $0.contains("Impulse") })
        #expect([unrecorded, reference].standingDifferences(from: unrecorded).isEmpty)
    }

    @Test("The app's air settings give the standing the solver's configuration")
    func settingsMapToConfiguration() throws {
        var settings = try SavedRunTests().fixture().settings
        settings.detailedCharge = true
        settings.sharpShocks = true
        settings.shockLevels = 2
        let inputs = settings.standingInputs(ScenarioPreset.openGround.scenario)
        #expect(inputs.cellSize == 0.5)
        #expect(inputs.configuration.afterburning && inputs.configuration.airModel == .thermallyPerfect)
        #expect(inputs.configuration.refinement == 2 && inputs.configuration.refinementLevels == 2)
        #expect(Set(inputs.options) == [.afterburning, .hotAir, .twoLevelRefinement])
    }

    @Test("A headless run carries its standing into its summary, JSON, USD scene and volumes")
    @MainActor func headlessStanding() async throws {
        var scene = Scenario(
            name: "Air only", domainSize: SIMD3(repeating: 4), boxes: [],
            charge: Charge(mass: 0.01, position: SIMD3(2, 2, 1)))
        scene.gauges = [Gauge("Near", at: SIMD3(2.5, 2, 1))]
        var document = ProjectDocument(scenario: scene)
        document.runSettings?.resolution = "coarse"
        document.runSettings?.duration = 0.002
        let folder = FileManager.default.temporaryDirectory.appending(path: "standing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = folder.appending(path: "air.bombcad")
        try document.makeArchive().fileWrapper().write(to: project, originalContentsURL: nil)
        let usd = folder.appending(path: "air.usda")
        let volumes = folder.appending(path: "air.volumes")
        let json = folder.appending(path: "standing.json")
        let options = try HeadlessRun.Options.parse([
            project.path, "--usd", usd.path, "--vdb", volumes.path, "--standing", json.path,
            "--frame-interval", "2",
        ])
        #expect(options.standing == json)
        #expect(throws: ProjectFileError.self) {
            try HeadlessRun.Options.parse([project.path, "--standing", folder.path])
        }
        let result = try await HeadlessRun.execute(options)
        // 10 g on 0.5 m cells: far coarser than any grid compared.
        #expect(result.standing[.peakOverpressure]?.level == .approximation)
        #expect(result.run.standing == result.run.derivedStanding())
        #expect(try JSONDecoder().decode(SceneStanding.self, from: Data(contentsOf: json)) == result.standing)
        let text = try String(contentsOf: usd, encoding: .utf8)
        #expect(text.contains("dictionary standing = {"))
        #expect(text.contains("string peakOverpressure = \"approximation: "))
        #expect(text.contains("string[] notModelled = ["))
        let checker = URL(filePath: "/usr/bin/usdchecker")
        if FileManager.default.isExecutableFile(atPath: checker.path) {
            let process = Process()
            process.executableURL = checker
            process.arguments = [usd.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }
        let volume = String(
            decoding: try Data(contentsOf: volumes.appending(path: "blast.0000.vdb")), as: UTF8.self)
        #expect(volume.contains("bombcad_standing") && volume.contains("peakOverpressure=approximation"))
    }

    @Test("Results files carry their standing beside their own keys, which their readers pass over")
    func annotatedResults() throws {
        var spec = CloudSpec()
        spec.windSpeed = 3
        let standing = try #require(
            SceneStanding(
                StandingInputs(scenario: ScenarioPreset.openGround.scenario, cellSize: 0.25, cloud: spec))[
                    .cloud])
        let data = try JSONEncoder().encode(WithStanding(spec, standing))
        #expect(try JSONDecoder().decode(CloudSpec.self, from: data) == spec)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["standing"] != nil && object["windSpeed"] as? Double == 3)
    }
}
