import simd

/// CPU-only prescribed-motion geometry. Temporal midpoint quadrature is compared with
/// exact endpoint volume; it is not assumed conservative when walls cross cell boundaries.
public enum ExperimentalRigidBoxMotionStudy {
    public struct Result: Codable, Sendable {
        public let kind: String
        public let cellSize: Double
        public let temporalSamples: Int
        public let duration: Double
        public let solidVolumeChange: Double
        public let sweptVolume: Double
        public let volumeResidual: Double
        public let gasPressureWork: Double
        public let bodyPressureWork: Double
        public let workBalanceResidual: Double
        public let endpointPressureWork: Double
    }

    public static func run() throws -> [Result] {
        var results: [Result] = []
        for h in [0.2, 0.1, 0.05] {
            for kind in ["translation-crossing", "rotation", "ground-gap-opening"] {
                for samples in [8, 32, 128] {
                    results.append(try measure(kind: kind, cellSize: h, samples: samples))
                }
            }
        }
        return results
    }

    private static func measure(kind: String, cellSize h: Double, samples: Int) throws -> Result {
        let duration = 0.02
        let pressure = 101325.0
        let axis = simd_normalize(SIMD3<Double>(1, 2, 3))
        let rotating = kind == "rotation"
        let gap = kind == "ground-gap-opening"
        let start = gap ? SIMD3<Double>(2, 2, 0.40001) : SIMD3<Double>(2.095, 2, 2)
        let velocity = rotating ? SIMD3<Double>.zero : gap ? SIMD3(0, 0, 0.6) : SIMD3(6, 0, 0)
        let spin = rotating ? 4 * axis : .zero
        let lower =
            gap
            ? SIMD3<Double>(2 - h, 2 - h, 0)
            : rotating
                ? SIMD3(2.475, 2 - h / 2, 2 - h / 2)
                : SIMD3(floor(2.495 / h) * h, 2 - h / 2, 2 - h / 2)
        func body(at time: Double) throws -> RigidBoxBody {
            try RigidBoxBody(
                mass: 2, size: SIMD3(repeating: 0.8), position: start + time * velocity,
                orientation: simd_quatd(angle: rotating ? 0.11 + 4 * time : 0, axis: axis))
        }
        let initial = FractionalBoxGeometry(try body(at: 0)).solidVolumeFraction(lower: lower, cellSize: h)
        let final = FractionalBoxGeometry(try body(at: duration)).solidVolumeFraction(
            lower: lower, cellSize: h)
        let change = (final - initial) * h * h * h
        var swept = 0.0
        var gasWork = 0.0
        var bodyWork = 0.0
        let dt = duration / Double(samples)
        for n in 0..<samples {
            let current = try body(at: (Double(n) + 0.5) * dt)
            let geometry = FractionalBoxGeometry(current)
            func wallVelocity(_ point: SIMD3<Double>) -> SIMD3<Double> {
                velocity + simd_cross(spin, point - current.position)
            }
            for wall in geometry.wallPatches(lower: lower, cellSize: h) {
                swept += dt * wall.sweptVolumeRate(velocity: wallVelocity)
                gasWork += dt * wall.gasPressurePower(velocity: wallVelocity) { _ in pressure }
                let load = wall.pressureLoad(about: current.position) { _ in pressure }
                bodyWork += dt * (simd_dot(load.force, velocity) + simd_dot(load.torque, spin))
            }
        }
        return Result(
            kind: kind, cellSize: h, temporalSamples: samples, duration: duration,
            solidVolumeChange: change, sweptVolume: swept, volumeResidual: swept - change,
            gasPressureWork: gasWork, bodyPressureWork: bodyWork, workBalanceResidual: gasWork + bodyWork,
            endpointPressureWork: pressure * change)
    }
}
