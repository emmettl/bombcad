import simd

public enum ExperimentalPistonCrossingStudy {
    public struct Result: Codable, Sendable {
        public let cellLength: Double
        public let pistonVelocity: Double
        public let steps: Int
        public let gridCrossings: Int
        public let remeshes: Int
        public let finalCells: Int
        public let minimumCellVolume: Double
        public let volumeResidual: Double
        public let relativeMassChange: Double
        public let energyBudgetResidual: Double
        public let momentumBudgetResidual: SIMD3<Double>
        public let minimumPressure: Double
    }
    public static func run() throws -> [Result] {
        var results: [Result] = []
        for h in [0.1, 0.05] {
            for speed in [-1.0, 1.0] {
                let start = speed < 0 ? 0.655 : 0.355
                let result = try PrescribedPistonTube.run(
                    cellLength: h, area: 0.01, length: start, pistonVelocity: speed, duration: 0.3)
                let after = result.cells.reduce(SIMD8<Double>.zero) { $0 + $1.amount }
                let before = result.initialAmount
                results.append(
                    Result(
                        cellLength: h, pistonVelocity: speed, steps: result.steps,
                        gridCrossings: result.gridCrossings, remeshes: result.remeshes,
                        finalCells: result.cells.count,
                        minimumCellVolume: result.cells.map(\.volume).min()!,
                        volumeResidual: result.cells.reduce(0) { $0 + $1.volume } - 0.01
                            * (start + speed * 0.3),
                        relativeMassChange: after[0] / before[0] - 1,
                        energyBudgetResidual: after[4] - before[4] + result.wallWork,
                        momentumBudgetResidual: SIMD3(after[1], after[2], after[3]) + result.wallImpulse,
                        minimumPressure: result.cells.map { $0.pressure() }.min()!))
            }
        }
        return results
    }
}
