import BlastModel
import Foundation
import Metal
import simd

extension LangdonPanelTest {
    /// Runs one panel's test.
    public static func run(_ panel: Panel, settings: Settings = Settings(), device: MTLDevice) throws
        -> Result
    {
        let model = model(flexibleLength: panel.flexibleLengthMM, settings: settings)
        let solver = try ShellSolver(device: device, model: model)
        solver.groundContact = false
        solver.gravity = 0
        solver.damping = 0
        // "Positive" pushes the panel towards its connections' side, −y.
        solver.appliedLoad = PressureLoad(axis: 1, positiveSide: panel.isPositive, history: panel.pulse)
        let gauge = solver.nearestNode(to: SIMD3(0.44, 0, 0.4575))
        let foot = solver.nearestNode(to: SIMD3(0.44, 0, 0))
        let lever: Float = settings.connection == .springs ? 0.045 : 0
        let sign: Float = panel.isPositive ? -1 : 1
        let end = panel.durationMS.milliseconds / 1000 + settings.after
        let step = solver.criticalTimeStep
        let stepsPerSample = max(1, Int((0.0005 / step).rounded()))
        var history: [SIMD2<Float>] = []
        var time: Float = 0
        while time < end {
            solver.advance(steps: stepsPerSample)
            time += Float(stepsPerSample) * step
            let q = solver.node(foot).rotation
            let turn = 2 * atan2(q.imag.x, q.real)
            history.append(SIMD2(time, sign * solver.node(gauge).displacement.y + lever * sin(abs(turn))))
        }
        let peak = history.map(\.y).max() ?? 0
        let tail = history.filter { $0.x > end - settings.after / 2 }.map(\.y)
        let permanent = tail.reduce(0, +) / Float(max(tail.count, 1))
        let failed = (0..<solver.elementCount).filter { solver.flag($0) != .active }
        if ProcessInfo.processInfo.environment["LANGDON_DEBUG"] != nil {
            for e in failed.prefix(6) {
                let element = solver.mesh.elements[e]
                print(
                    "  failed \(e): solid \(element.solid), axis \(element.axis), centre \(solver.elementCentre(e)), flag \(solver.flag(e))"
                )
            }
        }
        let failedShells = failed.count
        let failedBeams = (0..<solver.beamCount).filter { solver.beamFlag($0) != .active }.count
        return Result(
            panel: panel, peak: peak, permanent: permanent, history: history,
            pullIn: solver.node(foot).displacement.z, failedShells: failedShells, failedBeams: failedBeams)
    }
}
