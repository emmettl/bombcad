import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

/// Thermally perfect air: N2 and O2 storing energy in vibration once hot.
@Suite("Air model")
struct AirModelTests {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

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

    @Test("A shock tube in units where the gas is cold gives the ideal gas's answer")
    func coldShockTubeMatchesIdealGas() throws {
        var results: [[Float]] = []
        for model in AirModel.allCases {
            var configuration = SolverConfiguration()
            configuration.reflectiveFaces = []
            configuration.airModel = model
            configuration.ambientPressure = 1
            let grid = Grid(nx: 200, ny: 1, nz: 1, cellSize: 1.0 / 200)
            let solver = try BlastSolver(device: device, grid: grid, configuration: configuration)
            solver.fill { i, _, _ in
                i < 100 ? Primitive(density: 1, pressure: 1) : Primitive(density: 0.125, pressure: 0.1)
            }
            solver.advance(until: 0.2)
            results.append((0..<200).map { solver.primitive($0, 0, 0).density })
        }
        for other in results.dropFirst() {
            let worst = zip(results[0], other).map { abs($0 - $1) }.max() ?? 1
            #expect(worst < 1e-4, "largest density difference \(worst)")
        }
    }

    @Test("Hot air is skipped where still without changing the answer")
    func stillAirWithHotAir() throws {
        var results: [[CellState]] = []
        for skip in [true, false] {
            let scenario = ScenarioPreset.streetCanyon.scenario
            let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 1)
            solver.configuration.airModel = .thermallyPerfect
            solver.configuration.afterburning = true
            solver.configuration.skipStillAir = skip
            try solver.load(scenario)
            solver.advance(until: 0.05)
            results.append(solver.withState { Array($0) })
        }
        #expect(results[0] == results[1])
    }

    @Test(
        "With afterburning, a charge in a closed room gives the design manual's gas pressure",
        arguments: [0.25, 1.0])
    func closedRoomPressure(chargePerVolume: Float) throws {
        let side: Float = 6
        var scenario = Scenario(
            name: "Room", domainSize: SIMD3(repeating: side), boxes: [],
            charge: Charge(mass: chargePerVolume * side * side * side, position: SIMD3(repeating: side / 2)))
        scenario.reflectiveFaces = .all
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.25)
        solver.configuration.airModel = .thermallyPerfect
        solver.configuration.afterburning = true
        try solver.load(scenario)
        solver.advance(until: 0.08)
        let volume = Double(side * side * side)
        let totals = solver.totals()
        let pressure =
            Double(
                AirModel.thermallyPerfect.pressure(
                    density: Float(totals.mass / volume), internalEnergy: Float(totals.energy / volume),
                    gamma: 1.4))
            - Double(scenario.atmosphere.pressure)
        let reference = try #require(UFC340.peakGasPressure(chargePerVolume: Double(chargePerVolume)))
        #expect(abs(pressure / reference - 1) < 0.15, "\(pressure) Pa against \(reference) Pa")
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

    @Test("A sealed box of hot dissociated air stays still, and the GPU reads back its pressure")
    func dissociatingAirAtRest() throws {
        let scenario = Scenario(
            name: "Box", domainSize: SIMD3(repeating: 2), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(repeating: 1)),
            gauges: [Gauge("Middle", at: SIMD3(repeating: 1))])
        var configuration = SolverConfiguration()
        configuration.airModel = .dissociating
        configuration.reflectiveFaces = .all
        let solver = try BlastSolver(
            device: device, scenario: scenario, cellSize: 0.25, configuration: configuration)
        // 5000 K at 2 kg/m3: about a third of the O2 split, as in a young fireball.
        let density: Float = 2
        let temperature: Float = 5000
        let pressure =
            density * Float(AirModel.dissociating(density: density, temperature: temperature).gasConstant)
            * temperature
        solver.fill(uniform: Primitive(density: density, pressure: pressure))
        solver.advance(steps: 20)
        let read = solver.gaugeHistories.first?.last?.pressure ?? 0
        #expect(abs(read - pressure) < 1e-3 * pressure, "\(read) Pa against \(pressure) Pa")
        let state = solver.primitive(4, 4, 4)
        #expect(simd_length(state.velocity) < 1e-3)
    }
}
