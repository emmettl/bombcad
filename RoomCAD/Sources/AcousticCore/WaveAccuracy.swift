import Foundation
import simd

/// The wave solver's numerical dispersion: how much more slowly than sound its waves travel.
///
/// Yee's staggered grid with leapfrog time steps supports a plane wave of angular frequency ω and
/// wavenumber k along unit direction u when
///
///     sin²(ωΔt/2) / (cΔt)² = Σᵢ sin²(k uᵢ Δᵢ / 2) / Δᵢ²
///
/// (Taflove and Hagness, *Computational Electrodynamics*, ch. 4; the acoustic scheme has the same form).
/// Waves travel at ω/k, slower than c by an amount that grows with frequency and is largest along the
/// grid's axes. A room mode's frequency is low by about the same fraction, and a wave arriving after a
/// distance d lags by 2πf·d/c times it.
public enum WaveAccuracy {
    /// The phase velocity's relative error at `frequency` along `direction`, negative when waves travel
    /// slower than sound; nil above the grid's cut-off in that direction.
    public static func phaseVelocityError(
        frequency: Double, direction: SIMD3<Double>, spacing: SIMD3<Double>, timeStep dt: Double,
        soundSpeed c: Double
    ) -> Double? {
        let u = simd_normalize(direction)
        let omega = 2 * Double.pi * frequency
        let target = pow(sin(omega * dt / 2) / (c * dt), 2)
        func supported(_ k: Double) -> Double {
            (0..<3).reduce(0) { $0 + pow(sin(k * u[$1] * spacing[$1] / 2) / spacing[$1], 2) }
        }
        // The right-hand side rises with k until the first component reaches half a wavelength per cell.
        let limit = Double.pi / (0..<3).map { abs(u[$0]) * spacing[$0] }.max()!
        guard supported(limit) >= target else { return nil }
        var low = 0.0
        var high = limit
        for _ in 0..<100 {
            let mid = (low + high) / 2
            if supported(mid) < target { low = mid } else { high = mid }
        }
        return omega / ((low + high) / 2 * c) - 1
    }

    /// Directions along an axis, a face diagonal and the body diagonal: between them, the extremes of
    /// the error on a cubic grid.
    public static let directions: [SIMD3<Double>] = [
        [1, 0, 0], [0, 1, 0], [0, 0, 1], [1, 1, 0], [1, 0, 1], [0, 1, 1], [1, 1, 1],
    ]

    /// The largest error, in magnitude, over `directions`.
    public static func worstPhaseVelocityError(
        frequency: Double, spacing: SIMD3<Double>, timeStep: Double, soundSpeed: Double
    ) -> Double? {
        let errors = directions.map {
            phaseVelocityError(
                frequency: frequency, direction: $0, spacing: spacing, timeStep: timeStep,
                soundSpeed: soundSpeed)
        }
        guard errors.allSatisfy({ $0 != nil }) else { return nil }
        return errors.compactMap { $0 }.max { abs($0) < abs($1) }
    }

    /// The grid RoomCAD would use for `room` with its crossover at `crossover` Hz: cell sizes and time step.
    public static func grid(room: ShoeboxRoom, sampleRate: Int, crossover: Double, atmosphere: Atmosphere)
        -> (spacing: SIMD3<Double>, timeStep: Double, cells: SIMD3<Int>)
    {
        let solver = WaveSolver(
            room: room, sampleRate: sampleRate, topFrequency: crossover * 2.squareRoot(),
            atmosphere: atmosphere)
        return (solver.spacing, solver.timeStep, solver.cells)
    }
}
