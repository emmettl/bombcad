import Foundation
import Metal
import simd

/// Whether the shell solver's beams buckle: a straight steel strut, pinned at one end (clamped with
/// `clamped`) and clamped at the other, which is shortened at a set speed (a prescribed node keeps
/// its spin, so that end cannot turn), its
/// square section `side` wide, shortened slowly after a small lateral nudge. The axial force it
/// carries is set against Euler's load P_E = π² E I / L²: 2.046 P_E pinned and clamped, 4 P_E clamped
/// at both ends; and, where the strut is stocky enough to yield first, the squash load f_y A.
public enum BucklingStudy {
    public struct Result: Sendable {
        public var length: Float
        public var side: Float
        public var elementSize: Float
        public var beams: Int
        /// Largest axial force carried (N), and the shortening at it (m).
        public var peakForce: Float
        public var shorteningAtPeak: Float
        /// The middle's largest lateral displacement (m).
        public var lateral: Float
        public var euler: Float
        public var squash: Float
        /// Force against shortening, sampled.
        public var history: [SIMD2<Float>]
        /// Nodes held at each end.
        public var endNodes: Int = 0
    }

    /// `rate` is the end's speed (m/s), `shortening` how far to go (m); `yieldStress` nil keeps
    /// the steel elastic. `nudge` is the middle's initial lateral speed (m/s).
    public static func run(
        device: MTLDevice, length: Float = 3, side: Float = 0.05, elementSize: Float = 0.05,
        rate: Float = 0.02,
        shortening: Float = 0.006, yieldStress: Float? = nil, nudge: Float = 0.002, damping: Float = 20,
        clamped: Bool = false
    ) throws -> Result {
        let material = StructureMaterial(
            name: "Strut steel", density: 7850, youngsModulus: 210e9, poissonRatio: 0.3,
            yieldStress: yieldStress ?? 1e30, hardeningModulus: 0, failureStrain: 1e30)
        let half = side / 2
        var model = StructureModel(
            solids: [Box(min: SIMD3(0, -half, 1 - half), max: SIMD3(length, half, 1 + half))],
            material: material,
            elementSize: elementSize, fixedBase: false)
        model.elementKind = .shell
        let solver = try ShellSolver(device: device, model: model)
        solver.gravity = 0
        solver.groundContact = false
        solver.damping = damping
        let fixed = solver.nodes { $0.x < 1e-4 }
        let pushed = solver.nodes { $0.x > length - 1e-4 }
        let middle = solver.nearestNode(to: SIMD3(length / 2, 0, 1))
        let positions = solver.referencePositions
        solver.mutateNodes { nodes in
            for n in fixed { nodes[n].restrain(x: true, y: true, z: true, rotation: clamped) }
            for n in pushed {
                nodes[n].restrain(y: true, z: true)
                nodes[n].isPrescribed = true
                nodes[n].velocity = SIMD3(-rate, 0, 0)
            }
            // A half-sine of lateral speed, the first mode's shape.
            for n in nodes.indices where !fixed.contains(n) && !pushed.contains(n) {
                let x = positions[n].x
                nodes[n].velocity.z = nudge * sin(Float.pi * x / length)
            }
        }
        var history: [SIMD2<Float>] = []
        var peak: Float = 0
        var atPeak: Float = 0
        var lateral: Float = 0
        let stepsPerSample = max(1, Int(0.0005 / solver.criticalTimeStep))
        while Float(solver.time) * rate < shortening {
            solver.advance(steps: stepsPerSample)
            let force = pushed.reduce(Float(0)) { $0 + solver.nodalForce($1).x }
            let short = Float(solver.time) * rate
            history.append(SIMD2(short, abs(force)))
            if abs(force) > peak {
                peak = abs(force)
                atPeak = short
            }
            lateral = max(lateral, abs(solver.node(middle).displacement.z))
        }
        let inertia = side * side * side * side / 12
        return Result(
            length: length, side: side, elementSize: elementSize, beams: solver.beamCount, peakForce: peak,
            shorteningAtPeak: atPeak, lateral: lateral,
            euler: Float.pi * Float.pi * material.youngsModulus * inertia / (length * length),
            squash: (yieldStress ?? .infinity) * side * side, history: history, endNodes: fixed.count)
    }
}
