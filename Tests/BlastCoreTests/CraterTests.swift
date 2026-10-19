import Foundation
import Metal
import Testing
import simd

@testable import BlastCore
@testable import BlastModel

@Suite("Craters and ground that takes energy")
struct CraterTests {
    @Test(
        "On soft ground the air's charge holds 0.9 of the energy; rigid ground, the same to the bit",
        .gpuThreads)
    func air() throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
        let scenario = Scenario(
            name: "Open", domainSize: SIMD3(8, 8, 4), boxes: [],
            charge: Charge(mass: 0.5, position: SIMD3(4, 4, 0)))
        func loaded(_ ground: GroundType?) throws -> BlastSolver {
            let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.25)
            solver.configuration.ground = ground
            try solver.load(scenario)
            return solver
        }
        let rigid = try loaded(nil)
        let ambient = try loaded(nil)
        ambient.mutateState { cells in
            for n in cells.indices {
                cells[n] = CellState(Primitive(density: 1.225, pressure: 101_325), gamma: 1.4)
            }
        }
        let still = ambient.totals().energy
        let soil = try loaded(.alluvium)
        let ratio = (soil.totals().energy - still) / (rigid.totals().energy - still)
        #expect(abs(ratio - 0.9) < 0.01, "ratio \(ratio)")
        let explicitRigid = try loaded(.rigid)
        let same = explicitRigid.withState { a in rigid.withState { b in a.elementsEqual(b) { $0 == $1 } } }
        #expect(same)
    }
}
