import simd

/// Axis-aligned, constant-translation reference. Crossings split overlap topology;
/// two-point Gaussian time quadrature integrates the resulting quadratic volume rate.
/// Rotation requires a separate event treatment and is explicitly rejected here.
enum TranslatingBoxCellSweep {
    enum Failure: Error { case unsupportedOrientation }
    struct Result {
        let volumeChange: Double
        let sweptVolume: Double
        let gasWork: Double
        let bodyWork: Double
        let intervals: Int
        var evaluations: Int { 2 * intervals }
    }

    static func integrate(
        body: RigidBoxBody, velocity: SIMD3<Double>, lower: SIMD3<Double>, cellSize h: Double,
        duration: Double, pressure: Double
    ) throws -> Result {
        precondition(h.isFinite && h > 0 && duration.isFinite && duration > 0 && pressure.isFinite)
        precondition((0..<3).allSatisfy { velocity[$0].isFinite && lower[$0].isFinite })
        for axis in 0..<3 {
            var unit = SIMD3<Double>.zero
            unit[axis] = 1
            let direction = abs(body.orientation.act(unit))
            guard (0..<3).filter({ direction[$0] > 1 - 1e-12 }).count == 1,
                (0..<3).filter({ direction[$0] < 1e-12 }).count == 2
            else { throw Failure.unsupportedOrientation }
        }
        let low = body.corners.reduce(SIMD3<Double>(repeating: .infinity), simd_min)
        let high = body.corners.reduce(SIMD3<Double>(repeating: -.infinity), simd_max)
        var times = [0.0, duration]
        for axis in 0..<3 where velocity[axis] != 0 {
            for wall in [low[axis], high[axis]] {
                for face in [lower[axis], lower[axis] + h] {
                    let time = (face - wall) / velocity[axis]
                    if time > 0 && time < duration { times.append(time) }
                }
            }
        }
        // Remove only exact duplicates: even very short intervals can carry finite volume.
        times = Array(Set(times)).sorted()
        func geometry(at time: Double) throws -> FractionalBoxGeometry {
            FractionalBoxGeometry(
                try RigidBoxBody(
                    mass: body.mass, size: body.size,
                    position: body.position + time * velocity, orientation: body.orientation,
                    centreOfMass: body.centreOfMass, inertia: body.inertia))
        }
        let initial = try geometry(at: 0).solidVolumeFraction(lower: lower, cellSize: h)
        let final = try geometry(at: duration).solidVolumeFraction(lower: lower, cellSize: h)
        var swept = 0.0
        var gasWork = 0.0
        var bodyWork = 0.0
        for n in 0..<(times.count - 1) {
            let midpoint = (times[n] + times[n + 1]) / 2
            let weight = (times[n + 1] - times[n]) / 2
            for time in [midpoint - weight / sqrt(3.0), midpoint + weight / sqrt(3.0)] {
                let current = try geometry(at: time)
                for wall in current.wallPatches(lower: lower, cellSize: h) {
                    swept += weight * wall.sweptVolumeRate { _ in velocity }
                    gasWork +=
                        weight
                        * wall.gasPressurePower(velocity: { _ in velocity }, pressure: { _ in pressure })
                    let load = wall.pressureLoad(about: body.position + time * velocity) { _ in pressure }
                    bodyWork += weight * simd_dot(load.force, velocity)
                }
            }
        }
        return Result(
            volumeChange: (final - initial) * h * h * h, sweptVolume: swept,
            gasWork: gasWork, bodyWork: bodyWork, intervals: times.count - 1)
    }
}
