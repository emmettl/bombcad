import simd

/// Prescribed volume transfer through a small gas cell, separate from acoustic time stepping.
public enum ExperimentalFractionalSubstepStudy {
    public struct Result: Codable, Sendable {
        public let transitVolume: Double
        public let acceptedSteps: Int
        public let rejectedIntervals: Int
        public let transferCount: Int
        public let maximumOutflowFraction: Double
        public let relativeMassChange: Double
        public let momentumChange: SIMD3<Double>
        public let relativeEnergyChange: Double
        public let maximumRelativePressureError: Double
    }

    public static func run(transitVolumes: [Double] = [0.004, 0.001, 0.00025]) throws -> [Result] {
        try transitVolumes.map { transit in
            precondition(transit.isFinite && transit > 0)
            func volumes(_ time: Double) -> [Double] { [0.02 * (1 - time), transit, 0.02 * time] }
            let initial = volumes(0).map {
                FractionalGasTransport.Cell(
                    volume: $0, density: 1.225, velocity: SIMD3(1, 2, 3), pressure: 101325)
            }
            let faces = [
                FractionalVolumeRemap.Face(a: 0, b: 1, openArea: 1),
                .init(a: 1, b: 2, openArea: 1),
            ]
            let result = try FractionalRemapStepper.advance(
                initial, duration: 1, volumesAt: volumes, facesBetween: { _, _ in faces })
            let before = initial.reduce(SIMD8<Double>.zero) { $0 + $1.amount }
            let after = result.cells.reduce(SIMD8<Double>.zero) { $0 + $1.amount }
            return Result(
                transitVolume: transit, acceptedSteps: result.steps.count,
                rejectedIntervals: result.rejectedIntervals,
                transferCount: result.steps.reduce(0) { $0 + $1.transfers },
                maximumOutflowFraction: result.steps.map(\.maximumOutflowFraction).max() ?? 0,
                relativeMassChange: after[0] / before[0] - 1,
                momentumChange: SIMD3(after[1] - before[1], after[2] - before[2], after[3] - before[3]),
                relativeEnergyChange: after[4] / before[4] - 1,
                maximumRelativePressureError: result.cells.filter { $0.volume > 0 }
                    .map { abs($0.pressure() / 101325 - 1) }.max() ?? 0)
        }
    }
}
