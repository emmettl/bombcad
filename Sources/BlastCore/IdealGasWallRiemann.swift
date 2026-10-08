import Foundation

/// Exact planar ideal-gas wall pressure for a uniform incident state.
/// Positive normal velocity is toward the wall, measured relative to the wall.
/// Shock/rarefaction relations: https://www.clawpack.org/riemann_book/html/Euler.html
enum IdealGasWallRiemann {
    enum Failure: Error { case invalidState }
    struct Result {
        let pressure: Double
        /// Acoustic/shock rate relative to the wall; wall travel is added by the timestep reference.
        let signalSpeed: Double
        let vacuum: Bool
    }
    static func solve(
        density: Double, pressure: Double, normalVelocity: Double, gamma: Double = 1.4
    ) throws -> Result {
        guard density.isFinite && density > 0, pressure.isFinite && pressure > 0,
            normalVelocity.isFinite, gamma.isFinite && gamma > 1
        else { throw Failure.invalidState }
        let sound = sqrt(gamma * pressure / density)
        let wallPressure: Double
        let wave: Double
        let vacuum: Bool
        if normalVelocity > 0 {
            // Invert u = (p* - p) sqrt(A / (p* + B)) on the compressive branch.
            let a = 2 / ((gamma + 1) * density)
            let b = (gamma - 1) / (gamma + 1) * pressure
            let q = normalVelocity * normalVelocity / a
            wallPressure = pressure + q / 2 + sqrt(q) * sqrt(pressure + b + q / 4)
            wave = sqrt(((gamma + 1) * wallPressure + (gamma - 1) * pressure) / (2 * density))
            vacuum = false
        } else {
            let base = 1 + (gamma - 1) * normalVelocity / (2 * sound)
            vacuum = base <= 0
            wallPressure = vacuum ? 0 : pressure * pow(base, 2 * gamma / (gamma - 1))
            wave = sound
        }
        let signalSpeed = abs(normalVelocity) + wave
        guard wallPressure.isFinite && wallPressure >= 0, signalSpeed.isFinite && signalSpeed > 0 else {
            throw Failure.invalidState
        }
        return Result(pressure: wallPressure, signalSpeed: signalSpeed, vacuum: vacuum)
    }
}
