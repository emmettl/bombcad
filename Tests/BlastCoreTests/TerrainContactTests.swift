import Metal
import Testing
import simd

@testable import BlastCore
@testable import BlastModel

/// Freestanding objects on the terrain: resting, sliding and tipping as statics says.
@Suite("Freestanding objects on the terrain", .gpuThreads)
struct TerrainContactTests {
    @Test("Laying a terrain sets the objects on it, and Compute Motion's cropped scene keeps it under them")
    func scenes() throws {
        var scenario = Scenario(
            name: "Hill", domainSize: SIMD3(40, 30, 16), boxes: [],
            charge: Charge(mass: 1, position: SIMD3(8, 15, 0.5)),
            rigidObjects: [
                try RigidObjectDefinition(
                    name: "Crate", shape: .box(size: SIMD3(1, 1, 1)), position: SIMD3(22, 15, 0.5), mass: 200)
            ])
        scenario.rigidCars = [try .saloon(position: SIMD3(26, 12, 0))]
        let hill = Terrain.hill(
            domain: scenario.domainSize, spacing: 0.5, centre: SIMD2(25, 15), height: 5, radius: 6)
        scenario.replaceTerrain(with: hill)
        let world = try RigidBodyWorld(scenario: scenario)
        #expect(world.terrain == hill)
        for member in world.members {
            let lowest = (member.body.corners + member.supports.map(member.body.worldPoint))
                .map { $0.z - Double(hill.height(at: SIMD3<Float>($0))) }.min()!
            #expect(abs(lowest) < 1e-5, "\(lowest)")
        }
        let (cropped, offset) = try FreestandingMotion.cropped(scenario)
        let piece = try #require(cropped.terrain)
        #expect(cropped.domainSize.z > piece.highest)
        for x in stride(from: 0.5, to: Double(cropped.domainSize.x), by: 1.3) {
            for y in stride(from: 0.5, to: Double(cropped.domainSize.y), by: 1.7) {
                let local = SIMD3<Float>(Float(x), Float(y), 0)
                #expect(abs(piece.height(at: local) - hill.height(at: local + SIMD3<Float>(offset))) < 1e-4)
            }
        }
        // Flat ground is left as the floor.
        scenario.replaceTerrain(with: .flat(domain: scenario.domainSize, spacing: 1))
        #expect(try FreestandingMotion.cropped(scenario).scene.terrain == nil)
    }

    @Test(
        "A crate on a slope, in the air of a small blast, stays on it and upright to it",
        .enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func motionOnASlope() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let angle = 15 * Double.pi / 180
        var scenario = Scenario(
            name: "Slope", domainSize: SIMD3(30, 12, 12), boxes: [],
            charge: Charge(mass: 0.2, position: SIMD3(4, 6, 0.3)))
        scenario.terrain = .slope(domain: scenario.domainSize, spacing: 0.25, foot: 8, angle: 15)
        let normal = SIMD3(-sin(angle), 0, cos(angle))
        let foot = SIMD3(12, 6, 4 * tan(angle))
        scenario.rigidObjects = [
            try RigidObjectDefinition(
                name: "Crate", shape: .box(size: SIMD3(1, 1, 0.8)), position: foot + 0.40001 * normal,
                mass: 200,
                orientation: simd_quatd(angle: -angle, axis: SIMD3(0, 1, 0)).vector)
        ]
        let motion = try FreestandingMotion.compute(
            device: device, scenario: scenario, duration: 0.05, frameInterval: 0.01, cellSize: 0.3,
            refinement: 1)
        #expect(motion.failure == nil)
        let crate = motion.objects[0]
        #expect(
            simd_length(crate.displacement) < 0.01 && crate.finalTilt < 1 && !crate.overturned, "\(crate)")
        let last = try #require(motion.frames.last?.poses.first)
        let pose = simd_quatd(vector: last.orientation)
        for corner in 0..<8 {
            let local = SIMD3<Double>(
                corner & 1 == 0 ? -0.5 : 0.5, corner & 2 == 0 ? -0.5 : 0.5, corner & 4 == 0 ? -0.4 : 0.4)
            let point = last.centre + pose.act(local)
            #expect(RigidBodyWorld.clearance(point, above: try #require(scenario.terrain)).gap > -1e-3)
        }
    }
}
