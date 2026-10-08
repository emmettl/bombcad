import Testing
import simd

@testable import BlastCore

@Suite("Piston tube cell crossings")
struct PrescribedPistonTubeTests {
    @Test("Physical-time snapshots retain their own gas/wall budgets", arguments: [-20.0, 20.0])
    func snapshots(speed: Double) throws {
        let start = speed < 0 ? 0.655 : 0.355
        let times = [0.0, 0.0005, 0.002, 0.005, 0.015]
        let run = try PrescribedPistonTube.run(
            cellLength: 0.1, area: 0.01, length: start,
            pistonVelocity: speed, duration: 0.015, outputTimes: Array(times.reversed()))
        #expect(run.snapshots.map(\.time) == times)
        #expect(run.snapshots.first!.steps == 0 && run.snapshots.last!.steps == run.steps)
        for frame in run.snapshots {
            let after = frame.cells.reduce(SIMD8<Double>.zero) { $0 + $1.amount }
            #expect(abs(after[0] / run.initialAmount[0] - 1) < 1e-12)
            #expect(abs(after[4] - run.initialAmount[4] + frame.wallWork) < 1e-9)
            #expect(simd_length(SIMD3(after[1], after[2], after[3]) + frame.wallImpulse) < 1e-12)
            #expect(
                abs(frame.cells.reduce(0) { $0 + $1.volume } - 0.01 * (start + speed * frame.time)) < 1e-14)
        }
        #expect(run.snapshots.last!.cells.map(\.amount) == run.cells.map(\.amount))
    }
    @Test("Alternative merge fractions and CFL limits conserve crossing budgets", arguments: [0.125, 0.5])
    func policies(merge: Double) throws {
        var stepCounts: [Int] = []
        for cfl in [0.4, 0.2] {
            let run = try PrescribedPistonTube.run(
                cellLength: 0.1, area: 0.01, length: 0.655,
                pistonVelocity: -20, duration: 0.015, mergeFraction: merge, cfl: cfl)
            stepCounts.append(run.steps)
            let after = run.cells.reduce(SIMD8<Double>.zero) { $0 + $1.amount }
            #expect(abs(after[0] / run.initialAmount[0] - 1) < 1e-12)
            #expect(abs(after[4] - run.initialAmount[4] + run.wallWork) < 1e-9)
            #expect(simd_length(SIMD3(after[1], after[2], after[3]) + run.wallImpulse) < 1e-12)
            #expect(run.cells.allSatisfy { $0.volume >= merge * 0.001 * (1 - 1e-10) && $0.pressure() > 0 })
        }
        #expect(stepCounts[1] > stepCounts[0])
    }
    @Test(
        "Compression and expansion cross three grid cells with closed gas/wall budgets",
        arguments: [-1.0, 1.0])
    func crossings(speed: Double) throws {
        let start = speed < 0 ? 0.65 : 0.35
        let result = try PrescribedPistonTube.run(
            cellLength: 0.1, area: 0.01, length: start,
            pistonVelocity: speed, duration: 0.3)
        #expect(result.gridCrossings == 3 && result.remeshes == 3)
        #expect(result.steps < 20000)
        let after = result.cells.reduce(SIMD8<Double>.zero) { $0 + $1.amount }
        let before = result.initialAmount
        let volume = result.cells.reduce(0) { $0 + $1.volume }
        #expect(abs(volume - 0.01 * (start + speed * 0.3)) < 1e-14)
        #expect(abs(after[0] / before[0] - 1) < 1e-11)
        #expect(abs(after[4] - before[4] + result.wallWork) < 1e-8)
        #expect(simd_length(SIMD3(after[1], after[2], after[3]) + result.wallImpulse) < 1e-11)
        #expect(result.cells.allSatisfy { $0.volume >= 0.00025 * (1 - 1e-10) && $0.pressure() > 0 })
    }

    @Test("Repartitioning conserves a nonuniform extensive state and uniform split states")
    func repartition() throws {
        let old = [
            FractionalGasTransport.Cell(volume: 0.001, density: 1, velocity: SIMD3(2, 1, 0), pressure: 90000),
            .init(volume: 0.0002, density: 2, velocity: SIMD3(-1, 0, 3), pressure: 120000),
        ]
        let merged = try PrescribedPistonTube.repartition(old, volumes: [0.0012])
        let before = old.reduce(SIMD8<Double>.zero) { $0 + $1.amount }
        for axis in 0..<5 { #expect(abs(merged[0].amount[axis] - before[axis]) < 1e-12) }
        let split = try PrescribedPistonTube.repartition(merged, volumes: [0.0003, 0.0009])
        for cell in split {
            #expect(abs(cell.pressure() / merged[0].pressure() - 1) < 1e-12)
            #expect(simd_length(cell.velocity - merged[0].velocity) < 1e-12)
        }
    }

    @Test("Invalid geometry and exhausted step budgets fail explicitly")
    func failure() throws {
        for times in [[0.001, 0.001], [-0.001], [0.4]] {
            #expect(throws: PrescribedPistonTube.Failure.self) {
                try PrescribedPistonTube.run(
                    cellLength: 0.1, area: 0.01, length: 0.65,
                    pistonVelocity: -1, duration: 0.3, outputTimes: times)
            }
        }
        for merge in [0.0, 0.75] {
            #expect(throws: PrescribedPistonTube.Failure.self) {
                try PrescribedPistonTube.run(
                    cellLength: 0.1, area: 0.01, length: 0.65,
                    pistonVelocity: -1, duration: 0.3, mergeFraction: merge)
            }
        }
        #expect(throws: PrescribedPistonTube.Failure.self) {
            try PrescribedPistonTube.run(
                cellLength: 0.1, area: 0.01, length: 0.1, pistonVelocity: -1, duration: 0.2)
        }
        #expect(throws: PrescribedPistonTube.Failure.self) {
            try PrescribedPistonTube.run(
                cellLength: 0.1, area: 0.01, length: 0.65, pistonVelocity: -1, duration: 0.3, maximumSteps: 1)
        }
        #expect(throws: PrescribedPistonTube.Failure.self) {
            try PrescribedPistonTube.repartition([.init(volume: 1, density: 1, pressure: 1)], volumes: [2])
        }
    }
}
