import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

/// Paths through the refined levels that the other refinement suites do not reach: a charge
/// mapped from one dimension onto refined air, a pool of patches used up with no room to grow,
/// the margin kept around the shock, the second level's own threshold, refinement held about a
/// structure in two levels, and the levels' own steps turned down over the terrain's cut cells.
@Suite("Refinement paths not otherwise reached", .gpuThreads)
struct RefinementGapTests {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    private func refined(levels: Int = 1, threshold: Float = 0.05) -> SolverConfiguration {
        var configuration = SolverConfiguration()
        configuration.refinement = 2
        configuration.refinementLevels = levels
        configuration.refinementThreshold = threshold
        configuration.refinementMemory = 256 << 20
        return configuration
    }

    /// The closed room with a block in it that `RefinementTests` and `RefinementLevelsTests` use.
    private func closedBox(_ configuration: SolverConfiguration) throws -> BlastSolver {
        var scenario = Scenario(
            name: "Closed box", domainSize: SIMD3(24, 20, 16),
            boxes: [Box(x: 13...18, y: 6...14, height: 9)],
            charge: Charge(mass: 5, position: SIMD3(8, 10, 1)))
        scenario.reflectiveFaces = .all
        return try BlastSolver(
            device: device, scenario: scenario, cellSize: 0.5, configuration: configuration)
    }

    /// Every coarse cell's impulse, Pa s.
    private func impulses(_ solver: BlastSolver) -> [Float] {
        let grid = solver.grid
        var values = [Float](repeating: 0, count: grid.cellCount)
        for k in 0..<grid.nz {
            for j in 0..<grid.ny {
                for i in 0..<grid.nx { values[grid.index(i, j, k)] = solver.impulse(i, j, k) }
            }
        }
        return values
    }

    /// A charge mapped from its one-dimensional solution is laid down before `restart()` places
    /// the patches around its shock, but its impulse field is written after (`recordMapped`), so
    /// each patch already placed must take its coarse cells' impulse again
    /// (`AirRefinement.reseedImpulseBase`). If it did not, the first restriction would rebuild
    /// those cells' impulse from nothing and the impulse the one-dimensional solution recorded
    /// inside the mapped radius would be lost under every patch. Impulse only accumulates, so no
    /// cell's may fall from one step to the next. Every other refined test starts from the
    /// balloon, so none reaches this path.
    @Test(
        "A charge mapped onto refined air keeps the impulse its solution recorded under the patches",
        arguments: [1, 2])
    func mappedStartKeepsImpulse(levels: Int) throws {
        // 10 kg on the ground in a 24 x 24 x 8 m open field: mapped to 0.8 of the 8 m to the top,
        // 6.4 m, well past three cells of 0.5 m.
        let scenario = Scenario(
            name: "Mapped", domainSize: SIMD3(24, 24, 8), boxes: [],
            charge: Charge(mass: 10, position: SIMD3(12, 12, 0)))
        var configuration = refined(levels: levels)
        configuration.mappedCharge = true
        let solver = try BlastSolver(
            device: device, scenario: scenario, cellSize: 0.5, configuration: configuration)
        try #require(solver.time > 0, "the charge was not mapped")
        let level = try #require(solver.refinement)
        let grid = solver.grid
        let before = impulses(solver)
        // Some cell the patches placed at the restart refine holds the mapped impulse.
        var covered = 0
        for k in 0..<grid.nz {
            for j in 0..<grid.ny {
                for i in 0..<grid.nx where before[grid.index(i, j, k)] > 0 && !solver.isSolid(i, j, k) {
                    if level.holdsAny(from: SIMD3(i, j, k), through: SIMD3(i, j, k)) { covered += 1 }
                }
            }
        }
        try #require(covered > 0, "no patch lies over the mapped impulse")
        let result = solver.advance(steps: 2)
        #expect(result.isStable && result.refinedTiles > 0)
        let after = impulses(solver)
        var fallen = 0
        var worst: Float = 0
        for n in 0..<grid.cellCount where after[n] < before[n] * (1 - 1e-6) {
            fallen += 1
            worst = max(worst, before[n] - after[n])
        }
        #expect(fallen == 0, "\(fallen) cells' impulse fell, by up to \(worst) Pa s")
    }

    /// With the pool fixed at a few dozen patches (`refinementStartMemory` nil, so it starts at
    /// its whole `refinementMemory` and cannot grow), the shock wants more blocks than the pool
    /// holds and the rest stay coarse. `repeatableWhenFull` checks that run repeats; this checks
    /// it still conserves the gas across the edge of a refined region the pool, not the shock,
    /// decides, and that the pools report running out without counting it as having grown too
    /// late.
    @Test(
        "With the pool of patches used up, the rest stays coarse and the gas is still conserved",
        arguments: [1, 2])
    func exhaustedPoolConserves(levels: Int) throws {
        var configuration = refined(levels: levels)
        configuration.refinementMemory = 4 << 20
        configuration.refinementStartMemory = nil
        let solver = try closedBox(configuration)
        let before = solver.totals()
        let result = solver.advance(steps: 100)
        #expect(result.isStable)
        let after = solver.totals()
        let pools = solver.refinementPools
        #expect(pools.count == levels)
        #expect(pools.allSatisfy { $0.held == $0.capacity }, "\(pools)")
        let finest = try #require(pools.last)
        #expect(finest.ranOut && finest.most == finest.capacity, "\(pools)")
        #expect(!solver.refinementPoolGrewLate)
        // Measured on the Studio, 19 October 2026: mass and energy kept to 4e-8 with one level or two.
        #expect(abs(after.mass - before.mass) / before.mass < 1e-6, "mass \(before.mass) -> \(after.mass)")
        #expect(
            abs(after.energy - before.energy) / before.energy < 1e-6,
            "energy \(before.energy) -> \(after.energy)")
    }

    /// The blocks a level refines at the start, as a set of block indices.
    private func refinedBlocks(_ level: AirRefinement) -> Set<Int> {
        let tiles = level.tileDims.x * level.tileDims.y * level.tileDims.z
        let map = (level.patchOfTile.contents() + level.patchOffset * 4).bindMemory(
            to: Int32.self, capacity: tiles)
        return Set((0..<tiles).filter { map[$0] >= 0 })
    }

    /// `refinementMargin` (cells around a sharp jump whose blocks are refined too) is never set
    /// by any other test, so only its default of 1 is run. The coarse state at the start does not
    /// depend on it, so the blocks placed around the charge at the restart grow with the margin,
    /// each set holding the one before; and whatever the margin, the reflux across the refined
    /// region's edge conserves the gas.
    @Test("A wider refinement margin refines a superset of the blocks, and every margin conserves the gas")
    func margin() throws {
        var blocks: [Set<Int>] = []
        for margin in [0, 1, 3] {
            var configuration = refined()
            configuration.refinementMargin = margin
            configuration.refinementStartMemory = nil
            let solver = try closedBox(configuration)
            blocks.append(refinedBlocks(try #require(solver.refinement)))
            if margin != 1 {
                let before = solver.totals()
                let result = solver.advance(steps: 100)
                #expect(result.isStable && result.refinedTiles > 0)
                let after = solver.totals()
                // Measured on the Studio, 19 October 2026: mass and energy kept to 4e-8 at margins 0 and 3.
                #expect(
                    abs(after.mass - before.mass) / before.mass < 1e-6,
                    "margin \(margin): mass \(before.mass) -> \(after.mass)")
                #expect(
                    abs(after.energy - before.energy) / before.energy < 1e-6,
                    "margin \(margin): energy \(before.energy) -> \(after.energy)")
            }
        }
        #expect(!blocks[0].isEmpty)
        #expect(blocks[0].isSubset(of: blocks[1]) && blocks[1].isSubset(of: blocks[2]))
        #expect(blocks[2].count > blocks[0].count, "\(blocks.map(\.count)) blocks")
    }

    /// `refinementFinerThreshold` is set in one test, to the same value as the first level's, so
    /// neither a different value nor its nil fallback is checked. Nil must run exactly as the
    /// first level's threshold given explicitly; a threshold no jump can pass leaves the second
    /// level empty while the first still follows the shock; and a lower one places at least as
    /// many second-level blocks at the start as a higher one (the first level's cells it flags
    /// from are the same).
    @Test("The second level's own threshold: nil is the first's, one never passed leaves it empty")
    func finerThreshold() throws {
        var unset = refined(levels: 2)
        unset.refinementFinerThreshold = nil
        var same = unset
        same.refinementFinerThreshold = unset.refinementThreshold
        let a = try closedBox(unset)
        let b = try closedBox(same)
        a.advance(steps: 40)
        b.advance(steps: 40)
        let alike = a.withState { x in b.withState { y in zip(x, y).allSatisfy { $0 == $1 } } }
        #expect(alike)

        var never = unset
        never.refinementFinerThreshold = 1e30
        let empty = try closedBox(never)
        var first = 0
        var second = 0
        for _ in 0..<4 {
            let result = empty.advance(steps: 20)
            #expect(result.isStable)
            first = max(first, result.refinedTiles)
            second = max(second, result.finerRefinedTiles)
        }
        #expect(first > 0 && second == 0, "\(first) first-level and \(second) second-level blocks")

        func startingBlocks(_ threshold: Float) throws -> Int {
            var configuration = unset
            configuration.refinementFinerThreshold = threshold
            configuration.refinementStartMemory = nil
            return try closedBox(configuration).refinementPatchesInUse[1]
        }
        let low = try startingBlocks(0.01)
        let high = try startingBlocks(0.2)
        #expect(low > 0 && low >= high, "\(low) blocks at 0.01, \(high) at 0.2")
    }

    /// `refinementHoldsStructures` is tested with one level only. With two, the second level's
    /// cells are mapped to the coarse band by its own scale (`FacadeBandParameters.ratio`, the
    /// level's `parentScale`), and are held through `refineFlagFine`, a kernel the one-level test
    /// never runs. The scene is `heldAboutStructure`'s.
    @Test("Refinement held about a structure holds the second level too after the shock has gone")
    func heldAboutStructureInTwoLevels() throws {
        let wall = Box(min: SIMD3(6, 2, 0), max: SIMD3(6.4, 8, 3))
        let scenario = Scenario(
            name: "Wall", domainSize: SIMD3(10, 10, 4), boxes: [],
            charge: Charge(mass: 0.5, position: SIMD3(3, 5, 0.5)),
            structure: StructureModel(solids: [wall], elementSize: 0.2, fixedBase: true))
        func patches(hold: Float?) throws -> (first: Int, second: Int) {
            var configuration = SolverConfiguration()
            configuration.refinement = 2
            configuration.refinementLevels = 2
            configuration.refinementMemory = 64 << 20
            configuration.refinementHoldsStructures = hold
            let solver = try BlastSolver(
                device: device, scenario: scenario, cellSize: 0.5, configuration: configuration)
            var last = (first: 0, second: 0)
            while solver.time < 0.02 {
                let batch = solver.advance(steps: 8, timeLimit: 0.02)
                last = (batch.refinedTiles, batch.finerRefinedTiles)
                if batch.steps == 0 { break }
            }
            return last
        }
        let free = try patches(hold: nil)
        let held = try patches(hold: 100)
        #expect(held.first > free.first, "first level: \(held.first) held, \(free.first) without")
        #expect(held.second > free.second, "second level: \(held.second) held, \(free.second) without")
    }

    /// With the terrain's cut cells the levels may not take their own steps (`ownLevelSteps`
    /// turns them off, as the cut cells' differences are shared out after every substep's final
    /// sweep). Asking for them there must change nothing: every substep taken, and the run the
    /// same to the bit as one that did not ask. The hill is `TerrainCutCellTests`' closed hill.
    @Test("Over the terrain's cut cells a level's own steps are not taken, and the run is unchanged")
    func ownStepsOffOverCutTerrain() throws {
        func run(own: Bool) throws -> (state: [CellState], substeps: Double) {
            var configuration = SolverConfiguration()
            configuration.terrainCutCells = true
            configuration.refinement = 2
            configuration.refinementThreshold = 0.02
            configuration.refinementMemory = 256 << 20
            configuration.refinementOwnSteps = own
            var scenario = Scenario(
                name: "Closed hill", domainSize: SIMD3(16, 8, 8), boxes: [],
                charge: Charge(mass: 2, position: SIMD3(4, 4, 1.5)))
            scenario.reflectiveFaces = .all
            scenario.terrain = .hill(
                domain: scenario.domainSize, spacing: 0.3, centre: SIMD2(10, 4), height: 4, radius: 2.5)
            let solver = try BlastSolver(
                device: device, scenario: scenario, cellSize: 0.25, configuration: configuration)
            try #require(solver.refinement?.cutTerrain == true)
            let result = solver.advance(steps: 30)
            #expect(result.isStable && result.refinedTiles > 0)
            return (solver.withState { Array($0) }, result.firstLevelSubsteps)
        }
        let every = try run(own: false)
        let asked = try run(own: true)
        #expect(asked.substeps == 2)
        let differing = zip(every.state, asked.state).filter { $0 != $1 }.count
        #expect(differing == 0, "\(differing) cells differ")
    }
}
