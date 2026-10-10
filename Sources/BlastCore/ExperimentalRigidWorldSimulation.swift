import Foundation
import Metal
import simd

/// Explicit opt-in, synchronous reference for several freestanding objects around a charge: the
/// scenario's rigid objects and cars move and collide together in `RigidBodyWorld`, among its
/// rigid blocks, and those chosen, by default all of them, are also in the air and driven by it
/// as in `ExperimentalRigidBoxSimulation` and `ExperimentalRigidCarSimulation`: each is a moving
/// boundary of the air with its own patches, shields and reflects onto the others, and takes the
/// load of the faces it owns.
///
/// Any left out of the air take no load from it and do not obstruct it: the blast passes through
/// them and their own motion comes only from contact.
public final class ExperimentalRigidWorldSimulation {
    public typealias Failure = ExperimentalRigidBoxSimulation.Failure
    public typealias Motion = ExperimentalRigidBoxSimulation.Motion
    public typealias Timings = ExperimentalRigidCarSimulation.Timings

    public struct Member: Sendable, Codable {
        public let name: String
        public let isCar: Bool
        public let corners: [SIMD3<Double>]
        /// Tyre contact points, for cars: FL, FR, RL, RR.
        public let tyres: [SIMD3<Double>]
        public let centreOfMass: SIMD3<Double>
        public let velocity: SIMD3<Double>
        public let orientation: SIMD4<Double>
        /// Angle between the body's up axis and the vertical (degrees).
        public var tilt: Double {
            acos(min(1, max(-1, simd_quatd(vector: orientation).act(SIMD3<Double>(0, 0, 1)).z))) * 180 / .pi
        }
    }

    public let air: BlastSolver
    public let motion: Motion
    /// The members in the air, in order.
    public let coupled: [Int]
    public let names: [String]
    public var gravity = SIMD3<Double>(0, 0, -9.81)
    private var world: RigidBodyWorld
    private let carCount: Int
    /// The air's impulse over the last step on all the members together, and on each.
    public private(set) var lastImpulse = SIMD3<Double>.zero
    public private(set) var lastAngularImpulse = SIMD3<Double>.zero
    public private(set) var lastAirImpulses: [SIMD3<Double>] = []
    public private(set) var lastAirAngularImpulses: [SIMD3<Double>] = []
    /// Contact impulse on each member over the last step: ground, blocks and other members.
    public private(set) var lastContactImpulses: [SIMD3<Double>] = []
    public private(set) var timings = Timings()

    public init(
        device: MTLDevice, scenario: Scenario, cellSize: Float,
        configuration: SolverConfiguration = SolverConfiguration(), motion: Motion = .free,
        coupled: [Int]? = nil
    ) throws {
        let objects = scenario.rigidObjects ?? []
        let cars = scenario.rigidCars ?? []
        guard objects.count + cars.count >= 1, scenario.structure == nil,
            [0, 1, 2, 4].contains(configuration.refinement),
            !configuration.afterburning,
            configuration.airModel == .idealGas, configuration.twoWayCoupling, configuration.movingWalls
        else { throw Failure.unsupportedConfiguration }
        let built = try RigidBodyWorld(scenario: scenario)
        world = built
        names = objects.map(\.name) + cars.map(\.name)
        carCount = cars.count
        self.coupled = Array(Set(coupled ?? Array(built.members.indices))).sorted()
        guard !self.coupled.isEmpty, self.coupled.allSatisfy(built.members.indices.contains) else {
            throw Failure.unsupportedConfiguration
        }
        self.motion = motion
        var config = configuration
        config.skipStillAir = false
        config.mappedCharge = false
        var initial = scenario
        initial.charge.mass = 0
        initial.additionalCharges = nil
        initial.rigidObjects = nil
        initial.rigidCars = nil
        air = try BlastSolver(device: device, scenario: initial, cellSize: cellSize, configuration: config)
        try air.installExperimentalBoxes(self.coupled.map { built.members[$0].body })
        air.deposit(scenario.charge)
        for charge in scenario.additionalCharges ?? [] { air.deposit(charge) }
        air.restart()
        try air.checkExperimentalBoxRefinement()
        air.removeExperimentalBoxPackedGas()
        lastContactImpulses = Array(repeating: .zero, count: built.members.count)
        lastAirImpulses = lastContactImpulses
        lastAirAngularImpulses = lastContactImpulses
    }

    /// The member nearest the charge, for coupling one object alone.
    public static func nearest(in scenario: Scenario) throws -> Int {
        let world = try RigidBodyWorld(scenario: scenario)
        let charge = SIMD3<Double>(scenario.charge.position)
        guard
            let nearest = world.members.indices.min(by: {
                simd_distance(world.members[$0].body.worldPoint(.zero), charge)
                    < simd_distance(world.members[$1].body.worldPoint(.zero), charge)
            })
        else { throw Failure.unsupportedConfiguration }
        return nearest
    }

    public var count: Int { world.members.count }

    public var members: [Member] {
        world.members.enumerated().map { n, member in
            Member(
                name: names[n], isCar: n >= world.members.count - carCount, corners: member.body.corners,
                tyres: member.supports.map(member.body.worldPoint), centreOfMass: member.body.position,
                velocity: member.body.linearVelocity, orientation: member.body.orientation.vector)
        }
    }

    public var linearMomentum: SIMD3<Double> { world.linearMomentum }

    public func applyImpulse(_ impulse: SIMD3<Double>, to member: Int, at point: SIMD3<Double>? = nil) throws
    {
        guard motion == .free else { throw Failure.unsupportedConfiguration }
        world.applyImpulse(impulse, to: member, at: point)
        if coupled.contains(member) {
            try air.updateExperimentalBoxes(coupled.map { world.members[$0].body })
        }
    }
    public var kineticEnergy: Double { world.kineticEnergy }

    /// Always step through this driver: each air step is followed by a world step.
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
            let loads = air.experimentalBoxLoads()
            lastAirImpulses = Array(repeating: .zero, count: world.members.count)
            lastAirAngularImpulses = lastAirImpulses
            for (load, member) in zip(loads, coupled) {
                lastAirImpulses[member] = load.linear
                lastAirAngularImpulses[member] = load.angular
            }
            lastImpulse = loads.reduce(.zero) { $0 + $1.linear }
            lastAngularImpulse = loads.reduce(.zero) { $0 + $1.angular }
            lap(\.coupling)
            guard motion == .free else { continue }
            var next = world
            for (load, member) in zip(loads, coupled) {
                next.applyImpulse(load.linear, to: member)
                next.applyAngularImpulse(load.angular, to: member)
            }
            let contacts = next.advance(by: result.elapsed, gravity: gravity)
            lap(\.mechanics)
            try air.updateExperimentalBoxes(coupled.map { next.members[$0].body })
            lap(\.coupling)
            var contactImpulses = [SIMD3<Double>](repeating: .zero, count: next.members.count)
            for contact in contacts {
                let impulse = contact.normalImpulse * contact.normal + contact.tangentImpulse
                contactImpulses[contact.member] += impulse
                if case .member(let j) = contact.other { contactImpulses[j] -= impulse }
            }
            lastContactImpulses = contactImpulses
            world = next
        }
    }
}
