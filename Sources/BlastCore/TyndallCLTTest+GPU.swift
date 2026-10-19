import BlastModel
import Foundation
import Metal
import simd

extension TyndallCLTTest {
    public static func run(
        device: MTLDevice, test: Test, cellSize: Float = 0.25, refinement: Int = 2, elementSize: Float = 0.15,
        duration: Double = 0.25, pad: SIMD3<Float> = .zero,
        history: ((Double, Float, Float, [Float]) -> Void)? = nil,
        configure: ((inout SolverConfiguration) -> Void)? = nil,
        progress: ((String) -> Void)? = nil
    ) throws -> Result {
        let scenario = scenario(test, elementSize: elementSize, pad: pad)
        let x0 = 24 + pad.x
        let yc = 8 + pad.y
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: cellSize)
        // Pinned to the balloon until rerun on the mapped start (validation.md, "Still on the balloon start").
        solver.configuration = .recommended.balloonStart
        solver.configuration.refinement = refinement
        configure?(&solver.configuration)
        try solver.load(scenario)
        guard let shells = solver.shells else { throw BlastError.allocationFailed("shells") }
        let floor: Float = 12 * 12 * inch
        let first = shells.nearestNode(to: SIMD3(x0 + 0.05, yc, floor / 2))
        let second = shells.nearestNode(to: SIMD3(x0 + 0.05, yc, floor + 1.9))
        // Rest, under the building's own weight, settled before the blast.
        solver.settleStructures()
        let rest = (shells.node(first).displacement.x, shells.node(second).displacement.x)
        var firstFloor = SIMD2<Float>.zero
        var secondFloor = SIMD2<Float>.zero
        var nextReport = 0.02
        let started = Date()
        while solver.time < duration {
            let result = solver.advance(steps: 16, timeLimit: duration)
            if result.steps == 0 && !solver.airIsAsleep { break }
            // Inbound is away from the charge, along +x.
            let a = shells.node(first).displacement.x - rest.0
            let b = shells.node(second).displacement.x - rest.1
            history?(
                solver.time, a, b,
                solver.gaugeHistories.map { ($0.last?.pressure ?? 0) - scenario.atmosphere.pressure })
            firstFloor = SIMD2(max(firstFloor.x, a), min(firstFloor.y, a))
            secondFloor = SIMD2(max(secondFloor.x, b), min(secondFloor.y, b))
            if let progress, solver.time >= nextReport {
                nextReport += 0.02
                progress(
                    String(
                        format: "%3.0f ms: first storey %5.1f mm, second %5.1f mm", solver.time * 1000,
                        a * 1000,
                        b * 1000))
            }
        }
        let ambient = scenario.atmosphere.pressure
        // The positive phase, as the report gives it: from the shock to the pressure's first fall
        // back below ambient.
        func positive(_ samples: [GaugeSample]) -> (peak: Float, impulse: Float) {
            guard let start = samples.firstIndex(where: { $0.pressure - ambient > 0.01 * ambient }) else {
                return (0, 0)
            }
            var impulse: Float = 0
            var peak: Float = 0
            for (p, q) in zip(samples[start...], samples[(start + 1)...]) {
                if q.pressure < ambient { break }
                impulse += Float(q.time - p.time) * (0.5 * (p.pressure + q.pressure) - ambient)
                peak = max(peak, q.pressure - ambient)
            }
            return (peak, impulse)
        }
        let wall = positive(solver.gaugeHistories.first ?? [])
        let freeField = scenario.gauges.firstIndex { $0.name.hasPrefix("Free field") }
        let free = positive(freeField.map { solver.gaugeHistories[$0] } ?? [])
        let summary = shells.summary()
        return Result(
            firstFloor: firstFloor, secondFloor: secondFloor, reflected: wall.peak, impulse: wall.impulse,
            incident: free.peak, incidentImpulse: free.impulse,
            wallSeconds: Date().timeIntervalSince(started),
            maxDamage: summary.maxDamage, removed: summary.erodedElements)
    }
}
