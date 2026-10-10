import CompressibleFlow

/// Planar wall reference supplied by exact-tagged ContinuumKit.
/// Positive normal velocity is toward the wall, measured relative to the wall.
/// Geometry, wall motion, timestep, impulse/work and transport policy remain app-owned.
enum IdealGasWallRiemann {
    enum Failure: Error { case invalidState }
    struct Result {
        let pressure: Double
        /// Legacy incident-state rate estimate; not an exact shock-front velocity.
        let signalSpeed: Double
        let vacuum: Bool
    }
    static func solve(
        density: Double, pressure: Double, normalVelocity: Double, gamma: Double = 1.4
    ) throws -> Result {
        do {
            let result = try CompressibleFlow.IdealGasWallRiemann.solve(
                density: density, pressure: pressure, normalVelocity: normalVelocity, gamma: gamma)
            return Result(pressure: result.pressure, signalSpeed: result.signalSpeed, vacuum: result.vacuum)
        } catch {
            // Keep the app's existing failure contract, including rejected numerical states.
            throw Failure.invalidState
        }
    }
}
