import Foundation
import simd

/// Known affine pressure with a quadratic time envelope on a translating rectangular box.
/// This isolates surface/time load integration; the imposed trace is not a source-free
/// Euler solution. No gas state, numerical reflection, body motion or contact is solved.
public enum ExperimentalMovingPressureStudy {
    public struct Loads: Codable, Sendable {
        public let impulse: SIMD3<Double>
        public let angularImpulse: SIMD3<Double>
        public let work: Double
        public let relativeImpulseError: Double
        public let relativeAngularImpulseError: Double
        public let relativeWorkError: Double
    }
    public struct Result: Codable, Sendable {
        public let cellSize: Double
        public let rotation: Double
        public let timeSlices: Int
        public let duration: Double
        public let velocity: SIMD3<Double>
        public let size: SIMD3<Double>
        public let initialGeometricCentre: SIMD3<Double>
        public let initialCentreOfMass: SIMD3<Double>
        public let pressureCoefficients: SIMD3<Double>
        public let gradientCoefficients: [SIMD3<Double>]
        public let wallPatches: Int
        public let wallSamples: Int
        public let geometryEvaluations: Int
        public let maximumIntervals: Int
        public let minimumSamplePressure: Double
        public let maximumRelativeSampleMomentResidual: Double
        public let sampled: Loads
        public let centroid: Loads
        public let exactImpulse: SIMD3<Double>
        public let exactAngularImpulse: SIMD3<Double>
        public let exactWork: Double
        public let impulseWorkResidual: Double
        public let computeSeconds: Double
    }
    enum Failure: Error { case invalidConfiguration }
    static let duration = 0.0008
    static let velocity = SIMD3<Double>(300, 100, -40)
    static let size = SIMD3<Double>(0.8, 0.6, 0.4)
    static let geometricCentre = SIMD3<Double>(1.013, 1.027, 1.041)
    static let pressureCoefficients = SIMD3<Double>(101325, 15000, 10000)
    static let gradients = [
        SIMD3<Double>(23000, -17000, 31000),
        SIMD3<Double>(7000, 19000, -11000),
        SIMD3<Double>(13000, -9000, 17000),
    ]

    static func body(angle: Double) throws -> RigidBoxBody {
        let orientation = simd_quatd(angle: angle, axis: simd_normalize(SIMD3(1, 2, 3)))
        let offset = SIMD3<Double>(0.08, -0.06, 0.04)
        return try .init(
            mass: 2, size: size, position: geometricCentre + orientation.act(offset),
            orientation: orientation, centreOfMass: offset, inertia: SIMD3(0.1, 0.15, 0.2))
    }
    static func pressure(point: SIMD3<Double>, time: Double) -> Double {
        let s = time / duration
        let gradient = gradients[0] + s * gradients[1] + s * s * gradients[2]
        return pressureCoefficients.x + s * pressureCoefficients.y + s * s * pressureCoefficients.z
            + simd_dot(gradient, point - geometricCentre - time * velocity)
    }

    public static func run(
        cellSizes: [Double] = [0.4, 0.2, 0.1], rotations: [Double] = [0, 0.23],
        timeSlices: [Int] = [1, 4], progress: (Result) throws -> Void = { _ in }
    ) throws -> [Result] {
        guard !timeSlices.isEmpty, timeSlices.allSatisfy({ $0 > 0 && $0 <= 64 }),
            !cellSizes.isEmpty, !rotations.isEmpty
        else { throw Failure.invalidConfiguration }
        var rows: [Result] = []
        for h in cellSizes {
            guard h.isFinite && h >= 0.1 && h <= 0.4, abs(2 / h - (2 / h).rounded()) < 1e-10 else {
                throw Failure.invalidConfiguration
            }
            for angle in rotations {
                guard angle.isFinite else { throw Failure.invalidConfiguration }
                for slices in timeSlices {
                    let row = try measure(h: h, angle: angle, slices: slices)
                    rows.append(row)
                    try progress(row)
                }
            }
        }
        return rows
    }

    private static func measure(h: Double, angle: Double, slices: Int) throws -> Result {
        let clock = Date()
        let initial = try body(angle: angle)
        let boxVolume = size.x * size.y * size.z
        // Divergence theorem: F(t) = -V grad p(t). Affine pressure has zero torque
        // about the geometric centre; the offset COM supplies d × F(t).
        let exact = -boxVolume * duration * (gradients[0] + gradients[1] / 2 + gradients[2] / 3)
        let exactAngular = simd_cross(initial.worldPoint(.zero) - initial.position, exact)
        let exactWork = simd_dot(velocity, exact)
        var sampledImpulse = SIMD3<Double>.zero
        var sampledAngular = SIMD3<Double>.zero
        var sampledWork = 0.0
        var centroidImpulse = SIMD3<Double>.zero
        var centroidAngular = SIMD3<Double>.zero
        var centroidWork = 0.0
        var patches = 0
        var samples = 0
        var evaluations = 0
        var intervals = 0
        var minimumPressure = Double.infinity
        var maximumResidual = 0.0
        let count = Int((2 / h).rounded())
        let dt = duration / Double(slices)
        for slice in 0..<slices {
            let start = Double(slice) * dt
            let body = initial.translated(by: start * velocity)
            let geometry = try TranslatingBoxSpaceTimeGeometry(body: body, velocity: velocity)
            for z in 0..<count {
                for y in 0..<count {
                    for x in 0..<count {
                        let lower = h * SIMD3(Double(x), Double(y), Double(z))
                        let centre = lower + SIMD3(repeating: h / 2)
                        let r = try geometry.integrate(
                            lower: lower, cellSize: h, duration: dt, wallQuadrature: true)
                        evaluations += r.evaluations
                        intervals = max(intervals, r.eventTimes.count - 1)
                        for patch in r.walls where patch.areaTime > 0 {
                            patches += 1
                            let load = try MovingWallPressureQuadrature.integrate(
                                patch, cellCentre: centre, initialCentreOfMass: body.position,
                                velocity: velocity, duration: dt, lengthScale: h,
                                pressure: { point, time in
                                    let p = pressure(point: point, time: start + time)
                                    minimumPressure = min(minimumPressure, p)
                                    return p
                                })
                            sampledImpulse += load.impulse
                            sampledAngular += load.angularImpulse
                            sampledWork += load.work
                            let nodes = patch.samples!
                            samples += nodes.count
                            let area = nodes.reduce(0) { $0 + $1.areaTime }
                            let moment = nodes.reduce(SIMD3<Double>.zero) {
                                $0 + $1.areaTime * ($1.point - centre)
                            }
                            let timeMoment = nodes.reduce(0) { $0 + $1.areaTime * $1.time }
                            maximumResidual = max(
                                maximumResidual,
                                abs(area - patch.areaTime) / (h * h * dt),
                                simd_length(moment - patch.firstMomentTime) / (h * h * h * dt),
                                abs(timeMoment - patch.timeWeightedArea) / (h * h * dt * dt))
                            let point = centre + patch.firstMomentTime / patch.areaTime
                            let time = patch.timeWeightedArea / patch.areaTime
                            let packet =
                                patch.areaTime * pressure(point: point, time: start + time) * patch.normal
                            centroidImpulse += packet
                            centroidAngular += simd_cross(point - body.position - time * velocity, packet)
                            centroidWork += simd_dot(velocity, packet)
                        }
                    }
                }
            }
        }
        func loads(_ impulse: SIMD3<Double>, _ angular: SIMD3<Double>, _ work: Double) -> Loads {
            .init(
                impulse: impulse, angularImpulse: angular, work: work,
                relativeImpulseError: simd_length(impulse - exact) / simd_length(exact),
                relativeAngularImpulseError: simd_length(angular - exactAngular) / simd_length(exactAngular),
                relativeWorkError: abs(work - exactWork) / abs(exactWork))
        }
        return .init(
            cellSize: h, rotation: angle, timeSlices: slices, duration: duration, velocity: velocity,
            size: size, initialGeometricCentre: initial.worldPoint(.zero),
            initialCentreOfMass: initial.position,
            pressureCoefficients: pressureCoefficients, gradientCoefficients: gradients,
            wallPatches: patches, wallSamples: samples, geometryEvaluations: evaluations,
            maximumIntervals: intervals, minimumSamplePressure: minimumPressure,
            maximumRelativeSampleMomentResidual: maximumResidual,
            sampled: loads(sampledImpulse, sampledAngular, sampledWork),
            centroid: loads(centroidImpulse, centroidAngular, centroidWork),
            exactImpulse: exact, exactAngularImpulse: exactAngular, exactWork: exactWork,
            impulseWorkResidual: sampledWork - simd_dot(velocity, sampledImpulse),
            computeSeconds: Date().timeIntervalSince(clock))
    }
}
