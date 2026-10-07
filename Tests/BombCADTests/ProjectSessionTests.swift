import BlastCore
import Foundation
import Testing

@testable import BombCAD

@MainActor
@Suite("Document sessions", .serialized)
struct ProjectSessionTests {
    private func document() -> ProjectDocument {
        var document = ProjectDocument(scenario: ScenarioPreset.openGround.scenario)
        document.runSettings?.resolution = "coarse"
        return document
    }

    @Test("Opening a project does not immediately create a persisted change")
    func initialState() throws {
        let original = document()
        let opened = try ProjectDocument(archive: original.makeArchive())
        let session = ProjectSession(document: opened)
        #expect(session.snapshot == opened)
        #expect(session.model.grid?.cellSize == 0.5)
        #expect(!session.model.canUndo)
    }

    @Test("Simulation progress never dirties a project; numerical and view edits do")
    func changeTracking() async throws {
        let session = ProjectSession(document: document())
        let model = session.model
        model.duration = 0.02
        let beforeRun = session.snapshot
        model.speed = .unlimited
        model.run()
        let deadline = ContinuousClock.now + .seconds(10)
        while model.isRunning {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.time > 0)
        #expect(session.snapshot == beforeRun)
        model.camera.zoom(by: 0.8)
        #expect(session.snapshot != beforeRun)
        let cameraEdit = session.snapshot
        model.settings.detailedCharge = true
        #expect(session.snapshot != cameraEdit)
        let numericalEdit = session.snapshot
        model.duration = 0.03
        #expect(session.snapshot != numericalEdit)
    }

    @Test("Two windows have independent identities, geometry and simulation models")
    func independentWindows() {
        let first = ProjectSession(document: document())
        let second = ProjectSession(document: document())
        let original = second.snapshot
        #expect(first.model !== second.model)
        #expect(first.snapshot.documentID != second.snapshot.documentID)
        first.model.settings.scenario.charge.mass = 7
        first.model.camera.target.x += 1
        #expect(second.snapshot == original)
    }

    @Test("Revert restores the binding snapshot; publishing an edit does not reload its model")
    func revert() {
        let original = document()
        let session = ProjectSession(document: original)
        session.model.settings.scenario.charge.mass = 7
        session.model.recordEdit()
        #expect(session.model.canUndo)
        let edited = session.snapshot
        session.receive(edited)
        #expect(session.model.canUndo)
        session.receive(original)
        #expect(session.snapshot == original)
        #expect(!session.model.canUndo)
    }
}
