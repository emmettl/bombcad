import Foundation
import simd

/// Uniform resting gas to the left of a constant-speed piston, before the wave reaches x=0.
/// Euler shock/rarefaction relations: https://www.clawpack.org/riemann_book/html/Euler.html
struct PlanarPistonWave {
    enum Failure: Error { case invalidInput, vacuumUnsupported, reflectedWave }
    let length: Double
    let density: Double
    let pressure: Double
    let velocity: Double
    let wallPressure: Double
    let sound: Double
    let starSound: Double
    let starDensity: Double
    let shockSpeed: Double
    private let gamma = 1.4

    init(length: Double, density: Double, pressure: Double, velocity: Double) throws {
        guard length.isFinite && length > 0, velocity.isFinite else { throw Failure.invalidInput }
        let wall = try IdealGasWallRiemann.solve(
            density: density, pressure: pressure, normalVelocity: -velocity)
        guard !wall.vacuum else { throw Failure.vacuumUnsupported }
        self.length = length
        self.density = density
        self.pressure = pressure
        self.velocity = velocity
        wallPressure = wall.pressure
        sound = sqrt(1.4 * pressure / density)
        let ratio = wall.pressure / pressure
        let beta = 0.4 / 2.4
        starDensity =
            velocity < 0
            ? density * (ratio + beta) / (beta * ratio + 1)
            : density * pow(ratio, 1 / 1.4)
        starSound = sqrt(1.4 * wall.pressure / starDensity)
        shockSpeed = sqrt((2.4 * wall.pressure + 0.4 * pressure) / (2 * density))
    }

    /// Extensive exact cell average. Four-point Gaussian quadrature integrates the degree-seven
    /// rarefaction conserved state for gamma=1.4, after splitting at each wave boundary.
    func cell(lower: Double, upper: Double, time: Double, area: Double) throws -> FractionalGasTransport.Cell
    {
        guard time.isFinite && time > 0, area.isFinite && area > 0,
            lower.isFinite && upper.isFinite && lower >= 0 && upper > lower,
            upper <= length + velocity * time + 1e-12 * length
        else { throw Failure.invalidInput }
        let frontSpeed = velocity < 0 ? shockSpeed : sound
        guard length - frontSpeed * time > 0 else { throw Failure.reflectedWave }
        let fronts =
            velocity < 0
            ? [length - shockSpeed * time]
            : [length - sound * time, length + (velocity - starSound) * time]
        let bounds = ([lower, upper] + fronts.filter { $0 > lower && $0 < upper }).sorted()
        let nodes = [-0.8611363115940526, -0.3399810435848563, 0.3399810435848563, 0.8611363115940526]
        let weights = [0.3478548451374538, 0.6521451548625461, 0.6521451548625461, 0.3478548451374538]
        var amount = SIMD8<Double>.zero
        for n in 0..<(bounds.count - 1) {
            let middle = (bounds[n] + bounds[n + 1]) / 2
            let half = (bounds[n + 1] - bounds[n]) / 2
            for q in nodes.indices {
                amount += half * weights[q] * area * state(x: middle + half * nodes[q], time: time)
            }
        }
        return FractionalGasTransport.Cell(volume: (upper - lower) * area, amount: amount)
    }

    private func state(x: Double, time: Double) -> SIMD8<Double> {
        let xi = (x - length) / time
        let rho: Double
        let u: Double
        let p: Double
        if xi <= -(velocity < 0 ? shockSpeed : sound) {
            (rho, u, p) = (density, 0, pressure)
        } else if velocity < 0 || xi >= velocity - starSound {
            (rho, u, p) = (starDensity, velocity, wallPressure)
        } else {
            let a = 2 / (gamma + 1) * (sound - (gamma - 1) * xi / 2)
            u = 2 / (gamma + 1) * (sound + xi)
            rho = density * pow(a / sound, 2 / (gamma - 1))
            p = pressure * pow(a / sound, 2 * gamma / (gamma - 1))
        }
        return SIMD8(rho, rho * u, 0, 0, p / (gamma - 1) + 0.5 * rho * u * u, 0, 0, 0)
    }
}
