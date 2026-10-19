import Foundation
import Metal
import Testing
import simd

@testable import BlastCore
@testable import BlastModel

/// Thermally perfect air: N2 and O2 storing energy in vibration once hot.
@Suite("Air model", .gpuThreads)
struct AirModelTests {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
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
