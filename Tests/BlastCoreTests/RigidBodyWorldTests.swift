import Testing
import simd

@testable import BlastCore

/// Several freestanding bodies in contact with the ground, static blocks and each other.
/// Mechanical checks only; no air.
@Suite("Rigid-body world")
struct RigidBodyWorldTests {
    private func box(
        _ size: SIMD3<Double>, at position: SIMD3<Double>, mass: Double, yaw: Double = 0,
        friction: (Double, Double) = (0.6, 0.5)
    ) throws -> RigidBodyWorld.Member {
        RigidBodyWorld.Member(
            body: try RigidBoxBody(
                mass: mass, size: size, position: position,
                orientation: simd_quatd(angle: yaw, axis: SIMD3(0, 0, 1))),
            supports: [],
            friction: RigidBoxBody.Ground(staticFriction: friction.0, slidingFriction: friction.1))
    }

    private func car(at position: SIMD3<Double>, yaw: Double = 0, friction: (Double, Double) = (0.8, 0.7))
        throws -> RigidBodyWorld.Member
    {
        let definition = try RigidCarDefinition.saloon(
            position: position, orientation: simd_quatd(angle: yaw, axis: SIMD3(0, 0, 1)).vector,
            staticFriction: friction.0, slidingFriction: friction.1)
        let made = try definition.makeBody()
        return RigidBodyWorld.Member(body: made.body, supports: made.tyres, friction: definition.ground)
    }

    private func energy(_ world: RigidBodyWorld, gravity: Double = 9.81) -> Double {
        world.members.reduce(0) { $0 + $1.body.kineticEnergy + $1.body.mass * gravity * $1.body.position.z }
    }

    @Test("A box sliding into a wall stops against it without rebounding or entering it")
    func boxIntoWall() throws {
        let wall = Box(min: SIMD3(3, -2, 0), max: SIMD3(3.4, 2, 2))
        var world = RigidBodyWorld(
            members: [try box(SIMD3(1, 1, 0.6), at: SIMD3(0, 0, 0.3), mass: 200)], blocks: [wall])
        world.applyImpulse(SIMD3(200 * 6, 0, 0), to: 0)
        let dt = 0.001
        var previous = energy(world)
        var impact: Double?
        var speedBefore = 0.0
        for step in 0..<2000 {
            let speed = world.members[0].body.linearVelocity.x
            let contacts = world.advance(by: dt)
            if impact == nil, contacts.contains(where: { $0.other == .block(0) }) {
                impact = Double(step) * dt
                speedBefore = speed
            }
            let now = energy(world)
            #expect(now <= previous + 1e-9 * 200 * 9.81)
            previous = now
            #expect(world.members[0].body.linearVelocity.x > -1e-6)
            #expect(world.members[0].body.corners.allSatisfy { $0.x <= 3 + 1e-5 })
        }
        // Sliding friction 0.5 decelerates it over the 2.5 m to the wall: v² = v0² − 2μg d.
        #expect(abs(speedBefore - (36 - 2 * 0.5 * 9.81 * 2.5).squareRoot()) < 0.03)
        #expect(impact != nil)
        let body = world.members[0].body
        #expect(abs(body.corners.map(\.x).max()! - 3) < 1e-4)
        #expect(simd_length(body.linearVelocity) < 1e-6)
        #expect(simd_length(body.angularVelocity) < 1e-5)
    }

    @Test("Two cars colliding in free flight conserve linear and angular momentum and gain no energy")
    func carsCollideInFreeFlight() throws {
        var world = RigidBodyWorld(members: [
            try car(at: SIMD3(0, 0, 1)), try car(at: SIMD3(6, 0.8, 1.2), yaw: 0.3),
        ])
        world.applyImpulse(SIMD3(1500 * 10, 0, 0), to: 0)
        world.applyImpulse(SIMD3(-1500 * 2, 500, 0), to: 1, at: SIMD3(6.5, 0.8, 1.6))
        let momentum = world.linearMomentum
        let angular = world.angularMomentum
        var previous = world.kineticEnergy
        let start = previous
        var touched = false
        for _ in 0..<800 {
            let contacts = world.advance(by: 0.001, gravity: .zero, ground: false)
            touched = touched || !contacts.isEmpty
            #expect(world.kineticEnergy <= previous * (1 + 1e-12) + 1e-9)
            previous = world.kineticEnergy
        }
        #expect(touched)
        #expect(simd_length(world.linearMomentum - momentum) < 1e-9 * simd_length(momentum))
        #expect(simd_length(world.angularMomentum - angular) < 1e-8 * simd_length(angular))
        // Inelastic: the struck car takes up speed and kinetic energy is lost.
        #expect(world.members[1].body.linearVelocity.x > 2)
        #expect(world.kineticEnergy < 0.9 * start)
        // Never left overlapping.
        let a = world.members[0].body
        let b = world.members[1].body
        for corner in a.corners {
            let inside = RigidBodyWorld.pointAgainstBox(
                corner, centre: b.worldPoint(.zero), pose: b.orientation, half: b.size / 2)
            #expect((inside?.gap ?? 1) > -1e-5)
        }
    }

    @Test("Cars colliding on frictionless ground conserve horizontal momentum and gain no energy")
    func carsCollideOnGround() throws {
        var world = RigidBodyWorld(members: [
            try car(at: SIMD3(0, 0, 0), friction: (0, 0)), try car(at: SIMD3(0, 2.2, 0), friction: (0, 0)),
        ])
        world.applyImpulse(SIMD3(0, 1500 * 4, 0), to: 0)
        let momentum = world.linearMomentum
        var previous = energy(world)
        for _ in 0..<1500 {
            world.advance(by: 0.001)
            let now = energy(world)
            #expect(now <= previous + 1e-6)
            previous = now
        }
        let horizontal = SIMD2(world.linearMomentum.x, world.linearMomentum.y)
        #expect(simd_length(horizontal - SIMD2(momentum.x, momentum.y)) < 1e-8 * simd_length(momentum))
        // Side by side and equal: a perfectly inelastic hit shares the speed.
        for member in world.members {
            #expect(abs(member.body.linearVelocity.y - 2) < 0.05)
        }
    }

    @Test("Stacks of boxes rest without creeping or gaining energy, on the ground and on a block")
    func restingStacks() throws {
        let block = Box(min: SIMD3(4, -1, 0), max: SIMD3(6, 1, 0.8))
        var world = RigidBodyWorld(
            members: [
                try box(SIMD3(1, 1, 0.5), at: SIMD3(0, 0, 0.25), mass: 100),
                try box(SIMD3(1, 1, 0.5), at: SIMD3(0, 0, 0.75), mass: 60),  // equal footprints
                try box(SIMD3(0.6, 0.6, 0.4), at: SIMD3(0.1, -0.1, 1.2), mass: 30),
                try box(SIMD3(0.8, 0.8, 0.8), at: SIMD3(5, 0, 1.2), mass: 50, yaw: 0.4),
                try box(SIMD3(0.5, 0.5, 0.5), at: SIMD3(5, 0, 1.85), mass: 20, yaw: -0.2),
            ], blocks: [block])
        let start = world.members.map(\.body.position)
        let initial = energy(world)
        var contacts: [RigidBodyWorld.Contact] = []
        for _ in 0..<1000 { contacts = world.advance(by: 0.001) }
        for (member, position) in zip(world.members, start) {
            #expect(simd_distance(member.body.position, position) < 1e-4)
            #expect(simd_length(member.body.linearVelocity) < 1e-5)
            #expect(simd_length(member.body.angularVelocity) < 1e-4)
        }
        #expect(energy(world) <= initial + 1e-6)
        // The ground carries the first stack; the block carries the second.
        let onGround = contacts.filter { $0.other == .ground }.reduce(0) { $0 + $1.normalImpulse }
        #expect(abs(onGround / 0.001 - 190 * 9.81) < 1e-3 * 190 * 9.81)
        let onBlock = contacts.filter { $0.other == .block(0) }.reduce(0) { $0 + $1.normalImpulse }
        #expect(abs(onBlock / 0.001 - 70 * 9.81) < 1e-3 * 70 * 9.81)
    }

    @Test("The sweep finds exactly the overlapping pairs and few others in a sparse scene")
    func spatialFilter() throws {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func random() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 11) / Double(1 << 53)
        }
        var members: [RigidBodyWorld.Member] = []
        for _ in 0..<60 {
            members.append(
                try box(
                    SIMD3(0.5 + random(), 0.5 + random(), 0.3 + random()),
                    at: SIMD3(40 * random(), 40 * random(), 1 + 3 * random()), mass: 10, yaw: 3 * random()))
        }
        let blocks = (0..<10).map { _ -> Box in
            let low = SIMD3<Float>(Float(40 * random()), Float(40 * random()), 0)
            return Box(min: low, max: low + SIMD3(2, 0.3, 2))
        }
        let world = RigidBodyWorld(members: members, blocks: blocks)
        let pairs = world.candidatePairs(dt: 0.001)
        // Brute force over the same grown bounds.
        func bounds(_ body: RigidBoxBody) -> (SIMD3<Double>, SIMD3<Double>) {
            let c = body.corners
            let pad = 1e-6 * simd_length(body.size)
            return (
                c.reduce(SIMD3(repeating: .infinity)) { simd_min($0, $1) } - pad,
                c.reduce(SIMD3(repeating: -.infinity)) { simd_max($0, $1) } + pad
            )
        }
        var expected = 0
        for i in members.indices {
            let a = bounds(members[i].body)
            for j in (i + 1)..<members.count {
                let b = bounds(members[j].body)
                if all(a.0 .<= b.1) && all(b.0 .<= a.1) { expected += 1 }
            }
            for block in blocks {
                let low = SIMD3<Double>(block.min)
                let high = SIMD3<Double>(block.max)
                if all(a.0 .<= high) && all(low .<= a.1) { expected += 1 }
            }
        }
        #expect(pairs.count == expected)
        #expect(pairs.count < 60)  // against 60 × 59 / 2 + 600 pairs without filtering
    }

    @Test("One car in the world moves as the single-car reference does")
    func matchesCarReference() throws {
        let definition = try RigidCarDefinition.saloon(position: .zero)
        var reference = try definition.makeBody()
        var world = RigidBodyWorld(members: [try car(at: .zero)])
        reference.applyImpulse(SIMD3(0, 1500 * 4, 0), at: SIMD3(0.5, 0, 0.8))
        world.applyImpulse(SIMD3(0, 1500 * 4, 0), to: 0, at: SIMD3(0.5, 0, 0.8))
        for _ in 0..<1500 {
            reference.advanceWithGround(by: 0.001, ground: definition.ground)
            world.advance(by: 0.001)
        }
        #expect(simd_distance(reference.position, world.members[0].body.position) < 1e-6)
        #expect(simd_length(reference.linearVelocity - world.members[0].body.linearVelocity) < 1e-6)
    }
}
