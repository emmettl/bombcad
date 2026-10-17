import Foundation
import Metal
import simd

/// A structure meshed as shells and beams, stood under gravity alone for a while, damped, and
/// judged: does it stand, stand but still deflect, or fall? The IFC corpus judges imported
/// buildings this way (docs/ifc-import-corpus.md, "Under gravity"), and the layouts are held to it.
public struct GravityCheck: Sendable {
    public enum Verdict: String, Sendable, Equatable {
        /// The supports carry at least 95% of the weight.
        case stands
        /// Less is carried yet, but what moves is coming to rest.
        case deflects
        /// What moves keeps moving, near the speed of a body falling against the damping.
        case falls
    }

    /// The supports' reaction (connections' and clamps') over the weight.
    public var carried: Float
    /// The share of the weight on nodes that moved under 10 mm.
    public var still: Float
    /// The mean speed (m/s) of the weight that moved over 10 mm, at five-sixths of the time and
    /// at its end.
    public var settling: (early: Float, late: Float)
    /// The largest displacement (m), and the elements that failed.
    public var peak: Float
    public var eroded: Int
    public var weight: Float

    /// Mass-proportional damping (1/s), and how long (s) the structure is stood.
    public static let damping: Float = 50
    public static let duration = 0.3
    /// g over the damping rate: the speed a body falling against the damping keeps.
    public static let fallingSpeed = 9.81 / damping

    public var verdict: Verdict {
        if carried >= 0.95 { return .stands }
        return settling.late < 0.5 * Self.fallingSpeed && settling.late <= settling.early ? .deflects : .falls
    }

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
