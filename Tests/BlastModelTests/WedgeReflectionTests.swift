import Foundation
import Testing

@testable import BlastModel

/// A plane shock on a slope: the theory, and the air solver against it.
@Suite("Wedge reflection")
struct WedgeReflectionTests {
    private let degrees = 180 / Double.pi

    @Test("Two-shock theory: normal-shock limits and the transition angles")
    func theory() throws {
        typealias T = ShockReflectionTheory
        let behind = T.behindNormalShock(shock: 2, density: 1.225, pressure: 101_325)
        #expect(abs(behind.pressure / 101_325 - 4.5) < 1e-12)
        #expect(abs(behind.density / 1.225 - 8.0 / 3) < 1e-12)
        // Mach 2 gives the largest deflection 23.0° (the standard oblique-shock tables).
        #expect(abs(T.maximumDeflection(mach: 2).deflection * degrees - 22.97) < 0.02)
        // Regular reflection at a wall nearly square to the shock approaches normal reflection,
        // 15 times the pressure ahead for Mach 2.
        #expect(abs(try #require(T.regularReflectionPressure(shock: 2, wedge: 89.9 / degrees)) - 15) < 0.01)
        let detachment = T.transitionWedge(shock: 2) * degrees
        let sonic = T.transitionWedge(shock: 2, sonic: true) * degrees
        #expect(abs(detachment - 50.59) < 0.01 && abs(sonic - 50.77) < 0.01)
        // Weak shocks reflect regularly down to ever smaller wedges, as sound does.
        #expect(T.transitionWedge(shock: 1.01) * degrees < 16)
        #expect(T.triplePointAngle(shock: 2, wedge: 55 / degrees) == nil)
        #expect(abs(try #require(T.triplePointAngle(shock: 2, wedge: 30 / degrees)) * degrees - 8.50) < 0.01)
    }
}
