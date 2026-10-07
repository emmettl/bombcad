import simd

/// Periodic or walled pressure pulse with stationary fractional volumes; not moving-wall coupling.
public enum ExperimentalFractionalFluxStudy {
    public struct Result: Codable, Sendable {
        public let smallestVolume: Double
        public let reflectingWalls: Bool
        public let duration: Double
        public let steps: Int
        public let minimumStep: Double
        public let relativeMassChange: Double
        public let momentumChange: SIMD3<Double>
        public let wallImpulse: SIMD3<Double>
        public let momentumBudgetResidual: SIMD3<Double>
        public let relativeEnergyChange: Double
        public let minimumPressure: Double
        public let maximumSpeed: Double
    }

    public static func run(reflectingWalls: Bool = false) throws -> [Result] {
        try [0.001, 0.00025, 0.0000625].map { volume in
            let initial = (0..<8).map {
                FractionalGasTransport.Cell(
                    volume: $0 == 0 ? volume : 0.001, density: 1.225,
                    pressure: $0 == (reflectingWalls ? 0 : 4) ? 150000 : 101325)
            }
            let faces = (0..<(reflectingWalls ? 7 : 8)).map {
                FractionalEulerFlux.Face(a: $0, b: ($0 + 1) % 8, normal: SIMD3(1, 0, 0), area: 0.01)
            }
            let walls: [FractionalEulerFlux.Wall] =
                reflectingWalls
                ? [
                    .init(cell: 0, normal: SIMD3(-1, 0, 0), area: 0.01),
                    .init(cell: 7, normal: SIMD3(1, 0, 0), area: 0.01),
                ] : []
            let duration = 0.0005
            var cells = initial
            var elapsed = 0.0
            var steps = 0
            var minimumStep = Double.infinity
            var wallImpulse = SIMD3<Double>.zero
            while elapsed < duration {
                let limit = try FractionalEulerFlux.maximumStep(cells, faces: faces, walls: walls)
                let step = min(limit, duration - elapsed)
                guard steps < 100000 && step > 0 && elapsed + step > elapsed else {
                    throw FractionalEulerFlux.Failure.invalidStep
                }
                let result = try FractionalEulerFlux.advanceWithWalls(
                    cells, faces: faces, walls: walls, duration: step)
                cells = result.cells
                wallImpulse += result.wallImpulses.reduce(.zero, +)
                elapsed += step
                steps += 1
                minimumStep = min(minimumStep, step)
            }
            let before = initial.reduce(SIMD8<Double>.zero) { $0 + $1.amount }
            let after = cells.reduce(SIMD8<Double>.zero) { $0 + $1.amount }
            let momentumChange = SIMD3(after[1] - before[1], after[2] - before[2], after[3] - before[3])
            return Result(
                smallestVolume: volume, reflectingWalls: reflectingWalls,
                duration: duration, steps: steps, minimumStep: minimumStep,
                relativeMassChange: after[0] / before[0] - 1,
                momentumChange: momentumChange, wallImpulse: wallImpulse,
                momentumBudgetResidual: momentumChange + wallImpulse,
                relativeEnergyChange: after[4] / before[4] - 1,
                minimumPressure: cells.map { $0.pressure() }.min()!,
                maximumSpeed: cells.map { simd_length($0.velocity) }.max()!)
        }
    }
}
