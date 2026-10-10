import Metal
import Testing
import simd

@testable import BlastCore

/// Freestanding objects on the terrain: resting, sliding and tipping as statics says.
@Suite("Freestanding objects on the terrain")
struct TerrainContactTests {
    private let size = SIMD3<Double>(1, 0.6, 0.4)
    private let mass = 100.0

    private func member(
        at position: SIMD3<Double>, orientation: simd_quatd = simd_quatd(angle: 0, axis: SIMD3(0, 0, 1)),
        friction: (Double, Double)
    ) throws -> RigidBodyWorld.Member {
        RigidBodyWorld.Member(
            body: try RigidBoxBody(mass: mass, size: size, position: position, orientation: orientation),
            supports: [],
            friction: RigidBoxBody.Ground(staticFriction: friction.0, slidingFriction: friction.1))
    }

    /// The angle between the body's z axis and `up`, in degrees.
    private func tilt(_ body: RigidBoxBody, from up: SIMD3<Double> = SIMD3(0, 0, 1)) -> Double {
        acos(min(1, simd_dot(body.orientation.act(SIMD3(0, 0, 1)), up))) * 180 / .pi
    }

    /// A box lying on a 20° slope rising along x, its centre over x = 8 m, and the slope's
    /// directions: up it, and out of it.
    private func onSlope(friction: (Double, Double)) throws -> (
        RigidBodyWorld, up: SIMD3<Double>, normal: SIMD3<Double>
    ) {
        let angle = 20 * Double.pi / 180
        let slope = Terrain.slope(domain: SIMD3(20, 6, 10), spacing: 0.25, foot: 2, angle: 20)
        let up = SIMD3(cos(angle), 0, sin(angle))
        let normal = SIMD3(-sin(angle), 0, cos(angle))
        let foot = SIMD3(8, 3, 6 * tan(angle))
        let box = try member(
            at: foot + (size.z / 2 + 1e-5) * normal,
            orientation: simd_quatd(angle: -angle, axis: SIMD3(0, 1, 0)),
            friction: friction)
        return (RigidBodyWorld(members: [box], terrain: slope), up, normal)
    }

    @Test("A box on a slope below its friction angle stays put")
    func rests() throws {
        // tan 20° = 0.364 < 0.45.
        var (world, up, normal) = try onSlope(friction: (0.45, 0.4))
        let start = world.members[0].body.position
        for _ in 0..<1000 { world.advance(by: 0.001) }
        let body = world.members[0].body
        #expect(simd_length(body.position - start) < 1e-4, "\(body.position - start)")
        #expect(simd_length(body.linearVelocity) < 1e-4 && simd_length(body.angularVelocity) < 1e-3)
        #expect(tilt(body, from: normal) < 0.05)
        _ = up
    }

    @Test("Above its friction angle it slides at g (sin θ − μ cos θ)")
    func slides() throws {
        var (world, up, normal) = try onSlope(friction: (0.3, 0.25))
        let start = world.members[0].body.position
        let angle = 20 * Double.pi / 180
        let acceleration = 9.81 * (sin(angle) - 0.25 * cos(angle))
        for _ in 0..<1000 { world.advance(by: 0.001) }
        let body = world.members[0].body
        let down = -simd_dot(body.position - start, up)
        #expect(abs(down / (0.5 * acceleration) - 1) < 0.02, "slid \(down) m against \(0.5 * acceleration)")
        // Along the slope, on its face, without turning off it.
        #expect(abs(simd_dot(body.position - start, normal)) < 1e-3)
        #expect(abs(-simd_dot(body.linearVelocity, up) / acceleration - 1) < 0.02)
        #expect(tilt(body, from: normal) < 0.1)
    }

    @Test("Dropped level onto the slope, it lands on an edge, turns onto its face and stays")
    func settles() throws {
        let angle = 20 * Double.pi / 180
        let slope = Terrain.slope(domain: SIMD3(20, 6, 10), spacing: 0.25, foot: 2, angle: 20)
        let centre = SIMD3(8, 3, 6 * tan(angle) + 0.7)
        var world = RigidBodyWorld(members: [try member(at: centre, friction: (0.6, 0.55))], terrain: slope)
        for _ in 0..<2500 { world.advance(by: 0.001) }
        let body = world.members[0].body
        #expect(simd_length(body.linearVelocity) < 1e-3 && simd_length(body.angularVelocity) < 1e-2)
        #expect(abs(tilt(body) - 20) < 0.2, "tilt \(tilt(body))°")
        // Lying on its face: every corner of its lower face on the surface.
        let lowest = body.corners.map { RigidBodyWorld.clearance($0, above: slope).gap }.sorted()
        #expect(lowest[3] < 1e-4 && lowest[0] > -1e-4, "\(lowest)")
    }

    /// A plateau 0.5 m high for x ≤ 5 m, the ground beyond, on nodes 10 cm apart.
    private var step: Terrain {
        let spacing: Float = 0.1
        let (columns, rows) = (101, 61)
        var heights = [Float](repeating: 0, count: columns * rows)
        for j in 0..<rows {
            for i in 0...50 { heights[i + columns * j] = 0.5 }
        }
        return Terrain(spacing: spacing, columns: columns, rows: rows, heights: heights, source: "step")
    }

    /// The box resting on the plateau, its far end `overhang` metres past the edge.
    private func overhanging(_ overhang: Double) throws -> RigidBodyWorld {
        let centre = SIMD3(4.5 + overhang, 3, 0.5 + size.z / 2 + 1e-5)
        return RigidBodyWorld(members: [try member(at: centre, friction: (0.6, 0.5))], terrain: step)
    }

    @Test(
        "A box over a step's edge stays while its centre of mass is over the plateau, and tips off once past it"
    )
    func tipsOffAStep() throws {
        // Its centre 5 cm short of the edge: the edge holds it, a third of its length overhanging.
        var held = try overhanging(0.45)
        for _ in 0..<1000 { held.advance(by: 0.001) }
        let still = held.members[0].body
        #expect(tilt(still) < 0.05 && simd_length(still.linearVelocity) < 1e-4, "\(tilt(still))°")
        // Its centre 5 cm past the edge: it turns about the edge, lifting the end on the plateau,
        // and falls off.
        var tipping = try overhanging(0.55)
        var pivoted = false
        for step in 1...1200 {
            tipping.advance(by: 0.001)
            let body = tipping.members[0].body
            if step == 300 {
                // Turning about the edge: the end on the plateau has lifted off it, and the bottom
                // face still passes through the edge.
                let back = body.corners.filter { $0.x < 5 }.map(\.z).min()!
                #expect(tilt(body) > 2 && back > 0.5 + 0.01, "tilt \(tilt(body))°, back end at \(back) m")
                let local = body.orientation.inverse.act(SIMD3(5, 3, 0.5) - body.worldPoint(.zero))
                #expect(
                    abs(local.z + size.z / 2) < 2e-3, "the edge \(local.z + size.z / 2) m off the bottom face"
                )
                pivoted = true
            }
        }
        let fallen = tipping.members[0].body
        #expect(
            pivoted && tilt(fallen) > 30 && fallen.position.x > 5, "\(tilt(fallen))° at \(fallen.position)")
        // Nothing ended inside the ground.
        #expect(fallen.corners.allSatisfy { RigidBodyWorld.clearance($0, above: step).gap > -1e-4 })
    }

    @Test("A flat terrain is the floor: the world drops it")
    func flatIsTheFloor() throws {
        let box = try member(at: SIMD3(3, 3, 0.5), friction: (0.6, 0.5))
        var plain = RigidBodyWorld(members: [box])
        var flat = RigidBodyWorld(members: [box], terrain: .flat(domain: SIMD3(10, 6, 4), spacing: 0.5))
        #expect(flat.terrain == nil)
        plain.applyImpulse(SIMD3(150, 20, 0), to: 0, at: SIMD3(3.2, 3, 0.6))
        flat.applyImpulse(SIMD3(150, 20, 0), to: 0, at: SIMD3(3.2, 3, 0.6))
        for _ in 0..<500 {
            plain.advance(by: 0.001)
            flat.advance(by: 0.001)
        }
        #expect(plain.members[0].body.position == flat.members[0].body.position)
    }

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
