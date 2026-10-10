import Foundation
import simd

/// Pasquill's stability classes, from very unstable (A) to moderately stable (F), with the
/// growth of an instantaneous puff in each: σ = δ x^β, x the distance it has travelled in
/// metres, from Slade's (1968) estimates as the CCPS's *Guidelines for Consequence Analysis of
/// Chemical Releases* (1999) tabulate them, for 100 m to 4 km.
public enum PasquillClass: String, CaseIterable, Codable, Sendable {
    case a = "A"
    case b = "B"
    case c = "C"
    case d = "D"
    case e = "E"
    case f = "F"

    /// The class of air cooling with height at `lapseRate` kelvin a metre, by the US NRC's
    /// temperature-difference criteria (Safety Guide 23, 1972): A where it falls by more than
    /// 1.9 K a hundred metres, B 1.7, C 1.5, D 0.5, E to where it warms by 1.5 K, F (and G)
    /// beyond.
    public init(lapseRate: Double) {
        let change = -100 * lapseRate
        self =
            change < -1.9
            ? .a : change < -1.7 ? .b : change < -1.5 ? .c : change < -0.5 ? .d : change < 1.5 ? .e : .f
    }

    /// δ and β of the horizontal spread σ_y, which is also the spread along the wind.
    public var horizontal: (coefficient: Double, exponent: Double) {
        switch self {
        case .a: (0.18, 0.92)
        case .b: (0.14, 0.92)
        case .c: (0.10, 0.92)
        case .d: (0.06, 0.92)
        case .e: (0.04, 0.92)
        case .f: (0.02, 0.89)
        }
    }

    /// δ and β of the vertical spread σ_z.
    public var vertical: (coefficient: Double, exponent: Double) {
        switch self {
        case .a: (0.60, 0.75)
        case .b: (0.53, 0.73)
        case .c: (0.34, 0.71)
        case .d: (0.15, 0.70)
        case .e: (0.10, 0.65)
        case .f: (0.05, 0.61)
        }
    }

    /// A spread of `sigma` grown over `distance` more metres of travel: from the distance at
    /// which a puff of this class would have reached it, so that its growth depends on its size
    /// and not on where it started, and goes on smoothly when the class changes.
    static func grow(
        _ sigma: Double, by distance: Double, _ law: (coefficient: Double, exponent: Double)
    ) -> Double {
        let travelled = pow(max(sigma, 0) / law.coefficient, 1 / law.exponent)
        return law.coefficient * pow(travelled + distance, law.exponent)
    }
}

extension CloudRise.Model {
    /// The cloud after it stopped rising, from `state` at `start`, sampled at `times`: it sinks
    /// back to the level at which it is neutrally buoyant over half a buoyancy period, spreads
    /// there as a gravity current where the air is stable, and grows as a passive puff in the
    /// air's turbulence, drawing in the air around it as it grows, drifting with the wind at its
    /// centre, and raining out its water as the rising cloud does.
    func spread(from state: CloudRise.State, time start: Double, at times: [Double]) -> [CloudSample] {
        let g = CloudRise.gravity
        let r = CloudRise.gasConstant
        let cp = spec.specificHeat
        let first = derived(state)
        let radius = first.radius
        let volume = first.volume
        let stopped = state.height
        let fixed = spec.stabilityClass.flatMap(PasquillClass.init(rawValue:))

        func ambient(_ z: Double) -> (densityTemperature: Double, pressure: Double) {
            let air = atmosphere(z)
            let q = humidity(z)
            return (CloudRise.densityTemperature(air.temperature, vapour: q, water: q), air.pressure)
        }
        // The cloud's gas brought to `z` without mixing, dh = dp / ρ, less the air's density
        // temperature there: negative where it would sink.
        let gas = CloudRise.densityTemperature(first.temperature, vapour: first.vapour, water: state.water)
        func excess(_ z: Double) -> Double {
            let air = ambient(z)
            let enthalpy = state.enthalpy + r * gas * log(air.pressure / first.ambientPressure)
            let split = CloudRise.split(
                enthalpy: enthalpy, water: state.water, pressure: air.pressure, specificHeat: cp)
            return CloudRise.densityTemperature(split.temperature, vapour: split.vapour, water: state.water)
                - air.densityTemperature
        }
        // The level of neutral buoyancy below where it stopped, within four radii of it.
        var neutral = stopped
        if excess(stopped) < 0 {
            let lowest = max(stopped - 4 * radius, 0)
            var (low, high) = (lowest, stopped)
            var z = stopped
            while z > lowest, excess(z) < 0 { z = max(z - radius / 8, lowest) }
            if excess(z) >= 0 {
                (low, high) = (z, min(z + radius / 8, stopped))
                for _ in 0..<40 {
                    let middle = (low + high) / 2
                    if excess(middle) >= 0 { low = middle } else { high = middle }
                }
            }
            neutral = excess(z) >= 0 ? (low + high) / 2 : lowest
        }
        // Half a buoyancy period of the air between, in which it settles there.
        func frequency(_ low: Double, _ high: Double) -> Double {
            let (a, b) = (ambient(low).densityTemperature, ambient(high).densityTemperature)
            let squared = g / ((a + b) / 2) * ((b - a) / (high - low) + g / cp)
            return sqrt(max(squared, 0))
        }
        let settling =
            stopped > neutral + 1e-6
            ? Double.pi / max(frequency(neutral, stopped), 1e-6) : 0
        func height(_ t: Double) -> Double {
            guard settling > 0 else { return stopped }
            return neutral + (stopped - neutral) * (1 + cos(Double.pi * min(t / settling, 1))) / 2
        }

        var t = start
        var z = stopped
        var position = state.position
        var mass = state.mass
        var enthalpy = state.enthalpy
        var water = state.water
        var fallen = state.fallen
        var fallenIce = state.fallenIce
        // The gravity current's radius, and the turbulence's spreads, which add to its own
        // as variances of independent spreading do; its extent is √5 σ, which for a sphere of
        // uniform gas is its radius.
        var collapse = radius
        var across = 0.0
        var up = 0.0
        var current = PasquillClass.d
        var extent = (radius: radius, depth: radius)
        var occupied = volume
        var rise = 0.0

        func sample() -> CloudSample {
            let air = atmosphere(z)
            let split = CloudRise.split(
                enthalpy: enthalpy, water: water, pressure: air.pressure, specificHeat: cp)
            return CloudSample(
                time: t, height: z, radius: extent.radius, temperature: split.temperature,
                ambientTemperature: air.temperature, riseSpeed: rise, mass: mass, position: position,
                velocity: wind(z), water: water, liquidWater: water - split.vapour - split.ice,
                ice: split.ice,
                precipitation: fallen, snow: fallenIce, thickness: extent.depth,
                stabilityClass: current.rawValue)
        }

        var samples: [CloudSample] = []
        var next = 0
        while next < times.count, times[next] <= t + 1e-9 {
            samples.append(sample())
            next += 1
        }
        while next < times.count {
            var step = min(1, times[next] - t)
            if t - start < settling { step = min(step, settling / 50) }
            let later = height(t + step - start)
            let depth = max(extent.depth, 5)
            let (low, high) = (max(z - depth, 0), z + depth)
            let lapse = (atmosphere(low).temperature - atmosphere(high).temperature) / (high - low)
            current = fixed ?? PasquillClass(lapseRate: lapse)
            let n = frequency(low, high)
            collapse = cbrt(pow(collapse, 3) + 3 * spec.frontFroude * n * volume * step / (2 * .pi))
            let travelled = max(simd_length(wind(z)), spec.leastTransportSpeed) * step
            across = PasquillClass.grow(across, by: travelled, current.horizontal)
            up = PasquillClass.grow(up, by: travelled, current.vertical)
            let flattened = pow(radius, 3) / (collapse * collapse)
            extent = (
                (collapse * collapse + 5 * across * across).squareRoot(),
                (flattened * flattened + 5 * up * up).squareRoot()
            )
            let grown = 4 / 3 * Double.pi * extent.radius * extent.radius * extent.depth

            // Mixing in the air the puff has grown into, raining, and the pressure's work as it
            // sinks, at the start of the step's state.
            let before = atmosphere(z)
            let after = atmosphere(later)
            let split = CloudRise.split(
                enthalpy: enthalpy, water: water, pressure: before.pressure, specificHeat: cp)
            let condensed = water - split.vapour
            let falling = mass * spec.rainRate * max(condensed - spec.rainThreshold, 0) * step
            let frozen = condensed > 0 ? split.ice / condensed : 0
            let fallingEnthalpy = cp * split.temperature - CloudRise.fusionHeat * frozen
            let q = humidity(later)
            let airDensity =
                after.pressure / (r * CloudRise.densityTemperature(after.temperature, vapour: q, water: q))
            let drawn = max(airDensity * (grown - occupied), 0)
            let gas = CloudRise.densityTemperature(split.temperature, vapour: split.vapour, water: water)
            enthalpy += r * gas * log(after.pressure / before.pressure)
            let total = mass + drawn - falling
            enthalpy =
                (mass * enthalpy + drawn * (cp * after.temperature + CloudRise.latentHeat * q)
                    - falling * fallingEnthalpy) / total
            water = (mass * water + drawn * q - falling) / total
            mass = total
            fallen += falling
            fallenIce += falling * frozen
            occupied = max(grown, occupied)
            position += wind((z + later) / 2) * step
            rise = (later - z) / step
            z = later
            t += step
            while next < times.count, times[next] <= t + 1e-9 {
                samples.append(sample())
                next += 1
            }
        }
        return samples
    }
}
