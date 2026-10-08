import Foundation
import Testing

@testable import BlastCore

@Suite("Exact ideal-gas wall pressure")
struct IdealGasWallRiemannTests {
    @Test("Compression satisfies the shock jump relation")
    func compression() throws {
        let density = 1.225
        let pressure = 101325.0
        for speed in [0.001, 10.0, 100.0, 1000.0] {
            let result = try IdealGasWallRiemann.solve(
                density: density, pressure: pressure, normalVelocity: speed)
            let a = 2 / (2.4 * density)
            let b = 0.4 / 2.4 * pressure
            let recovered = (result.pressure - pressure) * sqrt(a / (result.pressure + b))
            #expect(abs(recovered - speed) < 1e-9)
            #expect(result.pressure > pressure && !result.vacuum)
        }
    }
    @Test("Expansion satisfies the rarefaction invariant and reaches vacuum")
    func expansion() throws {
        let sound = sqrt(1.4)
        let cutoff = -2 * sound / 0.4
        for fraction in [0.1, 0.5, 0.99] {
            let speed = cutoff * fraction
            let result = try IdealGasWallRiemann.solve(density: 1, pressure: 1, normalVelocity: speed)
            let recovered = 2 * sound / 0.4 * (pow(result.pressure, 0.4 / 2.8) - 1)
            #expect(abs(recovered - speed) < 1e-12)
            #expect(result.pressure > 0 && result.pressure < 1 && !result.vacuum)
        }
        let vacuum = try IdealGasWallRiemann.solve(density: 1, pressure: 1, normalVelocity: cutoff * 1.01)
        #expect(vacuum.pressure == 0 && vacuum.vacuum)
    }
    @Test("Rest and weak waves agree with static pressure and acoustic impedance")
    func acousticLimit() throws {
        let rest = try IdealGasWallRiemann.solve(density: 1.225, pressure: 101325, normalVelocity: 0)
        #expect(rest.pressure == 101325)
        let plus = try IdealGasWallRiemann.solve(density: 1.225, pressure: 101325, normalVelocity: 0.001)
        let minus = try IdealGasWallRiemann.solve(density: 1.225, pressure: 101325, normalVelocity: -0.001)
        let derivative = (plus.pressure - minus.pressure) / 0.002
        #expect(abs(derivative / (1.225 * rest.signalSpeed) - 1) < 1e-8)
    }
}
