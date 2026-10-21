import Testing

@testable import BlastModel

struct AcousticPhaseReferenceTests {
    @Test func rigidWallAndTravel() {
        let wave = AcousticPhaseReference(amplitude: 1)
        #expect(wave.velocity(x: 0, time: 7.5 / wave.soundSpeed) == 0)
        #expect(abs(wave.pressure(x: 0, time: 7.5 / wave.soundSpeed) - 2) < 1e-14)
        #expect(abs(wave.pressure(x: 4, time: 3.5 / wave.soundSpeed) - 1) < 1e-14)
        #expect(abs(wave.pressure(x: 4, time: 11.5 / wave.soundSpeed) - 1) < 1e-14)
        #expect(wave.pressure(x: 4, time: 4.5 / wave.soundSpeed) < 0)
        #expect(wave.firstImpulse(x: 0.75) == nil)
    }

    @Test func closedFormImpulseMatchesIntegratedPositiveLobe() throws {
        let wave = AcousticPhaseReference(amplitude: 10)
        for x in [0.0, 0.03125, 0.0625, 4.0625] {
            let end = (x < 0.5 ? 8 : 8 - x) / wave.soundSpeed
            let count = 100_000
            let dt = end / Double(count)
            let integral = (0..<count).reduce(0.0) { sum, i in
                sum + max(0, wave.pressure(x: x, time: (Double(i) + 0.5) * dt)) * dt
            }
            // Midpoint quadrature convergence, independently of the closed-form implementation.
            #expect(abs(integral - (try #require(wave.firstImpulse(x: x)))) < 1e-9)
        }
    }
}
