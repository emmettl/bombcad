import BlastModel
import Foundation
import Metal
import simd

extension BeamBenchmark {
    /// Bends the beam under displacement control until its centre has gone down by
    /// `deflection`, the loading plates descending at `rate` (m/s): slow against the beam's
    /// 16 ms period, and damped, so that the response is static.
    public static func run(
        device: MTLDevice, elementsThroughDepth: Int = 12, deflection: Float = 0.06, rate: Float = 0.1,
        unload: Bool = false, crackSlip: Bool = true,
        bondSlip: BondSlip? = nil,
        pressedInterlock: Bool = false,
        adjustModel: (inout StructureModel) -> Void = { _ in },
        adjust: (inout StructureMaterial) -> Void = { _ in },
        prepare: ((StructureSolver) -> Void)? = nil,
        sample: ((_ solver: StructureSolver, _ deflection: Float, _ moment: Float) -> Void)? = nil
    ) throws -> Result {
        var model = model(elementsThroughDepth: elementsThroughDepth)
        model.pressedInterlock = pressedInterlock
        adjustModel(&model)
        model.bondSlip = bondSlip
        model.crackSlip = crackSlip
        adjust(&model.material)
        let solver = try StructureSolver(device: device, model: model.loadedSlowly())
        solver.gravity = 0
        solver.groundContact = false
        solver.damping = 100
        prepare?(solver)

        let h = model.elementSize
        let overhang = (length - span) / 2
        let supports = [overhang, length - overhang].map { Int(($0 / h).rounded()) }
        let loads = [overhang + shearSpan, length - overhang - shearSpan].map { Int(($0 / h).rounded()) }
        // The load goes through plates 2 in wide: through one line of nodes it would crush the
        // elements beneath it on a fine mesh. They are on rollers, so that no arch or tie forms
        // between them; the beam is held lengthwise at one support only.
        let plate = Int((0.0254 / h).rounded())
        solver.mutateNodes { nodes in
            for j in 0...solver.ey {
                nodes[solver.nodeIndex(supports[0], j, 0)].restrain(x: true, z: true)
                nodes[solver.nodeIndex(supports[1], j, 0)].restrain(z: true)
                nodes[solver.nodeIndex(supports[0], j, 0)].restrain(y: j == 0)
                for centre in loads {
                    for i in (centre - plate)...(centre + plate) {
                        let n = solver.nodeIndex(i, j, solver.ez)
                        nodes[n].isPushedVertically = true
                        nodes[n].velocity = SIMD3(0, 0, -rate)
                    }
                }
            }
        }

        let start = ContinuousClock.now
        var curve: [SIMD2<Float>] = [.zero]
        let stepsPerSample = max(1, Int(0.00025 / rate * 0.1 / solver.criticalTimeStep))
        let middle = solver.ex / 2
        while curve.last!.x < deflection, solver.time < Double(1.5 * deflection / rate) {
            solver.advance(steps: stepsPerSample)
            // Each support carries half the load, and the moment between the loads is that
            // reaction times the shear span.
            var reaction: Float = 0
            for j in 0...solver.ey {
                for i in supports { reaction -= solver.nodalForce(i, j, 0).z }
            }
            let centre = -solver.displacement(middle, solver.ey / 2, 0).z
            curve.append(SIMD2(centre, 0.5 * reaction * shearSpan))
            sample?(solver, centre, 0.5 * reaction * shearSpan)
            if !centre.isFinite { break }
        }
        var residual: Float?
        if unload {
            // Draw the plates back up at the same rate until they no longer push, then let them go
            // and the beam settle.
            var plateNodes: [Int] = []
            for j in 0...solver.ey {
                for centre in loads {
                    for i in (centre - plate)...(centre + plate) {
                        plateNodes.append(solver.nodeIndex(i, j, solver.ez))
                    }
                }
            }
            solver.mutateNodes { nodes in
                for n in plateNodes { nodes[n].velocity = SIMD3(0, 0, rate) }
            }
            let limit = solver.time + Double(deflection / rate)
            while solver.time < limit {
                solver.advance(steps: stepsPerSample)
                var reaction: Float = 0
                for j in 0...solver.ey {
                    for i in supports { reaction -= solver.nodalForce(i, j, 0).z }
                }
                if reaction <= 0 { break }
            }
            solver.mutateNodes { nodes in
                for n in plateNodes {
                    nodes[n].isPushedVertically = false
                    nodes[n].velocity = .zero
                }
            }
            let settle = solver.time + 0.1
            while solver.time < settle { solver.advance(steps: stepsPerSample) }
            residual = -solver.displacement(middle, solver.ey / 2, 0).z
        }
        let elapsed = ContinuousClock.now - start
        let peak = curve.map(\.y).max() ?? 0
        let top = curve.firstIndex { $0.y == peak } ?? 0
        let failed = curve[top...].first { $0.y < 0.85 * peak }
        return Result(
            curve: curve, peakMoment: peak,
            failureDeflection: failed?.x,
            summary: solver.summary(), elementCount: solver.elementCount,
            wallSeconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18,
            residual: residual)
    }
}
