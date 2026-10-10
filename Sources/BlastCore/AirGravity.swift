import Foundation

/// Gravity acting on the air (see `stencilFluxesGravity` in Solver.metal and
/// docs/air-blast-model.md#gravity). The air is filled at rest in a hydrostatic atmosphere whose
/// ground is the air it was filled with, cooling with height at `lapseRate` as the standard
/// atmosphere does (the fireball's rise assumes the same), or isothermal; a vertical sweep then
/// works on the gas's deviation from that atmosphere, so air left at rest stays at rest to the bit.
/// Off by default (nil in `SolverConfiguration`).
public struct AirGravity: Sendable, Hashable, Codable {
    /// m/s², downwards.
    public var acceleration: Float = 9.80665
    /// K/m that the background cools with height; 0 for isothermal.
    public var lapseRate: Float = 0.0065

    public init(acceleration: Float = 9.80665, lapseRate: Float = 0.0065) {
        self.acceleration = acceleration
        self.lapseRate = lapseRate
    }

    /// Air's gas constant, J/(kg K), as the shaders take it.
    static let gasConstant: Float = 287.05

    /// The background at height `z` above air at the ground of `ground`: density and pressure.
    public func atmosphere(at z: Float, ground: Primitive) -> (density: Float, pressure: Float) {
        let t0 = ground.pressure / (ground.density * Self.gasConstant)
        let t: Float
        let p: Float
        if lapseRate > 0 {
            t = t0 - lapseRate * z
            p = ground.pressure * pow(t / t0, acceleration / (Self.gasConstant * lapseRate))
        } else {
            t = t0
            p = ground.pressure * exp(-acceleration * z / (Self.gasConstant * t0))
        }
        return (p / (Self.gasConstant * t), p)
    }
}
