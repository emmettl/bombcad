import Testing
import simd

@testable import BlastCore

@Suite("Grouped held-box pressure loads")
struct ConnectedLoadStudyTests {
    @Test("Matched-energy initialization is identical across timestep settings and grids")
    func matchedEnergy() throws {
        let results = try ExperimentalConnectedLoadStudy.run(
            cellSizes: [0.2, 0.1], rotations: [0],
            duration: 0.00005, cfls: [0.2, 0.1], targetPulseEnergy: 6400)
        #expect(results.count == 4)
        for r in results {
            #expect(abs(r.pulseEnergy / 6400 - 1) < 1e-12)
            let background = 101325 / (1.4 - 1) * r.initialMass / 1.225
            #expect(abs(r.initialEnergy - background - 6400) < 1e-7)
            #expect(abs(r.relativeMassChange) < 1e-12 && abs(r.relativeEnergyChange) < 1e-12)
            #expect(simd_length(r.momentumBudgetResidual) < 1e-10)
        }
        for h in [0.2, 0.1] {
            let large = try #require(results.first { $0.cellSize == h && $0.cfl == 0.2 })
            let small = try #require(results.first { $0.cellSize == h && $0.cfl == 0.1 })
            #expect(
                large.initialEnergy == small.initialEnergy && large.pulseAmplitude == small.pulseAmplitude)
            #expect(small.steps > large.steps)
        }
    }
    @Test("Invalid timestep and energy configurations fail before running")
    func invalidConfiguration() throws {
        #expect(throws: ExperimentalConnectedLoadStudy.Failure.self) {
            try ExperimentalConnectedLoadStudy.run(cfls: [0.6])
        }
        #expect(throws: ExperimentalConnectedLoadStudy.Failure.self) {
            try ExperimentalConnectedLoadStudy.run(targetPulseEnergy: -1)
        }
    }
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
