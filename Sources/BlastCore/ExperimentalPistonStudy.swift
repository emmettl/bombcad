import Foundation
import simd

/// Prescribed planar piston in a closed four-cell tube, without cell crossings.
public enum ExperimentalPistonStudy {
    public struct Result: Codable, Sendable {
        public let pistonVelocity: Double
        public let duration: Double
        public let steps: Int
        public let finalVolume: Double
        public let volumeResidual: Double
        public let relativeMassChange: Double
        public let wallWork: Double
        public let energyBudgetResidual: Double
        public let momentumBudgetResidual: SIMD3<Double>
        public let meanPressure: Double
        public let quasiStaticPressure: Double
        public let relativeQuasiStaticPressureError: Double
    }
    public static func run() throws -> [Result] {
        try [-1.0, -0.5, -0.25, 0.25, 0.5, 1].map { speed in
            let initial = [FractionalGasTransport.Cell](
                repeating: .init(volume: 0.001, density: 1.225, pressure: 101325), count: 4)
            let faces = (0..<3).map {
                FractionalEulerFlux.Face(a: $0, b: $0 + 1, normal: SIMD3(1, 0, 0), area: 0.01)
            }
            let walls = [
                FractionalEulerFlux.Wall(cell: 0, normal: SIMD3(-1, 0, 0), area: 0.01),
                .init(cell: 3, normal: SIMD3(1, 0, 0), area: 0.01, velocity: SIMD3(speed, 0, 0)),
            ]
            let duration = 0.04 / abs(speed)
            var cells = initial
            var elapsed = 0.0
            var steps = 0
            var wallWork = 0.0
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
                wallWork += result.wallWork.reduce(0, +)
                wallImpulse += result.wallImpulses.reduce(.zero, +)
                elapsed += step
                steps += 1
            }
            let before = initial.reduce(SIMD8<Double>.zero) { $0 + $1.amount }
            let after = cells.reduce(SIMD8<Double>.zero) { $0 + $1.amount }
            let volume = cells.reduce(0) { $0 + $1.volume }
            let expectedVolume = 0.004 + 0.01 * speed * duration
            let meanPressure = cells.reduce(0) { $0 + $1.volume * $1.pressure() } / volume
            let quasiStatic = 101325 * pow(0.004 / expectedVolume, 1.4)
            return Result(
                pistonVelocity: speed, duration: duration, steps: steps,
                finalVolume: volume, volumeResidual: volume - expectedVolume,
                relativeMassChange: after[0] / before[0] - 1,
                wallWork: wallWork, energyBudgetResidual: after[4] - before[4] + wallWork,
                momentumBudgetResidual: SIMD3(
                    after[1] - before[1], after[2] - before[2], after[3] - before[3]) + wallImpulse,
                meanPressure: meanPressure, quasiStaticPressure: quasiStatic,
                relativeQuasiStaticPressureError: meanPressure / quasiStatic - 1)
        }
    }
}
