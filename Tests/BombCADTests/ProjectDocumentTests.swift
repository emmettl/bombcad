import BlastCore
import BlastRender
import DocumentKit
import Foundation
import Testing

@testable import BombCAD

@MainActor
@Suite("Project documents", .serialized)
struct ProjectDocumentTests {
    @Test("Project settings, geometry and view restore independently of current preferences")
    func settingsRoundTrip() throws {
        let model = SimulationModel()
        model.settings.resolution = .coarse
        model.settings.detailedCharge = true
        model.settings.sharpShocks = true
        model.settings.solidElementSize = 0.1
        model.settings.scenario.charge.mass = 42
        model.duration = 0.123
        model.camera = OrbitCamera(target: SIMD3(3, 4, 5), distance: 18, azimuth: 0.3, elevation: 0.6)
        model.renderSettings.mode = .impulse
        model.renderSettings.showWave = false
        model.renderSettings.impulseScale = 250
        let snapshot = ProjectDocument(model: model)
        let restored = try ProjectDocument(fileWrapper: snapshot.makeArchive().fileWrapper())
        #expect(restored.scenario == snapshot.scenario)
        #expect(restored.runSettings == snapshot.runSettings)
        #expect(restored.viewSettings == snapshot.viewSettings)
        model.settings.detailedCharge = false
        model.settings.sharpShocks = false
        model.duration = 1
        model.open(restored)
        #expect(model.settings.resolution == .coarse)
        #expect(model.settings.detailedCharge && model.settings.sharpShocks)
        #expect(model.settings.solidElementSize == 0.1)
        #expect(model.duration == 0.123)
        #expect(model.camera == snapshot.viewSettings?.camera)
        #expect(model.renderSettings.mode == .impulse && !model.renderSettings.showWave)
        #expect(!model.canUndo && !model.canRedo)
        #expect(model.projectDocumentID == snapshot.documentID)
    }

    @Test("Re-saving and replacing the scene preserve embedded assets and document identity")
    func assetPreservation() throws {
        let model = SimulationModel()
        model.settings.resolution = .coarse
        var archive = try ProjectDocument(model: model).makeArchive()
        let data = Data("source mesh".utf8)
        let asset = ProjectManifest.Asset(path: "assets/model.obj", data: data)
        archive.manifest.assets.append(asset)
        archive.files[asset.path] = data
        archive.files["results/report.txt"] = Data("optional report".utf8)
        model.open(try ProjectDocument(archive: archive))
        model.settings.scenario.charge.mass = 12
        let saved = try ProjectDocument(model: model).makeArchive()
        #expect(saved.manifest == archive.manifest)
        #expect(saved.files[asset.path] == data)
        #expect(saved.files["results/report.txt"] == archive.files["results/report.txt"])
        let previousID = model.projectDocumentID
        model.select(.openGround)
        #expect(model.projectDocumentID == previousID)
        #expect(model.projectArchive?.files[asset.path] == data)
    }

    @Test("Every built-in scene can be captured as a project; simple JSON loading remains available")
    func presets() throws {
        let model = SimulationModel()
        for preset in ScenarioPreset.allCases {
            model.settings.scenario = preset.scenario
            let project = try ProjectDocument(archive: ProjectDocument(model: model).makeArchive())
            #expect(project.scenario == preset.scenario)
        }
        let legacy = try ProjectDocument(
            legacyJSON: ScenarioDocument.encode(ScenarioPreset.openGround.scenario))
        #expect(legacy.scenario == ScenarioPreset.openGround.scenario)
        #expect(legacy.runSettings != nil && legacy.archive == nil)
    }

    @Test("Invalid settings and other application projects fail before changing the model")
    func invalidProjects() throws {
        let model = SimulationModel()
        var archive = try ProjectDocument(model: model).makeArchive()
        archive.manifest.documentType = "roomcad"
        #expect(throws: (any Error).self) { try ProjectDocument(archive: archive) }
        archive.manifest.documentType = "bombcad"
        var settings = ProjectRunSettings(model: model)
        settings.resolution = "unknown"
        archive.files["settings.json"] = try ProjectArchive.encodeJSON(settings)
        #expect(throws: (any Error).self) { try ProjectDocument(archive: archive) }
        var view = ProjectViewSettings(model: model)
        view.fieldOfView = 0
        archive.files["settings.json"] = try ProjectArchive.encodeJSON(ProjectRunSettings(model: model))
        archive.files["view.json"] = try ProjectArchive.encodeJSON(view)
        #expect(throws: (any Error).self) { try ProjectDocument(archive: archive) }
        var snapshot = ProjectDocument(model: model)
        snapshot.scenario.domainSize.x = -1
        #expect(throws: (any Error).self) { try snapshot.makeArchive() }
        snapshot.scenario.domainSize.x = 1e30
        #expect(throws: (any Error).self) { try snapshot.makeArchive() }
    }

    @Test("Absent view settings use scene framing and fresh display defaults")
    func absentView() throws {
        let model = SimulationModel()
        model.settings.scenario = ScenarioPreset.openGround.scenario
        var archive = try ProjectDocument(model: model).makeArchive()
        archive.files.removeValue(forKey: "view.json")
        model.camera.target = SIMD3(100, 200, 300)
        model.renderSettings.showWave = false
        model.renderSettings.mode = .impulse
        model.open(try ProjectDocument(archive: archive))
        #expect(model.camera == OrbitCamera.framing(ScenarioPreset.openGround.scenario))
        #expect(model.renderSettings.showWave)
        #expect(model.renderSettings.mode == .peakOverpressure)
        #expect(!model.isRunning)
    }
}
