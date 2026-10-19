import BlastModel
import Foundation
import Metal
import simd

extension GravityCheck {
    /// Stands `model` (meshed as shells) under gravity for `duration`, damped at `damping`;
    /// `inspect` sees the solver at the end.
    public static func run(
        _ model: StructureModel, device: MTLDevice, duration: Double = duration, damping: Float = damping,
        inspect: (ShellSolver) -> Void = { _ in }
    ) throws -> GravityCheck {
        let solver = try ShellSolver(device: device, model: model)
        solver.damping = damping
        // The mean speed of the weight on nodes not tied to others that moved over 10 mm.
        func moving() -> Float {
            var weight: Float = 0
            var momentum: Float = 0
            solver.mutateNodes { nodes in
                for node in nodes where node.flags & 128 == 0 && simd_length(node.displacement) >= 0.01 {
                    weight += node.mass
                    momentum += node.mass * simd_length(SIMD3(node.vx, node.vy, node.vz))
                }
            }
            return weight > 0 ? momentum / weight : 0
        }
        let steps = Int(duration / Double(solver.criticalTimeStep))
        solver.advance(steps: steps * 5 / 6)
        let early = moving()
        solver.advance(steps: steps - steps * 5 / 6)
        let late = moving()
        // A tied node's mass is added to its master's, so it is counted once, there.
        var mass: Float = 0
        var held: Float = 0
        var clamped: Float = 0
        solver.mutateNodes { nodes in
            for n in nodes.indices where nodes[n].flags & 128 == 0 {
                mass += nodes[n].mass
                if simd_length(nodes[n].displacement) < 0.01 { held += nodes[n].mass }
                if nodes[n].isClamped { clamped -= solver.nodalForce(n).z }
            }
        }
        let weight = mass * solver.gravity
        let summary = solver.summary()
        let reaction = (solver.anchorSummary()?.reaction.z ?? 0) + clamped
        inspect(solver)
        return GravityCheck(
            carried: weight > 0 ? reaction / weight : 0, still: mass > 0 ? held / mass : 0,
            settling: (early, late), peak: summary.maxDisplacement, eroded: summary.erodedElements,
            weight: weight)
    }
}
