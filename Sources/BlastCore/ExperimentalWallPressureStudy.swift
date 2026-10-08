import Foundation

/// Incident uniform gas against a planar wall, spanning expansion, vacuum and compression.
public enum ExperimentalWallPressureStudy {
    public struct Result: Codable, Sendable {
        public let normalMach: Double
        public let pressureRatio: Double
        public let signalSpeed: Double
        public let vacuum: Bool
    }
    public static func run() throws -> [Result] {
        let density = 1.225
        let pressure = 101325.0
        let sound = sqrt(1.4 * pressure / density)
        return try [-6.0, -4, -2, -0.1, 0, 0.1, 1, 3].map { mach in
            let result = try IdealGasWallRiemann.solve(
                density: density, pressure: pressure, normalVelocity: mach * sound)
            return Result(
                normalMach: mach, pressureRatio: result.pressure / pressure,
                signalSpeed: result.signalSpeed, vacuum: result.vacuum)
        }
    }
}
