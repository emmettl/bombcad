import Foundation
import simd

/// A study of the fireball's rise and cloud after the blast: what it is asked for. Any field
/// left out of its JSON takes its default.
public struct CloudSpec: Codable, Sendable, Equatable {
    /// Gas at least this hot at the end of the run, once brought to the ambient pressure, is
    /// handed over as the cloud, in kelvin.
    public var handOverTemperature: Float = 500
    /// The entrainment coefficient: the speed at which the surrounding air is drawn in, as a
    /// share of the cloud's rise speed. In the self-similar regime the cloud's radius grows by
    /// this much for each metre it rises.
    public var entrainment = 0.25
    /// The added mass of the air the cloud pushes aside, as a share of the air it displaces; a
    /// half for a sphere.
    public var addedMass = 0.5
    /// The cloud's emissivity for the heat it radiates; 0 keeps all its heat.
    public var emissivity = 0.0
    /// The atmosphere's lapse rate up to the tropopause, in kelvin a metre; isothermal above.
    public var lapseRate = 0.0065
    public var tropopause = 11_000.0
    /// The specific heat of the cloud's gas and of the air it draws in, in J/(kg K).
    public var specificHeat = 1005.0
    /// Seconds of the cloud's rise followed after the run.
    public var duration = 600.0
    /// Seconds of the cloud's rise between frames of the USD scene.
    public var frameInterval = 1.0

    public init() {}

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CloudSpec()
        handOverTemperature =
            try values.decodeIfPresent(Float.self, forKey: .handOverTemperature)
            ?? defaults.handOverTemperature
        entrainment = try values.decodeIfPresent(Double.self, forKey: .entrainment) ?? defaults.entrainment
        addedMass = try values.decodeIfPresent(Double.self, forKey: .addedMass) ?? defaults.addedMass
        emissivity = try values.decodeIfPresent(Double.self, forKey: .emissivity) ?? defaults.emissivity
        lapseRate = try values.decodeIfPresent(Double.self, forKey: .lapseRate) ?? defaults.lapseRate
        tropopause = try values.decodeIfPresent(Double.self, forKey: .tropopause) ?? defaults.tropopause
        specificHeat = try values.decodeIfPresent(Double.self, forKey: .specificHeat) ?? defaults.specificHeat
        duration = try values.decodeIfPresent(Double.self, forKey: .duration) ?? defaults.duration
        frameInterval =
            try values.decodeIfPresent(Double.self, forKey: .frameInterval) ?? defaults.frameInterval
    }

    public func validate() throws {
        let finite = [
            Double(handOverTemperature), entrainment, addedMass, emissivity, lapseRate, tropopause,
            specificHeat,
            duration, frameInterval,
        ]
        guard finite.allSatisfy(\.isFinite), handOverTemperature > 300, entrainment > 0, entrainment <= 1,
            addedMass >= 0, addedMass <= 2, emissivity >= 0, emissivity <= 1, lapseRate >= 0,
            lapseRate < CloudRise.gravity / specificHeat, tropopause > 0, specificHeat >= 500,
            specificHeat <= 3000,
            duration > 0, duration <= 7200, frameInterval >= 0.01, duration / frameInterval <= 100_000
        else {
            throw CocoaError(
                .coderInvalidValue,
                userInfo: [NSLocalizedDescriptionKey: "The cloud description is out of range."])
        }
    }
}

/// The hot gas left in the air at the end of a run, as the cloud model takes it over: its mass,
/// and its volume, centre and temperature once brought to the ambient pressure.
public struct CloudHandOver: Codable, Sendable, Equatable {
    public var time: Double
    /// Of the gas at least `handOverTemperature`, in kilograms; zero if there is none.
    public var mass: Double
    /// At the ambient pressure, in cubic metres.
    public var volume: Double
    /// The centre of its mass.
    public var centre: SIMD3<Float>
    /// Its mass-weighted mean temperature at the ambient pressure, p / (ρR), in kelvin: what makes
    /// its volume, and so its buoyancy, right.
    public var temperature: Double
    /// The mean vertical velocity of its mass, in metres a second.
    public var riseSpeed: Double
    /// The hottest of it, in kelvin.
    public var hottest: Double
    /// Its buoyancy, its weight less that of the air it displaces, in newtons.
    public var buoyancy: Double
    /// The buoyancy of all the gas warmer than the ambient air, handed over or not.
    public var warmBuoyancy: Double
    /// The air at the ground.
    public var ambientTemperature: Double
    public var ambientPressure: Double

    public init(
        time: Double, mass: Double, volume: Double, centre: SIMD3<Float>, temperature: Double,
        riseSpeed: Double,
        hottest: Double, buoyancy: Double, warmBuoyancy: Double, ambientTemperature: Double,
        ambientPressure: Double
    ) {
        self.time = time
        self.mass = mass
        self.volume = volume
        self.centre = centre
        self.temperature = temperature
        self.riseSpeed = riseSpeed
        self.hottest = hottest
        self.buoyancy = buoyancy
        self.warmBuoyancy = warmBuoyancy
        self.ambientTemperature = ambientTemperature
        self.ambientPressure = ambientPressure
    }

    /// The radius of a sphere of its volume.
    public var radius: Double { cbrt(3 * volume / (4 * .pi)) }
}

extension BlastSolver {
    /// The gas at least `hotterThan` kelvin once brought to the ambient pressure, to hand over to
    /// the cloud model. Each cell of air is brought to the ambient pressure isentropically, with
    /// the configuration's gamma; its temperature is then p / (ρR), which for dissociating air
    /// is above the true temperature but gives its density. Reads the state, spread across the
    /// CPU's cores; call it only while no batch is in flight.
    public func cloudHandOver(hotterThan threshold: Float) -> CloudHandOver {
        let (nx, ny, nz) = (grid.nx, grid.ny, grid.nz)
        let cellVolume = pow(Double(grid.cellSize), 3)
        let h = Double(grid.cellSize)
        let gamma = configuration.gamma
        let airModel = configuration.airModel
        let ambientPressure = Double(configuration.ambientPressure)
        let gasConstant = Double(AirModel.gasConstant)
        let ambientTemperature = ambientPressure / (Double(ambientDensity) * gasConstant)
        let mask = maskBuffer.contents().bindMemory(to: UInt8.self, capacity: grid.cellCount)
        struct Sums {
            var mass = 0.0
            var heat = 0.0
            var position = SIMD3<Double>.zero
            var momentum = 0.0
            var hottest = 0.0
            var warm = 0.0
        }
        var planes = [Sums](repeating: Sums(), count: nz)
        withState { cells in
            planes.withUnsafeMutableBufferPointer { planes in
                DispatchQueue.concurrentPerform(iterations: nz) { k in
                    var sums = Sums()
                    for j in 0..<ny {
                        for i in 0..<nx {
                            let index = grid.index(i, j, k)
                            guard mask[index] == 0 else { continue }
                            let air = Self.primitive(of: cells[index], gamma: gamma, airModel: airModel)
                            let density = Double(air.density)
                            let pressure = Double(air.pressure)
                            guard density > 0, pressure > 0, density.isFinite, pressure.isFinite else {
                                continue
                            }
                            let relaxed = density * pow(ambientPressure / pressure, 1 / Double(gamma))
                            let t = ambientPressure / (relaxed * gasConstant)
                            guard t > ambientTemperature else { continue }
                            let mass = density * cellVolume
                            sums.warm += mass * (t / ambientTemperature - 1)
                            guard t >= Double(threshold) else { continue }
                            sums.mass += mass
                            sums.heat += mass * t
                            sums.position +=
                                mass * SIMD3<Double>(Double(i) + 0.5, Double(j) + 0.5, Double(k) + 0.5)
                            sums.momentum += mass * Double(air.velocity.z)
                            sums.hottest = max(sums.hottest, t)
                        }
                    }
                    planes[k] = sums
                }
            }
        }
        let total = planes.reduce(into: Sums()) { total, plane in
            total.mass += plane.mass
            total.heat += plane.heat
            total.position += plane.position
            total.momentum += plane.momentum
            total.hottest = max(total.hottest, plane.hottest)
            total.warm += plane.warm
        }
        let g = CloudRise.gravity
        guard total.mass > 0 else {
            return CloudHandOver(
                time: time, mass: 0, volume: 0, centre: .zero, temperature: 0, riseSpeed: 0, hottest: 0,
                buoyancy: 0, warmBuoyancy: g * total.warm, ambientTemperature: ambientTemperature,
                ambientPressure: ambientPressure)
        }
        let temperature = total.heat / total.mass
        return CloudHandOver(
            time: time, mass: total.mass, volume: total.mass * gasConstant * temperature / ambientPressure,
            centre: SIMD3<Float>(total.position / total.mass * h), temperature: temperature,
            riseSpeed: total.momentum / total.mass, hottest: total.hottest,
            buoyancy: g * total.mass * (temperature / ambientTemperature - 1), warmBuoyancy: g * total.warm,
            ambientTemperature: ambientTemperature, ambientPressure: ambientPressure)
    }
}

/// The still air the cloud rises through: the temperature falling at a steady lapse rate up to
/// the tropopause and constant above it, and the pressure in hydrostatic balance, as in the
/// International Standard Atmosphere's lower layers.
public struct CloudAtmosphere: Sendable, Equatable {
    public var groundTemperature: Double
    public var groundPressure: Double
    /// In kelvin a metre.
    public var lapseRate: Double
    public var tropopause: Double

    public init(groundTemperature: Double, groundPressure: Double, lapseRate: Double, tropopause: Double) {
        self.groundTemperature = groundTemperature
        self.groundPressure = groundPressure
        self.lapseRate = lapseRate
        self.tropopause = tropopause
    }

    /// The temperature (K) and pressure (Pa) at `height` metres above the ground.
    public func callAsFunction(_ height: Double) -> (temperature: Double, pressure: Double) {
        let g = CloudRise.gravity
        let r = CloudRise.gasConstant
        let z = min(height, tropopause)
        let temperature = groundTemperature - lapseRate * z
        let pressure =
            lapseRate > 0
            ? groundPressure * pow(temperature / groundTemperature, g / (r * lapseRate))
            : groundPressure * exp(-g * z / (r * groundTemperature))
        guard height > tropopause else { return (temperature, pressure) }
        return (temperature, pressure * exp(-g * (height - tropopause) / (r * temperature)))
    }
}

/// The cloud at one moment: a sphere of well-mixed gas at the ambient pressure.
public struct CloudSample: Codable, Sendable, Equatable {
    /// Since the detonation, in seconds.
    public var time: Double
    /// Of its centre above the ground, in metres.
    public var height: Double
    public var radius: Double
    /// In kelvin, and the air's around it.
    public var temperature: Double
    public var ambientTemperature: Double
    /// Upward, in metres a second.
    public var riseSpeed: Double
    /// In kilograms: what was handed over and all the air drawn in since.
    public var mass: Double

    public init(
        time: Double, height: Double, radius: Double, temperature: Double, ambientTemperature: Double,
        riseSpeed: Double, mass: Double
    ) {
        self.time = time
        self.height = height
        self.radius = radius
        self.temperature = temperature
        self.ambientTemperature = ambientTemperature
        self.riseSpeed = riseSpeed
        self.mass = mass
    }

    /// The top of the cloud above the ground.
    public var top: Double { height + radius }
}

/// The rise of a buoyant cloud as an integral model of a turbulent thermal: Morton, Taylor and
/// Turner's (1956) entrainment assumption, the air drawn in across the cloud's surface at a
/// fixed share of its rise speed, in the form Escudier and Maxworthy (1973) gave for any density
/// difference and with the added mass of the air pushed aside. The cloud is a sphere of
/// well-mixed gas at the ambient pressure, rising through still air whose temperature and
/// pressure fall with height; it cools by mixing with that air, by expanding as it rises, and,
/// if it is given an emissivity, by radiating.
public enum CloudRise {
    public static let gravity = 9.806_65
    public static let gasConstant = Double(AirModel.gasConstant)

    /// The cloud's state for integration: height, mass, upward impulse (its own momentum and its
    /// added mass's) and temperature.
    struct State {
        var height: Double
        var mass: Double
        var impulse: Double
        var temperature: Double

        static func + (a: State, b: State) -> State {
            State(
                height: a.height + b.height, mass: a.mass + b.mass, impulse: a.impulse + b.impulse,
                temperature: a.temperature + b.temperature)
        }

        static func * (a: State, s: Double) -> State {
            State(
                height: a.height * s, mass: a.mass * s, impulse: a.impulse * s, temperature: a.temperature * s
            )
        }
    }

    /// The cloud from `handOver`, followed through `atmosphere` and sampled at `times`, which
    /// must be ascending and no earlier than the hand-over; also the first moment it stopped
    /// rising, if it did by the last of them.
    public static func follow(
        _ handOver: CloudHandOver, spec: CloudSpec,
        atmosphere: @escaping (Double) -> (temperature: Double, pressure: Double), at times: [Double]
    ) -> (samples: [CloudSample], stabilised: CloudSample?) {
        guard handOver.mass > 0, let end = times.last else { return ([], nil) }
        let model = Model(spec: spec, atmosphere: atmosphere)
        let start = Double(handOver.centre.z)
        let air = atmosphere(start)
        let ambientDensity = air.pressure / (gasConstant * air.temperature)
        // The hand-over's temperature at the ground's pressure, brought to that at its height.
        let temperature =
            handOver.temperature
            * pow(air.pressure / handOver.ambientPressure, gasConstant / spec.specificHeat)
        let volume = handOver.mass * gasConstant * temperature / air.pressure
        var state = State(
            height: start, mass: handOver.mass,
            impulse: (handOver.mass + spec.addedMass * ambientDensity * volume) * handOver.riseSpeed,
            temperature: temperature)
        var time = handOver.time
        var samples: [CloudSample] = []
        var stabilised: CloudSample?
        var next = 0
        while next < times.count, times[next] <= time + 1e-12 {
            samples.append(model.sample(state, time: time))
            next += 1
        }
        var rising = model.sample(state, time: time).riseSpeed > 0
        while time < end - 1e-12 {
            let step = min(model.step(state), times[next] - time)
            let k1 = model.rate(state)
            let k2 = model.rate(state + k1 * (step / 2))
            let k3 = model.rate(state + k2 * (step / 2))
            let k4 = model.rate(state + k3 * step)
            state = state + (k1 + k2 * 2 + k3 * 2 + k4) * (step / 6)
            time += step
            let now = model.sample(state, time: time)
            if rising, now.riseSpeed <= 0, stabilised == nil { stabilised = now }
            rising = now.riseSpeed > 0
            while next < times.count, times[next] <= time + 1e-9 {
                samples.append(now)
                next += 1
            }
            if next == times.count { break }
        }
        return (samples, stabilised)
    }

    struct Model {
        let spec: CloudSpec
        let atmosphere: (Double) -> (temperature: Double, pressure: Double)
        static let stefanBoltzmann = 5.670_374e-8

        struct Derived {
            var ambientTemperature: Double
            var ambientPressure: Double
            var ambientDensity: Double
            var volume: Double
            var radius: Double
            var riseSpeed: Double
        }

        func derived(_ state: State) -> Derived {
            let air = atmosphere(state.height)
            let ambientDensity = air.pressure / (gasConstant * air.temperature)
            let volume = state.mass * gasConstant * state.temperature / air.pressure
            return Derived(
                ambientTemperature: air.temperature, ambientPressure: air.pressure,
                ambientDensity: ambientDensity,
                volume: volume,
                radius: cbrt(3 * volume / (4 * .pi)),
                riseSpeed: state.impulse / (state.mass + spec.addedMass * ambientDensity * volume))
        }

        /// The time derivative of `state`: the air drawn in across the surface at the
        /// entrainment coefficient times the rise speed; the impulse changed by the buoyancy;
        /// and the temperature by mixing with the air drawn in, by expanding as the pressure
        /// falls (cp dT = dp / ρ, which in hydrostatic air is −(T / T_air) g dz), and by
        /// radiating.
        func rate(_ state: State) -> State {
            let d = derived(state)
            let area = 4 * Double.pi * d.radius * d.radius
            let entrained = area * spec.entrainment * d.ambientDensity * abs(d.riseSpeed)
            let buoyancy = (d.ambientDensity * d.volume - state.mass) * gravity
            let radiated =
                spec.emissivity * Self.stefanBoltzmann
                * (pow(state.temperature, 4) - pow(d.ambientTemperature, 4)) * area
            let gradient = (atmosphere(state.height + 1).pressure - atmosphere(state.height - 1).pressure) / 2
            let heating =
                spec.specificHeat * (d.ambientTemperature - state.temperature) * entrained
                + state.mass * gasConstant * state.temperature / d.ambientPressure * gradient * d.riseSpeed
                - radiated
            return State(
                height: d.riseSpeed, mass: entrained, impulse: buoyancy,
                temperature: heating / (state.mass * spec.specificHeat))
        }

        /// A step short against the time the cloud takes to rise its own radius, from rest or at
        /// its speed, to draw in its own mass, and to cool by radiation.
        func step(_ state: State) -> Double {
            let d = derived(state)
            let inertia = state.mass + spec.addedMass * d.ambientDensity * d.volume
            let acceleration = abs(d.ambientDensity * d.volume - state.mass) * gravity / inertia
            let entrained =
                4 * Double.pi * d.radius * d.radius * spec.entrainment * d.ambientDensity * abs(d.riseSpeed)
            var step = min(
                0.02 * d.radius / max(abs(d.riseSpeed), 1e-6),
                0.02 * sqrt(d.radius / max(acceleration, 1e-9)),
                0.02 * state.mass / max(entrained, 1e-30), 0.5)
            if spec.emissivity > 0 {
                let radiated =
                    spec.emissivity * Self.stefanBoltzmann * pow(state.temperature, 4) * 4 * .pi * d.radius
                    * d.radius
                step = min(step, 0.02 * state.mass * spec.specificHeat * state.temperature / radiated)
            }
            return max(step, 1e-7)
        }

        func sample(_ state: State, time: Double) -> CloudSample {
            let d = derived(state)
            return CloudSample(
                time: time, height: state.height, radius: d.radius, temperature: state.temperature,
                ambientTemperature: d.ambientTemperature, riseSpeed: d.riseSpeed, mass: state.mass)
        }
    }
}

/// The cloud after a run: what was handed over and how it rose.
public struct CloudResult: Codable, Sendable {
    public var spec: CloudSpec
    public var handOver: CloudHandOver
    /// From the hand-over, closer together early on when the cloud changes fastest.
    public var samples: [CloudSample]
    /// The first moment the cloud stopped rising, if it did.
    public var stabilised: CloudSample?

    /// Follows `handOver` through the standard atmosphere `spec` describes, from the hand-over's
    /// own air at the ground.
    public init(spec: CloudSpec, handOver: CloudHandOver) {
        self.spec = spec
        self.handOver = handOver
        let start = handOver.time
        var times = [start]
        var offset = 0.01
        while offset < spec.duration {
            times.append(start + offset)
            offset *= 1.05
        }
        times.append(start + spec.duration)
        (samples, stabilised) = CloudRise.follow(
            handOver, spec: spec, atmosphere: spec.atmosphere(handOver).callAsFunction, at: times)
    }

    /// The cloud every `frameInterval` from the hand-over, for the USD scene.
    public func frames() -> [CloudSample] {
        let count = Int((spec.duration / spec.frameInterval).rounded(.down))
        let times = (0...count).map { handOver.time + Double($0) * spec.frameInterval }
        return CloudRise.follow(
            handOver, spec: spec, atmosphere: spec.atmosphere(handOver).callAsFunction, at: times
        ).samples
    }

    public var summary: [String] {
        guard handOver.mass > 0 else {
            return [
                String(
                    format: "Cloud: no gas at least %.0f K left at %.0f ms to hand over.",
                    Double(spec.handOverTemperature), handOver.time * 1000)
            ]
        }
        var lines = [
            String(
                format:
                    "Cloud: %.0f kg of gas at least %.0f K handed over at %.0f ms, %.1f m across at %.0f K, its centre %.1f m up, rising at %.1f m/s; %.0f%% of the warm gas's buoyancy",
                handOver.mass, Double(spec.handOverTemperature), handOver.time * 1000, 2 * handOver.radius,
                handOver.temperature, Double(handOver.centre.z), handOver.riseSpeed,
                100 * handOver.buoyancy / max(handOver.warmBuoyancy, 1e-30))
        ]
        if let stabilised {
            lines.append(
                String(
                    format:
                        "  stopped rising at %.0f s: centre %.0f m up, top %.0f m, %.0f m across, %.1f K above the air",
                    stabilised.time, stabilised.height, stabilised.top, 2 * stabilised.radius,
                    stabilised.temperature - stabilised.ambientTemperature))
        }
        if let last = samples.last {
            lines.append(
                String(
                    format: "  at %.0f s: centre %.0f m up, top %.0f m, %.0f m across, rising at %.1f m/s",
                    last.time, last.height, last.top, 2 * last.radius, last.riseSpeed))
        }
        return lines
    }
}

extension CloudSpec {
    /// The standard atmosphere this describes, from `handOver`'s air at the ground.
    public func atmosphere(_ handOver: CloudHandOver) -> CloudAtmosphere {
        CloudAtmosphere(
            groundTemperature: handOver.ambientTemperature, groundPressure: handOver.ambientPressure,
            lapseRate: lapseRate, tropopause: tropopause)
    }
}
