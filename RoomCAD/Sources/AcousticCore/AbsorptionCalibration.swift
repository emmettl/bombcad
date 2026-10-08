import Foundation
import ImpulseResponseKit

/// Fits a room's absorption to measured reverberation times by simulating it.
///
/// Eyring's formula takes the sound field to be diffuse. Where absorption is concentrated, on an
/// audience floor for example, or surfaces scatter little, a room decays more slowly than the formula
/// says, so absorption fitted with it leaves the simulated decay too long. Here every absorbing
/// surface's absorption, and every fitted zone's, is scaled together in each octave band, keeping
/// their proportions until one reaches 0.99, until the simulated T30 matches the target.
///
/// Each step simulates the room and measures T30 in each band at every receiver. The first step scales
/// the absorption by the ratio of the absorption area the target implies to the area the simulated
/// time implies, both by Sabine's formula with the room's air: `A = 24 ln 10 V / (c T) - 4 m V`. Later
/// steps take how strongly the time answered the last change, `T ∝ f^(-b)`, and solve for the target
/// with that: a secant step.
public enum AbsorptionCalibration {
    public struct Step: Sendable {
        /// Mean T30 over the receivers in each band, or nil where it could not be measured.
        public var reverberationTime: [Double?]
        /// The factor the absorption was scaled by in each band, from the room as given.
        public var factors: [Double]
    }

    /// The room with `settings`' absorption scaled so the simulated T30 meets `target` within
    /// `tolerance` (a fraction) in every band that has a target, or after `iterations` simulations.
    /// Bands without a target, or whose decay cannot be measured, keep their absorption. `simulate`
    /// generates a response's channels for settings (by default the full model).
    ///
    /// Returns the calibrated room, each step's measurements, and the best: in each band, the factor
    /// and time from the step that came closest to the target there. Each band's absorption barely
    /// changes another band's decay, so the bands are chosen apart; a band whose time is noisy, or held
    /// by the wave solver, keeps its best step rather than its last.
    public static func fit(
        _ settings: RoomResponseSettings, to target: [Double?], tolerance: Double = 0.02, iterations: Int = 5,
        simulate: (RoomResponseSettings) throws -> [[Float]] = {
            try RoomResponseGenerator.generate($0).response.channels
        }
    ) throws -> (room: ShoeboxRoom, steps: [Step], best: Step) {
        precondition(target.count == OctaveBands.count)
        let room = settings.room
        let c = settings.atmosphere.soundSpeed
        let volume = room.volume
        func area(_ time: Double, band: Int) -> Double {
            let air =
                settings.airAbsorption
                ? 2 * settings.atmosphere.amplitudeAttenuationPerMetre(frequency: OctaveBands.centres[band])
                : 0
            return 24 * log(10) * volume / (c * time) - 4 * air * volume
        }
        var factors = [Double](repeating: 1, count: OctaveBands.count)
        var steps: [Step] = []
        for iteration in 0...iterations {
            var trial = settings
            trial.room = room.scalingAbsorption(by: factors)
            let channels = try simulate(trial)
            let times = OctaveBands.centres.indices.map { band -> Double? in
                let measured = channels.compactMap {
                    DecayAnalysis.reverberationTime(
                        DecayAnalysis.octaveBand($0, sampleRate: settings.sampleRate, band: band),
                        sampleRate: settings.sampleRate)
                }
                return measured.count == channels.count && !measured.isEmpty
                    ? measured.reduce(0, +) / Double(measured.count) : nil
            }
            steps.append(Step(reverberationTime: times, factors: factors))
            let done = OctaveBands.centres.indices.allSatisfy { band in
                guard let goal = target[band], let time = times[band] else { return true }
                return abs(time / goal - 1) <= tolerance
            }
            if done || iteration == iterations { break }
            for band in factors.indices {
                guard let goal = target[band], let time = times[band] else { continue }
                var ratio: Double
                if steps.count >= 2, let before = steps[steps.count - 2].reverberationTime[band],
                    steps[steps.count - 2].factors[band] != factors[band], before != time
                {
                    // How strongly the time has answered the absorption: T ∝ f^(-b), from the last two
                    // steps. A room that is not diffuse answers less than Sabine's formula says.
                    let b =
                        -log(time / before) / log(factors[band] / steps[steps.count - 2].factors[band])
                    if b >= 0.3 {
                        ratio = pow(time / goal, 1 / min(b, 1.5))
                    } else {
                        // The time hardly answered, or went the wrong way, as it can where the wave
                        // solver holds a band or the decay is noisy: fall back to Sabine's ratio.
                        let have = area(time, band: band)
                        let want = area(goal, band: band)
                        guard have > 0, want > 0 else { continue }
                        ratio = want / have
                    }
                } else {
                    let have = area(time, band: band)
                    let want = area(goal, band: band)
                    guard have > 0, want > 0 else { continue }
                    ratio = want / have
                }
                // Never more than doubling or halving in one step, and never past total absorption.
                let limit = room.absorptionScaleLimit(band: band)
                factors[band] = min(max(factors[band] * min(max(ratio, 0.5), 2), 0), limit)
            }
        }
        var best = Step(reverberationTime: steps[0].reverberationTime, factors: steps[0].factors)
        for band in factors.indices {
            guard let goal = target[band] else { continue }
            let closest = steps.min { a, b in
                abs((a.reverberationTime[band] ?? .infinity) / goal - 1)
                    < abs((b.reverberationTime[band] ?? .infinity) / goal - 1)
            }!
            best.factors[band] = closest.factors[band]
            best.reverberationTime[band] = closest.reverberationTime[band]
        }
        return (room.scalingAbsorption(by: best.factors), steps, best)
    }
}

extension ShoeboxRoom {
    /// The room with every surface's absorption, and every fitted zone's, multiplied by `factors` in
    /// each band, at most 0.99.
    public func scalingAbsorption(by factors: [Double]) -> ShoeboxRoom {
        func scaled(_ material: SurfaceMaterial) -> SurfaceMaterial {
            var result = material
            result.absorption = zip(material.absorption, factors).map { min($0 * $1, 0.99) }
            return result
        }
        var room = self
        for surface in Surface.allCases { room[surface] = scaled(room[surface]) }
        if var plan = room.plan {
            plan.walls = plan.walls.map(scaled)
            room.plan = plan
        }
        if var mesh = room.mesh {
            mesh.materials = mesh.materials.map(scaled)
            room.mesh = mesh
        }
        room.fittings = room.fittings?.map { zone in
            var zone = zone
            zone.absorption = zip(zone.absorption, factors).map { min($0 * $1, 0.99) }
            return zone
        }
        return room
    }

    /// The largest factor worth applying in a band: the one that brings the least absorbent surface
    /// that absorbs at all to 0.99. Beyond the factor that saturates the most absorbent, the others keep
    /// scaling while it stays at 0.99.
    func absorptionScaleLimit(band: Int) -> Double {
        let least = (boundaries.map { $0.material.absorption[band] } + zones.map { $0.absorption[band] })
            .filter { $0 > 0 }.min()
        return least.map { 0.99 / $0 } ?? 1
    }
}
