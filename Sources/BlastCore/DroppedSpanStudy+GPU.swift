import BlastModel
import Foundation
import Metal
import simd

extension DroppedSpanStudy {
    /// Runs the study for `duration` seconds after the strike.
    public static func run(
        device: MTLDevice, seat: Float, speed: Float, law: Anchorage = .resting(friction: 0.5),
        duration: Float = 1.5, elementSize: Float = 0.1
    ) throws -> Result {
        let started = ContinuousClock.now
        let model = model(seat: seat, law: law, elementSize: elementSize)
        let solver = try StructureSolver(device: device, model: model)
        // Pieces that fall meet what is below them.
        solver.contactMode = .always
        let dt = Double(solver.criticalTimeStep)
        solver.damping = 100
        solver.advance(steps: Int((0.1 / dt).rounded()))
        solver.damping = 0

        let h = model.elementSize
        let right = columnSide + span
        // The struck column's nodes, its top's, and the beam's nodes over its corbel and their
        // corbel's below them.
        var struck: [(node: Int, height: Float)] = []
        var beamEnd: [Int] = []
        var corbelTop: [Int] = []
        var columnTop: Int?
        for k in 0...solver.ez {
            for j in 0...solver.ey {
                for i in 0...solver.ex {
                    guard let n = solver.storedNode(i, j, k) else { continue }
                    let p = solver.referencePosition(i, j, k)
                    if p.x >= right - corbel - 1e-3 && p.z <= height + 1e-3 {
                        struck.append((n, p.z))
                        if abs(p.z - height) < 1e-3, abs(p.x - (right + columnSide)) < 1e-3 { columnTop = n }
                    }
                    if p.x >= right - corbel - 1e-3, p.x <= right - corbel + seat + 1e-3 {
                        if abs(p.z - (height + h)) < 1e-3 { beamEnd.append(n) }
                        if abs(p.z - height) < 1e-3 { corbelTop.append(n) }
                    }
                }
            }
        }
        solver.mutateNodes { nodes in
            for (n, z) in struck { nodes[n].velocity.x += speed * z / height }
        }
        func mean(_ list: [Int], _ nodes: UnsafeMutableBufferPointer<StructureNode>) -> SIMD3<Float> {
            list.reduce(SIMD3<Float>.zero) { $0 + nodes[$1].displacement } / Float(max(list.count, 1))
        }
        var result = Result(speed: speed, seat: seat, summary: StructureSummary(), wallSeconds: 0)
        let sample = 5e-3
        let stepsPerSample = max(1, Int((sample / dt).rounded()))
        var start = SIMD3<Float>.zero
        solver.mutateNodes { start = mean(beamEnd, $0) }
        for _ in 0..<Int((Double(duration) / sample).rounded()) {
            solver.advance(steps: stepsPerSample)
            solver.mutateNodes { nodes in
                if let columnTop { result.peakSway = max(result.peakSway, nodes[columnTop].ux) }
                result.peakSlide = max(result.peakSlide, mean(corbelTop, nodes).x - mean(beamEnd, nodes).x)
                result.drop = start.z - mean(beamEnd, nodes).z
            }
        }
        // The struck end's seat is the second support region.
        if let pairs = solver.pairSummary(support: 1) {
            result.unseated = 1 - pairs.seatedArea / max(solver.supportBearingArea(at: 1), 1e-9)
        }
        result.summary = solver.summary()
        let elapsed = ContinuousClock.now - started
        result.wallSeconds =
            Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
        return result
    }
}
