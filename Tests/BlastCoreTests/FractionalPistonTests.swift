import Testing
import simd

@testable import BlastCore

@Suite("Prescribed fractional piston motion")
struct FractionalPistonTests {
    @Test("Closed-tube pressure approaches the quasi-static limit as piston speed decreases")
    func quasiStaticLimit() throws {
        let results = try ExperimentalPistonStudy.run()
        for r in results {
            #expect(abs(r.volumeResidual) < 1e-14)
            #expect(abs(r.relativeMassChange) < 1e-12)
            #expect(abs(r.energyBudgetResidual) < 1e-9)
            #expect(simd_length(r.momentumBudgetResidual) < 1e-12)
            #expect(abs(r.relativeQuasiStaticPressureError) < 1e-4)
        }
        for sign in [-1.0, 1.0] {
            let fast = try #require(results.first { $0.pistonVelocity == sign })
            let slow = try #require(results.first { $0.pistonVelocity == sign * 0.25 })
            #expect(
                abs(slow.relativeQuasiStaticPressureError) < 0.4 * abs(fast.relativeQuasiStaticPressureError))
        }
    }
    @Test(
        "Compression and expansion use matched swept volume, impulse and wall work", arguments: [-1.0, 1.0])
    func pressureWork(speed: Double) throws {
        let initial = FractionalGasTransport.Cell(volume: 0.001, density: 1.225, pressure: 101325)
        let walls = [
            FractionalEulerFlux.Wall(cell: 0, normal: SIMD3(-1, 0, 0), area: 0.01),
            .init(cell: 0, normal: SIMD3(1, 0, 0), area: 0.01, velocity: SIMD3(speed, 0, 0)),
        ]
        let step = try FractionalEulerFlux.maximumStep([initial], faces: [], walls: walls)
        let result = try FractionalEulerFlux.advanceWithWalls(
            [initial], faces: [], walls: walls, duration: step)
        let gas = result.cells[0]
        #expect(abs(gas.volume - (initial.volume + 0.01 * speed * step)) < 1e-16)
        #expect(gas.amount[0] == initial.amount[0])
        #expect(abs(gas.amount[4] - initial.amount[4] + result.wallWork.reduce(0, +)) < 1e-12)
        let momentum = SIMD3(gas.amount[1], gas.amount[2], gas.amount[3])
        #expect(simd_length(momentum + result.wallImpulses.reduce(.zero, +)) < 1e-12)
        #expect(result.wallWork[1] * speed > 0)
        #expect(abs(result.wallWork[1] - speed * result.wallImpulses[1].x) < 1e-14)
        #expect(speed < 0 ? gas.pressure() > initial.pressure() : gas.pressure() < initial.pressure())
    }

    @Test("A translating cavity and comoving uniform gas preserve volume and gas state")
    func translatingCavity() throws {
        let velocity = SIMD3<Double>(4, 2, 0)
        let old = FractionalGasTransport.Cell(
            volume: 0.001, density: 1.225, velocity: velocity, pressure: 101325)
        let walls = [
            FractionalEulerFlux.Wall(cell: 0, normal: SIMD3(-1, 0, 0), area: 0.01, velocity: velocity),
            .init(cell: 0, normal: SIMD3(1, 0, 0), area: 0.01, velocity: velocity),
        ]
        let step = try FractionalEulerFlux.maximumStep([old], faces: [], walls: walls)
        let result = try FractionalEulerFlux.advanceWithWalls([old], faces: [], walls: walls, duration: step)
        #expect(abs(result.cells[0].volume - old.volume) < 1e-16)
        for axis in 0..<5 { #expect(abs(result.cells[0].amount[axis] - old.amount[axis]) < 1e-12) }
        #expect(result.wallWork.reduce(0, +) == 0)
    }
}
