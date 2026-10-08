import Foundation
import simd

/// Calorically perfect gas, gamma=1.4, initially resting left of a leftward normal shock.
/// Independent jump relations: https://www.grc.nasa.gov/WWW/k-12/airplane/normal.html
/// Reflection leaves gas at rest at x=0. No numerical wall-Riemann solver is called here.
struct NormalShockReflection {
    enum Failure: Error { case invalidInput, boundaryInteraction }
    let density: Double
    let pressure: Double
    let shockPosition: Double
    let length: Double
    let mach: Double
    let incidentDensity: Double
    let incidentPressure: Double
    let incidentVelocity: Double
    let reflectedDensity: Double
    let reflectedPressure: Double
    let incidentSpeed: Double
    let reflectedSpeed: Double
    let arrivalTime: Double
    /// Earliest intersection of the opposite wall's rarefaction head with either shock.
    let interactionTime: Double

    init(
        mach: Double, shockPosition: Double = 0.655, length: Double = 2,
        density: Double = 1.225, pressure: Double = 101325
    ) throws {
        guard mach.isFinite && mach > 1, length.isFinite && length > 0,
            shockPosition.isFinite && shockPosition > 0 && shockPosition < length,
            density.isFinite && density > 0, pressure.isFinite && pressure > 0
        else { throw Failure.invalidInput }
        let gamma = 1.4
        func ratios(_ m: Double) -> (rho: Double, p: Double) {
            let square = m * m
            return (
                (gamma + 1) * square / ((gamma - 1) * square + 2),
                (2 * gamma * square - (gamma - 1)) / (gamma + 1)
            )
        }
        let first = ratios(mach)
        let shockSpeed = mach * sqrt(gamma * pressure / density)
        let rho1 = density * first.rho
        let p1 = pressure * first.p
        let u1 = -shockSpeed * (1 - 1 / first.rho)
        let sound1 = sqrt(gamma * p1 / rho1)
        // Solve the normal-shock velocity jump for reflected upstream Mach Mr:
        // |u1|/c1 = 2/(gamma+1) * (Mr - 1/Mr).
        let k = (gamma + 1) * abs(u1) / (2 * sound1)
        let reflectedMach = (k + sqrt(k * k + 4)) / 2
        let second = ratios(reflectedMach)
        let speed = u1 + reflectedMach * sound1
        let arrival = shockPosition / shockSpeed
        let headSpeed = sound1 - u1
        let before = headSpeed > shockSpeed ? (length - shockPosition) / (headSpeed - shockSpeed) : .infinity
        let after = (length + speed * arrival) / (headSpeed + speed)
        guard rho1.isFinite && p1.isFinite && u1.isFinite,
            speed.isFinite && speed > 0, second.rho.isFinite && second.p.isFinite,
            (rho1 * second.rho).isFinite && (p1 * second.p).isFinite,
            before > arrival, after > arrival
        else { throw Failure.invalidInput }
        self.density = density
        self.pressure = pressure
        self.shockPosition = shockPosition
        self.length = length
        self.mach = mach
        incidentDensity = rho1
        incidentPressure = p1
        incidentVelocity = u1
        reflectedDensity = rho1 * second.rho
        reflectedPressure = p1 * second.p
        incidentSpeed = shockSpeed
        reflectedSpeed = speed
        arrivalTime = arrival
        interactionTime = after
    }

    func wallPressure(time: Double) throws -> Double {
        try check(time)
        return time < arrivalTime ? pressure : reflectedPressure
    }
    /// Positive pressure impulse magnitude on the reflecting wall, including ambient pressure.
    func wallImpulse(time: Double, area: Double) throws -> Double {
        try check(time)
        guard area.isFinite && area > 0 else { throw Failure.invalidInput }
        return area * (pressure * time + (reflectedPressure - pressure) * max(0, time - arrivalTime))
    }
    /// Conservative cell average in the region unaffected by the opposite wall.
    func cell(lower: Double, upper: Double, time: Double, area: Double) throws -> FractionalGasTransport.Cell
    {
        try check(time)
        let sound1 = sqrt(1.4 * incidentPressure / incidentDensity)
        let unaffectedEnd = length - (sound1 - incidentVelocity) * time
        guard area.isFinite && area > 0, lower.isFinite && upper.isFinite,
            lower >= 0 && upper > lower && upper <= unaffectedEnd
        else { throw Failure.boundaryInteraction }
        let front =
            time < arrivalTime ? shockPosition - incidentSpeed * time : reflectedSpeed * (time - arrivalTime)
        let left = min(upper - lower, max(0, front - lower))
        let base = FractionalGasTransport.Cell(
            volume: left * area,
            density: time < arrivalTime ? density : reflectedDensity,
            pressure: time < arrivalTime ? pressure : reflectedPressure)
        let incident = FractionalGasTransport.Cell(
            volume: (upper - lower - left) * area,
            density: incidentDensity, velocity: SIMD3(incidentVelocity, 0, 0), pressure: incidentPressure)
        return .init(volume: (upper - lower) * area, amount: base.amount + incident.amount)
    }
    private func check(_ time: Double) throws {
        guard time.isFinite && time >= 0 else { throw Failure.invalidInput }
        guard time < interactionTime else { throw Failure.boundaryInteraction }
    }
}
