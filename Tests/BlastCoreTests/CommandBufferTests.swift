import Foundation
import Metal
import Testing

@testable import BlastCore
@testable import BlastModel

/// `advance` hands the GPU its steps in command buffers of about `BlastSolver.commandBufferTarget`
/// of its time, so that none holds it long enough to starve the window server, and the steps are
/// the same however they are cut.
@Suite("Command buffers sized by the GPU's time", .gpuThreads)
struct CommandBufferTests {
    @Test("A buffer takes the target's worth of steps at the rate measured lately, at least one")
    func sizing() {
        var rate = GPUStepRate()
        rate.target = 0.075
        #expect(rate.part(100) == 4)
        rate.measure(gpuSeconds: 0.004, steps: 4)
        #expect(rate.part(1000) == 75 && rate.part(20) == 20)
        // Smoothed: a slower buffer moves the rate a third of the way.
        rate.measure(gpuSeconds: 0.03, steps: 10)
        #expect(abs(rate.seconds! - (0.7 * 0.001 + 0.3 * 0.003)) < 1e-12)
        rate.measure(gpuSeconds: 10, steps: 1)
        #expect(rate.part(50) == 1)
        // A buffer that took no time, or no steps, tells nothing.
        let before = rate.seconds
        rate.measure(gpuSeconds: 0, steps: 5)
        rate.measure(gpuSeconds: 1, steps: 0)
        #expect(rate.seconds == before)
    }

    @Test("Refined air, and a structure with it, step the same in one-step buffers as in the usual ones")
    func airInvariant() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var configuration = SolverConfiguration()
        configuration.refinement = 2
        configuration.refinementMemory = 256 << 20
        /// The air's state, its peaks, the clock and the structure's largest deflection, as numbers.
        func run(_ seconds: Double?, preset: ScenarioPreset) throws -> [Float] {
            let solver = try BlastSolver(
                device: device, scenario: preset.scenario, cellSize: 0.5, configuration: configuration)
            if let seconds { solver.commandBufferSeconds = seconds }
            let result = solver.advance(steps: 70, timeLimit: 0.02)
            #expect(result.steps > 0 && result.isStable)
            var values: [Float] = solver.withState { cells in
                cells.flatMap { [$0.density, $0.momentumX, $0.momentumY, $0.momentumZ, $0.energy] }
            }
            let grid = solver.grid
            for k in 0..<grid.nz {
                for j in 0..<grid.ny {
                    for i in 0..<grid.nx { values.append(solver.peakOverpressure(i, j, k)) }
                }
            }
            values.append(Float(solver.time))
            values.append(solver.bodySummary()?.maxDisplacement ?? 0)
            return values
        }
        for preset in [ScenarioPreset.streetCanyon, .blastWall] {
            let usual = try run(nil, preset: preset)
            let single = try run(1e-12, preset: preset)
            #expect(usual.map(\.bitPattern) == single.map(\.bitPattern), "\(preset)")
        }
    }

    @Test("A structure on its own, failing, steps the same in one-substep buffers, across 2,000-substep runs")
    func structureInvariant() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let wall = Box(min: .zero, max: SIMD3(0.2, 2, 2))
        var model = StructureModel(solids: [wall], elementSize: 0.1, fixedBase: true)
        model.addMat(to: wall, thicknessAxis: 0, areaPerMetre: 4e-4, depth: 0.04)
        // The rate averaged over 50 steps, as when this test was written, under which this load
        // breaks the wall within the run; the 100 µs window strengthens it enough to hold.
        model.strainRateWindow = nil
        let load = PressureLoad(
            axis: 0, positiveSide: false,
            history: [SIMD2(0, 0), SIMD2(0.0005, 3e6), SIMD2(0.004, 0), SIMD2(10, 0)])
        /// The nodes' displacements and velocities, the deflection, damage and failures, and the clock.
        func numbers(_ nodes: [SIMD3<Float>], _ summary: StructureSummary, _ time: Double) -> [Double] {
            nodes.flatMap { [Double($0.x), Double($0.y), Double($0.z)] }
                + [
                    Double(summary.maxDisplacement), Double(summary.maxDamage),
                    Double(summary.erodedElements), time,
                ]
        }
        func solids(_ seconds: Double?) throws -> [Double] {
            let solver = try StructureSolver(device: device, model: model)
            if let seconds { solver.commandBufferSeconds = seconds }
            solver.appliedLoad = load
            solver.advance(steps: 2300)
            var nodes: [SIMD3<Float>] = []
            solver.mutateNodes { all in
                for n in all { nodes += [SIMD3(n.ux, n.uy, n.uz), SIMD3(n.vx, n.vy, n.vz)] }
            }
            return numbers(nodes, solver.summary(), solver.time)
        }
        let usual = try solids(nil)
        let single = try solids(1e-12)
        #expect(usual[usual.count - 2] > 0, "the wall should fail, so that its contact joins in")
        #expect(usual.map(\.bitPattern) == single.map(\.bitPattern))
        var shellModel = model
        shellModel.elementKind = .shell
        func shells(_ seconds: Double?) throws -> [Double] {
            let solver = try ShellSolver(device: device, model: shellModel)
            if let seconds { solver.commandBufferSeconds = seconds }
            solver.appliedLoad = load
            solver.advance(steps: 2300)
            var nodes: [SIMD3<Float>] = []
            solver.mutateNodes { all in
                for n in all { nodes += [SIMD3(n.ux, n.uy, n.uz), SIMD3(n.vx, n.vy, n.vz)] }
            }
            return numbers(nodes, solver.summary(), solver.time)
        }
        let usualShells = try shells(nil)
        let singleShells = try shells(1e-12)
        #expect(usualShells.map(\.bitPattern) == singleShells.map(\.bitPattern))
    }
}
