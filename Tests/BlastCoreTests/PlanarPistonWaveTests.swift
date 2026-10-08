import Testing
import simd

@testable import BlastCore

@Suite("Analytical planar piston waves")
struct PlanarPistonWaveTests {
    @Test("Four-grid numerical profiles reduce pressure error against analytical cell averages")
    func gridStudy() throws {
        let results = try ExperimentalPistonWaveStudy.run()
        #expect(results.count == 16)
        for speed in [-20.0, 20.0] {
            for cfl in [0.4, 0.2] {
                let coarse = try #require(
                    results.first { $0.cellLength == 0.1 && $0.cfl == cfl && $0.pistonVelocity == speed })
                let fine = try #require(
                    results.first { $0.cellLength == 0.0125 && $0.cfl == cfl && $0.pistonVelocity == speed })
                #expect(fine.frames.count == 2)
                for n in fine.frames.indices {
                    #expect(fine.frames[n].relativePressureL1 < 0.7 * coarse.frames[n].relativePressureL1)
                    #expect(abs(fine.frames[n].relativeWallWorkError) < 0.001)
                    #expect(abs(fine.frames[n].relativeMassChange) < 1e-12)
                    #expect(abs(fine.frames[n].energyBudgetResidual) < 1e-9)
                }
            }
        }
    }
    @Test(
        "Shock and rarefaction cell averages satisfy closed mass, momentum and work budgets",
        arguments: [-100.0, -20.0, 20.0, 100.0])
    func budgets(speed: Double) throws {
        let length = 0.655
        let time = 0.0008
        let area = 0.01
        let wave = try PlanarPistonWave(length: length, density: 1.225, pressure: 101325, velocity: speed)
        let end = length + speed * time
        var sum = SIMD8<Double>.zero
        for n in 0..<17 {
            sum += try wave.cell(
                lower: end * Double(n) / 17, upper: end * Double(n + 1) / 17,
                time: time, area: area
            ).amount
        }
        #expect(abs(sum[0] / (1.225 * area * length) - 1) < 1e-12)
        #expect(abs(sum[1] + area * (wave.wallPressure - 101325) * time) < 1e-12)
        #expect(abs(sum[4] - 101325 / 0.4 * area * length + area * wave.wallPressure * speed * time) < 1e-9)
        let whole = try wave.cell(lower: 0, upper: end, time: time, area: area)
        for axis in 0..<5 { #expect(abs(sum[axis] - whole.amount[axis]) < 1e-9) }
    }

    @Test("The shock jump satisfies mass and momentum conditions")
    func shockJump() throws {
        let w = try PlanarPistonWave(length: 1, density: 1.225, pressure: 101325, velocity: -100)
        #expect(abs(w.density * w.shockSpeed - w.starDensity * (w.shockSpeed + w.velocity)) < 1e-10)
        #expect(abs(w.wallPressure - w.pressure + w.density * w.shockSpeed * w.velocity) < 1e-8)
    }

    @Test("The reference rejects reflected waves and unsupported vacuum gaps")
    func scope() throws {
        let w = try PlanarPistonWave(length: 0.1, density: 1.225, pressure: 101325, velocity: 20)
        #expect(throws: PlanarPistonWave.Failure.self) {
            try w.cell(lower: 0, upper: 0.12, time: 0.001, area: 0.01)
        }
        #expect(throws: PlanarPistonWave.Failure.self) {
            try PlanarPistonWave(length: 1, density: 1, pressure: 1, velocity: 7)
        }
    }
}
