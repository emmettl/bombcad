import Testing
import simd

@testable import BlastCore

@Suite("Fractional gas transport reference")
struct FractionalGasTransportTests {
    @Test("Transport uses frozen donor states independently of face traversal order")
    func faceOrder() throws {
        let old = [
            FractionalGasTransport.Cell(volume: 0.1, density: 2, pressure: 200000),
            .init(volume: 0.1, density: 1, pressure: 100000),
            .init(volume: 0.1, density: 0.5, pressure: 50000),
        ]
        let faces = [
            FractionalGasTransport.Transfer(from: 0, to: 1, volume: 0.04),
            .init(from: 1, to: 2, volume: 0.04),
        ]
        let a = try FractionalGasTransport.advance(old, newVolumes: [0.06, 0.1, 0.14], transfers: faces)
        let b = try FractionalGasTransport.advance(
            old, newVolumes: [0.06, 0.1, 0.14], transfers: faces.reversed())
        for cell in a.indices {
            for axis in 0..<5 { #expect(abs(a[cell].amount[axis] - b[cell].amount[axis]) < 1e-10) }
        }
        #expect(abs(a[2].amount[0] - (old[2].amount[0] + 0.04)) < 1e-12)
    }
    @Test("Pressure work converges to adiabatic compression while conserving mass and energy budgets")
    func compression() throws {
        let results = try ExperimentalFractionalGasStudy.run()
        for r in results {
            #expect(abs(r.massChange) < 1e-12)
            #expect(abs(r.energyBudgetResidual) < 1e-8)
            #expect(abs(r.bodyWallWork + r.gasWallWork) < 1e-12)
            #expect(r.pressure > 101325 && r.finalVolume == 0.9)
        }
        for n in 1..<results.count {
            #expect(abs(results[n].relativePressureError) < abs(results[n - 1].relativePressureError))
        }
        #expect(abs(results.last!.relativePressureError) < 1e-4)
    }

    @Test("Tiny opening cells receive finite positive conserved gas without a density floor")
    func tinyVolume() throws {
        for volume in [2e-8, 2e-12] {
            let old = [volume, 0.08, 0].map {
                FractionalGasTransport.Cell(volume: $0, density: 1.225, pressure: 101325)
            }
            let new = try FractionalGasTransport.advance(
                old, newVolumes: [0, 0.08, volume],
                transfers: [.init(from: 0, to: 1, volume: volume), .init(from: 1, to: 2, volume: volume)])
            #expect(abs(new[2].amount[0] / volume - 1.225) < 1e-12)
            #expect(abs(new[2].pressure() - 101325) < 1e-8)
            #expect(new[0].amount == .zero)
        }
    }
    @Test("Balanced prescribed transfers preserve a uniform field while cells close and open")
    func uniformField() throws {
        let velocity = SIMD3<Double>(1, 2, 3)
        let old = [0.02, 0.08, 0].map {
            FractionalGasTransport.Cell(volume: $0, density: 1.225, velocity: velocity, pressure: 101325)
        }
        let new = try FractionalGasTransport.advance(
            old, newVolumes: [0, 0.08, 0.02],
            transfers: [.init(from: 0, to: 1, volume: 0.02), .init(from: 1, to: 2, volume: 0.02)])
        #expect(new[0].amount == .zero)
        for cell in new where cell.volume > 0 {
            #expect(abs(cell.amount[0] / cell.volume - 1.225) < 1e-12)
            #expect(simd_length(cell.velocity - velocity) < 1e-12)
            #expect(abs(cell.pressure() - 101325) < 1e-8)
        }
        let before = old.reduce(SIMD8<Double>.zero) { $0 + $1.amount }
        let after = new.reduce(SIMD8<Double>.zero) { $0 + $1.amount }
        for axis in 0..<5 { #expect(abs(before[axis] - after[axis]) < 1e-10) }
    }
    @Test("Nonuniform transport and wall loads conserve the extensive impulse/energy budget")
    func extensiveBudget() throws {
        let old = [
            FractionalGasTransport.Cell(volume: 0.1, density: 2, velocity: SIMD3(1, 2, 0), pressure: 200000),
            .init(volume: 0.1, density: 1, velocity: SIMD3(-2, 0, 1), pressure: 100000),
        ]
        let impulse = SIMD3<Double>(0.01, -0.02, 0.03)
        let new = try FractionalGasTransport.advance(
            old, newVolumes: [0.07, 0.13],
            transfers: [.init(from: 0, to: 1, volume: 0.03)],
            walls: [.init(cell: 1, impulse: impulse, gasWork: 10)])
        let difference =
            new.reduce(SIMD8<Double>.zero) { $0 + $1.amount }
            - old.reduce(SIMD8<Double>.zero) { $0 + $1.amount }
        #expect(abs(difference[0]) < 1e-12)
        #expect(simd_length(SIMD3(difference[1], difference[2], difference[3]) - impulse) < 1e-12)
        #expect(abs(difference[4] - 10) < 1e-8)
    }
    @Test("Overdrawing a donor, leaving gas in a dry cell and negative internal energy are rejected")
    func rejectsInvalidUpdates() throws {
        let old = [
            FractionalGasTransport.Cell(volume: 0.1, density: 1.225, pressure: 101325),
            .init(volume: 0.1, density: 1.225, pressure: 101325),
        ]
        #expect(throws: FractionalGasTransport.Failure.self) {
            try FractionalGasTransport.advance(
                old, newVolumes: [0.1, 0.1], transfers: [.init(from: 0, to: 1, volume: 0.11)])
        }
        #expect(throws: FractionalGasTransport.Failure.self) {
            try FractionalGasTransport.advance(old, newVolumes: [0, 0.2], transfers: [])
        }
        #expect(throws: FractionalGasTransport.Failure.self) {
            try FractionalGasTransport.advance(
                old, newVolumes: [0.1, 0.1], transfers: [],
                walls: [.init(cell: 0, impulse: SIMD3(1000, 0, 0), gasWork: 0)])
        }
    }
}
