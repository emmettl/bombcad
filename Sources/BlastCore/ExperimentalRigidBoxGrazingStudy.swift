import simd

/// Corner encounters with zero endpoint volume change and nonzero analytical impulse.
public enum ExperimentalRigidBoxGrazingStudy {
    public struct Result: Codable, Sendable {
        public let contactDuration: Double
        public let linearImpulse: SIMD3<Double>
        public let expectedLinearImpulse: SIMD3<Double>
        public let angularImpulse: SIMD3<Double>
        public let midpointImpulse: SIMD3<Double>
        public let volumeResidual: Double
        public let workBalanceResidual: Double
        public let impulseTolerance: Double
        public let impulseErrorEstimate: Double
        public let angularErrorEstimate: Double
        public let evaluations: Int
    }
    public static func run() throws -> [Result] {
        try [0.001, 0.0001, 0.00001].map { gap in
            let pressure = 101325.0
            let duration = 0.4
            let body = try RigidBoxBody(
                mass: 1, size: SIMD3(repeating: 0.2), position: SIMD3(-0.3, 0.1 + gap, 0.5))
            let velocity = SIMD3<Double>(1, -1, 0)
            let magnitude = pressure * 0.2 * gap * gap / 2
            let tolerance = max(1e-12, magnitude * 1e-5)
            let sweep = try AdaptiveBoxCellSweep.integrate(
                body: body, velocity: velocity, spin: .zero,
                lower: .zero, cellSize: 1, duration: duration, pressure: pressure,
                volumeTolerance: 1e-14, impulseTolerance: tolerance, angularTolerance: tolerance)
            var midpointImpulse = SIMD3<Double>.zero
            for n in 0..<128 {
                let time = (Double(n) + 0.5) * duration / 128
                let pose = try RigidBoxBody(
                    mass: 1, size: body.size, position: body.position + time * velocity)
                for wall in FractionalBoxGeometry(pose).wallPatches(lower: .zero, cellSize: 1) {
                    midpointImpulse +=
                        duration / 128 * wall.pressureLoad(about: pose.position) { _ in pressure }.force
                }
            }
            return Result(
                contactDuration: gap, linearImpulse: sweep.linearImpulse,
                expectedLinearImpulse: SIMD3(-magnitude, -magnitude, 0), angularImpulse: sweep.angularImpulse,
                midpointImpulse: midpointImpulse, volumeResidual: sweep.sweptVolume - sweep.volumeChange,
                workBalanceResidual: sweep.gasWork + sweep.bodyWork, impulseTolerance: tolerance,
                impulseErrorEstimate: sweep.impulseErrorEstimate,
                angularErrorEstimate: sweep.angularErrorEstimate,
                evaluations: sweep.evaluations)
        }
    }
}
