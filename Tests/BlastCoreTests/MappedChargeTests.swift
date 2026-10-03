import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

/// The blast's first moments solved in one dimension and mapped onto the grid.
@Suite("Mapped charge")
struct MappedChargeTests {
    @Test("The one-dimensional blast keeps its energy and spreads as Sedov and Taylor say")
    func sphericalBlast() {
        // The energy of 10 kg of TNT with almost no mass, so that it is a point blast.
        let energy = 10 * Double(Charge.energyPerKilogram)
        var blast = SphericalBlast(
            mass: 0.001, energy: energy, radius: 0.05, extent: 2, cells: 500, gamma: 1.4,
            ambientDensity: 1.225, ambientPressure: 101_325)
        func total(_ b: SphericalBlast) -> Double {
            (0..<b.density.count).reduce(0) { sum, i in
                let inner = Double(i) * b.cellSize
                let outer = inner + b.cellSize
                return sum + (b.energy[i] - 101_325 / 0.4) * 4 / 3 * Double.pi
                    * (outer * outer * outer - inner * inner * inner)
            }
        }
        let start = total(blast)
        blast.run(toShockRadius: 1.2)
        #expect(abs(total(blast) - start) / start < 0.01, "energy \(total(blast)) J against \(start) J")
        // A strong point blast: R = 1.033 (E t^2 / rho)^(1/5) for gamma = 1.4. At 1.2 m the shock
        // is still strong (some 20 atmospheres). (A real charge's mass slows it at first.)
        let sedov = 1.033 * pow(energy * blast.time * blast.time / 1.225, 0.2)
        #expect(abs(sedov - 1.2) / 1.2 < 0.08, "Sedov-Taylor radius \(sedov) m at \(blast.time) s")
    }

    @Test("Mapped onto the grid, the charge brings its energy, and gauges it passed keep their record")
    func mappedOntoGrid() throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
        var scenario = ScenarioPreset.openGround.scenario
        scenario.gauges = [Gauge("Near", at: SIMD3(34, 32, 0.25)), Gauge("Far", at: SIMD3(52, 32, 0.25))]
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.5)
        let balloon = solver.totals()
        solver.configuration.mappedCharge = true
        try solver.load(scenario)
        let mapped = solver.totals()
        // The same energy as the balloon it replaces, which holds exactly the charge's.
        let charge = Double(scenario.charge.energy)
        #expect(
            abs(mapped.energy - balloon.energy) < 0.03 * charge,
            "\(mapped.energy) J against \(balloon.energy) J")
        #expect(solver.time > 0)
        // The near gauge, 2 m out, lies inside the mapped region: its history starts at the
        // blast's arrival, from the one-dimensional solution.
        let near = try #require(solver.gaugeHistories.first)
        #expect(!near.isEmpty && (near.map(\.pressure).max() ?? 0) > 1e6)
        #expect(solver.peakOverpressure(68, 64, 0) > 1e6)
    }
}
