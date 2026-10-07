import Foundation
import Testing
import simd

@testable import BlastCore

@Suite("Rigid object definitions")
struct RigidObjectDefinitionTests {
    private func box() throws -> RigidObjectDefinition {
        try RigidObjectDefinition(
            name: "Box", shape: .box(size: SIMD3(2, 4, 6)), position: SIMD3(10, 20, 5), mass: 12)
    }

    @Test("Object identity and validated inputs survive repeated JSON round trips exactly")
    func roundTrip() throws {
        let object = try RigidObjectDefinition(
            name: "Offset mass", shape: .box(size: SIMD3(2, 4, 6)),
            position: SIMD3(10, 20, 5), mass: 12,
            orientation: 2 * simd_quatd(angle: 0.7, axis: simd_normalize(SIMD3(1, 2, 3))).vector,
            centreOfMass: SIMD3(0.25, -0.5, -0.75), inertia: SIMD3(52, 40, 20),
            staticFriction: 0.7, slidingFriction: 0.4)
        #expect(abs(simd_length(object.orientation) - 1) < 1e-12)
        var copy = object
        for _ in 0..<10 {
            copy = try JSONDecoder().decode(RigidObjectDefinition.self, from: JSONEncoder().encode(copy))
            #expect(copy == object)
        }
    }

    @Test("Legacy scenarios omit rigid objects; populated and explicitly empty arrays round trip")
    func scenarioRoundTrip() throws {
        var scene = ScenarioPreset.openGround.scenario
        let legacy = try JSONEncoder().encode(scene)
        let json = try #require(try JSONSerialization.jsonObject(with: legacy) as? [String: Any])
        #expect(json["rigidObjects"] == nil)
        #expect(try JSONDecoder().decode(Scenario.self, from: legacy) == scene)
        scene.rigidObjects = [try box()]
        #expect(try JSONDecoder().decode(Scenario.self, from: JSONEncoder().encode(scene)) == scene)
        scene.rigidObjects = []
        #expect(try JSONDecoder().decode(Scenario.self, from: JSONEncoder().encode(scene)) == scene)
    }

    @Test("Saved geometry and centre of mass map to the correct runtime pose and torque")
    func runtimeConversion() throws {
        let object = try RigidObjectDefinition(
            name: "Offset box", shape: .box(size: SIMD3(2, 4, 6)), position: SIMD3(10, 20, 5), mass: 12,
            orientation: simd_quatd(angle: .pi / 2, axis: SIMD3(0, 0, 1)).vector,
            centreOfMass: SIMD3(0.25, -0.5, -0.75), inertia: SIMD3(52, 40, 20))
        var body = try object.makeBody()
        #expect(simd_distance(body.position, SIMD3(10.5, 20.25, 4.25)) < 1e-12)
        #expect(simd_distance(body.worldPoint(.zero), object.position) < 1e-12)
        #expect(abs(body.corners.map(\.z).min()! - 2) < 1e-12)
        body.applyImpulse(SIMD3(0, 0, 40), at: object.position)
        #expect(simd_distance(body.angularMomentum, SIMD3(-10, 20, 0)) < 1e-12)
        #expect(simd_distance(body.angularVelocity, SIMD3(-0.25, 20.0 / 52, 0)) < 1e-12)
        #expect(object.ground.staticFriction == 0.6 && object.ground.slidingFriction == 0.5)
        let restarted = try object.makeBody()
        #expect(restarted.linearVelocity == .zero && restarted.angularMomentum == .zero)
        #expect(try box().makeBody().inertia == SIMD3(52, 40, 20))
    }

    @Test("Invalid constructors throw before a runtime body can be created")
    func invalidConstruction() throws {
        #expect(throws: RigidObjectDefinition.InvalidDefinition.self) {
            try RigidObjectDefinition(
                name: " ", shape: .box(size: SIMD3(repeating: 1)), position: .zero, mass: 1)
        }
        #expect(throws: RigidObjectDefinition.InvalidDefinition.self) {
            try RigidObjectDefinition(
                name: "Box", shape: .box(size: SIMD3(repeating: 1)),
                position: SIMD3(0, 0, 1), mass: 1,
                staticFriction: 0.2, slidingFriction: 0.3)
        }
        #expect(throws: RigidObjectDefinition.InvalidDefinition.self) {
            try RigidObjectDefinition(
                name: "Box", shape: .box(size: SIMD3(repeating: 1)),
                position: SIMD3(0, 0, 1), mass: 1,
                centreOfMass: SIMD3(0.1, 0, 0))
        }
        #expect(throws: RigidObjectDefinition.InvalidDefinition.self) {
            try RigidObjectDefinition(
                name: "Box", shape: .box(size: SIMD3(repeating: 1)),
                position: SIMD3(0, 0, 0.5), mass: 1,
                orientation: simd_quatd(angle: .pi / 4, axis: SIMD3(0, 1, 0)).vector)
        }
    }

    @Test("Malformed JSON is validated rather than bypassing constructor checks")
    func malformedInput() throws {
        let valid = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(box())) as? [String: Any])
        let replacements: [(String, Any)] = [
            ("name", ""), ("mass", 0), ("mass", "NaN"),
            ("shape", ["box": ["size": [2, -4, 6]]]),
            ("orientation", [0, 0, 0, 0]), ("orientation", [0, 0, 0, "Infinity"] as [Any]),
            ("position", [0, 0, -1]), ("position", [0, "NaN", 5] as [Any]),
            ("centreOfMass", [100, 0, 0]), ("centreOfMass", [0.1, 0, 0]),
            ("inertia", [-1, 1, 1]), ("inertia", [10, 1, 1]),
            ("staticFriction", -1), ("slidingFriction", 2), ("staticFriction", "NaN"),
        ]
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        for (key, value) in replacements {
            var json = valid
            json[key] = value
            let data = try JSONSerialization.data(withJSONObject: json)
            #expect(throws: DecodingError.self, "Invalid \(key) should be rejected") {
                try decoder.decode(RigidObjectDefinition.self, from: data)
            }
        }
        var scene = ScenarioPreset.openGround.scenario
        scene.rigidObjects = [try box()]
        var json = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(scene)) as? [String: Any])
        var invalid = valid
        invalid["mass"] = -1
        json["rigidObjects"] = [invalid]
        #expect(throws: DecodingError.self) {
            try decoder.decode(Scenario.self, from: JSONSerialization.data(withJSONObject: json))
        }
    }

    @Test("Experimental objects do not become static obstacles or change charge blocking")
    func existingBehaviour() throws {
        let scene = ScenarioPreset.openGround.scenario
        var withObjects = scene
        withObjects.rigidObjects = [
            try RigidObjectDefinition(
                name: "Box", shape: .box(size: SIMD3(repeating: 2)),
                position: SIMD3(1, 1, 1), mass: 1)
        ]
        #expect(withObjects.rigidBoxes == scene.rigidBoxes)
        #expect(withObjects.chargeIsBlocked == scene.chargeIsBlocked)
        #expect(withObjects.structure == scene.structure)
    }
}
