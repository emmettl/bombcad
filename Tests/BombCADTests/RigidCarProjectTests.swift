import BlastCore
import DocumentKit
import Foundation
import Testing

@testable import BombCAD

@MainActor
@Suite("Rigid car project persistence")
struct RigidCarProjectTests {
    @Test("Cars survive the project package codec and repeated saves beside rigid objects")
    func projectRoundTrip() throws {
        var scene = ScenarioPreset.openGround.scenario
        scene.rigidCars = [try .saloon(name: "Parked saloon", position: SIMD3(6, 4, 0))]
        scene.rigidObjects = [
            try RigidObjectDefinition(
                name: "Box", shape: .box(size: SIMD3(repeating: 1)), position: SIMD3(1, 1, 0.5), mass: 1)
        ]
        let input = try ProjectDocument(legacyJSON: ScenarioDocument.encode(scene))
        let reopened = try ProjectDocument(fileWrapper: input.makeArchive().fileWrapper())
        let resaved = try ProjectDocument(archive: reopened.makeArchive())
        #expect(reopened.scenario == scene)
        #expect(resaved.scenario == scene)
        #expect(resaved.scenario.rigidCars?.first?.id == scene.rigidCars?.first?.id)
    }

    @Test("Projects saved before cars existed open unchanged")
    func olderProject() throws {
        let scene = ScenarioPreset.openGround.scenario
        let reopened = try ProjectDocument(
            archive: ProjectDocument(legacyJSON: ScenarioDocument.encode(scene)).makeArchive())
        #expect(reopened.scenario == scene)
        #expect(reopened.scenario.rigidCars == nil)
    }

    @Test("A malformed car makes project loading fail")
    func invalidProject() throws {
        var scene = ScenarioPreset.openGround.scenario
        scene.rigidCars = [try .saloon()]
        var archive = try ProjectDocument(legacyJSON: ScenarioDocument.encode(scene)).makeArchive()
        let data = try #require(archive.files["scene.json"])
        var payload = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var scenario = try #require(payload["scenario"] as? [String: Any])
        var cars = try #require(scenario["rigidCars"] as? [[String: Any]])
        cars[0]["wheelbase"] = 10
        scenario["rigidCars"] = cars
        payload["scenario"] = scenario
        archive.files["scene.json"] = try JSONSerialization.data(withJSONObject: payload)
        #expect(throws: DecodingError.self) { try ProjectDocument(archive: archive) }
    }
}
