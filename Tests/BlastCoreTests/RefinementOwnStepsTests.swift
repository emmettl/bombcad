import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

/// Refined levels taking only the substeps their own waves need.
@Suite("Refinement with each level's own steps")
struct RefinementOwnStepsTests {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    private func ownSteps(levels: Int, threshold: Float = 0.05) -> SolverConfiguration {
        var configuration = SolverConfiguration()
        configuration.refinement = 2
        configuration.refinementLevels = levels
        configuration.refinementThreshold = threshold
        configuration.refinementMemory = 256 << 20
        configuration.refinementOwnSteps = true
        return configuration
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

    @Test("Uniform air refined everywhere, taking its own steps, stays exactly uniform", arguments: [1, 2])
    func uniformStaysUniform(levels: Int) throws {
        var configuration = ownSteps(levels: levels, threshold: -1)
        configuration.reflectiveFaces = [.zMin, .xMax]
        let solver = try BlastSolver(
            device: device, grid: Grid(nx: 20, ny: 12, nz: 10, cellSize: 0.5), configuration: configuration)
        solver.mutateMask { mask in mask[solver.grid.index(10, 6, 3)] = 1 }
        solver.fill(uniform: Primitive(density: 1.225, pressure: 101_325))
        let start = solver.withState { $0[0] }
        let result = solver.advance(steps: 20)
        #expect(result.refinedTiles == 5 * 3 * 3)
        // Still air's waves are the same everywhere, so every level takes all its substeps.
        #expect(result.firstLevelSubsteps == 2)
        let worst = solver.withState { state in
            (0..<state.count).filter { !solver.isSolid($0 % 20, ($0 / 20) % 12, $0 / 240) }
                .map { state[$0] == start ? 0 : 1 }.reduce(0, +)
        }
        #expect(worst == 0, "\(worst) cells changed")
    }

    @Test(
        "Taking its own steps, a level conserves mass and energy, with afterburning too", arguments: [1, 2])
    func conservation(levels: Int) throws {
        for afterburning in [false, true] {
            var configuration = ownSteps(levels: levels)
            configuration.afterburning = afterburning
            // The burst of `burst` in a room it does not reach in the time, closed on every side.
            var scenario = Scenario(
                name: "Closed burst", domainSize: SIMD3(16, 16, 8), boxes: [],
                charge: Charge(mass: 1, position: SIMD3(8, 8, 0)))
            scenario.reflectiveFaces = .all
            let solver = try BlastSolver(
                device: device, scenario: scenario, cellSize: 0.2, configuration: configuration)
            let start = solver.totals()
            let fuel = solver.speciesTotals()
            var taken: [String] = []
            var fewer = false
            while solver.time < 0.008 {
                let result = solver.advance(steps: 40, timeLimit: 0.008)
                if result.steps == 0 { break }
                #expect(result.isStable)
                taken.append(
                    String(format: "%.2f/%.2f", result.firstLevelSubsteps, result.secondLevelSubsteps))
                fewer =
                    fewer || result.firstLevelSubsteps < 2
                    || (levels > 1 && result.secondLevelSubsteps < 4)
            }
            // The fireball's hot gas, unrefined once the shock has left it, sets the step.
            #expect(fewer, "every level took all its substeps: \(taken)")
            let end = solver.totals()
            let left = solver.speciesTotals()
            let heat = afterburning ? Double(configuration.afterburnEnergy) : 0
            #expect(abs(end.mass - start.mass) / start.mass < 1e-4, "mass \(start.mass) -> \(end.mass)")
            let before = start.energy + heat * fuel.fuel
            let after = end.energy + heat * left.fuel
            #expect(abs(after - before) / before < 1e-4, "energy \(before) -> \(after)")
            if afterburning {
                let perFuel = Double(BlastSolver.oxygenPerFuel)
                let oxygenBefore = fuel.oxygen - perFuel * fuel.fuel
                let oxygenAfter = left.oxygen - perFuel * left.fuel
                #expect(abs(oxygenAfter - oxygenBefore) / oxygenBefore < 1e-4)
            }
        }
    }

    @Test("Taking their own steps, the levels repeat exactly", arguments: [1, 2])
    func repeatable(levels: Int) throws {
        let first = try closedBox(ownSteps(levels: levels))
        let second = try closedBox(ownSteps(levels: levels))
        first.advance(steps: 90)
        second.advance(steps: 90)
        let same = first.withState { a in second.withState { b in zip(a, b).allSatisfy { $0 == $1 } } }
        #expect(same)
    }

    /// Peak overpressure and impulse at 3 m from 1 kg on the ground, on 0.2 m cells, and the
    /// substeps taken.
    private func burst(levels: Int, own: Bool) throws -> (peak: Float, impulse: Float, substeps: Double) {
        let scenario = Scenario(
            name: "Burst", domainSize: SIMD3(8, 8, 4), boxes: [],
            charge: Charge(mass: 1, position: SIMD3(2, 4, 0)),
            gauges: [Gauge("3 m", at: SIMD3(5.05, 4.05, 0.05))])
        var configuration = ownSteps(levels: levels)
        configuration.refinementOwnSteps = own
        let solver = try BlastSolver(
            device: device, scenario: scenario, cellSize: 0.2, configuration: configuration)
        let result = solver.advance(until: 0.008)
        #expect(result.isStable)
        let peak = (solver.gaugeHistories[0].map(\.pressure).max() ?? 0) - scenario.atmosphere.pressure
        let cell = solver.nearestFluidCell(to: scenario.gauges[0].position)
        return (peak, solver.impulse(cell.i, cell.j, cell.k), result.firstLevelSubsteps)
    }

    @Test(
        "Taking their own steps, the levels give a burst's peak and impulse as taking every substep does",
        arguments: [1, 2])
    func sameAnswer(levels: Int) throws {
        let every = try burst(levels: levels, own: false)
        let own = try burst(levels: levels, own: true)
        #expect(own.substeps < every.substeps)
        #expect(abs(own.peak - every.peak) < 0.03 * every.peak, "peak \(every.peak) -> \(own.peak) Pa")
        #expect(
            abs(own.impulse - every.impulse) < 0.03 * every.impulse,
            "impulse \(every.impulse) -> \(own.impulse)")
    }
}
