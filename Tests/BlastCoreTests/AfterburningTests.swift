import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

/// Burning of the detonation products in the air around them.
@Suite("Afterburning")
struct AfterburningTests {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    /// A charge in the middle of a closed cubic room `side` metres across.
    private func room(side: Float, charge: Float, afterburning: Bool) throws -> BlastSolver {
        var scenario = Scenario(
            name: "Room", domainSize: SIMD3(repeating: side), boxes: [],
            charge: Charge(mass: charge, position: SIMD3(repeating: side / 2)))
        scenario.reflectiveFaces = .all
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.25)
        solver.configuration.afterburning = afterburning
        try solver.load(scenario)
        return solver
    }

    @Test("Products burn in TNT's proportion of oxygen, releasing the afterburn energy, and conserve mass")
    func burningIsConservative() throws {
        let solver = try room(side: 4, charge: 8, afterburning: true)
        let start = solver.totals()
        let before = solver.speciesTotals()
        #expect(abs(before.fuel - 8) < 1e-3)
        solver.advance(until: 0.05)
        let after = solver.speciesTotals()
        let end = solver.totals()
        let burnt = before.fuel - after.fuel
        #expect(burnt > 1, "only \(burnt) kg burnt")
        let oxygen = before.oxygen - after.oxygen
        #expect(
            abs(oxygen / burnt - Double(BlastSolver.oxygenPerFuel)) < 0.01 * Double(BlastSolver.oxygenPerFuel)
        )
        let released = Double(solver.configuration.afterburnEnergy) * burnt
        #expect(
            abs((end.energy - start.energy) - released) < 0.01 * released, "\(end.energy - start.energy) J")
        #expect(abs(end.mass - start.mass) < 1e-4 * start.mass)
    }

    @Test("A heavy charge in a small room burns only as much as the room's oxygen allows")
    func oxygenLimitsBurning() throws {
        let solver = try room(side: 3, charge: 60, afterburning: true)
        let oxygen = solver.speciesTotals().oxygen
        solver.advance(until: 0.1)
        let after = solver.speciesTotals()
        let burnt = 60 - after.fuel
        #expect(burnt <= oxygen / Double(BlastSolver.oxygenPerFuel) * 1.001)
        #expect(after.oxygen < 0.2 * oxygen, "oxygen left \(after.oxygen) of \(oxygen) kg")
    }

    @Test("Burnt out in a closed vessel, the gas pressure is within 15% of Cooper's worked example")
    func cooperClosedVessel() throws {
        // Cooper, Explosives Engineering, pp. 153-158: 2 kg of TNT burnt completely in 14.1 m³ of
        // air leaves 7.35 atm of overpressure. The same charge per volume, 0.1415 kg/m³, here.
        let side: Float = 2.5
        let mass = 0.1415 * side * side * side
        var scenario = Scenario(
            name: "Vessel", domainSize: SIMD3(repeating: side), boxes: [],
            charge: Charge(mass: mass, position: SIMD3(repeating: side / 2)))
        scenario.reflectiveFaces = .all
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.25)
        solver.configuration.afterburning = true
        solver.configuration.airModel = .thermallyPerfect
        try solver.load(scenario)
        solver.advance(until: 0.3)
        #expect(
            solver.speciesTotals().fuel < 0.02 * Double(mass), "unburnt \(solver.speciesTotals().fuel) kg")
        // The mean pressure of the gas, from its mean density and internal energy (what is still
        // moving is negligible by now).
        let volume = Double(side * side * side)
        let totals = solver.totals()
        let pressure = solver.configuration.airModel.pressure(
            density: Float(totals.mass / volume), internalEnergy: Float(totals.energy / volume),
            gamma: solver.configuration.gamma)
        let overpressure = Double(pressure - scenario.atmosphere.pressure)
        let cooper = 7.35 * 101_325.0
        #expect(abs(overpressure / cooper - 1) < 0.15, "\(overpressure / 1e6) MPa against Cooper's 0.745")
    }

    @Test("Without afterburning nothing burns and no fuel is tracked")
    func offMeansOff() throws {
        let solver = try room(side: 4, charge: 8, afterburning: false)
        let start = solver.totals()
        solver.advance(until: 0.02)
        #expect(solver.speciesTotals().fuel == 0)
        #expect(abs(solver.totals().energy - start.energy) < 1e-4 * start.energy)
    }

    @Test("Afterburning gives the same answer with still air skipped")
    func stillAirSkippedWhileBurning() throws {
        var results: [[CellState]] = []
        for skip in [true, false] {
            let scenario = ScenarioPreset.streetCanyon.scenario
            let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 1)
            solver.configuration.afterburning = true
            solver.configuration.skipStillAir = skip
            try solver.load(scenario)
            solver.advance(until: 0.05)
            results.append(solver.withState { Array($0) })
        }
        #expect(results[0] == results[1])
    }
}
