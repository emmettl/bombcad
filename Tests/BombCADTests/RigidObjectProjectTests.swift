import BlastCore
import DocumentKit
import Foundation
import Testing

@testable import BombCAD

@MainActor
@Suite("Rigid object project persistence")
struct RigidObjectProjectTests {
    @Test("Rigid objects survive the project package codec and repeated saves")
    func projectRoundTrip() throws {
        var scene = ScenarioPreset.openGround.scenario
        scene.rigidObjects = [
            try RigidObjectDefinition(
                name: "Freestanding box", shape: .box(size: SIMD3(2, 3, 1)),
                position: SIMD3(4, 5, 0.5), mass: 100,
                staticFriction: 0.7, slidingFriction: 0.4)
        ]
        let input = try ProjectDocument(legacyJSON: ScenarioDocument.encode(scene))
        let archive = try input.makeArchive()
        let reopened = try ProjectDocument(fileWrapper: archive.fileWrapper())
        let resaved = try ProjectDocument(archive: reopened.makeArchive())
        #expect(reopened.scenario == scene)
        #expect(resaved.scenario == scene)
        #expect(reopened.documentID == resaved.documentID)
        #expect(resaved.scenario.rigidObjects?.first?.id == scene.rigidObjects?.first?.id)
    }

    @Test("Legacy project packages without rigid-object inputs still open unchanged")
    func olderProject() throws {
        let scene = ScenarioPreset.openGround.scenario
        let input = try ProjectDocument(legacyJSON: ScenarioDocument.encode(scene))
        let reopened = try ProjectDocument(archive: input.makeArchive())
        #expect(reopened.scenario == scene)
        #expect(reopened.scenario.rigidObjects == nil)
    }

    @Test("A malformed rigid-object definition makes project loading fail")
    func invalidProject() throws {
        var scene = ScenarioPreset.openGround.scenario
        scene.rigidObjects = [
            try RigidObjectDefinition(
                name: "Box", shape: .box(size: SIMD3(repeating: 1)),
                position: SIMD3(1, 1, 0.5), mass: 1)
        ]
        let input = try ProjectDocument(legacyJSON: ScenarioDocument.encode(scene))
        var archive = try input.makeArchive()
        let data = try #require(archive.files["scene.json"])
        var payload = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var scenario = try #require(payload["scenario"] as? [String: Any])
        var objects = try #require(scenario["rigidObjects"] as? [[String: Any]])
        objects[0]["mass"] = -1
        scenario["rigidObjects"] = objects
        payload["scenario"] = scenario
        archive.files["scene.json"] = try JSONSerialization.data(withJSONObject: payload)
        #expect(throws: DecodingError.self) { try ProjectDocument(archive: archive) }
    }
}
