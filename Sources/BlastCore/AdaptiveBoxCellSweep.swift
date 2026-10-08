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
        let linearImpulse: SIMD3<Double>
        let angularImpulse: SIMD3<Double>
        let impulseErrorEstimate: Double
        let angularErrorEstimate: Double
        let integratedOpenFaceAreas: [Double]
        let faceAreaTimeErrorEstimate: Double
        let faceAreaTimeTolerance: Double
    }
    private struct Interval {
        let low: Double
        let high: Double
        let value: SIMD16<Double>
        let error: Double
        let impulseError: Double
        let angularError: Double
        let faceError: Double
        let priority: Double
    }
    static func integrate(
        body: RigidBoxBody, velocity: SIMD3<Double>, spin: SIMD3<Double>, lower: SIMD3<Double>,
        cellSize h: Double, duration: Double, pressure: Double, volumeTolerance: Double,
        maximumIntervals: Int = 4096, impulseTolerance: Double = 1e-8, angularTolerance: Double = 1e-8,
        faceAreaTimeTolerance: Double? = nil
    ) throws -> Result {
        precondition(h.isFinite && h > 0 && duration.isFinite && duration > 0 && pressure.isFinite)
        precondition(volumeTolerance.isFinite && volumeTolerance > 0 && maximumIntervals > 0)
        precondition(
            impulseTolerance.isFinite && impulseTolerance > 0 && angularTolerance.isFinite
                && angularTolerance > 0)
        precondition((0..<3).allSatisfy { velocity[$0].isFinite && spin[$0].isFinite && lower[$0].isFinite })
        let faceTolerance = faceAreaTimeTolerance ?? h * h * duration * 1e-8
        precondition(faceTolerance.isFinite && faceTolerance > 0)
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
        let radius = body.corners.map { simd_length($0 - body.position) }.max() ?? 0
        let maximumSpeed = simd_length(velocity) + speed * radius
        var evaluations = 0
        func quadrature(_ low: Double, _ high: Double) throws -> (value: SIMD16<Double>, occupied: Bool) {
            let midpoint = (low + high) / 2
            let weight = (high - low) / 2
            var value = SIMD16<Double>.zero
            var occupied = false
            for time in [midpoint - weight / sqrt(3.0), midpoint + weight / sqrt(3.0)] {
                evaluations += 1
                let current = try pose(time)
                func wallVelocity(_ point: SIMD3<Double>) -> SIMD3<Double> {
                    velocity + simd_cross(spin, point - current.position)
                }
                let geometry = FractionalBoxGeometry(current)
                let faces = geometry.openFacePatches(lower: lower, cellSize: h)
                for side in 0..<6 { value[9 + side] += weight * faces[side].area }
                occupied = occupied || geometry.solidVolumeFraction(lower: lower, cellSize: h) > 1e-14
                for wall in geometry.wallPatches(lower: lower, cellSize: h) {
                    occupied = true
                    let load = wall.pressureLoad(about: current.position) { _ in pressure }
                    value +=
                        weight
                        * SIMD16(
                            wall.sweptVolumeRate(velocity: wallVelocity),
                            wall.gasPressurePower(velocity: wallVelocity) { _ in pressure },
                            simd_dot(load.force, velocity) + simd_dot(load.torque, spin),
                            load.force.x, load.force.y, load.force.z,
                            load.torque.x, load.torque.y, load.torque.z, 0, 0, 0, 0, 0, 0, 0)
                }
            }
            return (value, occupied)
        }
        func interval(_ low: Double, _ high: Double) throws -> Interval {
            let middle = (low + high) / 2
            let coarse = try quadrature(low, high)
            let left = try quadrature(low, middle)
            let right = try quadrature(middle, high)
            let fine = left.value + right.value
            let start = try volume(low)
            let end = try volume(high)
            let change = end - start
            let error = abs(fine[0] - change) + abs(fine[0] - coarse.value[0])
            let difference = fine - coarse.value
            func endpointValues(_ time: Double) throws -> SIMD16<Double> {
                evaluations += 1
                let current = try pose(time)
                var value = SIMD16<Double>.zero
                let geometry = FractionalBoxGeometry(current)
                let faces = geometry.openFacePatches(lower: lower, cellSize: h)
                for side in 0..<6 { value[9 + side] = faces[side].area }
                for wall in geometry.wallPatches(lower: lower, cellSize: h) {
                    let load = wall.pressureLoad(about: current.position) { _ in pressure }
                    for axis in 0..<3 {
                        value[3 + axis] += load.force[axis]
                        value[6 + axis] += load.torque[axis]
                    }
                }
                return value
            }
            // Endpoint-inclusive comparison detects a force jump at the end of an otherwise
            // occupied interval, which Gaussian nodes alone can sample on only one side.
            let endpointEstimate =
                try (endpointValues(low) + 4 * endpointValues(middle) + endpointValues(high))
                * ((high - low) / 6)
            let endpointDifference = fine - endpointEstimate
            let impulseError = max(
                simd_length(SIMD3(difference[3], difference[4], difference[5])),
                simd_length(SIMD3(endpointDifference[3], endpointDifference[4], endpointDifference[5])))
            let angularError = max(
                simd_length(SIMD3(difference[6], difference[7], difference[8])),
                simd_length(SIMD3(endpointDifference[6], endpointDifference[7], endpointDifference[8])))
            let faceError = (9..<15).map { max(abs(difference[$0]), abs(endpointDifference[$0])) }.max()!
            var priority = max(
                max(error / volumeTolerance, faceError / faceTolerance),
                max(impulseError / impulseTolerance, angularError / angularTolerance)
            )
            if maximumSpeed > 0 && !coarse.occupied
                && !left.occupied
                && !right.occupied,
                mayIntersect(
                    try pose(middle), lower: lower, cellSize: h, expansion: maximumSpeed * (high - low) / 2)
            {
                // Empty quadrature can miss a grazing pass or the tail of an occupied endpoint.
                // Refine until occupancy is sampled or separation is proved for the interval.
                priority = .infinity
            }
            return Interval(
                low: low, high: high, value: fine,
                error: error, impulseError: impulseError, angularError: angularError,
                faceError: faceError, priority: priority)
        }
        // These excursion limits reduce undersampling but do not prove that arbitrarily
        // brief grazing contacts are detected or certify force-impulse accuracy.
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
        while intervals.reduce(0, { $0 + $1.priority }) > 1 {
            guard intervals.count < maximumIntervals else { throw Failure.resolutionLimit }
            let index = intervals.indices.max { intervals[$0].priority < intervals[$1].priority }!
            let old = intervals.remove(at: index)
            let middle = (old.low + old.high) / 2
            guard middle > old.low && middle < old.high else { throw Failure.resolutionLimit }
            intervals.append(try interval(old.low, middle))
            intervals.append(try interval(middle, old.high))
        }
        let value = intervals.reduce(SIMD16<Double>.zero) { $0 + $1.value }
        return Result(
            volumeChange: try volume(duration) - volume(0), sweptVolume: value[0],
            gasWork: value[1], bodyWork: value[2], errorEstimate: intervals.reduce(0) { $0 + $1.error },
            intervals: intervals.count, evaluations: evaluations,
            linearImpulse: SIMD3(value[3], value[4], value[5]),
            angularImpulse: SIMD3(value[6], value[7], value[8]),
            impulseErrorEstimate: intervals.reduce(0) { $0 + $1.impulseError },
            angularErrorEstimate: intervals.reduce(0) { $0 + $1.angularError },
            integratedOpenFaceAreas: (9..<15).map { value[$0] },
            faceAreaTimeErrorEstimate: intervals.reduce(0) { $0 + $1.faceError },
            faceAreaTimeTolerance: faceTolerance)
    }

    /// Separating-axis bound at the midpoint, inflated by maximum corner travel.
    /// Disjoint projections prove no intersection anywhere in the interval.
    private static func mayIntersect(
        _ body: RigidBoxBody, lower: SIMD3<Double>, cellSize h: Double, expansion: Double
    ) -> Bool {
        let cellAxes = [SIMD3<Double>(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)]
        let boxAxes = cellAxes.map { body.orientation.act($0) }
        let axes = cellAxes + boxAxes + boxAxes.flatMap { b in cellAxes.map { simd_cross(b, $0) } }
        let difference = body.worldPoint(.zero) - (lower + SIMD3(repeating: h / 2))
        for raw in axes where simd_length_squared(raw) > 1e-24 {
            let axis = simd_normalize(raw)
            let boxRadius = (0..<3).reduce(0.0) { $0 + body.size[$1] / 2 * abs(simd_dot(axis, boxAxes[$1])) }
            let cellRadius = h / 2 * (abs(axis.x) + abs(axis.y) + abs(axis.z))
            if abs(simd_dot(axis, difference)) > boxRadius + cellRadius + expansion { return false }
        }
        return true
    }
}
