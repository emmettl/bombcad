import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

/// The air's finer level near the shock.
@Suite("Refinement")
struct RefinementTests {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    private func refined(_ ratio: Int, threshold: Float = 0.05) -> SolverConfiguration {
        var configuration = SolverConfiguration()
        configuration.refinement = ratio
        configuration.refinementThreshold = threshold
        configuration.refinementMemory = 256 << 20
        return configuration
    }

    @Test("Uniform air refined everywhere stays exactly uniform", arguments: [2, 4])
    func uniformStaysUniform(ratio: Int) throws {
        // A negative threshold refines every tile.
        var configuration = refined(ratio, threshold: -1)
        configuration.reflectiveFaces = [.zMin, .xMax]
        let solver = try BlastSolver(
            device: device, grid: Grid(nx: 20, ny: 12, nz: 10, cellSize: 0.5), configuration: configuration)
        solver.mutateMask { mask in mask[solver.grid.index(10, 6, 3)] = 1 }
        solver.fill(uniform: Primitive(density: 1.225, pressure: 101_325))
        let start = solver.withState { $0[0] }
        let result = solver.advance(steps: 20)
        // Blocks of 4 x 4 x 4 cells: 5 by 3 by 3 of them.
        #expect(result.refinedTiles == 5 * 3 * 3)
        let worst = solver.withState { state in
            (0..<state.count).filter { !solver.isSolid($0 % 20, ($0 / 20) % 12, $0 / 240) }
                .map { state[$0] == start ? 0 : 1 }.reduce(0, +)
        }
        #expect(worst == 0, "\(worst) cells changed")
    }

    private func closedBox(_ configuration: SolverConfiguration) throws -> BlastSolver {
        var scenario = Scenario(
            name: "Closed box", domainSize: SIMD3(24, 20, 16),
            boxes: [Box(x: 13...18, y: 6...14, height: 9)],
            charge: Charge(mass: 5, position: SIMD3(8, 10, 1)))
        scenario.reflectiveFaces = .all
        return try BlastSolver(
            device: device, scenario: scenario, cellSize: 0.5, configuration: configuration)
    }

    @Test("Mass and energy are conserved across the refined level's edge", arguments: [2, 4])
    func conservation(ratio: Int) throws {
        let solver = try closedBox(refined(ratio))
        let before = solver.totals()
        let result = solver.advance(steps: 100)
        let after = solver.totals()
        #expect(result.isStable)
        #expect(result.refinedTiles > 0)
        #expect(abs(after.mass - before.mass) / before.mass < 1e-4, "mass \(before.mass) -> \(after.mass)")
        #expect(
            abs(after.energy - before.energy) / before.energy < 1e-4,
            "energy \(before.energy) -> \(after.energy)")
    }

    @Test(
        "With afterburning, mass is conserved and fuel burns into energy across the refined level",
        arguments: [2, 4])
    func afterburningConservation(ratio: Int) throws {
        var configuration = refined(ratio)
        configuration.afterburning = true
        let solver = try closedBox(configuration)
        let start = solver.totals()
        let fuel = solver.speciesTotals()
        #expect(abs(fuel.fuel - 5) < 1e-3, "fuel laid down \(fuel.fuel) kg")
        let result = solver.advance(steps: 150)
        #expect(result.isStable)
        #expect(result.refinedTiles > 0)
        let end = solver.totals()
        let left = solver.speciesTotals()
        #expect(fuel.fuel - left.fuel > 0.5, "only \(fuel.fuel - left.fuel) kg burnt")
        // What burns leaves as energy, and takes its oxygen with it.
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

    @Test("A refined run repeats exactly")
    func repeatable() throws {
        let first = try closedBox(refined(2))
        let second = try closedBox(refined(2))
        first.advance(steps: 60)
        second.advance(steps: 60)
        let same = first.withState { a in second.withState { b in zip(a, b).allSatisfy { $0 == $1 } } }
        #expect(same)
    }

    @Test("A centred burst in a closed cube stays mirror-symmetric while its refined blocks do")
    func mirrorSymmetry() throws {
        var scenario = Scenario(
            name: "Cube", domainSize: SIMD3(16, 16, 16), boxes: [],
            charge: Charge(mass: 2, position: SIMD3(8, 8, 8)))
        scenario.reflectiveFaces = .all
        let solver = try BlastSolver(
            device: device, scenario: scenario, cellSize: 0.5, configuration: refined(2))
        let result = solver.advance(steps: 12)
        #expect(result.refinedTiles > 0)
        // Whether a block is refined is a threshold on pressure jumps, which rounding can tip on one
        // side of a mirror and not the other (after about 20 steps here); from then on the two
        // sides are solved on different grids and differ by up to about 1%.
        let refinement = try #require(solver.refinement)
        let blocks = refinement.tileDims
        let map = refinement.patchOfTile.contents().bindMemory(
            to: Int32.self, capacity: blocks.x * blocks.y * blocks.z)
        var unmatched = 0
        for z in 0..<blocks.z {
            for y in 0..<blocks.y {
                for x in 0..<blocks.x {
                    let mirror = (blocks.x - 1 - x) + blocks.x * (y + blocks.y * (blocks.z - 1 - z))
                    unmatched += (map[x + blocks.x * (y + blocks.y * z)] >= 0) != (map[mirror] >= 0) ? 1 : 0
                }
            }
        }
        try #require(unmatched == 0, "\(unmatched) refined blocks have no mirror image")
        let n = solver.grid.nx
        let worst = solver.withState { state in
            var worst: Float = 0
            for k in 0..<n {
                for j in 0..<n {
                    for i in 0..<n / 2 {
                        let here = state[solver.grid.index(i, j, k)].density
                        for mirror in [
                            solver.grid.index(n - 1 - i, j, k), solver.grid.index(i, n - 1 - j, k),
                            solver.grid.index(i, j, n - 1 - k),
                        ] {
                            worst = max(worst, abs(here - state[mirror].density) / here)
                        }
                    }
                }
            }
            return worst
        }
        #expect(worst < 1e-5, "largest relative asymmetry \(worst)")
    }

    /// Peak overpressure at 3 m from 1 kg on the ground, on cells of `cellSize`.
    private func peakAtThreeMetres(cellSize: Float, ratio: Int) throws -> (peak: Float, refined: Int) {
        let scenario = Scenario(
            name: "Burst", domainSize: SIMD3(8, 8, 4), boxes: [],
            charge: Charge(mass: 1, position: SIMD3(2, 4, 0)),
            gauges: [Gauge("3 m", at: SIMD3(5.05, 4.05, 0.05))])
        let solver = try BlastSolver(
            device: device, scenario: scenario, cellSize: cellSize,
            configuration: ratio > 1 ? refined(ratio) : SolverConfiguration())
        var refinedTiles = 0
        while solver.time < 0.008 {
            let result = solver.advance(steps: 16, timeLimit: 0.008)
            refinedTiles = max(refinedTiles, result.refinedTiles)
            if result.steps == 0 { break }
        }
        let peak = (solver.gaugeHistories[0].map(\.pressure).max() ?? 0) - scenario.atmosphere.pressure
        return (peak, refinedTiles)
    }

    @Test("Refined, a coarse grid's peak overpressure comes close to that of a grid twice as fine")
    func sharperPeak() throws {
        let coarse = try peakAtThreeMetres(cellSize: 0.2, ratio: 1)
        let refined = try peakAtThreeMetres(cellSize: 0.2, ratio: 2)
        let fine = try peakAtThreeMetres(cellSize: 0.1, ratio: 1)
        #expect(refined.refined > 0)
        #expect(
            abs(refined.peak - fine.peak) < 0.4 * abs(coarse.peak - fine.peak),
            "coarse \(coarse.peak) Pa, refined \(refined.peak) Pa, fine \(fine.peak) Pa")
    }

    @Test("Sod's shock tube refined is nearer the exact solution than unrefined")
    func sodRefined() throws {
        func error(ratio: Int, cells: Int) throws -> Double {
            var configuration = ratio > 1 ? refined(ratio) : SolverConfiguration()
            configuration.reflectiveFaces = []
            configuration.pressureFloor = 1e-6
            let solver = try BlastSolver(
                device: device, grid: Grid(nx: cells, ny: 1, nz: 1, cellSize: 1 / Float(cells)),
                configuration: configuration)
            solver.fill { i, _, _ in
                i < cells / 2 ? Primitive(density: 1, pressure: 1) : Primitive(density: 0.125, pressure: 0.1)
            }
            solver.advance(until: 0.2)
            return solver.withState { state in
                (0..<cells).reduce(0.0) { sum, i in
                    let x = (Double(i) + 0.5) / Double(cells)
                    return sum
                        + abs(Double(state[i].density) - SolverVerificationTests.sodDensity(x: x, t: 0.2))
                } / Double(cells)
            }
        }
        let coarse = try error(ratio: 1, cells: 100)
        let twice = try error(ratio: 2, cells: 100)
        let fine = try error(ratio: 1, cells: 200)
        #expect(twice < coarse, "L1 error coarse \(coarse), refined \(twice), fine \(fine)")
    }
}

/// The finer level around a deformable structure.
extension RefinementTests {
    static let elastic = StructureMaterial.elastic(density: 2400, youngsModulus: 20e9, poissonRatio: 0.2)

    /// Momentum a free wall 3 m from 5 kg on the ground has gained after 20 ms.
    private func wallMomentum(cellSize: Float, ratio: Int) throws -> Double {
        let scenario = Scenario(
            name: "Free wall", domainSize: SIMD3(16, 12, 8), boxes: [],
            charge: Charge(mass: 5, position: SIMD3(4, 6, 0)),
            structure: StructureModel(
                solids: [Box(min: SIMD3(7, 3, 0), max: SIMD3(7.5, 9, 4))], material: Self.elastic,
                elementSize: 0.125, fixedBase: false))
        var configuration = ratio > 1 ? refined(ratio) : SolverConfiguration()
        configuration.refinementThreshold = 0.1
        let solver = try BlastSolver(
            device: device, scenario: scenario, cellSize: cellSize, configuration: configuration)
        let structure = try #require(solver.structure)
        structure.gravity = 0
        structure.groundContact = false
        let result = solver.advance(until: 0.02)
        #expect(result.isStable)
        return structure.momentum().x
    }

    @Test("A wall near a charge, in refined air, takes about the load of air twice as fine")
    func refinedLoadOnWall() throws {
        // About 320, 880 and 950 N s.
        let coarse = try wallMomentum(cellSize: 0.5, ratio: 1)
        let refined = try wallMomentum(cellSize: 0.5, ratio: 2)
        let fine = try wallMomentum(cellSize: 0.25, ratio: 1)
        #expect(
            abs(refined - fine) < 0.2 * abs(coarse - fine),
            "coarse \(coarse) N s, refined \(refined) N s, fine \(fine) N s")
    }

    @Test("A free wall in refined air gains exactly the impulse the air delivers to its face")
    func refinedImpulseTransfer() throws {
        var scenario = Scenario(
            name: "Piston", domainSize: SIMD3(16, 4, 4), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(1, 1, 1)),
            structure: StructureModel(
                solids: [Box(x: 8...8.5, y: 0...4, height: 4)], material: Self.elastic, elementSize: 0.125,
                fixedBase: false))
        scenario.reflectiveFaces = .all
        let solver = try BlastSolver(
            device: device, scenario: scenario, cellSize: 0.25, configuration: refined(2))
        let structure = try #require(solver.structure)
        structure.gravity = 0
        structure.groundContact = false
        let ambient = scenario.atmosphere
        solver.fill { i, _, _ in
            Primitive(
                density: ambient.density * (i < 8 ? 4 : 1), pressure: ambient.pressure * (i < 8 ? 5 : 1))
        }
        var refinedMost = 0
        while solver.time < 0.025 {
            let result = solver.advance(steps: 32, timeLimit: 0.025)
            refinedMost = max(refinedMost, result.refinedTiles)
            if result.steps == 0 { break }
        }
        #expect(refinedMost > 0)
        // The impulse recorded by the air cells touching the wall's face (i = 31): under a patch,
        // the largest of their fine cells', which is the fine cell beside the face the wall reads.
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

    @Test("A wall driven into still refined air raises the piston shock ahead of it")
    func refinedPiston() throws {
        var scenario = Scenario(
            name: "Piston", domainSize: SIMD3(16, 1, 1), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(1, 0.5, 0.5)),
            structure: StructureModel(
                solids: [Box(x: 6...6.5, y: 0...1, height: 1)], material: Self.elastic, elementSize: 0.125,
                fixedBase: false))
        scenario.reflectiveFaces = .all
        let solver = try BlastSolver(
            device: device, scenario: scenario, cellSize: 0.25, configuration: refined(2))
        let structure = try #require(solver.structure)
        structure.gravity = 0
        structure.groundContact = false
        let speed: Float = 100
        structure.mutateNodes { nodes in
            for index in nodes.indices {
                nodes[index].velocity = SIMD3(speed, 0, 0)
                nodes[index].isPrescribed = true
            }
        }
        let before = solver.totals()
        var refinedMost = 0
        while solver.time < 0.01 {
            let result = solver.advance(steps: 32, timeLimit: 0.01)
            #expect(result.isStable)
            refinedMost = max(refinedMost, result.refinedTiles)
            if result.steps == 0 { break }
        }
        #expect(refinedMost > 0)
        let ambient = scenario.atmosphere
        let gamma: Float = 1.4
        let mach = speed / (gamma * ambient.pressure / ambient.density).squareRoot()
        let quarter = (gamma + 1) / 4
        let ahead =
            1 + gamma * quarter * mach * mach + gamma * mach
            * (1 + quarter * quarter * mach * mach).squareRoot()
        let face = structure.position(0, 4, 4).x
        let front = solver.grid.cell(containing: SIMD3(face + 0.5 + 0.375, 0.5, 0.5))
        for offset in 0..<6 {
            let pressure = solver.primitive(front.i + offset, 0, 0).pressure / ambient.pressure
            #expect(abs(pressure - ahead) < 0.02 * ahead, "ahead of the wall \(pressure), expected \(ahead)")
        }
        // The wall swept 1 m of a 16 m tube: the gas is conserved within what the staircase allows.
        let after = solver.totals()
        #expect(abs(after.mass - before.mass) / before.mass < 0.02, "mass \(before.mass) -> \(after.mass)")
    }

    @Test("A wall broken by the blast in refined air, run twice, gives the same answer to the last bit")
    func refinedRepeatableBreach() throws {
        func run() throws -> (nodes: [StructureNode], failed: Int, refined: Int) {
            var scenario = ScenarioPreset.blastWall.scenario
            scenario.charge.mass = 500
            let solver = try BlastSolver(
                device: device, scenario: scenario, cellSize: 0.5, configuration: refined(2))
            let structure = try #require(solver.structure)
            var refinedMost = 0
            for steps in [7, 64, 3, 128, 1, 256, 256, 256] {
                refinedMost = max(refinedMost, solver.advance(steps: steps).refinedTiles)
            }
            var copy: [StructureNode] = []
            structure.mutateNodes { copy = Array($0) }
            return (copy, structure.summary().erodedElements, refinedMost)
        }
        let first = try run()
        let second = try run()
        #expect(first.refined > 0)
        #expect(first.failed > 100, "only \(first.failed) elements failed")
        #expect(first.failed == second.failed)
        let differing = zip(first.nodes, second.nodes).filter {
            $0.0.displacement != $0.1.displacement || $0.0.velocity != $0.1.velocity
        }.count
        #expect(differing == 0, "\(differing) of \(first.nodes.count) nodes differ")
    }
}

/// The fine cells' own outline.
extension RefinementTests {
    /// When a shock run down a closed tube 4 m long, reflected by a wall whose face is at 3.509 m
    /// (so at 3.50 m on cells of 0.02 m, at 3.51 m on cells of 0.01 m), passes back over 3.2 m.
    private func reflectedArrival(cellSize: Float, ratio: Int) throws -> (
        time: Double, mass: (Double, Double)
    ) {
        let ambient = Primitive(density: 1.225, pressure: 101_325)
        let shocked = Primitive(density: 2.4, velocity: SIMD3(330, 0, 0), pressure: 3 * 101_325)
        var scenario = Scenario(
            name: "Tube", domainSize: SIMD3(4, cellSize, cellSize),
            boxes: [Box(min: SIMD3(3.509, -1, -1), max: SIMD3(5, 1, 1))],
            charge: Charge(mass: 0, position: SIMD3(0.5, 0, 0)))
        scenario.reflectiveFaces = .all
        let solver = try BlastSolver(
            device: device, scenario: scenario, cellSize: cellSize,
            configuration: ratio > 1 ? refined(ratio) : SolverConfiguration())
        solver.fill { i, _, _ in Float(i) * cellSize < 1 ? shocked : ambient }
        let before = solver.totals().mass
        solver.setGauges(
            cells: [solver.grid.cell(containing: SIMD3(3.2, 0, 0))], points: [SIMD3(3.2, 0.001, 0.001)])
        solver.advance(until: 0.006)
        let history = solver.gaugeHistories[0]
        let peak = history.map(\.pressure).max() ?? 0
        let time = history.first { $0.time > 0.0035 && $0.pressure > 0.5 * (peak + 3 * 101_325) }?.time ?? 0
        return (time, (before, solver.totals().mass))
    }

    @Test("Refined air sees a wall where the fine cells put it, not the coarse ones")
    func fineOutline() throws {
        let coarse = try reflectedArrival(cellSize: 0.02, ratio: 1)
        let refined = try reflectedArrival(cellSize: 0.02, ratio: 2)
        let fine = try reflectedArrival(cellSize: 0.01, ratio: 1)
        // The coarse wall stands 1 cm nearer, so its echo comes back about 50 µs sooner.
        #expect(
            abs(refined.time - fine.time) < 0.25 * abs(coarse.time - fine.time),
            "echo at \(coarse.time), \(refined.time) and \(fine.time) s")
    }

    @Test("Across a fine outline that differs from the coarse one, mass and energy are conserved")
    func offsetOutlineConservation() throws {
        var scenario = Scenario(
            name: "Closed box", domainSize: SIMD3(24, 20, 16),
            boxes: [Box(min: SIMD3(13.25, 6.25, 0), max: SIMD3(18.25, 14.25, 9.25))],
            charge: Charge(mass: 5, position: SIMD3(8, 10, 1)))
        scenario.reflectiveFaces = .all
        let solver = try BlastSolver(
            device: device, scenario: scenario, cellSize: 0.5, configuration: refined(2))
        let before = solver.totals()
        // The fine outline leaves a sliver of air along some of the block's faces that the coarse
        // cells count as solid: placing patches there adds the still air it held, at most its
        // volume's worth (0.25 m deep, under 1% of the room), and from then on
        // the patches stay and the gas is conserved.
        var placed = solver.totals()
        for n in 0..<4 {
            let result = solver.advance(steps: 100)
            #expect(result.isStable)
            let now = solver.totals()
            if n == 0 {
                placed = now
                #expect(now.mass > before.mass && (now.mass - before.mass) / before.mass < 0.006)
            } else {
                #expect(
                    abs(now.mass - placed.mass) / placed.mass < 1e-4, "mass \(placed.mass) -> \(now.mass)")
                #expect(
                    abs(now.energy - placed.energy) / placed.energy < 1e-4,
                    "energy \(placed.energy) -> \(now.energy)")
            }
        }
    }
}

extension RefinementTests {
    /// Peak overpressure 0.75 m from 100 kg on the ground, and impulse on a wall 3.5 m away, in a
    /// closed room.
    private func nearField(cellSize: Float, ratio: Int) throws -> (peak: Float, impulse: Double) {
        var scenario = Scenario(
            name: "Room", domainSize: SIMD3(11.5, 16, 16), boxes: [],
            charge: Charge(mass: 100, position: SIMD3(8, 8, 0)),
            gauges: [Gauge("Near", at: SIMD3(8.76, 8.01, 0.05)), Gauge("Wall", at: SIMD3(11.46, 8.01, 0.05))])
        scenario.reflectiveFaces = .all
        let solver = try BlastSolver(
            device: device, scenario: scenario, cellSize: cellSize,
            configuration: ratio > 1 ? refined(ratio) : SolverConfiguration())
        solver.advance(until: 0.006)
        let near = (solver.gaugeHistories[0].map(\.pressure).max() ?? 0) - scenario.atmosphere.pressure
        var impulse = 0.0
        let wall = solver.gaugeHistories[1]
        for (a, b) in zip(wall, wall.dropFirst()) {
            impulse += Double(max(a.pressure - scenario.atmosphere.pressure, 0)) * (b.time - a.time)
        }
        return (near, impulse)
    }

    @Test("A charge in refined air starts as it would on a grid that fine")
    func refinedCharge() throws {
        // Laid down in coarse cells, a sphere two cells across is a blocky cube that the fine
        // cells then resolve; it drove peaks 30% too high this close.
        let refined = try nearField(cellSize: 0.25, ratio: 2)
        let fine = try nearField(cellSize: 0.125, ratio: 1)
        #expect(
            abs(refined.peak - fine.peak) / fine.peak < 0.05, "peak \(refined.peak) against \(fine.peak) Pa")
        #expect(
            abs(refined.impulse - fine.impulse) / fine.impulse < 0.03,
            "wall impulse \(refined.impulse) against \(fine.impulse) Pa s")
    }
}
