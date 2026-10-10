import Foundation
import Testing
import simd

@testable import BlastCore

@Suite("The cloud's spread once it stops rising")
struct CloudSpreadTests {
    private let groundTemperature = 288.15
    private let groundPressure = 101_325.0

    private var standard: CloudAtmosphere {
        CloudAtmosphere(
            groundTemperature: groundTemperature, groundPressure: groundPressure, lapseRate: 0.0065,
            tropopause: 11_000)
    }

    /// Air of one temperature and pressure at every height.
    private var uniform: (Double) -> (temperature: Double, pressure: Double) {
        { [groundTemperature, groundPressure] _ in (groundTemperature, groundPressure) }
    }

    /// A dry cloud of `radius` at rest `height` up, `excess` kelvin warmer than the air there, with
    /// `water` kilograms of water a kilogram, as the rising thermal hands it over to the spread.
    private func stopped(
        radius: Double, height: Double, excess: Double = 0, water: Double = 0,
        atmosphere: (Double) -> (temperature: Double, pressure: Double), spec: CloudSpec
    ) -> CloudRise.State {
        let air = atmosphere(height)
        let temperature = air.temperature + excess
        // The enthalpy that gives `temperature` with the water split at saturation there.
        let vapour = min(
            water, CloudRise.cloudSaturationHumidity(temperature: temperature, pressure: air.pressure))
        let ice = (1 - CloudRise.liquidFraction(temperature: temperature)) * (water - vapour)
        let enthalpy =
            spec.specificHeat * temperature + CloudRise.latentHeat * vapour - CloudRise.fusionHeat * ice
        let density =
            air.pressure
            / (CloudRise.gasConstant * CloudRise.densityTemperature(temperature, vapour: vapour, water: water))
        return CloudRise.State(
            height: height, position: .zero, mass: density * 4 / 3 * .pi * pow(radius, 3), impulse: 0,
            drift: .zero, enthalpy: enthalpy, water: water)
    }

    private func model(
        _ spec: CloudSpec, atmosphere: @escaping (Double) -> (temperature: Double, pressure: Double),
        wind: @escaping (Double) -> SIMD2<Double> = { _ in .zero },
        humidity: @escaping (Double) -> Double = { _ in 0 }
    ) -> CloudRise.Model {
        CloudRise.Model(
            spec: spec, atmosphere: atmosphere, wind: wind, humidity: humidity, turbulence: { _, _, _ in 0 })
    }

    @Test("The stability class follows the lapse rate, and a puff grows as Slade's σ = δ x^β")
    func classes() {
        #expect(PasquillClass(lapseRate: 0.0065) == .d)
        #expect(PasquillClass(lapseRate: 0.0098) == .d)
        #expect(PasquillClass(lapseRate: 0.016) == .c)
        #expect(PasquillClass(lapseRate: 0.018) == .b)
        #expect(PasquillClass(lapseRate: 0.025) == .a)
        #expect(PasquillClass(lapseRate: 0) == .e)
        #expect(PasquillClass(lapseRate: -0.03) == .f)
        // In the neutral class, 1 km of travel: 34 m across the wind and 19 m vertically.
        let law = PasquillClass.d.horizontal
        #expect(abs(PasquillClass.grow(0, by: 1000, law) - 0.06 * pow(1000, 0.92)) < 1e-9)
        #expect(
            abs(PasquillClass.grow(0, by: 1000, PasquillClass.d.vertical) - 0.15 * pow(1000, 0.70)) < 1e-9)
        // Grown in steps, a puff's size alone sets how fast it grows.
        var sigma = 0.0
        for _ in 0..<100 { sigma = PasquillClass.grow(sigma, by: 10, law) }
        #expect(abs(sigma / PasquillClass.grow(0, by: 1000, law) - 1) < 1e-9)
    }

    @Test("A neutrally buoyant puff without a gravity current grows by the stability class alone")
    func passivePuff() {
        var spec = CloudSpec()
        spec.frontFroude = 0
        spec.stabilityClass = "D"
        let wind = SIMD2(5.0, 0)
        let start = stopped(radius: 40, height: 300, atmosphere: uniform, spec: spec)
        let times = [100.0, 400, 1000]
        let samples = model(spec, atmosphere: uniform, wind: { _ in wind }).spread(
            from: start, time: 100, at: times)
        #expect(samples.count == 3)
        for sample in samples {
            let travelled = 5 * (sample.time - 100)
            let across = PasquillClass.grow(0, by: travelled, PasquillClass.d.horizontal)
            let up = PasquillClass.grow(0, by: travelled, PasquillClass.d.vertical)
            // The sphere's own spread and the turbulence's add as variances, its extent √5 σ.
            #expect(abs(sample.radius / (40 * 40 + 5 * across * across).squareRoot() - 1) < 1e-9)
            #expect(abs(sample.halfDepth / (40 * 40 + 5 * up * up).squareRoot() - 1) < 1e-9)
            #expect(sample.stabilityClass == "D" && sample.riseSpeed == 0 && sample.height == 300)
            // It drifts at the wind's speed, and fills its volume with the air it draws in.
            #expect(abs(sample.position.x - travelled) < 1e-6 && sample.velocity == wind)
            let density = groundPressure / (CloudRise.gasConstant * groundTemperature)
            #expect(abs(sample.mass / (density * sample.volume) - 1) < 1e-9)
        }
        // About 620 m across after 15 minutes at 5 m/s, from 80 m.
        #expect(abs(2 * samples[2].radius - 622) < 2, "\(2 * samples[2].radius)")
    }

    @Test(
        "In stable air the cloud spreads as a gravity current, R³ = R₀³ + (3 Fr / 2π) N V t, at constant volume"
    )
    func gravityCurrent() {
        var spec = CloudSpec()
        // The gentlest growth, in calm air, so the gravity current is nearly alone.
        spec.stabilityClass = "F"
        spec.leastTransportSpeed = 0.1
        let radius = 50.0
        let height = 500.0
        let start = stopped(radius: radius, height: height, atmosphere: standard.callAsFunction, spec: spec)
        let samples = model(spec, atmosphere: standard.callAsFunction).spread(
            from: start, time: 0, at: [60, 300, 600])
        let air = standard(height)
        let n = sqrt(
            CloudRise.gravity / air.temperature * (CloudRise.gravity / spec.specificHeat - standard.lapseRate)
        )
        let volume = 4 / 3 * Double.pi * pow(radius, 3)
        for sample in samples {
            let expected = cbrt(pow(radius, 3) + 3 * spec.frontFroude * n * volume * sample.time / (2 * .pi))
            #expect(
                abs(sample.radius / expected - 1) < 2e-3,
                "\(sample.time) s: \(sample.radius) against \(expected)")
            // It flattens as it spreads, keeping its volume but for the little the turbulence adds.
            #expect(abs(sample.volume / volume - 1) < 0.05, "\(sample.volume / volume)")
            #expect(abs(sample.height - height) < 1e-6)
        }
        #expect(samples[2].radius > 2.5 * radius && samples[2].halfDepth < radius / 6)
        // Without stability it does not spread: in the dry adiabatic atmosphere, only the turbulence
        // grows it, slowly in class F.
        let neutral = CloudAtmosphere(
            groundTemperature: groundTemperature, groundPressure: groundPressure,
            lapseRate: CloudRise.gravity / spec.specificHeat * (1 - 1e-9), tropopause: 11_000)
        let still = model(spec, atmosphere: neutral.callAsFunction).spread(
            from: stopped(radius: radius, height: height, atmosphere: neutral.callAsFunction, spec: spec),
            time: 0, at: [600])
        #expect(still[0].radius < radius * 1.01)
    }

    @Test("An overshooting cloud settles back to where it is neutrally buoyant within half a buoyancy period")
    func settling() {
        var spec = CloudSpec()
        spec.stabilityClass = "F"
        spec.leastTransportSpeed = 0.1
        spec.frontFroude = 0
        let height = 400.0
        let start = stopped(
            radius: 60, height: height, excess: -0.2, atmosphere: standard.callAsFunction, spec: spec)
        let samples = model(spec, atmosphere: standard.callAsFunction).spread(
            from: start, time: 0, at: Array(stride(from: 10.0, through: 600, by: 10)))
        // Dry air keeps its potential temperature: the level where the air's is the cloud's.
        let exponent = CloudRise.gasConstant / spec.specificHeat
        func potential(_ temperature: Double, _ z: Double) -> Double {
            temperature * pow(groundPressure / standard(z).pressure, exponent)
        }
        let cloud = potential(standard(height).temperature - 0.2, height)
        var (low, high) = (0.0, height)
        for _ in 0..<60 {
            let middle = (low + high) / 2
            if potential(standard(middle).temperature, middle) < cloud { low = middle } else { high = middle }
        }
        let last = samples.last!
        #expect(abs(last.height - low) < 0.5, "\(last.height) against \(low)")
        #expect(abs(last.temperature - last.ambientTemperature) < 0.01)
        #expect(last.riseSpeed == 0 && height - low > 40)
        // Sinking all the way, and only down.
        for (a, b) in zip(samples, samples.dropFirst()) { #expect(b.height <= a.height + 1e-9) }
        let n = sqrt(
            CloudRise.gravity / standard(height).temperature
                * (CloudRise.gravity / spec.specificHeat - standard.lapseRate))
        let settled = samples.first { $0.height == last.height }
        #expect(
            abs((settled?.time ?? 0) - Double.pi / n) < 15,
            "\(settled?.time ?? 0) s against \(Double.pi / n) s")
    }

    @Test("Spreading in humid air keeps every drop of water, in the cloud, fallen out or drawn in")
    func water() {
        var spec = CloudSpec()
        spec.frontFroude = 0
        spec.stabilityClass = "B"
        let humidity = 0.006
        // Cool, wet gas: saturated with condensate to rain, in air at its own temperature.
        let start = stopped(radius: 50, height: 300, water: 0.02, atmosphere: uniform, spec: spec)
        let samples = model(
            spec, atmosphere: uniform, wind: { _ in SIMD2(3, 0) }, humidity: { _ in humidity }
        )
        .spread(from: start, time: 0, at: [60, 600, 1800])
        let held = start.mass * start.water
        for sample in samples {
            let drawn = sample.mass + sample.precipitation - start.mass
            let water = sample.mass * sample.water + sample.precipitation
            #expect(
                abs(water - held - drawn * humidity) < 1e-9 * held,
                "\(water) against \(held + drawn * humidity)")
        }
        #expect(samples[0].liquidWater > 0 && samples[2].precipitation > 0)
        #expect(samples[2].liquidWater < samples[0].liquidWater)
    }

    @Test("The result spreads the cloud once it stops, unless told not to")
    func result() {
        var spec = CloudSpec()
        spec.duration = 1800
        spec.windSpeed = 5
        let start = CloudHandOver(
            time: 0.2, mass: 500, volume: 500 * 287.05 * 1200 / groundPressure, centre: SIMD3(0, 0, 4),
            temperature: 1200, riseSpeed: 0, hottest: 2000, buoyancy: 15_000, warmBuoyancy: 18_000,
            ambientTemperature: groundTemperature, ambientPressure: groundPressure, chargeMass: 60)
        let cloud = CloudResult(spec: spec, handOver: start)
        let stoppedAt = try? #require(cloud.stabilised)
        guard let stoppedAt else { return }
        let rising = cloud.samples.filter { $0.time <= stoppedAt.time }
        let spreading = cloud.samples.filter { $0.time > stoppedAt.time }
        #expect(rising.allSatisfy { $0.thickness == nil } && spreading.allSatisfy { $0.thickness != nil })
        #expect(spreading.count > 10)
        // It carries on from where it stopped, and never narrower: flattening as a gravity current
        // first, and then thickened by the turbulence as it drifts kilometres.
        let frames = cloud.frames()
        let first = try? #require(frames.first { $0.time > stoppedAt.time })
        #expect(abs((first?.radius ?? 0) / stoppedAt.radius - 1) < 0.02)
        #expect(abs((first?.height ?? 0) - stoppedAt.height) < 0.5)
        for (a, b) in zip(spreading, spreading.dropFirst()) { #expect(b.radius >= a.radius) }
        let last = spreading.last!
        #expect(last.radius > 2 * stoppedAt.radius)
        let thinnest = spreading.map(\.halfDepth).min()!
        #expect(
            thinnest < 0.8 * stoppedAt.radius && last.halfDepth > 1.5 * thinnest,
            "\(thinnest), \(last.halfDepth), \(stoppedAt.radius)")
        #expect(cloud.drift(last) > cloud.drift(stoppedAt) + 5 * (last.time - stoppedAt.time) * 0.9)
        #expect(cloud.summary.last?.contains("spread at") == true)
        // Without spreading, the thermal goes on as before.
        spec.spread = false
        let thermal = CloudResult(spec: spec, handOver: start)
        #expect(thermal.samples.allSatisfy { $0.thickness == nil } && thermal.stabilised == cloud.stabilised)
        #expect(thermal.samples.count == cloud.samples.count)
    }
}
