import simd

/// Matched finite-speed piston runs; sampled profiles allow comparisons across partitions.
public enum ExperimentalPistonSensitivityStudy {
    public struct Result: Codable, Sendable {
        public let cellLength: Double
        public let cfl: Double
        public let mergeFraction: Double
        public let pistonVelocity: Double
        public let steps: Int
        public let remeshes: Int
        public let meanPressure: Double
        public let wallWork: Double
        public let relativeMassChange: Double
        public let energyBudgetResidual: Double
        public let momentumBudgetResidual: SIMD3<Double>
        public let volumeResidual: Double
        /// Piecewise-constant samples at 64 uniform fractional positions in the final tube.
        public let pressureProfile: [Double]
        public let normalVelocityProfile: [Double]
    }
    public static func run(progress: (Result) throws -> Void = { _ in }) throws -> [Result] {
        var results: [Result] = []
        for h in [0.1, 0.05] {
            for cfl in [0.4, 0.2] {
                for merge in [0.125, 0.25, 0.5] {
                    for speed in [-20.0, 20.0] {
                        let start = speed < 0 ? 0.655 : 0.355
                        let duration = 0.3 / abs(speed)
                        let run = try PrescribedPistonTube.run(
                            cellLength: h, area: 0.01, length: start,
                            pistonVelocity: speed, duration: duration, mergeFraction: merge, cfl: cfl)
                        let cells = run.cells
                        let after = cells.reduce(SIMD8<Double>.zero) { $0 + $1.amount }
                        let before = run.initialAmount
                        let volume = cells.reduce(0) { $0 + $1.volume }
                        var boundaries = [0.0]
                        for cell in cells { boundaries.append(boundaries.last! + cell.volume) }
                        let samples = (0..<64).map { n in
                            let position = volume * (Double(n) + 0.5) / 64
                            return cells.indices.first { position < boundaries[$0 + 1] } ?? cells.count - 1
                        }
                        let result = Result(
                            cellLength: h, cfl: cfl, mergeFraction: merge, pistonVelocity: speed,
                            steps: run.steps, remeshes: run.remeshes,
                            meanPressure: cells.reduce(0) { $0 + $1.volume * $1.pressure() } / volume,
                            wallWork: run.wallWork, relativeMassChange: after[0] / before[0] - 1,
                            energyBudgetResidual: after[4] - before[4] + run.wallWork,
                            momentumBudgetResidual: SIMD3(after[1], after[2], after[3]) + run.wallImpulse,
                            volumeResidual: volume - 0.01 * (start + speed * duration),
                            pressureProfile: samples.map { cells[$0].pressure() },
                            normalVelocityProfile: samples.map { cells[$0].velocity.x })
                        results.append(result)
                        try progress(result)
                    }
                }
            }
        }
        return results
    }
}
