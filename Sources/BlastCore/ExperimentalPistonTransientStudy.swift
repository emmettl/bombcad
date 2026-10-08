import simd

/// Matched physical-time profiles on three grids; the finest run is a numerical reference.
public enum ExperimentalPistonTransientStudy {
    public struct Frame: Codable, Sendable {
        public let time: Double
        public let steps: Int
        public let meanPressure: Double
        public let wallWork: Double
        public let volumeResidual: Double
        public let relativeMassChange: Double
        public let energyBudgetResidual: Double
        public let momentumBudgetResidual: SIMD3<Double>
        public let pressureProfile: [Double]
        public let normalVelocityProfile: [Double]
        /// Complete ordered cell profiles for overlap-weighted comparisons without sample aliasing.
        public let cellVolumes: [Double]
        public let cellPressures: [Double]
        public let cellNormalVelocities: [Double]
    }
    public struct Result: Codable, Sendable {
        public let cellLength: Double
        public let cfl: Double
        public let mergeFraction: Double
        public let pistonVelocity: Double
        public let frames: [Frame]
    }
    public static func run(progress: (Result) throws -> Void = { _ in }) throws -> [Result] {
        var results: [Result] = []
        for h in [0.1, 0.05, 0.025] {
            for cfl in [0.4, 0.2] {
                for speed in [-20.0, 20.0] {
                    let start = speed < 0 ? 0.655 : 0.355
                    let run = try PrescribedPistonTube.run(
                        cellLength: h, area: 0.01, length: start, pistonVelocity: speed,
                        duration: 0.015, cfl: cfl, outputTimes: [0.0005, 0.002, 0.005, 0.015])
                    let frames = run.snapshots.map { snapshot in
                        let cells = snapshot.cells
                        let volume = cells.reduce(0) { $0 + $1.volume }
                        let after = cells.reduce(SIMD8<Double>.zero) { $0 + $1.amount }
                        let before = run.initialAmount
                        var boundaries = [0.0]
                        for cell in cells { boundaries.append(boundaries.last! + cell.volume) }
                        let samples = (0..<64).map { n in
                            let position = volume * (Double(n) + 0.5) / 64
                            return cells.indices.first { position < boundaries[$0 + 1] } ?? cells.count - 1
                        }
                        return Frame(
                            time: snapshot.time, steps: snapshot.steps,
                            meanPressure: cells.reduce(0) { $0 + $1.volume * $1.pressure() } / volume,
                            wallWork: snapshot.wallWork,
                            volumeResidual: volume - 0.01 * (start + speed * snapshot.time),
                            relativeMassChange: after[0] / before[0] - 1,
                            energyBudgetResidual: after[4] - before[4] + snapshot.wallWork,
                            momentumBudgetResidual: SIMD3(after[1], after[2], after[3])
                                + snapshot.wallImpulse,
                            pressureProfile: samples.map { cells[$0].pressure() },
                            normalVelocityProfile: samples.map { cells[$0].velocity.x },
                            cellVolumes: cells.map(\.volume), cellPressures: cells.map { $0.pressure() },
                            cellNormalVelocities: cells.map { $0.velocity.x })
                    }
                    let result = Result(
                        cellLength: h, cfl: cfl, mergeFraction: 0.25,
                        pistonVelocity: speed, frames: frames)
                    results.append(result)
                    try progress(result)
                }
            }
        }
        return results
    }
}
