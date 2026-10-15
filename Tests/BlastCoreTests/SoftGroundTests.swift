import Foundation
import Metal
import Testing

@testable import BlastCore

/// `SolverConfiguration.groundStiffness` reaches each structure's solid elements when a scene loads.
@Suite("Soft ground in the configuration")
struct SoftGroundConfigurationTests {
    @Test("The hard ground by default; soil's modulus when chosen")
    func applied() throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
        let scene = ScenarioPreset.blastWall.scenario
        let hard = try BlastSolver(device: device, scenario: scene, cellSize: 0.5)
        #expect(hard.structure?.groundStiffness == 0)
        var configuration = SolverConfiguration()
        configuration.groundStiffness = SolverConfiguration.soilSubgradeModulus
        let soft = try BlastSolver(
            device: device, scenario: scene, cellSize: 0.5, configuration: configuration)
        #expect(soft.structure?.groundStiffness == SolverConfiguration.soilSubgradeModulus)
        #expect(SolverConfiguration.soilSubgradeRange.contains(SolverConfiguration.soilSubgradeModulus))
    }
}
