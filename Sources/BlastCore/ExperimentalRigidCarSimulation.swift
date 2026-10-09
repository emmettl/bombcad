import Foundation
import Metal
import simd

/// Explicit opt-in, synchronous CPU/Metal reference for one simplified car in ideal-gas air,
/// following `ExperimentalRigidBoxSimulation`. The air sees only the car's shell, a box held
/// clear of the ground, so the blast can reach the underside through the gap; the tyres are
/// contact points only and do not obstruct the air. The air's impulse and torque about the
/// centre of mass drive `RigidCarBody`, whose four tyres carry the ground contact. Shares the
/// box path's limits: whole-cell remapping, numerical wall tractions, no chemistry or scenery.
public final class ExperimentalRigidCarSimulation {
    public typealias Failure = ExperimentalRigidBoxSimulation.Failure
    public typealias Motion = ExperimentalRigidBoxSimulation.Motion
    public let air: BlastSolver
    public let definition: RigidCarDefinition
    public let motion: Motion
    public var gravity = SIMD3<Double>(0, 0, -9.81)
    public var remapMode: ExperimentalBoxRemap = .redistribution {
        didSet {
            air.experimentalBoxRemapMode = remapMode
            air.refinement?.boxRemapMode = remapMode
        }
    }
    private var car: RigidCarBody
    /// World position of the centre of mass.
    public var position: SIMD3<Double> { car.position }
    public var orientation: SIMD4<Double> { car.body.orientation.vector }
    public var velocity: SIMD3<Double> { car.linearVelocity }
    public var angularVelocity: SIMD3<Double> { car.angularVelocity }
    public var angularMomentum: SIMD3<Double> { car.body.angularMomentum }
    /// Shell corners, as `RigidBoxBody.corners`.
    public var corners: [SIMD3<Double>] { car.body.corners }
    /// Tyre contact points: FL, FR, RL, RR.
    public var tyres: [SIMD3<Double>] { car.tyrePoints }
    public var mechanicalEnergy: Double {
        car.kineticEnergy - car.mass * simd_dot(gravity, car.position)
    }
    public private(set) var lastImpulse = SIMD3<Double>.zero
    public private(set) var lastAngularImpulse = SIMD3<Double>.zero
    /// Contact impulse alone, tyres and shell; gravity is accounted for separately.
    public private(set) var lastGroundImpulse = SIMD3<Double>.zero
    public private(set) var lastGroundAngularImpulse = SIMD3<Double>.zero
    /// Mean normal force on each tyre over the last step (N): FL, FR, RL, RR.
    public private(set) var lastTyreLoads = [Double](repeating: 0, count: 4)
    /// Wall-clock seconds so far in the air solver's steps, in moving the shell through the air
    /// (masks, remapping, gathering impulses) and in the car's contact mechanics.
    public private(set) var timings = Timings()
    public struct Timings: Codable, Sendable {
        public var air = 0.0
        public var coupling = 0.0
        public var mechanics = 0.0
    }

    public init(
        device: MTLDevice, scenario: Scenario, cellSize: Float,
        configuration: SolverConfiguration = SolverConfiguration(), motion: Motion = .free
    ) throws {
        guard let cars = scenario.rigidCars, cars.count == 1, scenario.rigidObjects?.isEmpty ?? true,
            scenario.structure == nil,
            [0, 1, 2, 4].contains(configuration.refinement),
            !configuration.afterburning,
            configuration.airModel == .idealGas, configuration.twoWayCoupling, configuration.movingWalls
        else { throw Failure.unsupportedConfiguration }
        definition = cars[0]
        car = try definition.makeBody()
        self.motion = motion
        var config = configuration
        config.skipStillAir = false
        config.mappedCharge = false
        var initial = scenario
        initial.charge.mass = 0
        initial.additionalCharges = nil
        air = try BlastSolver(device: device, scenario: initial, cellSize: cellSize, configuration: config)
        try air.installExperimentalBox(car.body)
        air.deposit(scenario.charge)
        for charge in scenario.additionalCharges ?? [] { air.deposit(charge) }
        air.restart()
        try air.checkExperimentalBoxRefinement()
        air.removeExperimentalBoxPackedGas()
    }

    public func applyImpulse(_ impulse: SIMD3<Double>, at point: SIMD3<Double>? = nil) throws {
        guard motion == .free else { throw Failure.unsupportedConfiguration }
        car.applyImpulse(impulse, at: point)
        try air.updateExperimentalBox(car.body)
    }

    public func applyAngularImpulse(_ impulse: SIMD3<Double>) throws {
        guard motion == .free else { throw Failure.unsupportedConfiguration }
        car.applyAngularImpulse(impulse)
        try air.updateExperimentalBox(car.body)
    }

    /// Always step through this driver, not air.advance: each GPU step is followed by a car step.
    public func advance(steps: Int, timeLimit: Double? = nil) throws {
        precondition(steps >= 0)
        var clock = Date.timeIntervalSinceReferenceDate
        func lap(_ phase: WritableKeyPath<Timings, Double>) {
            let now = Date.timeIntervalSinceReferenceDate
            timings[keyPath: phase] += now - clock
            clock = now
        }
        for _ in 0..<steps {
            try air.checkExperimentalBoxRefinement()
            try air.clearExperimentalBoxImpulse()
            lap(\.coupling)
            let result = air.advance(steps: 1, timeLimit: timeLimit)
            lap(\.air)
            if let timeLimit, result.elapsed == 0, air.time >= timeLimit - 1e-8 { return }
            guard result.isStable, result.elapsed > 0 else { throw Failure.unstable }
            let impulses = air.experimentalBoxImpulses()
            lastImpulse = impulses.linear
            lastAngularImpulse = impulses.angular
            lastGroundImpulse = .zero
            lastGroundAngularImpulse = .zero
            lastTyreLoads = [0, 0, 0, 0]
            lap(\.coupling)
            guard motion == .free else { continue }
            var next = car
            next.applyImpulse(impulses.linear)
            next.applyAngularImpulse(impulses.angular)
            let centre = next.position
            let contacts = next.advanceWithGround(
                by: result.elapsed, ground: definition.ground, gravity: gravity)
            lap(\.mechanics)
            try air.updateExperimentalBox(next.body)
            lap(\.coupling)
            for contact in contacts {
                let impulse = SIMD3(contact.tangent.x, contact.tangent.y, contact.normal)
                lastGroundImpulse += impulse
                lastGroundAngularImpulse += simd_cross(contact.point - centre, impulse)
                if case .tyre(let n) = contact.location {
                    lastTyreLoads[n] += contact.normal / result.elapsed
                }
            }
            car = next
        }
    }
}
