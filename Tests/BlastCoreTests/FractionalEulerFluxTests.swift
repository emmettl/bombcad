import Testing
import simd

@testable import BlastCore

@Suite("Stationary fractional Euler flux")
struct FractionalEulerFluxTests {
    private let faces = (0..<8).map {
        FractionalEulerFlux.Face(a: $0, b: ($0 + 1) % 8, normal: SIMD3(1, 0, 0), area: 0.01)
    }

    @Test("An identical-state interface carries analytical Euler momentum and enthalpy flux")
    func analyticalFlux() throws {
        let cells = [FractionalGasTransport.Cell](
            repeating: .init(volume: 1, density: 2, velocity: SIMD3(3, 4, 0), pressure: 10), count: 2)
        let result = try FractionalEulerFlux.advance(
            cells, faces: [.init(a: 0, b: 1, normal: SIMD3(1, 0, 0), area: 1)], duration: 0.01)
        // rho=2, u=(3,4,0), p=10, E=50: mass=6, momentum=(28,24,0), energy=180 per area/time.
        let expected = SIMD8<Double>(0.06, 0.28, 0.24, 0, 1.8, 0, 0, 0)
        for axis in 0..<5 {
            #expect(abs(cells[0].amount[axis] - result[0].amount[axis] - expected[axis]) < 1e-13)
            #expect(abs(result[1].amount[axis] - cells[1].amount[axis] - expected[axis]) < 1e-13)
        }
    }

    @Test("Uniform moving gas stays uniform across unequal periodic cell volumes")
    func uniformState() throws {
        let cells = (0..<8).map {
            FractionalGasTransport.Cell(
                volume: $0 == 0 ? 1e-6 : 0.001, density: 1.225, velocity: SIMD3(12, 3, -2),
                pressure: 101325)
        }
        let step = try FractionalEulerFlux.maximumStep(cells, faces: faces)
        let result = try FractionalEulerFlux.advance(cells, faces: faces, duration: step)
        for cell in result {
            #expect(abs(cell.pressure() / 101325 - 1) < 1e-12)
            #expect(simd_length(cell.velocity - SIMD3(12, 3, -2)) < 1e-10)
            #expect(abs(cell.amount[0] / cell.volume - 1.225) < 1e-12)
        }
    }

    @Test("Pressure-driven flow preserves global budgets and positive gas states")
    func pressurePulse() throws {
        let initial = (0..<8).map {
            FractionalGasTransport.Cell(
                volume: $0 == 0 ? 0.00001 : 0.001, density: 1.225,
                pressure: $0 == 4 ? 150000 : 101325)
        }
        var cells = initial
        for _ in 0..<100 {
            let step = try FractionalEulerFlux.maximumStep(cells, faces: faces)
            cells = try FractionalEulerFlux.advance(cells, faces: faces, duration: step)
        }
        let before = initial.reduce(SIMD8<Double>.zero) { $0 + $1.amount }
        let after = cells.reduce(SIMD8<Double>.zero) { $0 + $1.amount }
        #expect(abs(after[0] / before[0] - 1) < 1e-12)
        #expect(abs(after[4] / before[4] - 1) < 1e-12)
        for axis in 1...3 { #expect(abs(after[axis] - before[axis]) < 1e-12) }
        #expect(cells.allSatisfy { $0.amount[0] > 0 && $0.pressure() > 0 })
        #expect(cells.contains { simd_length($0.velocity) > 0.01 })
    }

    @Test("The acoustic timestep scales with the smallest volume and rejects excess duration")
    func smallCellLimit() throws {
        func cells(_ volume: Double) -> [FractionalGasTransport.Cell] {
            (0..<8).map { .init(volume: $0 == 0 ? volume : 0.001, density: 1.225, pressure: 101325) }
        }
        let large = try FractionalEulerFlux.maximumStep(cells(0.001), faces: faces)
        let small = try FractionalEulerFlux.maximumStep(cells(0.00001), faces: faces)
        #expect(abs(small / large - 0.01) < 1e-14)
        #expect(throws: FractionalEulerFlux.Failure.self) {
            try FractionalEulerFlux.advance(cells(0.00001), faces: faces, duration: small * 1.01)
        }
        #expect(throws: FractionalEulerFlux.Failure.self) {
            try FractionalEulerFlux.maximumStep(
                cells(0.001), faces: [.init(a: 0, b: 1, normal: SIMD3(2, 0, 0), area: 1)])
        }
    }
}
