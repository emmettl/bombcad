import Metal
import simd

/// Explicit opt-in, synchronous CPU/Metal reference for one rigid box in ideal-gas air.
/// Existing BlastSolver/scenario loading does not enable this path. Not a production backend.
/// Gas impulses use numerical wall tractions; whole-cell remapping is conservative but can
/// introduce local pressure artefacts. Uniform and adaptive air support free translation and
/// rotation, with fine-level conservative remapping. Chemistry and scenery contact are rejected.
public final class ExperimentalRigidBoxSimulation {
    public enum Failure: Error {
        case unsupportedConfiguration, outsideDomain, sceneryCollision, unresolvedBox, remap, unstable
    }
    public enum Motion { case free, held }
    public let air: BlastSolver
    public let definition: RigidObjectDefinition
    public let motion: Motion
    public var remapMode: ExperimentalBoxRemap = .redistribution {
        didSet {
            air.experimentalBoxRemapMode = remapMode
            air.refinement?.boxRemapMode = remapMode
        }
    }
    public var recordsRemapTimings = false {
        didSet { air.refinement?.measureBoxRemap = recordsRemapTimings }
    }
    public var remapTimings: [String: Double] { air.refinement?.boxRemapProfile ?? [:] }
    public var gravity = SIMD3<Double>(0, 0, -9.81)
    private var body: RigidBoxBody
    public var position: SIMD3<Double> { body.position }
    public var orientation: SIMD4<Double> { body.orientation.vector }
    public var velocity: SIMD3<Double> { body.linearVelocity }
    public var angularMomentum: SIMD3<Double> { body.angularMomentum }
    public var corners: [SIMD3<Double>] { body.corners }
    public var mechanicalEnergy: Double { body.kineticEnergy - body.mass * simd_dot(gravity, body.position) }
    public private(set) var lastImpulse = SIMD3<Double>.zero
    public private(set) var lastAngularImpulse = SIMD3<Double>.zero
    /// Contact impulse alone; gravity is accounted for separately.
    public private(set) var lastGroundImpulse = SIMD3<Double>.zero
    public private(set) var lastGroundAngularImpulse = SIMD3<Double>.zero

    public init(
        device: MTLDevice, scenario: Scenario, cellSize: Float,
        configuration: SolverConfiguration = SolverConfiguration(), motion: Motion = .free
    ) throws {
        guard let objects = scenario.rigidObjects, objects.count == 1, scenario.structure == nil,
            [0, 1, 2, 4].contains(configuration.refinement),
            !configuration.afterburning,
            configuration.airModel == .idealGas, configuration.twoWayCoupling, configuration.movingWalls
        else { throw Failure.unsupportedConfiguration }
        self.definition = objects[0]
        self.body = try definition.makeBody()
        self.motion = motion
        var config = configuration
        config.skipStillAir = false
        config.mappedCharge = false
        var initial = scenario
        initial.charge.mass = 0
        initial.additionalCharges = nil
        air = try BlastSolver(device: device, scenario: initial, cellSize: cellSize, configuration: config)
        try air.installExperimentalBox(body)
        air.deposit(scenario.charge)
        for charge in scenario.additionalCharges ?? [] { air.deposit(charge) }
        air.restart()
        try air.checkExperimentalBoxRefinement()
        air.removeExperimentalBoxPackedGas()
    }

    public func applyImpulse(_ impulse: SIMD3<Double>, at point: SIMD3<Double>? = nil) throws {
        guard motion == .free else { throw Failure.unsupportedConfiguration }
        body.applyImpulse(impulse, at: point)
        try air.updateExperimentalBox(body)
    }

    /// Always step through this driver, not air.advance: each GPU step is followed by a body step.
    public func advance(steps: Int, timeLimit: Double? = nil) throws {
        precondition(steps >= 0)
        for _ in 0..<steps {
            try air.checkExperimentalBoxRefinement()
            try air.clearExperimentalBoxImpulse()
            let result = air.advance(steps: 1, timeLimit: timeLimit)
            if let timeLimit, result.elapsed == 0, air.time >= timeLimit - 1e-8 { return }
            guard result.isStable, result.elapsed > 0 else { throw Failure.unstable }
            let impulses = air.experimentalBoxImpulses()
            lastImpulse = impulses.linear
            lastAngularImpulse = impulses.angular
            lastGroundImpulse = .zero
            lastGroundAngularImpulse = .zero
            if motion == .free {
                var next = body
                next.applyImpulse(impulses.linear)
                next.applyAngularImpulse(impulses.angular)
                let centre = next.position
                let contacts = next.advanceWithGround(
                    by: result.elapsed, ground: definition.ground, gravity: gravity)
                try air.updateExperimentalBox(next)
                for contact in contacts {
                    let impulse = SIMD3(contact.tangent.x, contact.tangent.y, contact.normal)
                    lastGroundImpulse += impulse
                    lastGroundAngularImpulse += simd_cross(contact.point - centre, impulse)
                }
                body = next
            }
        }
    }
}
