import Foundation
import Testing
import simd

@testable import BlastModel

/// Thermally perfect air: N2 and O2 storing energy in vibration once hot.
@Suite("Air model")
struct AirModelTests {
    @Test("Energy and pressure convert both ways, and air at room temperature has gamma 1.4")
    func equationOfState() {
        let air = AirModel.thermallyPerfect
        for temperature: Float in [250, 300, 1000, 2000, 3000, 6000] {
            let density: Float = 1.2
            let pressure = density * AirModel.gasConstant * temperature
            let energy = air.internalEnergy(density: density, pressure: pressure, gamma: 1.4)
            let back = air.pressure(density: density, internalEnergy: energy, gamma: 1.4)
            #expect(abs(back - pressure) < 1e-4 * pressure, "\(temperature) K: \(back) against \(pressure)")
            // The ratio 1 + p / (rho e) is 1.4 cold and falls as vibration wakes (the ratio of
            // specific heats itself falls further, to about 1.29 at 3000 K).
            let effective = 1 + pressure / energy
            if temperature <= 300 { #expect(abs(effective - 1.4) < 1e-3) }
            if temperature == 3000 { #expect(effective > 1.31 && effective < 1.34, "\(effective)") }
        }
    }

    @Test("The GPU's first guess at the temperature is within 10^-4, and one Newton step within 10^-6")
    func temperatureGuess() throws {
        // The shader's own coefficients, read from Solver.metal.
        let shader = try String(
            contentsOf: URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appending(path: "Sources/BlastCore/Shaders/Solver.metal"),
            encoding: .utf8)
        func coefficients(_ name: String) throws -> [Double] {
            let line = try #require(
                shader.split(separator: "\n").first { $0.contains("float \(name) = 1.0f + z * (") })
            return line.split(whereSeparator: { " ()*+;".contains($0) }).compactMap {
                $0.hasSuffix("f") ? Double($0.dropLast()) : nil
            }.filter { $0 != 1 }
        }
        let p = try coefficients("p")
        let q = try coefficients("q")
        #expect(p.count == 4 && q.count == 4)
        let r = Double(AirModel.gasConstant)
        func vibration(_ t: Double) -> (energy: Double, heat: Double) {
            var energy = 0.0
            var heat = 0.0
            for (theta, share) in [(3390.0, 0.79), (2270.0, 0.21)] {
                let x = min(theta / max(t, 1), 80)
                let below = 1 / (exp(x) - 1)
                energy += r * share * theta * below
                heat += r * share * x * x * exp(x) * below * below
            }
            return (energy, heat)
        }
        var temperature = 1.0
        while temperature < 60_000 {
            let e = 2.5 * r * temperature + vibration(temperature).energy
            let y = e / (2.5 * r)
            let z = y / 3000
            let guess =
                y * (1 + z * (p[0] + z * (p[1] + z * (p[2] + z * p[3]))))
                / (1 + z * (q[0] + z * (q[1] + z * (q[2] + z * q[3]))))
            #expect(abs(guess / temperature - 1) < 1e-4, "\(temperature) K: guess \(guess)")
            let v = vibration(guess)
            let step = guess - (2.5 * r * guess + v.energy - e) / (2.5 * r + v.heat)
            #expect(abs(step / temperature - 1) < 1e-6, "\(temperature) K: after a step \(step)")
            // The ratio of specific heats from the heat capacity at the guess.
            let gamma = 1 + r / (2.5 * r + v.heat)
            let exact = 1 + r / (2.5 * r + vibration(temperature).heat)
            #expect(abs(gamma / exact - 1) < 3e-6, "\(temperature) K: gamma \(gamma) against \(exact)")
            temperature *= 1.01
        }
    }

    @Test(
        "Dissociating air: energy and pressure convert both ways, and it is thermally perfect air when cool")
    func dissociatingEquationOfState() {
        let air = AirModel.dissociating
        for density: Float in [0.1, 1.2, 10] {
            for temperature: Float in [300, 1500, 3000, 4500, 6000, 8000] {
                let pressure =
                    density
                    * Float(AirModel.dissociating(density: density, temperature: temperature).gasConstant)
                    * temperature
                let energy = air.internalEnergy(density: density, pressure: pressure, gamma: 1.4)
                let back = air.pressure(density: density, internalEnergy: energy, gamma: 1.4)
                #expect(
                    abs(back - pressure) < 1e-4 * pressure,
                    "\(density) kg/m3, \(temperature) K: \(back) against \(pressure)")
                #expect(
                    abs(air.temperature(density: density, pressure: pressure) - temperature) < 1e-3
                        * temperature)
                // Up to 1500 K nothing dissociates, and it stores what thermally perfect air does
                // (within the difference in their gas constants' rounding).
                if temperature <= 1500 {
                    let perfect = AirModel.thermallyPerfect.internalEnergy(
                        density: density, pressure: pressure, gamma: 1.4)
                    #expect(
                        abs(energy - perfect) < 3e-3 * perfect,
                        "\(temperature) K: \(energy) against \(perfect)")
                }
            }
        }
    }

    @Test("At atmospheric pressure O2 dissociates between 2500 and 5000 K, N2 well above 4000 K")
    func dissociationRange() {
        func fractions(_ temperature: Float) -> [Float] {
            // Air at 1 atm: the density that gives 101,325 Pa at this temperature.
            var density: Float = 101_325 / (287 * temperature)
            for _ in 0..<20 {
                let r = Float(AirModel.dissociating(density: density, temperature: temperature).gasConstant)
                density = 101_325 / (r * temperature)
            }
            return AirModel.dissociatedFractions(density: density, temperature: temperature)
        }
        #expect(fractions(2500)[1] < 0.05, "O2 at 2500 K: \(fractions(2500)[1])")
        #expect(fractions(5000)[1] > 0.9, "O2 at 5000 K: \(fractions(5000)[1])")
        #expect(fractions(4000)[0] < 0.05, "N2 at 4000 K: \(fractions(4000)[0])")
        #expect(fractions(9000)[0] > 0.5, "N2 at 9000 K: \(fractions(9000)[0])")
    }
}
