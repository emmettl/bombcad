import Foundation
import Testing
import simd

@testable import BlastCore

@Suite("The cloud in turbulent air and in a measured sounding")
struct CloudAtmosphereTests {
    private let ambientTemperature = 288.15
    private let ambientPressure = 101_325.0

    /// A sphere of gas `excess` times as hot as the air, of `radius`, centred `height` up.
    private func handOver(radius: Double, height: Double, excess: Double) -> CloudHandOver {
        let temperature = ambientTemperature * (1 + excess)
        let volume = 4 / 3 * Double.pi * pow(radius, 3)
        let mass = ambientPressure * volume / (CloudRise.gasConstant * temperature)
        return CloudHandOver(
            time: 0, mass: mass, volume: volume, centre: SIMD3(0, 0, Float(height)), temperature: temperature,
            riseSpeed: 0, hottest: temperature, buoyancy: CloudRise.gravity * mass * excess,
            warmBuoyancy: CloudRise.gravity * mass * excess, ambientTemperature: ambientTemperature,
            ambientPressure: ambientPressure)
    }

    private static let soundings = URL(filePath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "Samples/Soundings")

    private func sounding(_ name: String) throws -> CloudSounding {
        try CloudSounding(
            wyomingCSV: String(contentsOf: Self.soundings.appending(path: name), encoding: .utf8))
    }

    // MARK: Turbulence

    @Test(
        "The boundary layer's turbulence: the surface layer's ε = u*³ / κz, and the mixed layer's 0.4 w*³ / h"
    )
    func turbulenceProfiles() throws {
        let neutral = CloudTurbulence(frictionVelocity: 0.4, convectiveVelocity: 0, height: 1000)
        let low = try #require(neutral(2))
        #expect(abs(low.dissipation / (pow(0.4, 3) / (0.4 * 2)) - 1) < 0.01, "\(low.dissipation)")
        #expect(abs(low.velocity - 1.3 * 0.4 * (1 - 0.8 * 2 / 1000)) < 1e-12)
        // T_L = Λ / 1.3σ_w, and above the layer and without u* or w*, nothing.
        let middle = try #require(neutral(500))
        #expect(abs(middle.timescale - 1 / (2.5 / 500 + 4.0 / 1000) / (1.3 * middle.velocity)) < 1e-9)
        #expect(neutral(1000) == nil && neutral(1500) == nil)
        #expect(CloudSpec().turbulence(10) == nil)

        let convective = CloudTurbulence(frictionVelocity: 0, convectiveVelocity: 2, height: 1500)
        let mixed = try #require(convective(450))
        #expect(abs(mixed.dissipation - 0.4 * 8 / 1500) < 1e-12)
        let shape = 2.1 * cbrt(0.3) * (1 - 0.8 * 0.3)
        #expect(abs(mixed.velocity - sqrt(0.4) * 2 * shape) < 1e-12)
        #expect(abs(mixed.timescale - 1 / (0.6 / 450 + 2.0 / 1500) / mixed.velocity) < 1e-9)

        // A small cloud takes the inertial range's (εb)^⅓; a large one σ_w's share, which falls
        // with time as the eddies come to carry it about instead of mixing into it.
        let small = neutral.entrainmentSpeed(height: 500, radius: 1, time: 0)
        #expect(abs(small - 0.655 * cbrt(middle.dissipation)) < 1e-12)
        let large = neutral.entrainmentSpeed(height: 500, radius: 1e4, time: 100)
        #expect(abs(large - 0.655 * middle.velocity / sqrt(1 + 100 / (2 * middle.timescale))) < 1e-12)
    }

    @Test(
        "A puff of the air's own temperature, at rest in steady turbulence, grows as b^⅔ = b₀^⅔ + ⅔ α ε^⅓ t")
    func richardsonGrowth() throws {
        // Without buoyancy, rise or wind, the puff draws in air only through the turbulence,
        // dm/dt = 4πb²ρ α (εb)^⅓, so that its radius follows Richardson's law of the growth of a
        // cloud of particles, b² ∝ ε t³ once large.
        let start = handOver(radius: 2, height: 100, excess: 0)
        let (alpha, epsilon) = (0.655, 1e-3)
        let times = [0.0, 100, 1000, 3000]
        let (samples, _) = CloudRise.follow(
            start, spec: CloudSpec(),
            atmosphere: { [ambientTemperature, ambientPressure] _ in (ambientTemperature, ambientPressure) },
            turbulence: { _, radius, _ in alpha * cbrt(epsilon * radius) }, at: times)
        #expect(samples.count == times.count)
        for sample in samples {
            let expected = pow(pow(2, 2.0 / 3) + 2.0 / 3 * alpha * cbrt(epsilon) * sample.time, 1.5)
            #expect(
                abs(sample.radius / expected - 1) < 1e-6,
                "\(sample.time) s: \(sample.radius) against \(expected)")
            #expect(abs(sample.height - 100) < 1e-9 && abs(sample.temperature - ambientTemperature) < 1e-9)
        }
    }

    @Test(
        "In turbulent air the cloud draws in more air and stops lower, the lower the stronger the turbulence")
    func turbulentRise() throws {
        var spec = CloudSpec()
        spec.duration = 900
        let start = handOver(radius: 7, height: 7, excess: 3)
        func stopped(_ frictionVelocity: Double, convective: Double = 0) throws -> CloudSample {
            spec.frictionVelocity = frictionVelocity
            spec.convectiveVelocity = convective
            return try #require(CloudResult(spec: spec, handOver: start).stabilised)
        }
        let still = try stopped(0)
        let light = try stopped(0.2)
        let strong = try stopped(0.6)
        #expect(
            light.height < still.height && strong.height < light.height,
            "\([still, light, strong].map(\.height))")
        #expect(light.mass > still.mass)
        let afternoon = try stopped(0.2, convective: 2)
        #expect(afternoon.height < light.height)
        // Off, the same as without it, to the last digit.
        spec.frictionVelocity = 0
        spec.convectiveVelocity = 0
        spec.turbulentEntrainment = 1
        var plain = CloudSpec()
        plain.duration = 900
        #expect(
            CloudResult(spec: spec, handOver: start).samples
                == CloudResult(spec: plain, handOver: start).samples)
    }

    // MARK: A measured sounding

    @Test("The Las Vegas soundings are read in kelvin, pascals and metres above the ground")
    func readSounding() throws {
        let dawn = try sounding("las-vegas-2024-06-15-12z.csv")
        #expect(dawn.levels.count == 94)
        let ground = dawn.levels[0]
        #expect(ground.height == 698 && ground.pressure == 92_720 && abs(ground.temperature - 303.85) < 1e-9)
        #expect(
            abs(ground.dewPoint - 272.35) < 1e-9 && ground.windSpeed == 1.5 && ground.windDirection == 196)
        #expect(dawn(0).temperature == ground.temperature && abs(dawn(0).pressure - ground.pressure) < 1e-6)
        // At a level its own values; between two, the temperature linear and the pressure's
        // logarithm.
        let (a, b) = (dawn.levels[10], dawn.levels[11])
        #expect(abs(dawn(a.height - ground.height).temperature - a.temperature) < 1e-9)
        let middle = dawn((a.height + b.height) / 2 - ground.height)
        #expect(abs(middle.temperature - (a.temperature + b.temperature) / 2) < 1e-9)
        #expect(abs(middle.pressure - sqrt(a.pressure * b.pressure)) < 1e-6)
        // The relative humidity from the dew point as the archive gives it, 13% at the ground.
        let saturated = CloudRise.saturationHumidity(
            temperature: ground.temperature, pressure: ground.pressure)
        #expect(abs(dawn.humidity(0) / saturated - 0.13) < 0.01, "\(dawn.humidity(0) / saturated)")
        // Above the top, isothermal and dry.
        let top = try #require(dawn.levels.last)
        let above = dawn(top.height - ground.height + 1000)
        #expect(above.temperature == top.temperature && above.pressure < top.pressure)
        #expect(dawn.humidity(top.height - ground.height + 1000) == 0)
    }

    @Test("The measured pressures are in hydrostatic balance with the measured temperatures, to 0.3%")
    func hydrostatic() throws {
        for name in ["las-vegas-2024-06-15-12z.csv", "las-vegas-2024-06-16-00z.csv"] {
            let profile = try sounding(name)
            var pressure = profile.levels[0].pressure
            var worst = 0.0
            for (a, b) in zip(profile.levels, profile.levels.dropFirst()) {
                // The hypsometric equation over each layer, with the mean virtual temperature.
                func virtual(_ level: CloudSounding.Level) -> Double {
                    let vapour = CloudRise.humidity(
                        vapourPressure: CloudRise.saturationPressure(temperature: level.dewPoint),
                        pressure: level.pressure)
                    return level.temperature * (1 + vapour / CloudRise.molarRatio - vapour)
                }
                let mean = (virtual(a) + virtual(b)) / 2
                pressure *= exp(-CloudRise.gravity * (b.height - a.height) / (CloudRise.gasConstant * mean))
                worst = max(worst, abs(pressure / b.pressure - 1))
            }
            #expect(worst < 0.003, "\(name): \(worst)")
        }
    }

    @Test("The wind blows from where the sounding says, north along y unless the scene says otherwise")
    func soundingWind() throws {
        let dawn = try sounding("las-vegas-2024-06-15-12z.csv")
        // From 196°, a little west of south, at 1.5 m/s: towards the north and a little east.
        let wind = dawn.wind(0, north: .pi / 2)
        let from = 196 * Double.pi / 180
        #expect(abs(wind.x + 1.5 * sin(from)) < 1e-12 && abs(wind.y + 1.5 * cos(from)) < 1e-12)
        #expect(wind.x > 0 && wind.y > 1.4)
        // North along x: the same wind turned a quarter clockwise in the scene.
        let turned = dawn.wind(0, north: 0)
        #expect(abs(turned.x - wind.y) < 1e-12 && abs(turned.y + wind.x) < 1e-12)
    }

    @Test("A sounding made from the standard atmosphere gives the standard atmosphere's cloud")
    func standardSounding() throws {
        let atmosphere = CloudAtmosphere(
            groundTemperature: ambientTemperature, groundPressure: ambientPressure, lapseRate: 0.0065,
            tropopause: 11_000)
        let levels = stride(from: 0.0, through: 16_000, by: 100).map { z in
            let air = atmosphere(z)
            return CloudSounding.Level(
                height: 500 + z, pressure: air.pressure, temperature: air.temperature, dewPoint: 150,
                windSpeed: 0,
                windDirection: 0)
        }
        var spec = CloudSpec()
        let start = handOver(radius: 7, height: 7, excess: 3)
        let standard = try #require(CloudResult(spec: spec, handOver: start).stabilised)
        spec.sounding = CloudSounding(levels: levels)
        try spec.validate()
        let measured = try #require(CloudResult(spec: spec, handOver: start).stabilised)
        #expect(
            abs(measured.height / standard.height - 1) < 0.005,
            "\(measured.height) against \(standard.height)")
        #expect(abs(measured.time / standard.time - 1) < 0.01)
    }

    @Test("Over Las Vegas the afternoon's deep mixed layer lifts the cloud higher than the dawn's air")
    func dawnAndAfternoon() throws {
        var spec = CloudSpec()
        spec.duration = 1800
        let start = handOver(radius: 7, height: 7, excess: 3)
        spec.sounding = try sounding("las-vegas-2024-06-15-12z.csv")
        let dawn = try #require(CloudResult(spec: spec, handOver: start).stabilised)
        spec.sounding = try sounding("las-vegas-2024-06-16-00z.csv")
        let afternoon = try #require(CloudResult(spec: spec, handOver: start).stabilised)
        #expect(afternoon.height > dawn.height, "\(afternoon.height) against \(dawn.height)")
        // Carried by the wind, mostly from the south-west, towards the north-east.
        #expect(dawn.position.x > 0 && dawn.position.y > 0)
    }

    @Test("A sounding is refused without its columns, with wind or humidity of its own, or out of order")
    func refusals() throws {
        #expect(throws: CocoaError.self) {
            try CloudSounding(wyomingCSV: "pressure_hPa,temperature_C\n1000,15\n900,10\n")
        }
        var spec = CloudSpec()
        spec.sounding = try sounding("las-vegas-2024-06-16-00z.csv")
        try spec.validate()
        let data = try JSONEncoder().encode(spec)
        #expect(try JSONDecoder().decode(CloudSpec.self, from: data) == spec)
        spec.windSpeed = 3
        #expect(throws: CocoaError.self) { try spec.validate() }
        spec.windSpeed = 0
        spec.sounding?.levels.swapAt(3, 4)
        #expect(throws: CocoaError.self) { try spec.validate() }
        let turbulent = try JSONDecoder().decode(
            CloudSpec.self, from: Data(#"{"frictionVelocity": 0.4, "boundaryLayerHeight": 800}"#.utf8))
        try turbulent.validate()
        #expect(turbulent.turbulence.frictionVelocity == 0.4 && turbulent.turbulence.height == 800)
        let wild = try JSONDecoder().decode(CloudSpec.self, from: Data(#"{"convectiveVelocity": -1}"#.utf8))
        #expect(throws: CocoaError.self) { try wild.validate() }
    }
}
