import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

@Suite("The fireball's rise and cloud")
struct FireballRiseTests {
    private let ambientTemperature = 288.15
    private let ambientPressure = 101_325.0
    private var ambientDensity: Double { ambientPressure / (CloudRise.gasConstant * ambientTemperature) }

    /// Air of one temperature and pressure at every height: no stratification, and no cooling
    /// by expansion as the cloud rises.
    private var uniform: (Double) -> (temperature: Double, pressure: Double) {
        { [ambientTemperature, ambientPressure] _ in (ambientTemperature, ambientPressure) }
    }

    /// A sphere of gas `excess` times as hot as the air, of `radius`, centred `height` up and
    /// rising at `riseSpeed` at `time`.
    private func handOver(
        radius: Double, height: Double, excess: Double, riseSpeed: Double = 0, time: Double = 0
    ) -> CloudHandOver {
        let temperature = ambientTemperature * (1 + excess)
        let volume = 4 / 3 * Double.pi * pow(radius, 3)
        let mass = ambientPressure * volume / (CloudRise.gasConstant * temperature)
        return CloudHandOver(
            time: time, mass: mass, volume: volume, centre: SIMD3(0, 0, Float(height)),
            temperature: temperature,
            riseSpeed: riseSpeed, hottest: temperature,
            buoyancy: CloudRise.gravity * mass * excess, warmBuoyancy: CloudRise.gravity * mass * excess,
            ambientTemperature: ambientTemperature, ambientPressure: ambientPressure)
    }

    /// The self-similar thermal in uniform surroundings: with the buoyancy F constant, the
    /// impulse (1 + k) ρ (4π/3) b³ w grows as F t, and with b = α z,
    /// z⁴ = 3 F t² / (2π (1 + k) ρ α³).
    private func selfSimilarHeight(force: Double, time: Double, spec: CloudSpec) -> Double {
        pow(
            3 * force * time * time
                / (2 * .pi * (1 + spec.addedMass) * ambientDensity * pow(spec.entrainment, 3)), 0.25)
    }

    @Test("A weakly buoyant thermal on the self-similar path follows z ∝ t^½, with b = αz and w = z / 2t")
    func selfSimilarRise() {
        let spec = CloudSpec()
        let height = 10.0
        let radius = spec.entrainment * height
        let excess = 1e-4
        var start = handOver(radius: radius, height: height, excess: excess)
        let force = start.buoyancy
        // The time at which the self-similar thermal is `height` up, and its speed there.
        let t0 = sqrt(
            pow(height, 4) * 2 * .pi * (1 + spec.addedMass) * ambientDensity * pow(spec.entrainment, 3)
                / (3 * force))
        start.time = t0
        start.riseSpeed = height / (2 * t0)
        let times = [t0, 10 * t0, 100 * t0, 1000 * t0]
        let (samples, stabilised) = CloudRise.follow(start, spec: spec, atmosphere: uniform, at: times)
        #expect(samples.count == times.count && stabilised == nil)
        for sample in samples {
            let expected = selfSimilarHeight(force: force, time: sample.time, spec: spec)
            #expect(
                abs(sample.height / expected - 1) < 1e-3,
                "\(sample.time) s: \(sample.height) against \(expected)")
            #expect(abs(sample.radius / (spec.entrainment * sample.height) - 1) < 1e-3)
            #expect(abs(sample.riseSpeed * 2 * sample.time / sample.height - 1) < 1e-3)
        }
        // A thousandfold in time is about thirty times as high.
        #expect(abs(samples[3].height / samples[0].height - sqrt(1000)) < 0.05)
    }

    @Test("A hot fireball in uniform air keeps its buoyancy and joins the self-similar law")
    func hotStart() {
        let spec = CloudSpec()
        let start = handOver(radius: 7, height: 7, excess: 7)
        let times = [0.0, 100, 200, 400, 600]
        let (samples, _) = CloudRise.follow(start, spec: spec, atmosphere: uniform, at: times)
        let force = start.buoyancy
        // Mixing and no expansion: the mass times the excess temperature, and so the buoyancy,
        // is conserved however hot the gas.
        for sample in samples {
            let buoyancy =
                CloudRise.gravity * sample.mass * (sample.temperature / sample.ambientTemperature - 1)
            #expect(abs(buoyancy / force - 1) < 1e-4, "\(buoyancy) against \(force)")
        }
        // Late on, the radius grows as αz and z as t^½, so b² grows steadily at the self-similar
        // rate α² √(3F / (2π (1 + k) ρ α³)), whatever the start's virtual origin in time and height.
        let rate =
            (pow(samples[4].radius, 2) - pow(samples[2].radius, 2)) / (samples[4].time - samples[2].time)
        let expected =
            spec.entrainment * spec.entrainment
            * sqrt(3 * force / (2 * .pi * (1 + spec.addedMass) * ambientDensity * pow(spec.entrainment, 3)))
        #expect(abs(rate / expected - 1) < 0.01, "\(rate / expected)")
        #expect(samples[4].temperature - ambientTemperature < 1 && samples[4].riseSpeed > 0)
    }

    @Test("In a stable atmosphere the cloud stops rising at a height growing as (F / N²)^¼")
    func stratifiedCeiling() {
        var spec = CloudSpec()
        spec.duration = 3000
        let adiabatic = CloudRise.gravity / spec.specificHeat
        // Small starts, a tenth of a metre across, so the rise is far above where they began, and
        // from the self-similar thermal's origin at the ground.
        func ceiling(excess: Double, lapseRate: Double) -> Double {
            let atmosphere = CloudAtmosphere(
                groundTemperature: ambientTemperature, groundPressure: ambientPressure, lapseRate: lapseRate,
                tropopause: 11_000)
            let start = handOver(radius: 0.1, height: 0.4, excess: excess)
            let (_, stabilised) = CloudRise.follow(
                start, spec: spec, atmosphere: atmosphere.callAsFunction, at: [0, 3000])
            return stabilised?.height ?? 0
        }
        let standard = ceiling(excess: 0.05, lapseRate: 0.0065)
        // Sixteen times the buoyancy, mg(T − T_air) / T_air, from the same volume: twice the height.
        let stronger = 16 * 0.05 / 1.05
        let buoyant = ceiling(excess: stronger / (1 - stronger), lapseRate: 0.0065)
        #expect(abs(buoyant / standard - 2) < 0.01, "\(buoyant / standard)")
        // A quarter of the stability, N² = (g / T)(g / cp − Γ): √2 times the height.
        let weak = ceiling(excess: 0.05, lapseRate: adiabatic - (adiabatic - 0.0065) / 4)
        #expect(abs(weak / standard - sqrt(2)) < 0.01, "\(weak / standard)")
    }

    @Test("Radiating its heat away, the cloud rises less")
    func radiation() {
        var spec = CloudSpec()
        let start = handOver(radius: 7, height: 7, excess: 7)
        let atmosphere = CloudAtmosphere(
            groundTemperature: ambientTemperature, groundPressure: ambientPressure, lapseRate: 0.0065,
            tropopause: 11_000)
        let dark = CloudRise.follow(start, spec: spec, atmosphere: atmosphere.callAsFunction, at: [0, 600])
        spec.emissivity = 1
        let bright = CloudRise.follow(start, spec: spec, atmosphere: atmosphere.callAsFunction, at: [0, 600])
        let high = try? #require(dark.stabilised)
        let low = try? #require(bright.stabilised)
        #expect((low?.height ?? 1) < (high?.height ?? 0))
    }

    @Test(
        "In a steady, uniform wind a cloud already moving with it rises as in still air and drifts at the wind's speed"
    )
    func galilean() {
        let spec = CloudSpec()
        let wind = SIMD2<Double>(6, -3)
        var start = handOver(radius: 7, height: 7, excess: 4, riseSpeed: 2)
        let times = [0.0, 1, 10, 100, 600]
        let still = CloudRise.follow(start, spec: spec, atmosphere: uniform, at: times)
        start.horizontalVelocity = wind
        let carried = CloudRise.follow(start, spec: spec, atmosphere: uniform, wind: { _ in wind }, at: times)
        for (a, b) in zip(still.samples, carried.samples) {
            #expect(abs(b.height / a.height - 1) < 1e-9 && abs(b.radius / a.radius - 1) < 1e-9)
            #expect(simd_length(b.position - wind * b.time) < 1e-6 * simd_length(wind) * b.time + 1e-9)
            #expect(simd_length(b.velocity - wind) < 1e-9)
        }
    }

    @Test(
        "A cloud starting at rest in a uniform wind takes it up as its impulse relative to the wind is conserved"
    )
    func takingUpTheWind() {
        let spec = CloudSpec()
        let wind = SIMD2<Double>(0, 8)
        let start = handOver(radius: 7, height: 7, excess: 4)
        let (samples, _) = CloudRise.follow(
            start, spec: spec, atmosphere: uniform, wind: { _ in wind }, at: [0, 0.5, 2, 10, 60, 300])
        // (m + kρV)(u − U) is conserved, the air drawn in bringing the wind's momentum with it,
        // so u = U (1 − M₀ / M).
        func inertia(_ sample: CloudSample) -> Double {
            sample.mass + spec.addedMass * ambientDensity * 4 / 3 * .pi * pow(sample.radius, 3)
        }
        let first = inertia(samples[0])
        for sample in samples {
            let expected = wind * (1 - first / inertia(sample))
            #expect(simd_length(sample.velocity - expected) < 1e-6 * simd_length(wind), "\(sample.velocity)")
        }
        #expect(samples[5].velocity.y > 0.99 * wind.y && samples[5].position.y > 0)
        // Blown through, it draws in more air than in still air and rises less.
        let still = CloudRise.follow(start, spec: spec, atmosphere: uniform, at: [0, 300]).samples
        #expect(samples[5].height < still[1].height && samples[5].mass > still[1].mass)
    }

    @Test("In a wind growing with height the cloud keeps up with the wind around it and stops lower")
    func shear() throws {
        var spec = CloudSpec()
        spec.windSpeed = 10
        spec.windDirection = 90
        let start = handOver(radius: 7, height: 7, excess: 4)
        let atmosphere = CloudAtmosphere(
            groundTemperature: ambientTemperature, groundPressure: ambientPressure, lapseRate: 0.0065,
            tropopause: 11_000)
        let blown = CloudRise.follow(
            start, spec: spec, atmosphere: atmosphere.callAsFunction, wind: spec.wind.callAsFunction,
            at: [0, 600])
        let still = CloudRise.follow(start, spec: spec, atmosphere: atmosphere.callAsFunction, at: [0, 600])
        let end = try #require(blown.samples.last)
        let around = spec.wind(end.height)
        #expect(
            abs(end.velocity.y / around.y - 1) < 0.02 && abs(end.velocity.x) < 1e-9,
            "\(end.velocity) \(around)")
        #expect(end.position.y > 5_000)
        let windy = try #require(blown.stabilised)
        let calm = try #require(still.stabilised)
        #expect(windy.height < calm.height, "\(windy.height) against \(calm.height)")
    }

    @Test("The wind grows as a power of height up to its ceiling, and blows where it is pointed")
    func windProfile() {
        let wind = CloudWind(speed: 5, direction: .pi / 2, height: 10, exponent: 1.0 / 7, ceiling: 1000)
        #expect(simd_length(wind(10) - SIMD2(0, 5)) < 1e-12)
        #expect(abs(wind(80).y / 5 - pow(8, 1.0 / 7)) < 1e-12)
        #expect(wind(5000) == wind(1000) && wind(0) == .zero && wind(-1) == .zero)
    }

    @Test("Saturation over water and ice, and gas split into vapour, liquid and ice at saturation")
    func saturation() {
        #expect(abs(CloudRise.saturationPressure(temperature: 273.15) - 611.2) < 1e-9)
        // 4.246 kPa at 30 °C, from the steam tables.
        #expect(abs(CloudRise.saturationPressure(temperature: 303.15) / 4246 - 1) < 0.002)
        #expect(CloudRise.saturationHumidity(temperature: 400, pressure: 101_325) == .infinity)
        // Over ice: 611.2 Pa at the triple point and 103.3 Pa at −20 °C.
        #expect(abs(CloudRise.saturationPressureOverIce(temperature: 273.16) / 611.2 - 1) < 0.001)
        #expect(abs(CloudRise.saturationPressureOverIce(temperature: 253.15) / 103.3 - 1) < 0.003)
        // The condensate is liquid above freezing, ice below 250.16 K, and a quarter liquid half way.
        #expect(
            CloudRise.liquidFraction(temperature: 280) == 1 && CloudRise.liquidFraction(temperature: 240) == 0
        )
        #expect(abs(CloudRise.liquidFraction(temperature: 261.66) - 0.25) < 1e-12)
        let cp = 1005.0
        let pressure = 90_000.0
        for (temperature, water) in [(280.0, 0.02), (300.0, 0.05), (262.0, 0.004), (245.0, 0.001)] {
            // Saturated air at `temperature` with the rest of `water` condensed, liquid and ice.
            let saturated = CloudRise.cloudSaturationHumidity(temperature: temperature, pressure: pressure)
            let ice = (1 - CloudRise.liquidFraction(temperature: temperature)) * (water - saturated)
            let enthalpy = cp * temperature + CloudRise.latentHeat * saturated - CloudRise.fusionHeat * ice
            let split = CloudRise.split(
                enthalpy: enthalpy, water: water, pressure: pressure, specificHeat: cp)
            #expect(abs(split.temperature - temperature) < 1e-7 && abs(split.vapour / saturated - 1) < 1e-9)
            #expect(abs(split.ice - ice) < 1e-12)
        }
        // Too little water to saturate: all vapour.
        let dry = CloudRise.split(
            enthalpy: cp * 290 + CloudRise.latentHeat * 0.001, water: 0.001, pressure: pressure,
            specificHeat: cp)
        #expect(abs(dry.temperature - 290) < 1e-9 && dry.vapour == 0.001)
    }

    @Test(
        "In uniform humid air, mixing conserves the cloud's excess water and moist enthalpy, through condensing"
    )
    func moistMixing() {
        var spec = CloudSpec()
        spec.productWater = 0.6
        spec.rainRate = 0
        let humidity =
            0.9 * CloudRise.saturationHumidity(temperature: ambientTemperature, pressure: ambientPressure)
        // Warm, wet gas, like breath on a cold day: its water rises faster with its heat along
        // the line of its mixtures with the air than saturation does.
        var start = handOver(radius: 3, height: 7, excess: 0.3)
        start.chargeMass = start.mass / 4
        let times = [0.0, 0.1, 0.3, 1, 3, 10, 30, 100, 300]
        let (samples, _) = CloudRise.follow(
            start, spec: spec, atmosphere: uniform, humidity: { _ in humidity }, at: times)
        func enthalpy(_ sample: CloudSample) -> Double {
            spec.specificHeat * sample.temperature + CloudRise.latentHeat
                * (sample.water - sample.liquidWater)
        }
        let air = spec.specificHeat * ambientTemperature + CloudRise.latentHeat * humidity
        let first = samples[0]
        #expect(abs(first.water - (0.6 / 4 + humidity * 3 / 4)) < 1e-12 && first.liquidWater == 0)
        for sample in samples {
            #expect(
                abs(sample.mass * (sample.water - humidity) / (first.mass * (first.water - humidity)) - 1)
                    < 1e-6)
            #expect(
                abs(sample.mass * (enthalpy(sample) - air) / (first.mass * (enthalpy(first) - air)) - 1)
                    < 1e-5)
        }
        // Mixed into air near saturation it condenses on the way, and evaporates again as it
        // thins: a mixing cloud.
        #expect(
            samples.contains { $0.liquidWater > 0 } && samples.last?.liquidWater == 0,
            "\(samples.map(\.liquidWater))")
    }

    @Test(
        "Air rising without mixing cools at the dry adiabatic lapse rate, and once saturated at the moist one"
    )
    func adiabats() throws {
        var spec = CloudSpec()
        spec.entrainment = 1e-9
        let atmosphere = CloudAtmosphere(
            groundTemperature: ambientTemperature, groundPressure: ambientPressure, lapseRate: 0.0065,
            tropopause: 11_000)
        for saturated in [false, true] {
            let humidity = CloudHumidity(relativeHumidity: saturated ? 1 : 0, atmosphere: atmosphere)
            // Air of the surroundings, 10 m up, sent upwards.
            let q = humidity(10)
            let air = atmosphere(10)
            var start = handOver(radius: 5, height: 10, excess: 0, riseSpeed: 3)
            start.temperature = air.temperature * (1 + q / CloudRise.molarRatio - q)
            start.ambientPressure = air.pressure
            let (samples, _) = CloudRise.follow(
                start, spec: spec, atmosphere: atmosphere.callAsFunction, humidity: humidity.callAsFunction,
                at: [0, 15])
            let lapse =
                (samples[0].temperature - samples[1].temperature) / (samples[1].height - samples[0].height)
            #expect(abs(samples[0].temperature - air.temperature) < 1e-9)
            let middle = atmosphere((samples[0].height + samples[1].height) / 2)
            let expected: Double
            if saturated {
                // The saturated adiabatic lapse rate, g (1 + L r / (R T)) / (c_p + L² r ε / (R T²)).
                let r = CloudRise.saturationHumidity(
                    temperature: middle.temperature, pressure: middle.pressure)
                let l = CloudRise.latentHeat
                let rt = CloudRise.gasConstant * middle.temperature
                expected =
                    CloudRise.gravity * (1 + l * r / rt)
                    / (spec.specificHeat + l * l * r * CloudRise.molarRatio / (rt * middle.temperature))
                #expect(samples[1].liquidWater > 0)
            } else {
                expected = CloudRise.gravity / spec.specificHeat
                #expect(samples[1].liquidWater == 0)
            }
            #expect(
                abs(lapse / expected - 1) < (saturated ? 0.02 : 0.002),
                "\(lapse * 1000) against \(expected * 1000) K/km")
        }
    }

    @Test(
        "Humid air lifts the cloud a little by its vapour, and saturated air lets it condense and go on rising"
    )
    func humidRise() throws {
        let atmosphere = CloudAtmosphere(
            groundTemperature: ambientTemperature, groundPressure: ambientPressure, lapseRate: 0.0065,
            tropopause: 11_000)
        var start = handOver(radius: 7, height: 7, excess: 4)
        start.chargeMass = 50
        func follow(_ relativeHumidity: Double) -> (samples: [CloudSample], stabilised: CloudSample?) {
            var spec = CloudSpec()
            spec.relativeHumidity = relativeHumidity
            return CloudRise.follow(
                start, spec: spec, atmosphere: atmosphere.callAsFunction,
                humidity: spec.humidity(start).callAsFunction, at: [0, 600, 1200])
        }
        let dry = follow(0)
        let humid = follow(0.8)
        let saturated = follow(1)
        let dryStop = try #require(dry.stabilised)
        let humidStop = try #require(humid.stabilised)
        #expect(humidStop.height > dryStop.height && humidStop.height < 1.1 * dryStop.height)
        #expect(humid.samples.allSatisfy { $0.liquidWater == 0 })
        // Saturated air at 6.5 K/km is unstable for a cloud that condenses as it rises, cooling at
        // the moist adiabatic rate of about 5 K/km.
        #expect(saturated.stabilised == nil && saturated.samples[2].riseSpeed > 0)
        #expect(saturated.samples[2].height > 2 * dryStop.height && saturated.samples[2].liquidWater > 0)
    }

    @Test(
        "Water falling out of the cloud leaves its condensate at the threshold, and every drop is accounted for"
    )
    func rain() throws {
        var spec = CloudSpec()
        spec.productWater = 0.6
        spec.rainRate = 0.01
        // Warm, wet gas in cold, humid, still air: it condenses, freezes in part and precipitates.
        let cold = 260.0
        let air: (Double) -> (temperature: Double, pressure: Double) = { [ambientPressure] _ in
            (cold, ambientPressure)
        }
        let humidity = 0.9 * CloudRise.saturationHumidity(temperature: cold, pressure: ambientPressure)
        var start = handOver(radius: 3, height: 7, excess: 0.3)
        start.ambientTemperature = cold
        start.temperature = cold * 1.3
        start.chargeMass = start.mass / 4
        let times = [0.0, 1, 3, 10, 30, 100, 300, 1000, 3000]
        let (samples, _) = CloudRise.follow(
            start, spec: spec, atmosphere: air, humidity: { _ in humidity }, at: times)
        let first = samples[0]
        // The water the cloud started with and drew in is in it or has fallen out.
        for sample in samples {
            let drawnIn = sample.mass + sample.precipitation - first.mass
            let budget = first.mass * first.water + humidity * drawnIn
            #expect(abs((sample.mass * sample.water + sample.precipitation) / budget - 1) < 1e-6)
        }
        let last = try #require(samples.last)
        #expect(last.precipitation > 0 && last.snow > 0 && last.snow < last.precipitation, "\(last)")
        #expect(samples.contains { $0.ice > 0 && $0.liquidWater > 0 })
    }

    @Test(
        "In saturated air a cloud condenses, freezes and snows as it rises, until saturated air would cool faster than the air"
    )
    func iceAndTropopause() throws {
        var spec = CloudSpec()
        spec.relativeHumidity = 1
        let atmosphere = CloudAtmosphere(
            groundTemperature: ambientTemperature, groundPressure: ambientPressure, lapseRate: 0.0065,
            tropopause: 11_000)
        var start = handOver(radius: 7, height: 7, excess: 4)
        start.chargeMass = 50
        let times = (0...72).map { Double($0) * 100 }
        let (samples, stabilised) = CloudRise.follow(
            start, spec: spec, atmosphere: atmosphere.callAsFunction,
            humidity: spec.humidity(start).callAsFunction,
            at: times)
        // Above the freezing level, 2.3 km up, its condensate turns to ice.
        let freezing = (ambientTemperature - CloudRise.freezingPoint) / 0.0065
        #expect(samples.contains { $0.height > freezing && $0.ice > 0 })
        #expect(samples.allSatisfy { $0.height > freezing - 100 || $0.ice == 0 })
        let last = try #require(samples.last)
        #expect(last.precipitation > 0 && last.snow > 0)
        // The saturated adiabatic lapse rate grows as the air grows colder and holds less water;
        // the cloud stops where it has passed the air's 6.5 K/km, well below the tropopause.
        let stop = try #require(stabilised)
        func saturatedLapse(_ height: Double) -> Double {
            let air = atmosphere(height)
            let r = CloudRise.saturationHumidity(temperature: air.temperature, pressure: air.pressure)
            let l = CloudRise.latentHeat
            let rt = CloudRise.gasConstant * air.temperature
            return CloudRise.gravity * (1 + l * r / rt)
                / (spec.specificHeat + l * l * r * CloudRise.molarRatio / (rt * air.temperature))
        }
        #expect(
            saturatedLapse(0) < 0.0065 && saturatedLapse(stop.height) > 0.0065,
            "\(saturatedLapse(stop.height))")
        #expect(stop.height > freezing && stop.height < 8_000, "\(stop.height)")
    }

    @Test("The standard atmosphere's pressure at the tropopause and above")
    func standardAtmosphere() {
        let atmosphere = CloudAtmosphere(
            groundTemperature: 288.15, groundPressure: 101_325, lapseRate: 0.0065, tropopause: 11_000)
        let tropopause = atmosphere(11_000)
        #expect(abs(tropopause.temperature - 216.65) < 1e-9)
        #expect(abs(tropopause.pressure / 22_632.1 - 1) < 1e-3, "\(tropopause.pressure)")
        #expect(abs(atmosphere(20_000).pressure / 5_474.89 - 1) < 1e-3, "\(atmosphere(20_000).pressure)")
        #expect(atmosphere(20_000).temperature == tropopause.temperature)
    }

    @Test("A hot sphere in the air is handed over with its mass, place, temperature and buoyancy")
    func handOverFromSolver() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let scenario = Scenario(
            name: "Hot", domainSize: SIMD3(repeating: 8), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(1, 1, 1)))
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.125)
        let centre = SIMD3<Float>(4, 3.5, 4)
        let pressure: Float = 101_325
        let ambient = Float(pressure) / (1.225 * 287.05)
        solver.mutateState { cells in
            for k in 0..<64 {
                for j in 0..<64 {
                    for i in 0..<64 {
                        let x = (SIMD3<Float>(Float(i), Float(j), Float(k)) + 0.5) * 0.125
                        let hot = simd_distance(x, centre) < 1.5
                        let t: Float = hot ? 2000 : ambient
                        // The hot gas compressed to twice the pressure, as if the blast had not
                        // quite left it, and rising.
                        let p = hot ? 2 * pressure : pressure
                        cells[solver.grid.index(i, j, k)] = CellState(
                            Primitive(
                                density: p / (287.05 * t), velocity: SIMD3(0, 0, hot ? 5 : 0), pressure: p),
                            gamma: 1.4)
                    }
                }
            }
        }
        let handOver = solver.cloudHandOver(hotterThan: 500)
        let volume = 4 / 3 * Double.pi * pow(1.5, 3)
        let mass = 2 * Double(pressure) * volume / (287.05 * 2000)
        #expect(abs(handOver.mass / mass - 1) < 0.02, "\(handOver.mass) against \(mass)")
        #expect(simd_distance(handOver.centre, centre) < 0.01)
        #expect(abs(handOver.riseSpeed - 5) < 1e-3)
        // Brought to the ambient pressure isentropically, cooling by 2^(0.4/1.4).
        let temperature = 2000 / pow(2, 0.4 / 1.4)
        #expect(abs(handOver.temperature / temperature - 1) < 1e-3, "\(handOver.temperature)")
        #expect(abs(handOver.volume / (handOver.mass * 287.05 * temperature / Double(pressure)) - 1) < 1e-3)
        #expect(
            abs(handOver.buoyancy / (9.80665 * handOver.mass * (temperature / Double(ambient) - 1)) - 1)
                < 1e-3)
        #expect(abs(handOver.warmBuoyancy / handOver.buoyancy - 1) < 1e-6)
        #expect(abs(handOver.ambientTemperature - Double(ambient)) < 1e-3)
        #expect(solver.cloudHandOver(hotterThan: 2000).mass == 0)
    }

    @Test("The description takes its defaults from empty JSON and refuses what is out of range")
    func spec() throws {
        let spec = try JSONDecoder().decode(CloudSpec.self, from: Data("{}".utf8))
        #expect(spec == CloudSpec())
        try spec.validate()
        let adiabatic = try JSONDecoder().decode(CloudSpec.self, from: Data(#"{"lapseRate": 0.01}"#.utf8))
        #expect(throws: CocoaError.self) { try adiabatic.validate() }
        let wide = try JSONDecoder().decode(CloudSpec.self, from: Data(#"{"entrainment": 0}"#.utf8))
        #expect(throws: CocoaError.self) { try wide.validate() }
        let windy = try JSONDecoder().decode(
            CloudSpec.self, from: Data(#"{"windSpeed": 5, "windDirection": 30}"#.utf8))
        try windy.validate()
        #expect(windy.windSpeed == 5 && windy.wind.direction == .pi / 6 && windy.windExponent == 1.0 / 7)
        let backwards = try JSONDecoder().decode(CloudSpec.self, from: Data(#"{"windSpeed": -1}"#.utf8))
        #expect(throws: CocoaError.self) { try backwards.validate() }
        let soaked = try JSONDecoder().decode(CloudSpec.self, from: Data(#"{"relativeHumidity": 1.2}"#.utf8))
        #expect(throws: CocoaError.self) { try soaked.validate() }
        #expect(spec.relativeHumidity == 0 && spec.productWater == 0.2 && spec.rainRate == 0.001)
        let pouring = try JSONDecoder().decode(CloudSpec.self, from: Data(#"{"rainThreshold": 0.1}"#.utf8))
        #expect(throws: CocoaError.self) { try pouring.validate() }
    }

    @Test(
        "The result samples the cloud more closely early on, and the scene gets it as a sphere after the run")
    func resultAndScene() throws {
        var spec = CloudSpec()
        spec.duration = 60
        spec.frameInterval = 2
        let result = CloudResult(spec: spec, handOver: handOver(radius: 5, height: 5, excess: 5, time: 0.1))
        #expect(result.samples.first?.time == 0.1 && abs((result.samples.last?.time ?? 0) - 60.1) < 1e-9)
        #expect(zip(result.samples, result.samples.dropFirst()).allSatisfy { $0.time < $1.time })
        #expect(result.samples.count > 100 && result.samples[1].time - result.samples[0].time < 0.02)
        #expect(result.summary.count == 2 && result.summary[0].hasPrefix("Cloud: "))
        let frames = result.frames()
        #expect(frames.count == 31 && abs(frames[1].time - 2.1) < 1e-9)

        let folder = FileManager.default.temporaryDirectory.appending(path: "cloud-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "scene.usda")
        var scenario = Scenario(
            name: "Cloud", domainSize: SIMD3(repeating: 10), boxes: [],
            charge: Charge(mass: 1, position: SIMD3(5, 5, 1)))
        scenario.gauges = []
        let writer = try USDSceneWriter(url: url, scenario: scenario, frameInterval: 0.001)
        for _ in 0..<3 { try writer.append(nil) }
        writer.addCloud(frames, secondsPerFrame: spec.frameInterval)
        try writer.finish()
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("endTimeCode = 33\n") && text.contains("double cloudStartTimeCode = 3\n"))
        #expect(text.contains("double simulatedSecondsPerCloudFrame = 2.0\n"))
        #expect(text.contains("def Sphere \"Cloud\"") && text.contains("            3: \"inherited\""))
        #expect(text.contains("float primvars:temperature.timeSamples"))
        #expect(
            text.contains("float primvars:liquidWater.timeSamples")
                && text.contains("float primvars:ice.timeSamples"))

        let checker = URL(filePath: "/usr/bin/usdchecker")
        if FileManager.default.isExecutableFile(atPath: checker.path) {
            let process = Process()
            process.executableURL = checker
            process.arguments = [url.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }
    }
}
