import simd

/// Galilean translation and x reflection of the independent stationary shock solution.
/// The right piston is at L+v*t; unshocked gas moves at v. This avoids an initial piston wave.
/// The fixed left wall must remain on the separating-gas branch for the inherited cutoff.
struct MovingShockReflection {
    enum Failure: Error { case invalidInput }
    let stationary: NormalShockReflection
    let velocity: Double

    init(mach: Double, velocity: Double) throws {
        let reference = try NormalShockReflection(mach: mach)
        guard velocity.isFinite && (velocity * velocity).isFinite,
            velocity > reference.incidentVelocity
        else { throw Failure.invalidInput }
        stationary = reference
        self.velocity = velocity
    }

    func wallImpulse(time: Double, area: Double) throws -> Double {
        try stationary.wallImpulse(time: time, area: area)
    }
    func wallWork(time: Double, area: Double) throws -> Double {
        try velocity * wallImpulse(time: time, area: area)
    }
    /// Exact conservative cell average, restricted to the unaffected part of the channel.
    func cell(lower: Double, upper: Double, time: Double, area: Double) throws -> FractionalGasTransport.Cell
    {
        let wall = stationary.length + velocity * time
        let cell = try stationary.cell(lower: wall - upper, upper: wall - lower, time: time, area: area)
        var amount = cell.amount
        amount[1] = velocity * cell.amount[0] - cell.amount[1]
        amount[4] = cell.amount[4] - velocity * cell.amount[1] + 0.5 * velocity * velocity * cell.amount[0]
        let result = FractionalGasTransport.Cell(volume: cell.volume, amount: amount)
        _ = try FractionalGasTransport.advance([result], newVolumes: [result.volume], transfers: [])
        return result
    }
}
