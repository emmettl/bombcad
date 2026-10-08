import simd

/// Cell-average comparisons against the analytical piston wave before wall reflections.
public enum ExperimentalPistonWaveStudy {
    public struct Frame: Codable, Sendable {
        public let time: Double
        public let steps: Int
        public let rejectedSteps: Int
        public let relativePressureL1: Double
        public let relativeDensityL1: Double
        public let relativeMomentumL1: Double
        public let relativeEnergyL1: Double
        public let relativeWallWorkError: Double
        public let energyBudgetResidual: Double
        public let relativeMassChange: Double
    }
    public struct Result: Codable, Sendable {
        public let cellLength: Double
        public let cfl: Double
        public let pistonVelocity: Double
        public let reconstruction: String
        public let frames: [Frame]
    }
    public static func run(limited: Bool = false, progress: (Result) throws -> Void = { _ in }) throws
        -> [Result]
    {
        var results: [Result] = []
        for h in [0.1, 0.05, 0.025, 0.0125] {
            for cfl in [0.4, 0.2] {
                for speed in [-20.0, 20.0] {
                    let start = speed < 0 ? 0.655 : 0.355
                    let wave = try PlanarPistonWave(
                        length: start, density: 1.225, pressure: 101325, velocity: speed)
                    let run = try PrescribedPistonTube.run(
                        cellLength: h, area: 0.01, length: start,
                        pistonVelocity: speed, duration: 0.0008, cfl: cfl, outputTimes: [0.0005, 0.0008],
                        reconstruction: limited ? .minmod : .constant)
                    let frames = try run.snapshots.map { snapshot in
                        let totalVolume = snapshot.cells.reduce(0) { $0 + $1.volume }
                        var x = 0.0
                        var pressureError = 0.0
                        var densityError = 0.0
                        var momentumError = 0.0
                        var energyError = 0.0
                        for cell in snapshot.cells {
                            let next = x + cell.volume / 0.01
                            let exact = try wave.cell(lower: x, upper: next, time: snapshot.time, area: 0.01)
                            pressureError += cell.volume * abs(cell.pressure() - exact.pressure())
                            densityError += abs(cell.amount[0] - exact.amount[0])
                            momentumError += abs(cell.amount[1] - exact.amount[1])
                            energyError += abs(cell.amount[4] - exact.amount[4])
                            x = next
                        }
                        let after = snapshot.cells.reduce(SIMD8<Double>.zero) { $0 + $1.amount }
                        let exactWork = 0.01 * wave.wallPressure * speed * snapshot.time
                        return Frame(
                            time: snapshot.time, steps: snapshot.steps, rejectedSteps: snapshot.rejectedSteps,
                            relativePressureL1: pressureError / (101325 * totalVolume),
                            relativeDensityL1: densityError / (1.225 * totalVolume),
                            relativeMomentumL1: momentumError / (1.225 * abs(speed) * totalVolume),
                            relativeEnergyL1: energyError / (101325 / 0.4 * totalVolume),
                            relativeWallWorkError: (snapshot.wallWork - exactWork) / abs(exactWork),
                            energyBudgetResidual: after[4] - run.initialAmount[4] + snapshot.wallWork,
                            relativeMassChange: after[0] / run.initialAmount[0] - 1)
                    }
                    let result = Result(
                        cellLength: h, cfl: cfl, pistonVelocity: speed,
                        reconstruction: limited ? "minmod" : "constant", frames: frames)
                    results.append(result)
                    try progress(result)
                }
            }
        }
        return results
    }
}
