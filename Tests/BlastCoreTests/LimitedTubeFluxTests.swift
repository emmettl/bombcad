import Testing
import simd

@testable import BlastCore

@Suite("Limited tube reconstruction")
struct LimitedTubeFluxTests {
    @Test("Stronger analytical waves improve with refinement across merge policies")
    func strongAccuracy() throws {
        let limited = try ExperimentalPistonWaveStudy.run(
            limited: true, strong: true, mergeStudy: true,
            cellLengths: [0.1, 0.0125], cfls: [0.2])
        let constant = try ExperimentalPistonWaveStudy.run(
            strong: true, mergeStudy: true,
            cellLengths: [0.0125], cfls: [0.2])
        #expect(limited.count == 12 && constant.count == 6)
        for speed in [-100.0, 100.0] {
            for merge in [0.125, 0.25, 0.5] {
                let coarse = try #require(
                    limited.first {
                        $0.cellLength == 0.1 && $0.pistonVelocity == speed && $0.mergeFraction == merge
                    })
                let fine = try #require(
                    limited.first {
                        $0.cellLength == 0.0125 && $0.pistonVelocity == speed && $0.mergeFraction == merge
                    })
                let baseline = try #require(
                    constant.first { $0.pistonVelocity == speed && $0.mergeFraction == merge })
                #expect(fine.frames.last!.relativePressureL1 < 0.4 * coarse.frames.last!.relativePressureL1)
                #expect(fine.frames.last!.relativePressureL1 < 0.5 * baseline.frames.last!.relativePressureL1)
                for frame in fine.frames {
                    #expect(abs(frame.relativeMassChange) < 1e-11)
                    #expect(abs(frame.energyBudgetResidual) < 1e-9)
                    #expect(abs(frame.volumeResidual) < 1e-14)
                    #expect(simd_length(frame.momentumBudgetResidual) < 1e-11)
                    #expect(abs(frame.relativeWallWorkError) < 0.002)
                }
            }
        }
    }
    @Test("Stage-limit control avoids repeated halving while preserving compression budgets")
    func stepControl() throws {
        let old = try PrescribedPistonTube.run(
            cellLength: 0.0125, area: 0.01, length: 0.655,
            pistonVelocity: -20, duration: 0.0008, cfl: 0.2, reconstruction: .minmod, stepControl: .halving)
        let improved = try PrescribedPistonTube.run(
            cellLength: 0.0125, area: 0.01, length: 0.655,
            pistonVelocity: -20, duration: 0.0008, cfl: 0.2, reconstruction: .minmod)
        #expect(Double(improved.steps) < 0.6 * Double(old.steps))
        #expect(improved.rejectedSteps < old.rejectedSteps / 10)
        for run in [old, improved] {
            let amount = run.cells.reduce(SIMD8<Double>.zero) { $0 + $1.amount }
            #expect(abs(amount[0] / run.initialAmount[0] - 1) < 1e-12)
            #expect(abs(amount[4] - run.initialAmount[4] + run.wallWork) < 1e-9)
            #expect(simd_length(SIMD3(amount[1], amount[2], amount[3]) + run.wallImpulse) < 1e-12)
        }
        #expect(abs(improved.wallWork / old.wallWork - 1) < 1e-4)
    }

    @Test(
        "Stronger compression and expansion remain positive across cell crossings",
        arguments: [-100.0, 100.0])
    func strongerMotion(speed: Double) throws {
        let run = try PrescribedPistonTube.run(
            cellLength: 0.05, area: 0.01,
            length: speed < 0 ? 0.655 : 0.355, pistonVelocity: speed, duration: 0.003,
            cfl: 0.2, reconstruction: .minmod)
        let amount = run.cells.reduce(SIMD8<Double>.zero) { $0 + $1.amount }
        #expect(run.cells.allSatisfy { $0.amount[0] > 0 && $0.pressure() > 0 })
        #expect(abs(amount[0] / run.initialAmount[0] - 1) < 1e-11)
        #expect(abs(amount[4] - run.initialAmount[4] + run.wallWork) < 1e-8)
        #expect(simd_length(SIMD3(amount[1], amount[2], amount[3]) + run.wallImpulse) < 1e-11)
    }
    @Test("Limited two-stage waves reduce finest-grid analytical pressure error")
    func analyticalImprovement() throws {
        let baseline = try ExperimentalPistonWaveStudy.run()
        let limited = try ExperimentalPistonWaveStudy.run(limited: true)
        for speed in [-20.0, 20.0] {
            for cfl in [0.4, 0.2] {
                let a = try #require(
                    baseline.first { $0.cellLength == 0.0125 && $0.cfl == cfl && $0.pistonVelocity == speed })
                let b = try #require(
                    limited.first { $0.cellLength == 0.0125 && $0.cfl == cfl && $0.pistonVelocity == speed })
                #expect(b.frames.last!.relativePressureL1 < 0.6 * a.frames.last!.relativePressureL1)
                for frame in b.frames {
                    #expect(abs(frame.relativeMassChange) < 1e-11)
                    #expect(abs(frame.energyBudgetResidual) < 1e-9)
                }
            }
        }
    }
    @Test("Nonuniform-cell traces stay between neighbouring positive primitive states")
    func boundedTraces() throws {
        let cells = [0.001, 0.00025, 0.001].enumerated().map {
            FractionalGasTransport.Cell(volume: $1, density: Double($0 + 1), pressure: Double(($0 + 1) * 10))
        }
        let faces = LimitedTubeFlux.faces(cells, area: 0.01)
        let left = try #require(faces[0].rightState)
        let right = try #require(faces[1].leftState)
        #expect(left.pressure() >= 10 && left.pressure() <= 20)
        #expect(right.pressure() >= 20 && right.pressure() <= 30)
        #expect(left.amount[0] > 0 && right.amount[0] > 0)
        #expect(right.pressure() > left.pressure())
    }
    @Test("A resting closed tube remains uniform under reconstructed two-stage updates")
    func uniformRest() throws {
        let old = [0.001, 0.00025, 0.001].map {
            FractionalGasTransport.Cell(volume: $0, density: 1.225, pressure: 101325)
        }
        let walls = [
            FractionalEulerFlux.Wall(cell: 0, normal: SIMD3(-1, 0, 0), area: 0.01),
            .init(cell: 2, normal: SIMD3(1, 0, 0), area: 0.01),
        ]
        let dt =
            try FractionalEulerFlux.maximumStep(
                old, faces: LimitedTubeFlux.faces(old, area: 0.01), walls: walls) / 2
        let result = try LimitedTubeFlux.advance(old, area: 0.01, walls: walls, duration: dt, cfl: 0.4)
        for n in old.indices {
            #expect(abs(result.cells[n].pressure() / 101325 - 1) < 1e-12)
            for axis in 0..<5 { #expect(abs(result.cells[n].amount[axis] - old[n].amount[axis]) < 1e-12) }
        }
        #expect(result.wallWork.reduce(0, +) == 0)
    }
    @Test("Reconstructed piston crossings conserve gas/wall budgets", arguments: [-20.0, 20.0])
    func crossingBudgets(speed: Double) throws {
        let run = try PrescribedPistonTube.run(
            cellLength: 0.05, area: 0.01,
            length: speed < 0 ? 0.655 : 0.355, pistonVelocity: speed, duration: 0.015, reconstruction: .minmod
        )
        let after = run.cells.reduce(SIMD8<Double>.zero) { $0 + $1.amount }
        #expect(abs(after[0] / run.initialAmount[0] - 1) < 1e-11)
        #expect(abs(after[4] - run.initialAmount[4] + run.wallWork) < 1e-8)
        #expect(simd_length(SIMD3(after[1], after[2], after[3]) + run.wallImpulse) < 1e-11)
        #expect(run.cells.allSatisfy { $0.pressure() > 0 })
    }
}
