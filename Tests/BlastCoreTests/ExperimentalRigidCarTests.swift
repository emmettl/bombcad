import Metal
import Testing
import simd

@testable import BlastCore

/// The car's shell in the air, following the rigid box's coupling checks. Numerical and
/// mechanical consistency only; nothing here is compared with a blast experiment.
@Suite("Experimental rigid-car coupling", .serialized)
struct ExperimentalRigidCarTests {
    let device: MTLDevice
    init() throws { device = try #require(MTLCreateSystemDefaultDevice()) }

    /// The saloon parked across the middle of an 8 × 5 × 3 m domain, its right side to the charge.
    private func scenario(charge: Double = 0) throws -> Scenario {
        var scene = Scenario(
            name: "One car", domainSize: SIMD3(8, 5, 3), boxes: [],
            charge: Charge(mass: Float(charge), position: SIMD3(4, 0.6, 0.3)))
        scene.rigidCars = [try .saloon(position: SIMD3(4, 2.5, 0))]
        return scene
    }

    private var weight: Double { 1500 * 9.81 }

    @Test("Ambient air exerts no net load; the free car rests on its static tyre loads")
    func ambientBalance() throws {
        let simulation = try ExperimentalRigidCarSimulation(
            device: device, scenario: scenario(), cellSize: 0.2)
        let start = simulation.position
        let before = simulation.air.totals()
        try simulation.advance(steps: 20)
        #expect(simd_length(simulation.lastImpulse) < 1e-6 * weight * simulation.air.time)
        #expect(simd_distance(simulation.position, start) < 1e-7)
        #expect(simd_length(simulation.velocity) < 1e-7)
        let statics = [1.5, 1.5, 1.2, 1.2].map { weight * $0 / 5.4 }
        for (load, expected) in zip(simulation.lastTyreLoads, statics) {
            #expect(abs(load - expected) < 1e-4 * weight)
        }
        #expect(abs(simulation.air.totals().mass / before.mass - 1) < 1e-7)
    }

    @Test(
        "With patches over the car, still air stays at ambient: the shell's faces inside coarse cells start with no packed gas",
        arguments: [2, 4])
    func refinedAmbientBalance(ratio: Int) throws {
        var config = SolverConfiguration()
        config.refinement = ratio
        config.refinementMemory = 256 << 20
        let simulation = try ExperimentalRigidCarSimulation(
            device: device, scenario: scenario(), cellSize: 0.2, configuration: config)
        let start = simulation.position
        let before = simulation.air.totals()
        var impulse = SIMD3<Double>.zero
        for _ in 0..<20 {
            try simulation.advance(steps: 1)
            impulse += simulation.lastImpulse
        }
        // Without the correction the gap and the roof start at 4/3 to 2 times ambient pressure
        // and push the resting car up by hundreds of newton seconds a second.
        #expect(simd_length(impulse) < 1e-6 * weight * simulation.air.time)
        #expect(simd_distance(simulation.position, start) < 1e-7)
        #expect(abs(simulation.air.totals().mass / before.mass - 1) < 1e-6)
    }

    @Test("Ground and air impulse records account for the coupled car's momentum")
    func impulseBudget() throws {
        let simulation = try ExperimentalRigidCarSimulation(
            device: device, scenario: scenario(), cellSize: 0.2)
        let initial = SIMD3<Double>(0, 3000, 0)
        try simulation.applyImpulse(initial)
        var linear = SIMD3<Double>.zero
        var angular = SIMD3<Double>.zero
        var ground = SIMD3<Double>.zero
        while simulation.air.time < 0.005 - 1e-8 {
            try simulation.advance(steps: 1, timeLimit: 0.005)
            linear += simulation.lastImpulse + simulation.lastGroundImpulse
            angular += simulation.lastAngularImpulse + simulation.lastGroundAngularImpulse
            ground += simulation.lastGroundImpulse
        }
        let momentum = 1500 * simulation.velocity
        #expect(
            simd_length(momentum - initial - linear - 1500 * simulation.air.time * simulation.gravity)
                < 1e-6 * simd_length(initial))
        #expect(simd_length(simulation.angularMomentum - angular) < 1e-6 * simd_length(initial))
        // Locked tyres slide: friction is the sliding coefficient times the normal impulse.
        // (The air also pushes back: jerking the shell sideways sends out a pressure wave.)
        // The air's push acts at the shell's centre, behind the centre of mass, so the car yaws
        // slightly and the slip, and friction, turn a little off the y axis.
        #expect(abs(simd_length(SIMD2(ground.x, ground.y)) - 0.7 * ground.z) < 1e-5 * ground.z)
        #expect(ground.y < 0 && abs(ground.x) < 2e-3 * ground.z)
    }

    @Test(
        "A pressure gradient pushes the held shell by its resolved volume, with torque about the low centre of mass"
    )
    func pressureGradient() throws {
        var config = SolverConfiguration()
        config.cfl = 0.1
        config.startupSteps = 1
        let simulation = try ExperimentalRigidCarSimulation(
            device: device, scenario: scenario(), cellSize: 0.2, configuration: config, motion: .held)
        let gradient = 1000.0  // Pa/m along x
        simulation.air.fill { i, _, _ in
            Primitive(density: 1.225, pressure: 101325 + Float(gradient) * (Float(i) + 0.5) * 0.2)
        }
        try simulation.advance(steps: 1)
        let force = simulation.lastImpulse / simulation.air.time
        let solid = Double(simulation.air.grid.cellCount - simulation.air.fluidCellCount) * 0.008
        // 23 × 7 × 6 cells at 0.2 m resolve the 4.6 × 1.55 × 1.3 m shell.
        #expect(abs(solid - 7.728) < 1e-9)
        // Each end face takes the pressure of the fluid cell beside it, half a cell out, so the
        // pressure difference spans 24 cells rather than 23.
        #expect(abs(force.x / (-gradient * 24 * 0.2 * (7 * 6 * 0.04)) - 1) < 2e-3)
        #expect(abs(force.y) < 1e-3 * abs(force.x) && abs(force.z) < 1e-3 * abs(force.x))
        // The shell's centre is 0.25 m above and 0.15 m behind the centre of mass, so a force
        // along x pitches the car by 0.25 F about y.
        #expect(abs(simulation.lastAngularImpulse.y / simulation.lastImpulse.x - 0.25) < 1e-3)
    }

    @Test("A blast beside the car pushes it away, loads its far tyres and unloads the near ones")
    func blast() throws {
        let held = try ExperimentalRigidCarSimulation(
            device: device, scenario: scenario(charge: 0.5), cellSize: 0.2, motion: .held)
        let free = try ExperimentalRigidCarSimulation(
            device: device, scenario: scenario(charge: 0.5), cellSize: 0.2)
        var heldImpulse = SIMD3<Double>.zero
        var linear = SIMD3<Double>.zero
        var farGain = 0.0
        var nearLoss = 0.0
        let statics = [1.5, 1.5, 1.2, 1.2].map { weight * $0 / 5.4 }
        while free.air.time < 0.015 - 1e-8 {
            try held.advance(steps: 1, timeLimit: 0.015)
            try free.advance(steps: 1, timeLimit: 0.015)
            heldImpulse += held.lastImpulse
            linear += free.lastImpulse + free.lastGroundImpulse
            let loads = free.lastTyreLoads
            farGain = max(farGain, loads[0] + loads[2] - statics[0] - statics[2])
            nearLoss = max(nearLoss, statics[1] + statics[3] - loads[1] - loads[3])
        }
        #expect(held.position == (try scenario().rigidCars![0].makeBody().position))
        #expect(heldImpulse.y > 50)
        #expect(free.velocity.y > 0)
        #expect(farGain > 0 && nearLoss > 0)
        #expect(
            simd_length(1500 * free.velocity - linear - 1500 * free.air.time * free.gravity)
                < 1e-6 * simd_length(heldImpulse))
        #expect(abs(free.air.time - 0.015) < 1e-8)
    }

    @Test("The blast replay records finite frames with tyres and loads at the requested end time")
    func replay() throws {
        let recordings = try RigidCarDemo.coupledRecordings(
            device: device, charges: [(mass: 1, standoff: 1.5)], duration: 0.01)
        let recording = try #require(recordings.first)
        #expect(recordings.count == 1 && recording.view == "front")
        #expect(abs(try #require(recording.frames.last).time - 0.01) < 1e-8)
        #expect(recording.frames.count > 10)
        for frame in recording.frames {
            #expect(frame.speed.isFinite && frame.energy.isFinite && frame.tyres?.count == 4)
            #expect((frame.corners + (frame.tyres ?? [])).allSatisfy { $0.z >= -1e-5 })
        }
        #expect(recording.frames.dropFirst().allSatisfy { $0.tyreLoads?.count == 4 })
        #expect(recording.description.contains("0.20 m uniform air"))
    }

    @Test("The car driver needs exactly one car and nothing else that moves")
    func configuration() throws {
        var twoCars = try scenario()
        twoCars.rigidCars?.append(try .saloon(position: SIMD3(4, 2.5, 0)))
        var withBox = try scenario()
        withBox.rigidObjects = [
            try RigidObjectDefinition(
                name: "Box", shape: .box(size: SIMD3(repeating: 0.4)), position: SIMD3(1, 1, 0.2), mass: 1)
        ]
        var noCar = try scenario()
        noCar.rigidCars = []
        var afterburning = SolverConfiguration()
        afterburning.afterburning = true
        for (scene, config) in [
            (twoCars, SolverConfiguration()), (withBox, SolverConfiguration()),
            (noCar, SolverConfiguration()),
            (try scenario(), afterburning),
        ] {
            #expect(throws: ExperimentalRigidCarSimulation.Failure.self) {
                try ExperimentalRigidCarSimulation(
                    device: device, scenario: scene, cellSize: 0.2, configuration: config)
            }
        }
        // Ordinary loading leaves the car inert: no solid cells in the air.
        let ordinary = try BlastSolver(device: device, scenario: try scenario(), cellSize: 0.2)
        #expect(ordinary.fluidCellCount == ordinary.grid.cellCount)
    }
}
