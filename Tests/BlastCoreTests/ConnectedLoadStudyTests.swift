import Testing
import simd

@testable import BlastCore

@Suite("Grouped held-box pressure loads")
struct ConnectedLoadStudyTests {
    @Test("A pressure pulse loads the held box while closing gas and wall budgets")
    func pulseBudgets() throws {
        let results = try ExperimentalConnectedLoadStudy.run(cellSizes: [0.2])
        #expect(results.count == 2)
        for r in results {
            #expect(r.bodyImpulse.x > 0.1)
            #expect(simd_length(r.bodyAngularImpulse) > 0.001)
            #expect(simd_length(r.domainImpulse) > 0.01)
            #expect(simd_length(r.momentumBudgetResidual) < 1e-10)
            #expect(abs(r.relativeMassChange) < 1e-12 && abs(r.relativeEnergyChange) < 1e-12)
            #expect(r.wallWork == 0 && r.minimumPressure > 0 && r.maximumSpeed > 0.1)
        }
    }
    @Test("Uniform pressure has no net box load or flow")
    func uniformPressure() throws {
        let r = try #require(
            ExperimentalConnectedLoadStudy.run(
                cellSizes: [0.2], rotations: [0.23],
                duration: 0.00005, pulseAmplitude: 0
            ).first)
        #expect(simd_length(r.bodyImpulse) < 1e-9)
        #expect(simd_length(r.bodyAngularImpulse) < 1e-9)
        #expect(r.maximumSpeed < 1e-8)
        #expect(r.wallWork == 0)
    }
}
