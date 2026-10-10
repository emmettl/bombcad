import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

/// The air refined in two levels, the second refining the first.
@Suite("Refinement in two levels")
struct RefinementLevelsTests {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    private func twoLevels(_ ratio: Int = 2, threshold: Float = 0.05) -> SolverConfiguration {
        var configuration = SolverConfiguration()
        configuration.refinement = ratio
        configuration.refinementLevels = 2
        configuration.refinementThreshold = threshold
        configuration.refinementMemory = 256 << 20
        return configuration
    }

    private func closedBox(_ configuration: SolverConfiguration, offset: Float = 0) throws -> BlastSolver {
        var scenario = Scenario(
            name: "Closed box", domainSize: SIMD3(24, 20, 16),
            boxes: [Box(min: SIMD3(13 + offset, 6, 0), max: SIMD3(18 + offset, 14, 9))],
            charge: Charge(mass: 5, position: SIMD3(8, 10, 1)))
        scenario.reflectiveFaces = .all
        return try BlastSolver(
            device: device, scenario: scenario, cellSize: 0.5, configuration: configuration)
    }

    /// Whether every patch of the second level has the first level's patches over every cell of
    /// the first level within two of it.
    private func nested(_ solver: BlastSolver) throws -> Bool {
        let first = try #require(solver.refinement)
        let second = try #require(solver.finerRefinement)
        let firstTiles = first.tileDims
        let secondTiles = second.tileDims
        let map = first.patchOfTile.contents().bindMemory(
            to: Int32.self, capacity: second.patchOffset + secondTiles.x * secondTiles.y * secondTiles.z)
        let dims = second.cellDims(solver.grid) / second.ratio
        for z in 0..<secondTiles.z {
            for y in 0..<secondTiles.y {
                for x in 0..<secondTiles.x {
                    let at = second.patchOffset + x + secondTiles.x * (y + secondTiles.y * z)
                    guard map[at] >= 0 else { continue }
                    let low = simd_max(SIMD3(x, y, z) &* 4 &- 2, .zero) / first.side
                    let high = simd_min(SIMD3(x, y, z) &* 4 &+ 5, dims &- 1) / first.side
                    for k in low.z...high.z {
                        for j in low.y...high.y {
                            for i in low.x...high.x where map[i + firstTiles.x * (j + firstTiles.y * k)] < 0 {
                                return false
                            }
                        }
                    }
                }
            }
        }
        return true
    }

    @Test("Uniform air refined everywhere in two levels stays exactly uniform")
    func uniformStaysUniform() throws {
        // A negative threshold refines every block of both levels.
        var configuration = twoLevels(threshold: -1)
        configuration.reflectiveFaces = [.zMin, .xMax]
        let solver = try BlastSolver(
            device: device, grid: Grid(nx: 20, ny: 12, nz: 10, cellSize: 0.5), configuration: configuration)
        solver.mutateMask { mask in mask[solver.grid.index(10, 6, 3)] = 1 }
        solver.fill(uniform: Primitive(density: 1.225, pressure: 101_325))
        let start = solver.withState { $0[0] }
        let result = solver.advance(steps: 20)
        // Blocks of 4 x 4 x 4 cells: 5 by 3 by 3 of the coarse grid's, 10 by 6 by 5 of the first
        // level's.
        #expect(result.refinedTiles == 5 * 3 * 3)
        #expect(result.finerRefinedTiles == 10 * 6 * 5)
        let worst = solver.withState { state in
            (0..<state.count).filter { !solver.isSolid($0 % 20, ($0 / 20) % 12, $0 / 240) }
                .map { state[$0] == start ? 0 : 1 }.reduce(0, +)
        }
        #expect(worst == 0, "\(worst) cells changed")
    }

    @Test("Mass, energy and momentum are conserved across both levels' edges, which stay nested")
    func conservation() throws {
        let solver = try closedBox(twoLevels())
        let before = solver.totals()
        var finer = 0
        for _ in 0..<5 {
            let result = solver.advance(steps: 20)
            #expect(result.isStable)
            finer = max(finer, result.finerRefinedTiles)
            #expect(try nested(solver))
        }
        let after = solver.totals()
        #expect(finer > 0)
        #expect(abs(after.mass - before.mass) / before.mass < 1e-4, "mass \(before.mass) -> \(after.mass)")
        #expect(
            abs(after.energy - before.energy) / before.energy < 1e-4,
            "energy \(before.energy) -> \(after.energy)")
        // Momentum in a closed box is not conserved (its walls push back), but by symmetry its
        // y component, across the box's mid-plane, stays near zero.
        let momentum = solver.momentum()
        #expect(abs(momentum.y) < 1e-3 * simd_length(momentum), "momentum \(momentum)")
    }

    @Test("With afterburning, mass, energy and oxygen are conserved across both levels")
    func afterburningConservation() throws {
        var configuration = twoLevels()
        configuration.afterburning = true
        let solver = try closedBox(configuration)
        let start = solver.totals()
        let fuel = solver.speciesTotals()
        #expect(abs(fuel.fuel - 5) < 1e-3, "fuel laid down \(fuel.fuel) kg")
        let result = solver.advance(steps: 150)
        #expect(result.isStable)
        #expect(result.finerRefinedTiles > 0)
        let end = solver.totals()
        let left = solver.speciesTotals()
        #expect(fuel.fuel - left.fuel > 0.5, "only \(fuel.fuel - left.fuel) kg burnt")
        let heat = Double(configuration.afterburnEnergy)
        let perFuel = Double(BlastSolver.oxygenPerFuel)
        #expect(abs(end.mass - start.mass) / start.mass < 1e-4, "mass \(start.mass) -> \(end.mass)")
        let before = start.energy + heat * fuel.fuel
        let after = end.energy + heat * left.fuel
        #expect(abs(after - before) / before < 1e-4, "energy and fuel \(before) -> \(after)")
        let oxygenBefore = fuel.oxygen - perFuel * fuel.fuel
        let oxygenAfter = left.oxygen - perFuel * left.fuel
        #expect(
            abs(oxygenAfter - oxygenBefore) / oxygenBefore < 1e-4, "oxygen \(oxygenBefore) -> \(oxygenAfter)")
    }

    @Test("Across fine outlines that differ from the coarser ones, mass and energy are conserved")
    func offsetOutlineConservation() throws {
        // The block's faces lie an eighth of a coarse cell off the coarse cells' faces, and a
        // quarter off the first level's: each level sees them where its own cells put them. As
        // with one level, placing patches over the slivers of air a coarser outline counts as
        // solid adds the still air they held (at most their volume's worth), and from then on the
        // patches stay and the gas is conserved.
        let solver = try closedBox(twoLevels(), offset: 0.125)
        let before = solver.totals()
        var placed = before
        for n in 0..<4 {
            // The blast has passed every face of the block by the first check.
            let result = solver.advance(steps: n == 0 ? 200 : 100)
            #expect(result.isStable)
            #expect(result.finerRefinedTiles > 0)
            let now = solver.totals()
            if n == 0 {
                placed = now
                #expect(
                    now.mass >= before.mass && (now.mass - before.mass) / before.mass < 0.006,
                    "mass \(before.mass) -> \(now.mass)")
            } else {
                #expect(
                    abs(now.mass - placed.mass) / placed.mass < 1e-4, "mass \(placed.mass) -> \(now.mass)")
                #expect(
                    abs(now.energy - placed.energy) / placed.energy < 1e-4,
                    "energy \(placed.energy) -> \(now.energy)")
            }
        }
    }

    @Test("A run in two levels repeats exactly")
    func repeatable() throws {
        let first = try closedBox(twoLevels())
        let second = try closedBox(twoLevels())
        first.advance(steps: 60)
        second.advance(steps: 60)
        let same = first.withState { a in second.withState { b in zip(a, b).allSatisfy { $0 == $1 } } }
        #expect(same)
    }

    @Test("When the pool of patches is used up, the same blocks are refined every run", arguments: [1, 2])
    func repeatableWhenFull(levels: Int) throws {
        // Room for a few dozen patches; the shock wants hundreds.
        var configuration = twoLevels()
        configuration.refinementLevels = levels
        configuration.refinementMemory = 4 << 20
        let first = try closedBox(configuration)
        let second = try closedBox(configuration)
        let result = first.advance(steps: 60)
        second.advance(steps: 60)
        let capacity = try #require(levels > 1 ? first.finerRefinement : first.refinement).maxPatches
        #expect((levels > 1 ? result.finerRefinedTiles : result.refinedTiles) == capacity)
        let same = first.withState { a in second.withState { b in zip(a, b).allSatisfy { $0 == $1 } } }
        #expect(same)
    }

    /// Peak overpressure at 3 m from 1 kg on the ground, on cells of `cellSize`.
    private func peakAtThreeMetres(cellSize: Float, levels: Int) throws -> (peak: Float, refined: Int) {
        let scenario = Scenario(
            name: "Burst", domainSize: SIMD3(8, 8, 4), boxes: [],
            charge: Charge(mass: 1, position: SIMD3(2, 4, 0)),
            gauges: [Gauge("3 m", at: SIMD3(5.05, 4.05, 0.05))])
        var configuration = SolverConfiguration()
        if levels > 0 {
            configuration = twoLevels()
            configuration.refinementLevels = levels
        }
        let solver = try BlastSolver(
            device: device, scenario: scenario, cellSize: cellSize, configuration: configuration)
        var refined = 0
        while solver.time < 0.008 {
            let result = solver.advance(steps: 16, timeLimit: 0.008)
            refined = max(refined, levels > 1 ? result.finerRefinedTiles : result.refinedTiles)
            if result.steps == 0 { break }
        }
        let peak = (solver.gaugeHistories[0].map(\.pressure).max() ?? 0) - scenario.atmosphere.pressure
        return (peak, refined)
    }

    @Test("Refined twice, a coarse grid's peak overpressure comes close to that of a grid four times as fine")
    func sharperPeak() throws {
        let coarse = try peakAtThreeMetres(cellSize: 0.2, levels: 0)
        let once = try peakAtThreeMetres(cellSize: 0.2, levels: 1)
        let twice = try peakAtThreeMetres(cellSize: 0.2, levels: 2)
        let fine = try peakAtThreeMetres(cellSize: 0.05, levels: 0)
        #expect(twice.refined > 0)
        #expect(
            abs(twice.peak - fine.peak) < 0.4 * abs(coarse.peak - fine.peak)
                && abs(twice.peak - fine.peak) < abs(once.peak - fine.peak),
            "coarse \(coarse.peak) Pa, once \(once.peak) Pa, twice \(twice.peak) Pa, fine \(fine.peak) Pa")
    }

    @Test("A free wall in air refined twice gains exactly the impulse the air delivers to its face")
    func impulseTransfer() throws {
        var scenario = Scenario(
            name: "Piston", domainSize: SIMD3(16, 4, 4), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(1, 1, 1)),
            structure: StructureModel(
                solids: [Box(x: 8...8.5, y: 0...4, height: 4)],
                material: .elastic(density: 2400, youngsModulus: 20e9, poissonRatio: 0.2), elementSize: 0.125,
                fixedBase: false))
        scenario.reflectiveFaces = .all
        let solver = try BlastSolver(
            device: device, scenario: scenario, cellSize: 0.25, configuration: twoLevels())
        let structure = try #require(solver.structure)
        structure.gravity = 0
        structure.groundContact = false
        let ambient = scenario.atmosphere
        solver.fill { i, _, _ in
            Primitive(
                density: ambient.density * (i < 8 ? 4 : 1), pressure: ambient.pressure * (i < 8 ? 5 : 1))
        }
        var finer = 0
        while solver.time < 0.025 {
            let result = solver.advance(steps: 32, timeLimit: 0.025)
            finer = max(finer, result.finerRefinedTiles)
            if result.steps == 0 { break }
        }
        #expect(finer > 0)
        // The impulse recorded by the air cells touching the wall's face (i = 31): the largest of
        // their finest cells', which is the cell beside the face the wall reads.
        var delivered = 0.0
        for k in 0..<solver.grid.nz {
            for j in 0..<solver.grid.ny {
                delivered += Double(solver.impulse(31, j, k)) * 0.25 * 0.25
            }
        }
        let momentum = structure.momentum()
        #expect(delivered > 10_000, "delivered \(delivered) N s")
        #expect(abs(momentum.x - delivered) / delivered < 0.01, "momentum \(momentum.x) vs \(delivered) N s")
    }
}

/// Two levels around a deformable structure.
extension RefinementLevelsTests {
    /// Momentum a free wall 3 m from 5 kg on the ground has gained after 20 ms.
    private func wallMomentum(cellSize: Float, levels: Int) throws -> Double {
        let scenario = Scenario(
            name: "Free wall", domainSize: SIMD3(16, 12, 8), boxes: [],
            charge: Charge(mass: 5, position: SIMD3(4, 6, 0)),
            structure: StructureModel(
                solids: [Box(min: SIMD3(7, 3, 0), max: SIMD3(7.5, 9, 4))],
                material: .elastic(density: 2400, youngsModulus: 20e9, poissonRatio: 0.2), elementSize: 0.125,
                fixedBase: false))
        var configuration = SolverConfiguration()
        if levels > 0 {
            configuration = twoLevels(threshold: 0.1)
            configuration.refinementLevels = levels
        }
        let solver = try BlastSolver(
            device: device, scenario: scenario, cellSize: cellSize, configuration: configuration)
        let structure = try #require(solver.structure)
        structure.gravity = 0
        structure.groundContact = false
        let result = solver.advance(until: 0.02)
        #expect(result.isStable)
        return structure.momentum().x
    }

    @Test("A wall near a charge, in air refined twice, takes about the load of air four times as fine")
    func loadOnWall() throws {
        let coarse = try wallMomentum(cellSize: 0.5, levels: 0)
        let once = try wallMomentum(cellSize: 0.5, levels: 1)
        let twice = try wallMomentum(cellSize: 0.5, levels: 2)
        let fine = try wallMomentum(cellSize: 0.125, levels: 0)
        #expect(
            abs(twice - fine) < 0.2 * abs(coarse - fine) && abs(twice - fine) < abs(once - fine),
            "coarse \(coarse) N s, once \(once) N s, twice \(twice) N s, fine \(fine) N s")
    }

    @Test("A wall broken by the blast in air refined twice, run twice, gives the same answer to the last bit")
    func repeatableBreach() throws {
        // Both levels' pools are used up from the fourth batch.
        typealias Batch = (air: [CellState], nodes: [StructureNode])
        func run() throws -> (batches: [Batch], failed: Int, refined: Int) {
            var scenario = ScenarioPreset.blastWall.scenario
            scenario.charge.mass = 500
            let solver = try BlastSolver(
                device: device, scenario: scenario, cellSize: 0.5, configuration: twoLevels())
            let structure = try #require(solver.structure)
            var refinedMost = 0
            var batches: [Batch] = []
            for steps in [7, 64, 3, 128, 1, 256] {
                let result = solver.advance(steps: steps)
                try #require(
                    result.isStable && result.steps == steps, "batch \(batches.count) did not complete")
                refinedMost = max(refinedMost, result.finerRefinedTiles)
                var nodes: [StructureNode] = []
                structure.mutateNodes { nodes = Array($0) }
                batches.append((solver.withState { Array($0) }, nodes))
            }
            return (batches, structure.summary().erodedElements, refinedMost)
        }
        let first = try run()
        let second = try run()
        #expect(first.refined > 0)
        #expect(first.failed > 100, "only \(first.failed) elements failed")
        #expect(first.failed == second.failed)
        for (batch, (a, b)) in zip(first.batches, second.batches).enumerated() {
            let air = zip(a.air, b.air).filter { $0.0 != $0.1 }.count
            let differing = zip(a.nodes, b.nodes).filter {
                $0.0.displacement != $0.1.displacement || $0.0.velocity != $0.1.velocity
            }.count
            #expect(
                air == 0 && differing == 0,
                "after batch \(batch): \(air) air cells and \(differing) of \(a.nodes.count) nodes differ")
            if air > 0 || differing > 0 { break }
        }
    }
}
