import Foundation
import Metal
import Testing

@testable import BlastCore
@testable import BlastModel

/// Structures' outlines as cut cells (`SolverConfiguration.structureCutCells`).
@Suite("Structures' outlines as cut cells", .gpuThreads)
struct StructureCutCellsTests {
    let device = MTLCreateSystemDefaultDevice()!

    /// A wall 1 m high and wide, its face at `face`, `thickness` thick, 3 m from 1 kg on the ground in
    /// a room of 10 x 6 x 4 m on 0.25 m cells, of elements 0.025 m across (its faces lie on their
    /// lattice, as every structure's do).
    private func wall(face: Float, thickness: Float, cut: Bool, closed: Bool = false) throws -> BlastSolver {
        var model = StructureModel(
            solids: [Box(min: SIMD3(face, 2.5, 0), max: SIMD3(face + thickness, 3.5, 1))],
            material: .elastic(density: 2400, youngsModulus: 30e9, poissonRatio: 0.2), elementSize: 0.025)
        model.elementKind = .solid
        var scenario = Scenario(
            name: "Wall", domainSize: SIMD3(10, 6, 4), boxes: [],
            charge: Charge(mass: 1, position: SIMD3(2, 3, 0)),
            structure: model)
        if closed { scenario.reflectiveFaces = .all }
        var configuration = SolverConfiguration()
        configuration.settlesStructures = false
        configuration.structureCutCells = cut
        return try BlastSolver(
            device: device, scenario: scenario, cellSize: 0.25, configuration: configuration)
    }

    @Test(
        "A wall whose faces lie on the cells' faces has no cut cells, and the air steps exactly as without them"
    )
    func onLatticeIdentical() throws {
        func run(_ cut: Bool) throws -> [UInt32] {
            let solver = try wall(face: 5, thickness: 0.5, cut: cut)
            #expect(solver.structureCut == nil)
            #expect(solver.advance(steps: 60).isStable)
            var values: [Float] = solver.withState { cells in
                cells.flatMap { [$0.density, $0.momentumX, $0.momentumY, $0.momentumZ, $0.energy] }
            }
            values.append(Float(solver.time))
            values.append(solver.bodySummary()?.maxDisplacement ?? 0)
            return values.map(\.bitPattern)
        }
        #expect(try run(false) == run(true))
    }

    @Test("A wall off the lattice is cut where its faces fall, and a closed room's gas is conserved")
    func offLatticeConserved() throws {
        let solver = try wall(face: 5.075, thickness: 0.3, cut: true, closed: true)
        let geometry = try #require(solver.structureCut?.geometry)
        // The face cuts the cells from x = 5 at 0.3 of their width, the back those from 5.25 at 0.5.
        let grid = solver.grid
        let front = geometry.index[grid.index(20, 12, 2)]
        let back = geometry.index[grid.index(21, 12, 2)]
        #expect(front >= 0 && abs(geometry.records[Int(front)].x - 0.3) < 0.02)
        #expect(back >= 0 && abs(geometry.records[Int(back)].x - 0.5) < 0.02)
        // Every record under half air passes the rest of its difference on.
        for (record, target) in zip(geometry.records, geometry.targets) where record.x < 0.5 {
            #expect(target >= 0)
        }
        let before = solver.totals()
        #expect(solver.advance(steps: 150).isStable)
        let after = solver.totals()
        #expect(abs(after.mass - before.mass) / before.mass < 1e-5, "mass \(before.mass) -> \(after.mass)")
        // The wall takes a little of the energy as work.
        #expect(
            abs(after.energy - before.energy) / before.energy < 1e-4,
            "energy \(before.energy) -> \(after.energy)")
    }

    @Test(
        "Beside cut ground and a rigid block, no structure cut cell gives to either, and the gas is conserved"
    )
    func besideTerrainAndBlock() throws {
        // Ground at 0.37 m cuts the cells from 0.25 to 0.5 m; the wall stands in it, its face 0.3 of
        // a cell off the lattice, and a block stands 5 cm behind it.
        var model = StructureModel(
            solids: [Box(min: SIMD3(5.075, 2.5, 0), max: SIMD3(5.375, 3.5, 1))],
            material: .elastic(density: 2400, youngsModulus: 30e9, poissonRatio: 0.2), elementSize: 0.025)
        model.elementKind = .solid
        var scenario = Scenario(
            name: "Wall on cut ground", domainSize: SIMD3(10, 6, 4),
            boxes: [Box(min: SIMD3(5.425, 2.25, 0), max: SIMD3(6.4, 3.75, 1.2))],
            charge: Charge(mass: 1, position: SIMD3(2, 3, 0.5)), structure: model)
        scenario.reflectiveFaces = .all
        scenario.terrain = Terrain.sampled(domain: scenario.domainSize, spacing: 0.25, source: "cut ground") {
            _ in
            0.37
        }
        var configuration = SolverConfiguration()
        configuration.settlesStructures = false
        configuration.terrainCutCells = true
        configuration.structureCutCells = true
        let solver = try BlastSolver(
            device: device, scenario: scenario, cellSize: 0.25, configuration: configuration)
        let geometry = try #require(solver.structureCut?.geometry)
        let terrain = try #require(solver.terrainCut?.geometry)
        let grid = solver.grid
        func terrainCut(_ index: Int) -> Bool {
            terrain.alpha(index % grid.nx, (index / grid.nx) % grid.ny, index / (grid.nx * grid.ny)) < 1
        }
        func solid(_ index: Int) -> Bool {
            solver.isSolid(index % grid.nx, (index / grid.nx) % grid.ny, index / (grid.nx * grid.ny))
        }
        #expect(!geometry.cells.isEmpty)
        for cell in geometry.cells { #expect(!terrainCut(Int(cell))) }
        for target in geometry.targets where target >= 0 {
            #expect(!terrainCut(Int(target)) && !solid(Int(target)), "receiver \(target)")
        }
        let before = solver.totals()
        #expect(solver.advance(steps: 150).isStable)
        let after = solver.totals()
        #expect(abs(after.mass - before.mass) / before.mass < 1e-5, "mass \(before.mass) -> \(after.mass)")
    }
}
