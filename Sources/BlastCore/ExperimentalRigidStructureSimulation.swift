import Foundation
import Metal
import simd

/// Explicit opt-in, synchronous reference for freestanding objects striking deformable
/// structures, without air: the scenario's rigid objects and cars move in `RigidBodyWorld` and
/// strike the solid elements or shells of any of its structures, all stepped together at the
/// shortest of the structures' time steps.
///
/// After each structure step the nodes near a member are handed to the world as point masses
/// (a shell's as spheres of half its thickness); the members' faces strike them with inelastic,
/// frictional impulses, equal and opposite, and the nodes' new velocities go back to the
/// structure. Contact so conserves the momentum of members and structures together and cannot add
/// kinetic energy; positional corrections move only the members. Nodes held along any axis, or
/// moved as set, are immovable. A solid's interior nodes (all eight elements around them intact)
/// are left out, as in the structure's own contact. A member's corner pressed into a face between
/// nodes is not found: the structures' elements should be smaller than the members' faces. The
/// structures do not meet each other here; they do through the air solver's contact.
public final class ExperimentalRigidStructureSimulation {
    public enum Structure {
        case solid(StructureSolver)
        case shell(ShellSolver)
        case mixed(MixedStructure)
    }

    public enum Failure: Error {
        case noStructure, noObjects
    }

    /// The scenario's structures, in its order.
    public let structures: [Structure]
    /// The first structure.
    public var structure: Structure { structures[0] }
    public let names: [String]
    public var gravity = SIMD3<Double>(0, 0, -9.81) {
        didSet { setStructureGravity() }
    }
    /// Whether the members touch the ground.
    public var ground = true
    /// Whether the structures touch the ground.
    public var structuresTouchGround = true {
        didSet {
            for part in parts {
                switch part.part {
                case .solid(let solver): solver.groundContact = structuresTouchGround
                case .shell(let solver): solver.groundContact = structuresTouchGround
                }
            }
        }
    }
    public private(set) var time = 0.0
    public private(set) var stepCount = 0
    /// Impulse the members gave the structure over the last step and since the start (N s).
    public private(set) var lastReaction = SIMD3<Double>.zero
    public private(set) var reaction = SIMD3<Double>.zero
    /// Kinetic energy contact has changed since the start: the members' (a loss, negative) and
    /// the structure's nodes' (J). Their sum is what contact dissipated, never positive.
    public private(set) var contactWork = (members: 0.0, structure: 0.0)
    /// Wall-clock seconds in the structure solver, and in contact and motion.
    public private(set) var timings = (structure: 0.0, mechanics: 0.0)

    private var world: RigidBodyWorld
    private let carCount: Int
    /// The structures' parts that have nodes: their solvers, and each node's reference position
    /// and radius.
    private enum Part {
        case solid(StructureSolver)
        case shell(ShellSolver)
    }
    private let parts: [(part: Part, references: [SIMD3<Double>], radii: [Double])]
    /// The step every structure takes.
    public let timeStep: Double

    /// `friction` is the structures' against the members, static and sliding; a pair takes the
    /// smaller coefficients.
    public init(
        device: MTLDevice, scenario: Scenario, friction: (static: Double, sliding: Double) = (0.6, 0.5)
    ) throws {
        let models = scenario.structuralObjects.compactMap(\.structure)
        guard !models.isEmpty else { throw Failure.noStructure }
        world = try RigidBodyWorld(scenario: scenario)
        guard !world.members.isEmpty else { throw Failure.noObjects }
        world.nodeFriction = RigidBoxBody.Ground(
            staticFriction: friction.static, slidingFriction: friction.sliding)
        names = (scenario.rigidObjects ?? []).map(\.name) + (scenario.rigidCars ?? []).map(\.name)
        carCount = scenario.rigidCars?.count ?? 0
        var structures: [Structure] = []
        var parts: [(part: Part, references: [SIMD3<Double>], radii: [Double])] = []
        func shellPart(_ solver: ShellSolver) {
            var radius = [Double](repeating: 0, count: solver.nodeCount)
            for element in solver.mesh.elements {
                for a in 0..<4 {
                    let n = Int(element.nodes[a])
                    radius[n] = max(radius[n], Double(element.thickness) / 2)
                }
            }
            for beam in solver.mesh.beams {
                for a in 0..<2 {
                    let n = Int(beam.nodes[a])
                    radius[n] = max(radius[n], Double(beam.section.max()) / 2)
                }
            }
            parts.append((.shell(solver), solver.mesh.positions.map(SIMD3<Double>.init), radius))
        }
        func solidPart(_ solver: StructureSolver) {
            var positions = [SIMD3<Double>](repeating: .zero, count: solver.nodeCount)
            for k in 0...solver.ez {
                for j in 0...solver.ey {
                    for i in 0...solver.ex {
                        if let n = solver.storedNode(i, j, k) {
                            positions[n] = SIMD3<Double>(solver.referencePosition(i, j, k))
                        }
                    }
                }
            }
            parts.append((.solid(solver), positions, Array(repeating: 0, count: solver.nodeCount)))
        }
        for model in models {
            if model.isMixed {
                let mixed = try MixedStructure(device: device, model: model)
                structures.append(.mixed(mixed))
                solidPart(mixed.solids)
                shellPart(mixed.shells)
            } else if model.elementKind == .shell {
                let solver = try ShellSolver(device: device, model: model)
                structures.append(.shell(solver))
                shellPart(solver)
            } else {
                let solver = try StructureSolver(device: device, model: model)
                structures.append(.solid(solver))
                solidPart(solver)
            }
        }
        self.structures = structures
        self.parts = parts
        // Every structure takes the shortest of their steps, so that they keep time together.
        let step = parts.map { part -> Float in
            switch part.part {
            case .solid(let solver): solver.criticalTimeStep
            case .shell(let solver): solver.criticalTimeStep
            }
        }.min()!
        for part in parts {
            switch part.part {
            case .solid(let solver): solver.stepOverride = step
            case .shell(let solver): solver.stepOverride = step
            }
        }
        timeStep = Double(step)
        setStructureGravity()
    }

    private func setStructureGravity() {
        for part in parts {
            switch part.part {
            case .solid(let solver): solver.gravity = Float(-gravity.z)
            case .shell(let solver): solver.gravity = Float(-gravity.z)
            }
        }
    }

    public var count: Int { world.members.count }

    public var members: [ExperimentalRigidWorldSimulation.Member] {
        world.members.enumerated().map { n, member in
            ExperimentalRigidWorldSimulation.Member(
                name: names[n], isCar: n >= world.members.count - carCount, corners: member.body.corners,
                tyres: member.supports.map(member.body.worldPoint), centreOfMass: member.body.position,
                velocity: member.body.linearVelocity, orientation: member.body.orientation.vector)
        }
    }

    public var linearMomentum: SIMD3<Double> { world.linearMomentum }
    public var kineticEnergy: Double { world.kineticEnergy }

    /// The momentum of all the structures together (kg m/s).
    public var structureMomentum: SIMD3<Double> {
        parts.reduce(.zero) { total, part in
            switch part.part {
            case .solid(let solver): total + solver.momentum()
            case .shell(let solver): total + solver.momentum()
            }
        }
    }

    public var structureKineticEnergy: Double {
        parts.reduce(0) { total, part in
            switch part.part {
            case .solid(let solver):
                var energy = 0.0
                solver.mutateNodes { nodes in
                    for node in nodes where node.mass > 0 {
                        energy += 0.5 * Double(node.mass) * Double(simd_length_squared(node.velocity))
                    }
                }
                return total + energy
            case .shell(let solver): return total + solver.kineticEnergy()
            }
        }
    }

    /// The largest displacement of any node of any structure (m).
    public var largestDisplacement: Double {
        var largest: Float = 0
        for part in parts {
            switch part.part {
            case .solid(let solver):
                solver.mutateNodes { nodes in
                    for node in nodes { largest = max(largest, simd_length(node.displacement)) }
                }
            case .shell(let solver):
                solver.mutateNodes { nodes in
                    for node in nodes { largest = max(largest, simd_length(node.displacement)) }
                }
            }
        }
        return Double(largest)
    }

    public func applyImpulse(_ impulse: SIMD3<Double>, to member: Int, at point: SIMD3<Double>? = nil) {
        world.applyImpulse(impulse, to: member, at: point)
    }

    /// The members' bounds, grown by their travel in a step and the thickest node.
    private func near(_ point: SIMD3<Double>, _ boxes: [(low: SIMD3<Double>, high: SIMD3<Double>)]) -> Bool {
        boxes.contains { all(point .>= $0.low) && all(point .<= $0.high) }
    }

    public func advance(steps: Int) {
        for _ in 0..<steps {
            var clock = Date.timeIntervalSinceReferenceDate
            func lap(_ phase: WritableKeyPath<(structure: Double, mechanics: Double), Double>) {
                let now = Date.timeIntervalSinceReferenceDate
                timings[keyPath: phase] += now - clock
                clock = now
            }
            let dt = timeStep
            for structure in structures {
                switch structure {
                case .solid(let solver): solver.advance(steps: 1)
                case .shell(let solver): solver.advance(steps: 1)
                case .mixed(let mixed): mixed.advance(steps: 1)
                }
            }
            lap(\.structure)
            let margin = 2 * (parts.flatMap(\.radii).max() ?? 0) + 1e-3
            let boxes = world.members.map { member -> (low: SIMD3<Double>, high: SIMD3<Double>) in
                let body = member.body
                let corners = body.corners
                let reach =
                    margin + 2 * dt
                    * (simd_length(body.linearVelocity) + simd_length(body.angularVelocity)
                        * simd_length(body.size))
                return (
                    corners.reduce(SIMD3(repeating: .infinity), simd_min) - reach,
                    corners.reduce(SIMD3(repeating: -.infinity), simd_max) + reach
                )
            }
            // Each node handed over: its part and index there.
            var indices: [(part: Int, node: Int)] = []
            var nodes: [RigidBodyWorld.Node] = []
            for (p, part) in parts.enumerated() {
                func gather(
                    _ n: Int, displacement: SIMD3<Float>, velocity: SIMD3<Float>, mass: Float, flags: UInt32
                ) {
                    let position = part.references[n] + SIMD3<Double>(displacement)
                    guard near(position, boxes) else { return }
                    let immovable = flags & 0b1111 != 0 || mass <= 0
                    indices.append((p, n))
                    nodes.append(
                        RigidBodyWorld.Node(
                            position: position, velocity: SIMD3<Double>(velocity),
                            inverseMass: immovable ? 0 : 1 / Double(mass), radius: part.radii[n]))
                }
                switch part.part {
                case .solid(let solver):
                    solver.mutateNodes { all in
                        for n in all.indices where all[n].flags & 32 == 0 {
                            gather(
                                n, displacement: all[n].displacement, velocity: all[n].velocity,
                                mass: all[n].mass, flags: all[n].flags)
                        }
                    }
                case .shell(let solver):
                    solver.mutateNodes { all in
                        for n in all.indices where all[n].flags & 128 == 0 {
                            gather(
                                n, displacement: all[n].displacement, velocity: all[n].velocity,
                                mass: all[n].mass, flags: all[n].flags)
                        }
                    }
                }
            }
            world.nodes = nodes
            let contacts = world.advance(by: dt, gravity: gravity, ground: ground)
            contactWork.members += world.lastContactWork.members
            contactWork.structure += world.lastContactWork.nodes
            lastReaction = .zero
            for contact in contacts {
                guard case .node = contact.other else { continue }
                lastReaction -= contact.normalImpulse * contact.normal + contact.tangentImpulse
            }
            reaction += lastReaction
            let struck = world.nodes
            func write(_ velocity: inout SIMD3<Float>, _ k: Int) {
                if struck[k].inverseMass > 0, struck[k].velocity != nodes[k].velocity {
                    velocity = SIMD3<Float>(struck[k].velocity)
                }
            }
            for (p, part) in parts.enumerated() {
                switch part.part {
                case .solid(let solver):
                    solver.mutateNodes { all in
                        for (k, at) in indices.enumerated() where at.part == p {
                            write(&all[at.node].velocity, k)
                        }
                    }
                case .shell(let solver):
                    solver.mutateNodes { all in
                        for (k, at) in indices.enumerated() where at.part == p {
                            write(&all[at.node].velocity, k)
                        }
                    }
                }
            }
            world.nodes = []
            time += dt
            stepCount += 1
            lap(\.mechanics)
        }
    }
}
