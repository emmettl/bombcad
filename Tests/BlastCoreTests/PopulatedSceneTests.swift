import Testing
import simd

@testable import BlastCore

/// The populated scenes are well formed: their objects stand apart, on the ground, clear of the
/// blocks and the charge, and stay put until something moves them.
@Suite("Populated scenes")
struct PopulatedSceneTests {
    @Test("Objects stand clear of each other, the blocks and the charge", arguments: PopulatedScene.allCases)
    func clear(scene: PopulatedScene) throws {
        let scenario = scene.scenario
        let world = try RigidBodyWorld(scenario: scenario)
        let charge = SIMD3<Double>(scenario.charge.position)
        let identity = simd_quatd(angle: 0, axis: SIMD3(0, 0, 1))
        for (n, member) in world.members.enumerated() {
            let body = member.body
            #expect(
                body.corners.allSatisfy {
                    all($0 .>= SIMD3(0, 0, -1e-9)) && all($0 .<= SIMD3<Double>(scenario.domainSize))
                })
            #expect(
                RigidBodyWorld.pointAgainstBox(
                    charge, centre: body.position, pose: body.orientation, half: body.size / 2
                )
                .map { $0.gap > 0.1 } ?? true)
            for (m, other) in world.members.enumerated() where m != n {
                for corner in body.corners {
                    let c = RigidBodyWorld.pointAgainstBox(
                        corner, centre: other.body.worldPoint(.zero), pose: other.body.orientation,
                        half: other.body.size / 2)
                    #expect((c?.gap ?? 1) > 0, "\(n) in \(m)")
                }
            }
            for block in scenario.boxes {
                let low = SIMD3<Double>(block.min)
                let high = SIMD3<Double>(block.max)
                for corner in body.corners {
                    let c = RigidBodyWorld.pointAgainstBox(
                        corner, centre: (low + high) / 2, pose: identity, half: (high - low) / 2)
                    #expect((c?.gap ?? 1) > 0, "\(n) in a block")
                }
            }
        }
    }

    @Test(
        "Parked cars and furniture rest where they stand; the crowded boxes land on each other",
        arguments: PopulatedScene.allCases)
    func rest(scene: PopulatedScene) throws {
        var world = try RigidBodyWorld(scenario: scene.scenario)
        let start = world.members.map(\.body.position)
        if scene == .crowdedPen {
            // Dropped up to 0.1 m onto each other, they land without passing through anything.
            for _ in 0..<100 { world.advance(by: 0.002) }
            for member in world.members {
                #expect(member.body.corners.allSatisfy { $0.z > -1e-3 })
                #expect(simd_length(member.body.linearVelocity) < 2)
            }
            return
        }
        for _ in 0..<500 { world.advance(by: 0.002) }
        #expect(world.kineticEnergy < 1e-6)
        for (member, position) in zip(world.members, start) {
            #expect(simd_distance(member.body.position, position) < 1e-4)
        }
    }

    @Test("Each fits the cropped air grid it is run on, and the presets are reproducible")
    func crops() throws {
        for scene in PopulatedScene.allCases {
            let (cropped, _) = try FreestandingMotion.cropped(
                scene.scenario, cellSize: Double(scene.resolution.cellSize))
            #expect((cropped.rigidObjects?.count ?? 0) + (cropped.rigidCars?.count ?? 0) > 10)
        }
        #expect(ScenarioPreset.populatedCarPark.scenario == ScenarioPreset.populatedCarPark.scenario)
        #expect(ScenarioPreset.furnishedRoom.scenario == ScenarioPreset.furnishedRoom.scenario)
        #expect(ScenarioPreset.populatedCarPark.scenario.rigidCars?.count == 17)
    }
}
