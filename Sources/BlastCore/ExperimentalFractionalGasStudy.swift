import simd

/// Sealed ideal-gas compression with prescribed volume and first-order pressure work.
/// Opposing fixed/moving wall impulses cancel; only the moving wall performs work.
public enum ExperimentalFractionalGasStudy {
    public struct Result: Codable, Sendable {
        public let steps: Int
        public let finalVolume: Double
        public let pressure: Double
        public let adiabaticPressure: Double
        public let relativePressureError: Double
        public let massChange: Double
        public let gasEnergyChange: Double
        public let gasWallWork: Double
        public let bodyWallWork: Double
        public let energyBudgetResidual: Double
    }
    public static func run() throws -> [Result] {
        let initial = FractionalGasTransport.Cell(volume: 1, density: 1.225, pressure: 101325)
        let finalVolume = 0.9
        let gamma = 1.4
        let exactPressure = 101325 * pow(1 / finalVolume, gamma)
        return try [1, 4, 16, 64].map { steps in
            var cells = [initial]
            var work = 0.0
            for n in 0..<steps {
                let volume = 1 - 0.1 * Double(n + 1) / Double(steps)
                let gasWork = cells[0].pressure() * (cells[0].volume - volume)
                work += gasWork
                cells = try FractionalGasTransport.advance(
                    cells, newVolumes: [volume], transfers: [],
                    walls: [.init(cell: 0, impulse: .zero, gasWork: gasWork)])
            }
            let final = cells[0]
            let energyChange = final.amount[4] - initial.amount[4]
            return Result(
                steps: steps, finalVolume: final.volume, pressure: final.pressure(),
                adiabaticPressure: exactPressure, relativePressureError: final.pressure() / exactPressure - 1,
                massChange: final.amount[0] - initial.amount[0], gasEnergyChange: energyChange,
                gasWallWork: work, bodyWallWork: -work, energyBudgetResidual: energyChange - work)
        }
    }
}
