import BlastCore
import DocumentKit
import Foundation
import Testing

@testable import BombCAD

/// Soft ground for debris in the app: chosen in the Run tab, saved with the project, carried into
/// headless runs and named in the standing.
@Suite("Soft ground")
struct SoftGroundTests {
    @MainActor
    @Test("Rigid by default and left out of the file; soil saved, reopened and read by the standing")
    func saved() throws {
        let scene = ScenarioPreset.blastWall.scenario
        let rigid = try #require(ProjectDocument(scenario: scene).runSettings)
        #expect(rigid.groundStiffness == nil)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(rigid)) as? [String: Any]
        #expect(json?["groundStiffness"] == nil)
        #expect(!rigid.standingInputs(scene).options.contains(.softGround))

        var settings = SimulationSettings()
        settings.scenario = scene
        settings.softGround = true
        settings.groundStiffness = 30e6
        let soil = ProjectRunSettings(settings: settings, duration: 0.1)
        #expect(soil.groundStiffness == 30e6)
        #expect(try JSONDecoder().decode(ProjectRunSettings.self, from: JSONEncoder().encode(soil)) == soil)
        let inputs = soil.standingInputs(scene)
        #expect(inputs.options.contains(.softGround) && inputs.configuration.groundStiffness == 30e6)
        // Without a structure there is no debris for it to matter to.
        #expect(!soil.standingInputs(ScenarioPreset.openGround.scenario).options.contains(.softGround))
        var bad = soil
        bad.groundStiffness = -1
        #expect(throws: (any Error).self) { try bad.validate() }

        var document = ProjectDocument(scenario: scene)
        document.runSettings = soil
        let reopened = SimulationModel(document: try ProjectDocument(archive: document.makeArchive()))
        #expect(reopened.settings.softGround && reopened.settings.groundStiffness == 30e6)
    }

    @MainActor
    @Test("A headless run takes --ground rigid, soil or a modulus in MN/m³")
    func headless() throws {
        #expect(try HeadlessRun.Options.parse(["a", "--ground", "rigid"]).ground == .some(nil))
        #expect(
            try HeadlessRun.Options.parse(["a", "--ground", "soil"]).ground
                == .some(SolverConfiguration.soilSubgradeModulus))
        #expect(try HeadlessRun.Options.parse(["a", "--ground", "80"]).ground == .some(80e6))
        for value in ["sand", "5", "500"] {
            #expect(throws: ProjectFileError.self) {
                try HeadlessRun.Options.parse(["a", "--ground", value])
            }
        }
        let document = ProjectDocument(scenario: ScenarioPreset.blastWall.scenario)
        var options = try HeadlessRun.Options.parse(["a", "--ground", "80"])
        #expect(try HeadlessRun.inputs(for: document, options: options).settings.groundStiffness == 80e6)
        options.ground = .some(nil)
        #expect(try HeadlessRun.inputs(for: document, options: options).settings.groundStiffness == nil)
    }
}
