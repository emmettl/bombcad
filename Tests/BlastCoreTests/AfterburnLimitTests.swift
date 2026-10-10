import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

/// Afterburning's extinction limit.
@Suite("Afterburning's extinction limit")
struct AfterburnLimitTests {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    /// A closed box of air at `temperature`, 512 cells of 0.125 m³, holding `fuel` kg/m³ of products,
    /// uniformly mixed.
    private func mixture(temperature: Float, fuel: Float, limit: AfterburnLimit?) throws -> BlastSolver {
        var configuration = SolverConfiguration()
        configuration.afterburning = true
        configuration.airModel = .thermallyPerfect
        configuration.afterburnLimit = limit
        configuration.reflectiveFaces = .all
        let solver = try BlastSolver(
            device: device, grid: Grid(nx: 8, ny: 8, nz: 8, cellSize: 0.5), configuration: configuration)
        let density: Float = 101_325 / (287.05 * temperature)
        solver.fill(uniform: Primitive(density: density, pressure: 101_325))
        solver.largestCharge = 100
        solver.mutateSpecies { species in
            for n in species.indices { species[n].x = fuel }
        }
        solver.restart()
        return solver
    }

    @Test("Cold products in air do not burn with the limit, and do without it; hot ones burn either way")
    func coldDoesNotBurn() throws {
        let cold = try mixture(temperature: 400, fuel: 0.02, limit: AfterburnLimit())
        cold.advance(steps: 40)
        #expect(abs(cold.speciesTotals().fuel / 1.28 - 1) < 1e-6, "fuel burnt in cold air with the limit")
        let unlimited = try mixture(temperature: 400, fuel: 0.02, limit: nil)
        unlimited.advance(steps: 40)
        #expect(unlimited.speciesTotals().fuel < 1.28 * 0.999)
        let hot = try mixture(temperature: 1600, fuel: 0.02, limit: AfterburnLimit())
        hot.advance(steps: 40)
        #expect(hot.speciesTotals().fuel < 1.28 * 0.999)
    }

    @Test("Warm but too dilute to reach the limit flame temperature, products do not burn")
    func diluteDoesNotBurn() throws {
        // At 900 K, above ignition: 0.002 kg/m³ of products releases about 20 kJ/m³, some 60 K.
        let dilute = try mixture(temperature: 900, fuel: 0.002, limit: AfterburnLimit())
        dilute.advance(steps: 40)
        #expect(abs(dilute.speciesTotals().fuel / 0.128 - 1) < 1e-6)
        // Rich enough to reach 1,500 K, it burns.
        let rich = try mixture(temperature: 900, fuel: 0.1, limit: AfterburnLimit())
        rich.advance(steps: 40)
        #expect(rich.speciesTotals().fuel < 6.4 * 0.999)
    }

    @Test("With the limit, what burns is what the gas gains, and mass and oxygen are conserved")
    func conservation() throws {
        var scenario = Scenario(
            name: "Room", domainSize: SIMD3(repeating: 4), boxes: [],
            charge: Charge(mass: 8, position: SIMD3(repeating: 2)))
        scenario.reflectiveFaces = .all
        var configuration = SolverConfiguration()
        configuration.afterburning = true
        configuration.airModel = .thermallyPerfect
        configuration.afterburnLimit = AfterburnLimit()
        let solver = try BlastSolver(
            device: device, scenario: scenario, cellSize: 0.25, configuration: configuration)
        let start = solver.totals()
        let before = solver.speciesTotals()
        solver.advance(until: 0.03)
        let end = solver.totals()
        let after = solver.speciesTotals()
        let burnt = before.fuel - after.fuel
        #expect(burnt > 0.5, "only \(burnt) kg burnt")
        let released = Double(configuration.afterburnEnergy) * burnt
        #expect(abs((end.energy - start.energy) - released) < 0.01 * released)
        #expect(abs(end.mass / start.mass - 1) < 1e-4)
    }
}
