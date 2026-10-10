import Metal
import Testing
import simd

@testable import BlastCore

/// Several freestanding objects with one in the air. Consistency checks only.
@Suite("Experimental rigid-world coupling", .serialized)
struct ExperimentalRigidWorldTests {
    let device: MTLDevice
    init() throws { device = try #require(MTLCreateSystemDefaultDevice()) }

    @Test("With one car, the world driver moves as the single-car driver does under a blast")
    func oneCarMatchesCarDriver() throws {
        var scene = Scenario(
            name: "One car", domainSize: SIMD3(8, 5, 3), boxes: [],
            charge: Charge(mass: 1, position: SIMD3(4, 0.6, 0.3)))
        scene.rigidCars = [try .saloon(position: SIMD3(4, 2.5, 0))]
        let car = try ExperimentalRigidCarSimulation(device: device, scenario: scene, cellSize: 0.2)
        let world = try ExperimentalRigidWorldSimulation(device: device, scenario: scene, cellSize: 0.2)
        #expect(world.coupled == [0] && world.count == 1)
        while car.air.time < 0.01 - 1e-8 {
            try car.advance(steps: 1, timeLimit: 0.01)
            try world.advance(steps: 1, timeLimit: 0.01)
            #expect(abs(car.air.time - world.air.time) < 1e-12)
        }
        let member = try #require(world.members.first)
        #expect(simd_length(car.velocity) > 0.01)
        #expect(simd_distance(member.centreOfMass, car.position) < 1e-6)
        #expect(simd_length(member.velocity - car.velocity) < 1e-5 * simd_length(car.velocity))
    }

    @Test(
        "A car pushed into its neighbour moves it, and air, contact and gravity account for the row's momentum"
    )
    func rowMomentumBudget() throws {
        var scene = try ExperimentalRigidRowStudy.scenario(chargeMass: 0, count: 2)
        scene.domainSize.y = 8.4
        // Coarse air: this checks bookkeeping, not loads.
        let simulation = try ExperimentalRigidWorldSimulation(
            device: device, scenario: scene, cellSize: 0.3, coupled: [0])
        #expect(simulation.coupled == [0])
        // Car 1 is in the air; shove it sideways towards Car 2, 0.85 m away.
        let push = SIMD3<Double>(0, 1500 * 6, 0)
        try simulation.applyImpulse(push, to: 0)
        var accounted = push
        while simulation.air.time < 0.2 - 1e-8 {
            try simulation.advance(steps: 1, timeLimit: 0.2)
            accounted += simulation.lastImpulse + simulation.lastContactImpulses.reduce(.zero, +)
        }
        accounted += 3000 * simulation.air.time * simulation.gravity
        let members = simulation.members
        #expect(members[1].velocity.y > 0.5)
        #expect(simd_length(simulation.linearMomentum - accounted) < 1e-6 * simd_length(push))
        // Never left overlapping.
        for corner in members[0].corners {
            let local = simd_quatd(vector: members[1].orientation).inverse.act(
                corner - (members[1].corners[0] + members[1].corners[7]) / 2)
            #expect(any(abs(local) .> SIMD3(2.3, 0.775, 0.65) - 1e-5))
        }
    }

    @Test(
        "Freestanding motion crops the scene around the objects and records them from where they were placed")
    func freestandingMotion() throws {
        var scene = Scenario(
            name: "Car park", domainSize: SIMD3(60, 60, 20),
            boxes: [
                Box(min: SIMD3(40, 20, 0), max: SIMD3(50, 40, 6)),
                Box(min: SIMD3(31, 33, 0), max: SIMD3(34, 34, 2)),
            ],
            charge: Charge(mass: 1, position: SIMD3(30, 27.725, 0.3)))
        scene.rigidCars = [
            try .saloon(position: SIMD3(30, 30, 0)), try .saloon(position: SIMD3(30, 32.4, 0)),
        ]
        let (cropped, offset) = try FreestandingMotion.cropped(scene)
        #expect(cropped.domainSize.x < 20 && cropped.domainSize.y < 20 && cropped.domainSize.z < 6)
        #expect(
            simd_distance(try #require(cropped.rigidCars?[1].position) + offset, SIMD3(30, 32.4, 0)) < 1e-9)
        // The far block is dropped and the near one clipped to the crop.
        #expect(cropped.boxes.count == 1)
        // Coarse uniform air: this checks the bookkeeping, not the loads.
        let motion = try FreestandingMotion.compute(
            device: device, scenario: scene, duration: 0.006, frameInterval: 0.001, cellSize: 0.3,
            refinement: 1, coupled: [0])
        #expect(motion.coupled == [0] && motion.objects.count == 2 && motion.failure == nil)
        #expect(motion.frames.count >= 4)
        let placed = try #require(motion.frames.first?.poses.first)
        #expect(simd_distance(placed.centre, SIMD3(30, 30, 0.15 + 0.65)) < 1e-9)
        #expect(motion.objects[0].peakSpeed > 0.01 && motion.objects[1].peakSpeed < 1e-6)
    }

    // MARK: - Every object in the air

    private func boxes(_ list: [(SIMD3<Double>, SIMD3<Double>)], domain: SIMD3<Float>, charge: Double = 0.2)
        throws -> Scenario
    {
        Scenario(
            name: "Boxes", domainSize: domain, boxes: [],
            charge: Charge(mass: Float(charge), position: SIMD3(1, domain.y / 2, 0.3)),
            rigidObjects: try list.enumerated().map { n, box in
                try RigidObjectDefinition(
                    name: "Box \(n + 1)", shape: .box(size: box.1), position: box.0, mass: 50)
            })
    }

    /// The air's impulse and moment on each held box over `duration`, and its largest force along x.
    private func heldLoads(_ scene: Scenario, cellSize: Float, refinement: Int, duration: Double) throws
        -> [(linear: SIMD3<Double>, angular: SIMD3<Double>, peak: Double)]
    {
        var config = SolverConfiguration()
        config.refinement = refinement
        config.refinementMemory = 64 << 20
        let simulation = try ExperimentalRigidWorldSimulation(
            device: device, scenario: scene, cellSize: cellSize, configuration: config, motion: .held)
        var loads = [(linear: SIMD3<Double>, angular: SIMD3<Double>, peak: Double)](
            repeating: (.zero, .zero, 0), count: simulation.count)
        while simulation.air.time < duration - 1e-8 {
            let start = simulation.air.time
            try simulation.advance(steps: 1, timeLimit: duration)
            for n in loads.indices {
                loads[n].linear += simulation.lastAirImpulses[n]
                loads[n].angular += simulation.lastAirAngularImpulses[n]
                loads[n].peak = max(
                    loads[n].peak, simulation.lastAirImpulses[n].x / (simulation.air.time - start))
            }
        }
        return loads
    }

    @Test(
        "Two boxes side by side take, between them, the load of one box of the same total size",
        arguments: [(Float(0.1), 1), (Float(0.2), 2)])
    func pairMatchesOneBox(cellSize: Float, refinement: Int) throws {
        let domain = SIMD3<Float>(4, 4, 2)
        let one = try heldLoads(
            boxes([(SIMD3(2.3, 2, 0.4), SIMD3(0.6, 1, 0.8))], domain: domain), cellSize: cellSize,
            refinement: refinement, duration: 0.004)[0]
        let pair = try heldLoads(
            boxes(
                [
                    (SIMD3(2.3, 1.75, 0.4), SIMD3(0.6, 0.5, 0.8)),
                    (SIMD3(2.3, 2.25, 0.4), SIMD3(0.6, 0.5, 0.8)),
                ],
                domain: domain), cellSize: cellSize, refinement: refinement, duration: 0.004)
        #expect(one.linear.x > 10)
        // The cells the pair holds are the box's, so the air is the same and the faces' loads sum.
        #expect(simd_length(pair[0].linear + pair[1].linear - one.linear) < 1e-9 * simd_length(one.linear))
        // About the box's centre, the halves' moments and the moments of their forces add up.
        let centre = SIMD3<Double>(2.3, 2, 0.4)
        let moment =
            pair[0].angular + simd_cross(SIMD3(2.3, 1.75, 0.4) - centre, pair[0].linear)
            + pair[1].angular + simd_cross(SIMD3(2.3, 2.25, 0.4) - centre, pair[1].linear)
        #expect(simd_length(moment - one.angular) < 1e-8 * simd_length(one.linear))
        // The charge faces the seam: each half takes half the push, and the pressure on their
        // outer sides pushes them together.
        #expect(abs(pair[0].linear.x / pair[1].linear.x - 1) < 0.01)
        #expect(pair[0].linear.y > 0 && pair[1].linear.y < 0)
        #expect(abs(pair[0].linear.y + pair[1].linear.y) < 0.01 * abs(pair[0].linear.y))
    }

    @Test("A box behind another is sheltered by it")
    func shelteredBox() throws {
        let domain = SIMD3<Float>(5, 4, 2.4)
        let front = (SIMD3<Double>(2.2, 2, 0.5), SIMD3<Double>(0.4, 1.6, 1))
        let back = (SIMD3<Double>(3.2, 2, 0.5), SIMD3<Double>(0.4, 1.6, 1))
        let duration = 0.008
        let alone = try heldLoads(
            boxes([back], domain: domain), cellSize: 0.1, refinement: 1, duration: duration)[0]
        let frontAlone = try heldLoads(
            boxes([front], domain: domain), cellSize: 0.1, refinement: 1, duration: duration)[0]
        let both = try heldLoads(
            boxes([front, back], domain: domain), cellSize: 0.1, refinement: 1, duration: duration)
        // The wave diffracting over the front box strikes the back one far more weakly than the
        // incident wave does; the front box's peak comes before anything returns from behind it.
        #expect(alone.peak > 1e4)
        #expect(both[1].peak < 0.5 * alone.peak)
        #expect(abs(both[0].peak / frontAlone.peak - 1) < 1e-3)
    }

    @Test(
        "Several boxes moving together through refined air, close enough to share patches, keep the gas",
        arguments: [ExperimentalBoxRemap.redistribution, .connectedTransport])
    func severalMovingBoxesConserveGas(mode: ExperimentalBoxRemap) throws {
        // Two boxes 0.1 m apart, whose patches meet and remap together, and one far from them.
        var scene = try boxes(
            [
                (SIMD3(2.095, 2, 1.5), SIMD3(0.8, 0.8, 0.8)), (SIMD3(2.095, 2.9, 1.5), SIMD3(0.8, 0.8, 0.8)),
                (SIMD3(5.6, 2.4, 1.5), SIMD3(0.6, 1.2, 0.8)),
            ], domain: SIMD3(8, 5, 3), charge: 0)
        scene.reflectiveFaces = .all
        var config = SolverConfiguration()
        config.refinement = 2
        config.refinementMemory = 64 << 20
        let simulation = try ExperimentalRigidWorldSimulation(
            device: device, scenario: scene, cellSize: 0.2, configuration: config)
        simulation.air.experimentalBoxRemapMode = mode
        simulation.air.refinement?.boxRemapMode = mode
        simulation.gravity = .zero
        simulation.air.fill { i, j, k in
            Primitive(
                density: 1.225 * (1 + 0.01 * Float(i % 5)), velocity: SIMD3(1, 2, 3),
                pressure: 101325 * (1 + 0.02 * Float((j + k) % 3)))
        }
        let before = simulation.air.totals()
        try simulation.applyImpulse(SIMD3(1000, 600, 0), to: 0, at: SIMD3(2.095, 2, 1.8))
        try simulation.applyImpulse(SIMD3(800, -600, 200), to: 1)
        try simulation.applyImpulse(SIMD3(-1200, 0, 0), to: 2, at: SIMD3(5.6, 2.9, 1.5))
        let moved = simulation.air.totals()
        #expect(abs(moved.mass / before.mass - 1) < 1e-7)
        #expect(abs(moved.energy / before.energy - 1) < 1e-7)
        try simulation.advance(steps: 100)
        #expect(simd_distance(simulation.members[0].centreOfMass, SIMD3(2.095, 2, 1.5)) > 0.15)
        #expect(simd_distance(simulation.members[2].centreOfMass, SIMD3(5.6, 2.4, 1.5)) > 0.15)
        #expect(abs(simulation.air.totals().mass / before.mass - 1) < 1e-6)
    }

    @Test("Moving boxes in the air exchange equal and opposite momentum with it")
    func severalBoxesMomentum() throws {
        var scene = try boxes(
            [(SIMD3(2, 2, 1.5), SIMD3(0.8, 0.8, 0.8)), (SIMD3(2, 2.9, 1.5), SIMD3(0.8, 0.8, 0.8))],
            domain: SIMD3(4, 5, 3), charge: 0)
        scene.reflectiveFaces = []
        var config = SolverConfiguration()
        config.refinement = 2
        config.refinementMemory = 64 << 20
        let simulation = try ExperimentalRigidWorldSimulation(
            device: device, scenario: scene, cellSize: 0.2, configuration: config)
        simulation.gravity = .zero
        try simulation.applyImpulse(SIMD3(500, 0, 0), to: 0)
        try simulation.applyImpulse(SIMD3(0, 0, -500), to: 1)
        let momentum = simulation.air.momentum() + simulation.linearMomentum
        try simulation.advance(steps: 10)
        #expect(simulation.members[0].velocity.x > 0 && simulation.members[0].velocity.x < 10)
        #expect(simd_length(simulation.air.momentum() + simulation.linearMomentum - momentum) < 1e-3)
    }
}
