import BlastModel
import Foundation
import Metal
import simd

extension LaminatedShellTest {
    /// Runs the pane under `pressures` (Pa pushing it along -z, one a `step`) for `duration`.
    public static func run(
        device: MTLDevice, laminate: LaminatedGlass, a: Double, b: Double, edges: Edges,
        pressures: [Double], step: Double, duration: Double, elements: Int = 24,
        glass: StructureMaterial = .annealedGlass, sixtySecondStrength: Double? = nil,
        progress: ((String) -> Void)? = nil
    ) throws -> Result {
        let model = model(
            laminate, a: a, b: b, edges: edges, elements: elements, glass: glass,
            sixtySecondStrength: sixtySecondStrength)
        let solver = try ShellSolver(device: device, model: model)
        solver.gravity = 0
        solver.groundContact = false
        let size = model.elementSize
        if edges == .pinned {
            let held = solver.nodes {
                $0.x < size / 4 || $0.y < size / 4 || $0.x > Float(a) - size / 4 || $0.y > Float(b) - size / 4
            }
            solver.mutateNodes { nodes in for n in held { nodes[n].restrain(x: true, y: true, z: true) } }
        }
        // The load as at most 256 points of its table.
        let stride = max(1, Int((Double(pressures.count) / 250).rounded(.up)))
        var history: [SIMD2<Float>] = []
        for i in Swift.stride(from: 0, to: pressures.count, by: stride) {
            history.append(SIMD2(Float((Double(i) + 0.5) * step), Float(pressures[i])))
        }
        history.append(SIMD2(Float(Double(pressures.count) * step), 0))
        solver.appliedLoad = PressureLoad(axis: 2, positiveSide: true, history: history)
        let centre = solver.nearestNode(
            to: SIMD3(Float(a / 2), Float(b / 2), 1 + Float(laminate.thickness) / 2))
        var result = Result(
            crackedAt: nil, peak: 0, removed: 0, releasedAt: nil, speedAtRelease: nil,
            sdof: EnvelopePanel.laminatedGlass(laminate, a: a, b: b, sixtySecondStrength: sixtySecondStrength)
                .response(pressures: pressures, step: step))
        let chunk = max(1, Int(5e-5 / Double(solver.criticalTimeStep)))
        var time = 0.0
        while time < duration {
            solver.advance(steps: chunk)
            time += Double(chunk) * Double(solver.criticalTimeStep)
            let summary = solver.summary()
            if result.crackedAt == nil, solver.hasFragmented(0) { result.crackedAt = time }
            let node = solver.node(centre)
            if result.releasedAt == nil {
                result.peak = max(result.peak, Double(-node.displacement.z))
                if edges == .silicone, solver.releasedSpringShare() >= 0.5 {
                    result.releasedAt = time
                    result.speedAtRelease = Double(abs(node.vz))
                }
            }
            result.removed = summary.erodedElements
            if summary.hasBlownUp { break }
        }
        progress?(String(format: "%.1f ms", time * 1e3))
        return result
    }
}
