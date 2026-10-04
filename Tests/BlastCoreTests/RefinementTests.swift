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
