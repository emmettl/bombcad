import Foundation
import Metal
import Testing
import simd

@testable import BlastCore
@testable import BlastModel

/// Mixing-limited afterburning (`MixedAfterburning`, emmettl/bombcad-work#22 stage 2).
@Suite("Mixing-limited afterburning", .gpuThreads)
struct MixedAfterburningTests {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    /// A closed box of still air at 1,600 K, 512 cells of 0.125 m³, holding 0.02 kg/m³ of products,
    /// uniformly mixed, with sub-grid mixing.
    private func stillMixture(_ burning: MixedAfterburning?) throws -> BlastSolver {
        var configuration = SolverConfiguration()
        configuration.afterburning = true
        configuration.airModel = .thermallyPerfect
        configuration.mixing = SubgridMixing()
        configuration.afterburnMixing = burning
        configuration.reflectiveFaces = .all
        let solver = try BlastSolver(
            device: device, grid: Grid(nx: 8, ny: 8, nz: 8, cellSize: 0.5), configuration: configuration)
        solver.fill(uniform: Primitive(density: 101_325 / (287.05 * 1600), pressure: 101_325))
        solver.largestCharge = 100
        solver.mutateSpecies { species in
            for n in species.indices { species[n].x = 0.02 }
        }
        solver.restart()
        return solver
    }

    @Test("Hot products in still air, with no turbulence to mix them, do not burn with the limit")
    func stillDoesNotBurn() throws {
        let limited = try stillMixture(MixedAfterburning())
        limited.advance(steps: 40)
        #expect(abs(limited.speciesTotals().fuel / 1.28 - 1) < 1e-6, "fuel burnt in still air with the limit")
        let fitted = try stillMixture(nil)
        fitted.advance(steps: 40)
        #expect(fitted.speciesTotals().fuel < 1.28 * 0.999)
    }

    @Test("A charge's products burn where it stirs the air; what burns is what the gas gains")
    func stirredBurnsAndConserves() throws {
        var scenario = Scenario(
            name: "Room", domainSize: SIMD3(repeating: 4), boxes: [],
            charge: Charge(mass: 8, position: SIMD3(repeating: 2)))
        scenario.reflectiveFaces = .all
        var configuration = SolverConfiguration()
        configuration.afterburning = true
        configuration.airModel = .thermallyPerfect
        configuration.afterburnMixing = MixedAfterburning(coefficient: 10)
        let solver = try BlastSolver(
            device: device, scenario: scenario, cellSize: 0.25, configuration: configuration)
        // Loading the scene turned the sub-grid mixing on.
        #expect(solver.configuration.mixing != nil)
        let start = solver.totals()
        let before = solver.speciesTotals()
        solver.advance(until: 0.03)
        let end = solver.totals()
        let after = solver.speciesTotals()
        let burnt = before.fuel - after.fuel
        #expect(burnt > 0.1, "only \(burnt) kg burnt")
        let released = Double(configuration.afterburnEnergy) * burnt
        #expect(abs((end.energy - start.energy) - released) < 0.01 * released)
        #expect(abs(end.mass / start.mass - 1) < 1e-4)
    }
}
