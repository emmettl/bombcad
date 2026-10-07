import simd

/// Adaptive reference for constant COM velocity and world spin with arbitrary initial pose.
/// Endpoint geometry checks volume integration. This is not a complete event detector.
enum AdaptiveBoxCellSweep {
    enum Failure: Error { case resolutionLimit }
    struct Result {
        let volumeChange: Double
        let sweptVolume: Double
        let gasWork: Double
        let bodyWork: Double
        let errorEstimate: Double
        let intervals: Int
        let evaluations: Int
    }
    private struct Interval {
        let low: Double
        let high: Double
        let value: SIMD3<Double>
        let error: Double
    }
    static func integrate(
        body: RigidBoxBody, velocity: SIMD3<Double>, spin: SIMD3<Double>, lower: SIMD3<Double>,
        cellSize h: Double, duration: Double, pressure: Double, volumeTolerance: Double,
        maximumIntervals: Int = 4096
    ) throws -> Result {
        precondition(h.isFinite && h > 0 && duration.isFinite && duration > 0 && pressure.isFinite)
        precondition(volumeTolerance.isFinite && volumeTolerance > 0 && maximumIntervals > 0)
        precondition((0..<3).allSatisfy { velocity[$0].isFinite && spin[$0].isFinite && lower[$0].isFinite })
        let speed = simd_length(spin)
        func pose(_ time: Double) throws -> RigidBoxBody {
            let turn =
                speed > 0
                ? simd_quatd(angle: speed * time, axis: spin / speed)
                : simd_quatd(angle: 0, axis: SIMD3(0, 0, 1))
            return try RigidBoxBody(
                mass: body.mass, size: body.size,
                position: body.position + time * velocity, orientation: turn * body.orientation,
                centreOfMass: body.centreOfMass, inertia: body.inertia)
        }
        func volume(_ time: Double) throws -> Double {
            FractionalBoxGeometry(try pose(time)).solidVolumeFraction(lower: lower, cellSize: h) * h * h * h
        }
        var evaluations = 0
        func quadrature(_ low: Double, _ high: Double) throws -> SIMD3<Double> {
            let midpoint = (low + high) / 2
            let weight = (high - low) / 2
            var value = SIMD3<Double>.zero
            for time in [midpoint - weight / sqrt(3.0), midpoint + weight / sqrt(3.0)] {
                evaluations += 1
                let current = try pose(time)
                func wallVelocity(_ point: SIMD3<Double>) -> SIMD3<Double> {
                    velocity + simd_cross(spin, point - current.position)
                }
                for wall in FractionalBoxGeometry(current).wallPatches(lower: lower, cellSize: h) {
                    let load = wall.pressureLoad(about: current.position) { _ in pressure }
                    value +=
                        weight
                        * SIMD3(
                            wall.sweptVolumeRate(velocity: wallVelocity),
                            wall.gasPressurePower(velocity: wallVelocity) { _ in pressure },
                            simd_dot(load.force, velocity) + simd_dot(load.torque, spin))
                }
            }
            return value
        }
        func interval(_ low: Double, _ high: Double) throws -> Interval {
            let middle = (low + high) / 2
            let coarse = try quadrature(low, high)
            let fine = try quadrature(low, middle) + quadrature(middle, high)
            let change = try volume(high) - volume(low)
            return Interval(
                low: low, high: high, value: fine,
                error: abs(fine.x - change) + abs(fine.x - coarse.x))
        }
        // These excursion limits reduce undersampling but do not prove that arbitrarily
        // brief grazing contacts are detected or certify force-impulse accuracy.
        let radius = body.corners.map { simd_length($0 - body.position) }.max() ?? 0
        let subdivisions = ceil(
            max(
                duration * (simd_length(velocity) + speed * radius) / (0.25 * h),
                duration * speed / 0.1))
        guard subdivisions.isFinite && subdivisions <= Double(maximumIntervals) else {
            throw Failure.resolutionLimit
        }
        let initialCount = max(1, Int(subdivisions))
        var intervals: [Interval] = []
        for n in 0..<initialCount {
            intervals.append(
                try interval(
                    duration * Double(n) / Double(initialCount),
                    duration * Double(n + 1) / Double(initialCount)))
        }
        while intervals.reduce(0, { $0 + $1.error }) > volumeTolerance {
            guard intervals.count < maximumIntervals else { throw Failure.resolutionLimit }
            let index = intervals.indices.max { intervals[$0].error < intervals[$1].error }!
            let old = intervals.remove(at: index)
            let middle = (old.low + old.high) / 2
            guard middle > old.low && middle < old.high else { throw Failure.resolutionLimit }
            intervals.append(try interval(old.low, middle))
            intervals.append(try interval(middle, old.high))
        }
        let value = intervals.reduce(SIMD3<Double>.zero) { $0 + $1.value }
        return Result(
            volumeChange: try volume(duration) - volume(0), sweptVolume: value.x,
            gasWork: value.y, bodyWork: value.z, errorEstimate: intervals.reduce(0) { $0 + $1.error },
            intervals: intervals.count, evaluations: evaluations)
    }
}
