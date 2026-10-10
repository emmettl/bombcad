import Foundation
import Testing

@testable import BlastCore

@Suite("Released shared wall reference compatibility")
struct SharedWallReferenceTests {
    @Test("App bridge adopts the independently verified near-isothermal limit")
    func nearIsothermal() throws {
        let wall = try IdealGasWallRiemann.solve(
            density: 1, pressure: 1, normalVelocity: -0.2, gamma: (1.0).nextUp)
        #expect(abs(wall.pressure - exp(-0.2)) < 1e-12)
        #expect(!wall.vacuum)
    }

    @Test("Invalid and unrepresentable states retain the app failure category")
    func failures() {
        #expect(throws: IdealGasWallRiemann.Failure.self) {
            try IdealGasWallRiemann.solve(density: 0, pressure: 1, normalVelocity: 0)
        }
        #expect(throws: IdealGasWallRiemann.Failure.self) {
            try IdealGasWallRiemann.solve(
                density: 1, pressure: .greatestFiniteMagnitude, normalVelocity: 0)
        }
        let gamma = 1.001
        let retreat = -0.9 * 2 * sqrt(gamma) / (gamma - 1)
        #expect(throws: IdealGasWallRiemann.Failure.self) {
            try IdealGasWallRiemann.solve(density: 1, pressure: 1, normalVelocity: retreat, gamma: gamma)
        }
    }
}
