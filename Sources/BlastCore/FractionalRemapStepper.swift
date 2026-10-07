import simd

/// Transactional, capacity-limited remapping with prescribed geometry. This is not an
/// acoustic CFL controller, a wall-work integrator or a physical numerical gas flux.
enum FractionalRemapStepper {
    enum Failure: Error { case initialGeometry, substepLimit }
    struct Step {
        let start: Double
        let end: Double
        let transfers: Int
        let maximumOutflowFraction: Double
    }
    struct Result {
        let cells: [FractionalGasTransport.Cell]
        let steps: [Step]
        let rejectedIntervals: Int
    }
    static func advance(
        _ initial: [FractionalGasTransport.Cell], duration: Double,
        maximumSubsteps: Int = 4096, maximumBisections: Int = 24, relativeTolerance: Double = 1e-9,
        volumesAt: (Double) throws -> [Double],
        facesBetween: (Double, Double) throws -> [FractionalVolumeRemap.Face]
    ) throws -> Result {
        precondition(duration.isFinite && duration > 0 && maximumSubsteps > 0 && maximumBisections >= 0)
        precondition(relativeTolerance.isFinite && relativeTolerance > 0)
        let expected = try volumesAt(0)
        guard expected.count == initial.count else { throw Failure.initialGeometry }
        for n in initial.indices {
            guard expected[n].isFinite && expected[n] >= 0,
                abs(expected[n] - initial[n].volume) <= relativeTolerance
                    * max(expected[n], initial[n].volume)
            else { throw Failure.initialGeometry }
        }
        var cells = try FractionalGasTransport.advance(
            initial, newVolumes: initial.map(\.volume), transfers: [])
        var pending = [(low: 0.0, high: duration, depth: 0)]
        var steps: [Step] = []
        var rejected = 0
        while let interval = pending.popLast() {
            let next = try volumesAt(interval.high)
            let faces = try facesBetween(interval.low, interval.high)
            do {
                let plan = try FractionalVolumeRemap.build(
                    old: cells.map(\.volume), new: next, faces: faces,
                    relativeTolerance: relativeTolerance)
                let updated = try FractionalGasTransport.advance(
                    cells, newVolumes: next, transfers: plan.transfers)
                cells = updated
                steps.append(
                    Step(
                        start: interval.low, end: interval.high, transfers: plan.transfers.count,
                        maximumOutflowFraction: plan.maximumOutflowFraction))
            } catch FractionalVolumeRemap.Failure.unroutable {
                rejected += 1
                let middle = (interval.low + interval.high) / 2
                guard interval.depth < maximumBisections,
                    steps.count + pending.count + 2 <= maximumSubsteps,
                    middle > interval.low && middle < interval.high
                else { throw Failure.substepLimit }
                // Geometry is recomputed after each accepted step, including newly opened cells.
                pending.append((middle, interval.high, interval.depth + 1))
                pending.append((interval.low, middle, interval.depth + 1))
            }
        }
        return Result(cells: cells, steps: steps, rejectedIntervals: rejected)
    }
}
