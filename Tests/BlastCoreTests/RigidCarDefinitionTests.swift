import Foundation
import Testing
import simd

@testable import BlastCore

@Suite("Rigid car definitions")
struct RigidCarDefinitionTests {
    @Test("Car identity, assumptions and inputs survive repeated JSON round trips exactly")
    func roundTrip() throws {
        let car = try RigidCarDefinition(
            name: "Estate", position: SIMD3(10, 20, 0.3), mass: 1700, wheelbase: 2.8, track: 1.6,
            centreOfMass: SIMD3(0.1, -0.05, 0.6), inertia: SIMD3(600, 2800, 3000),
            shellSize: SIMD3(4.8, 1.8, 1.5), groundClearance: 0.16,
            orientation: 3 * simd_quatd(angle: 0.3, axis: simd_normalize(SIMD3(1, 2, 3))).vector,
            staticFriction: 0.9, slidingFriction: 0.75)
        #expect(abs(simd_length(car.orientation) - 1) < 1e-12)
        var copy = car
        for _ in 0..<10 {
            copy = try JSONDecoder().decode(RigidCarDefinition.self, from: JSONEncoder().encode(copy))
            #expect(copy == car)
        }
        let json = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(car)) as? [String: Any])
        #expect(json["wheels"] as? String == "allLocked")
        #expect(json["suspension"] as? String == "rigid")
    }

    @Test("Layouts without cars keep their encoding; cars sit beside rigid objects and round trip")
    func scenarioRoundTrip() throws {
        var scene = ScenarioPreset.openGround.scenario
        let legacy = try JSONEncoder().encode(scene)
        let json = try #require(try JSONSerialization.jsonObject(with: legacy) as? [String: Any])
        #expect(json["rigidCars"] == nil)
        #expect(try JSONDecoder().decode(Scenario.self, from: legacy) == scene)
        scene.rigidCars = [try .saloon(position: SIMD3(5, 5, 0))]
        scene.rigidObjects = [
            try RigidObjectDefinition(
                name: "Box", shape: .box(size: SIMD3(repeating: 1)), position: SIMD3(1, 1, 0.5), mass: 1)
        ]
        let decoded = try JSONDecoder().decode(Scenario.self, from: JSONEncoder().encode(scene))
        #expect(decoded == scene)
        #expect(decoded.rigidCars?.first?.id == scene.rigidCars?.first?.id)
        scene.rigidCars = []
        #expect(try JSONDecoder().decode(Scenario.self, from: JSONEncoder().encode(scene)) == scene)
        #expect(scene.rigidBoxes == ScenarioPreset.openGround.scenario.rigidBoxes)
    }

    @Test("Saved geometry maps to the runtime tyre contacts, shell and centre of mass")
    func runtimeConversion() throws {
        let yaw = simd_quatd(angle: .pi / 2, axis: SIMD3(0, 0, 1))
        let saloon = try RigidCarDefinition.saloon(position: SIMD3(10, 20, 0), orientation: yaw.vector)
        let car = try saloon.makeBody()
        #expect(simd_distance(car.position, SIMD3(10, 20.15, 0.55)) < 1e-12)
        let expected: [SIMD3<Double>] = [
            SIMD3(9.225, 21.35, 0), SIMD3(10.775, 21.35, 0), SIMD3(9.225, 18.65, 0), SIMD3(10.775, 18.65, 0),
        ]
        for (point, target) in zip(car.tyrePoints, expected) { #expect(simd_distance(point, target) < 1e-12) }
        let heights = car.body.corners.map(\.z)
        #expect(abs(heights.min()! - 0.15) < 1e-12 && abs(heights.max()! - 1.45) < 1e-12)
        #expect(car.body.inertia == SIMD3(550, 2500, 2700))
        #expect(car.linearVelocity == .zero && car.angularVelocity == .zero)
        #expect(saloon.wheels == .allLocked && saloon.suspension == .rigid)
        #expect(saloon.ground.staticFriction == 0.8 && saloon.ground.slidingFriction == 0.7)
    }

    @Test("Invalid cars throw before a runtime body can be created")
    func invalidConstruction() throws {
        func make(
            name: String = "Car", position: SIMD3<Double> = .zero, wheelbase: Double = 2.7,
            track: Double = 1.55, centreOfMass: SIMD3<Double> = SIMD3(0, 0, 0.55),
            inertia: SIMD3<Double> = SIMD3(550, 2500, 2700), clearance: Double = 0.15,
            orientation: SIMD4<Double> = SIMD4(0, 0, 0, 1), friction: (Double, Double) = (0.8, 0.7)
        ) throws -> RigidCarDefinition {
            try RigidCarDefinition(
                name: name, position: position, mass: 1500, wheelbase: wheelbase, track: track,
                centreOfMass: centreOfMass, inertia: inertia, shellSize: SIMD3(4.6, 1.55, 1.3),
                groundClearance: clearance, orientation: orientation,
                staticFriction: friction.0, slidingFriction: friction.1)
        }
        _ = try make()
        let failures: [() throws -> RigidCarDefinition] = [
            { try make(name: " ") },
            { try make(friction: (0.5, 0.6)) },
            { try make(wheelbase: 5) },
            { try make(track: 1.6) },
            { try make(track: 0) },
            { try make(clearance: -0.1) },
            { try make(centreOfMass: SIMD3(0, 0, 2)) },
            { try make(inertia: SIMD3(550, 2500, 5000)) },
            { try make(position: SIMD3(0, 0, -0.01)) },
            { try make(orientation: simd_quatd(angle: 0.2, axis: SIMD3(1, 0, 0)).vector) },
        ]
        for failure in failures {
            #expect(throws: RigidCarDefinition.InvalidDefinition.self) { _ = try failure() }
        }
    }

    @Test("Malformed JSON is validated rather than bypassing constructor checks")
    func malformedInput() throws {
        let valid = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(RigidCarDefinition.saloon()))
                as? [String: Any])
        let replacements: [(String, Any)] = [
            ("name", ""), ("mass", 0), ("mass", "NaN"), ("wheelbase", -1), ("track", 3),
            ("shellSize", [4.6, 1.55, -1]), ("groundClearance", "NaN"), ("orientation", [0, 0, 0, 0]),
            ("position", [0, 0, -1]), ("centreOfMass", [0, 0, 5]), ("inertia", [1, 1, 10]),
            ("staticFriction", -1), ("slidingFriction", 2), ("wheels", "rolling"), ("suspension", "sprung"),
        ]
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        for (key, value) in replacements {
            var json = valid
            json[key] = value
            let data = try JSONSerialization.data(withJSONObject: json)
            #expect(throws: DecodingError.self, "Invalid \(key) should be rejected") {
                try decoder.decode(RigidCarDefinition.self, from: data)
            }
        }
        var scene = ScenarioPreset.openGround.scenario
        scene.rigidCars = [try .saloon()]
        var json = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(scene)) as? [String: Any])
        var invalid = valid
        invalid["mass"] = -1
        json["rigidCars"] = [invalid]
        #expect(throws: DecodingError.self) {
            try decoder.decode(Scenario.self, from: JSONSerialization.data(withJSONObject: json))
        }
    }
}
