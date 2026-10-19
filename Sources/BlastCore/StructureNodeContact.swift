import Foundation
import simd

/// The nodes of the air's structures that freestanding members strike
/// (`ExperimentalRigidWorldSimulation`), as `ExperimentalRigidStructureSimulation` hands them to
/// `RigidBodyWorld` without air: after the structure's step, each node near a member goes to the
/// world as a point mass (a shell's as a sphere of half its thickness, a beam's of half its
/// section's larger side), and the velocities the members' faces give them come back. Nodes held
/// along any axis, or moved as set, are immovable; a solid's interior nodes are left out.
struct StructureNodeContact {
    enum Part {
        case solid(StructureSolver)
        case shell(ShellSolver)
    }

    private var parts: [(part: Part, references: [SIMD3<Double>], radii: [Double])] = []
    /// The structures' extents as built.
    private var bounds: [Box] = []
    /// The structures' shortest step (s).
    private(set) var step: Float = .infinity
    /// Each node handed over in the last `gather`: its part and index there.
    private var handed: [(part: Int, node: Int)] = []

    init(_ bodies: [StructuralBody]) {
        for body in bodies {
            bounds.append(body.model.bounds)
            step = min(step, body.criticalTimeStep)
            if let solids = body.solids { addSolid(solids) }
            if let shells = body.shells { addShell(shells) }
        }
    }

    private mutating func addShell(_ solver: ShellSolver) {
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

    private mutating func addSolid(_ solver: StructureSolver) {
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

    /// Whether any of `bodies` lies within `margin` (m) of a structure as built.
    func isNear(_ bodies: [RigidBoxBody], margin: Double) -> Bool {
        guard !bounds.isEmpty else { return false }
        return bodies.contains { body in
            let corners = body.corners
            let low = corners.reduce(SIMD3(repeating: .infinity), simd_min) - margin
            let high = corners.reduce(SIMD3(repeating: -.infinity), simd_max) + margin
            return bounds.contains { box in
                all(SIMD3<Double>(box.min) .<= high) && all(low .<= SIMD3<Double>(box.max))
            }
        }
    }

    /// The nodes within reach of `bodies` over a step of `step` (s), as the world's point masses.
    mutating func gather(_ bodies: [RigidBoxBody], step: Double) -> [RigidBodyWorld.Node] {
        handed = []
        guard !parts.isEmpty else { return [] }
        let margin = 2 * (parts.flatMap(\.radii).max() ?? 0) + 1e-3
        let boxes = bodies.map { body -> (low: SIMD3<Double>, high: SIMD3<Double>) in
            let corners = body.corners
            let reach =
                margin + 2 * step
                * (simd_length(body.linearVelocity) + simd_length(body.angularVelocity)
                    * simd_length(body.size))
            return (
                corners.reduce(SIMD3(repeating: .infinity), simd_min) - reach,
                corners.reduce(SIMD3(repeating: -.infinity), simd_max) + reach
            )
        }
        var nodes: [RigidBodyWorld.Node] = []
        for (p, part) in parts.enumerated() {
            func take(
                _ n: Int, displacement: SIMD3<Float>, velocity: SIMD3<Float>, mass: Float, flags: UInt32
            ) {
                let position = part.references[n] + SIMD3<Double>(displacement)
                guard boxes.contains(where: { all(position .>= $0.low) && all(position .<= $0.high) }) else {
                    return
                }
                let immovable = flags & 0b1111 != 0 || mass <= 0
                handed.append((p, n))
                nodes.append(
                    RigidBodyWorld.Node(
                        position: position, velocity: SIMD3<Double>(velocity),
                        inverseMass: immovable ? 0 : 1 / Double(mass), radius: part.radii[n]))
            }
            switch part.part {
            case .solid(let solver):
                solver.mutateNodes { all in
                    for n in all.indices where all[n].flags & 32 == 0 {
                        take(
                            n, displacement: all[n].displacement, velocity: all[n].velocity,
                            mass: all[n].mass,
                            flags: all[n].flags)
                    }
                }
            case .shell(let solver):
                solver.mutateNodes { all in
                    for n in all.indices where all[n].flags & 128 == 0 {
                        take(
                            n, displacement: all[n].displacement, velocity: all[n].velocity,
                            mass: all[n].mass,
                            flags: all[n].flags)
                    }
                }
            }
        }
        return nodes
    }

    /// Gives the nodes struck in the world's step their new velocities.
    func write(_ struck: [RigidBodyWorld.Node], over original: [RigidBodyWorld.Node]) {
        guard !handed.isEmpty else { return }
        for (p, part) in parts.enumerated() {
            func update(_ velocity: inout SIMD3<Float>, _ k: Int) {
                if struck[k].inverseMass > 0, struck[k].velocity != original[k].velocity {
                    velocity = SIMD3<Float>(struck[k].velocity)
                }
            }
            switch part.part {
            case .solid(let solver):
                solver.mutateNodes { all in
                    for (k, at) in handed.enumerated() where at.part == p {
                        update(&all[at.node].velocity, k)
                    }
                }
            case .shell(let solver):
                solver.mutateNodes { all in
                    for (k, at) in handed.enumerated() where at.part == p {
                        update(&all[at.node].velocity, k)
                    }
                }
            }
        }
    }
}
