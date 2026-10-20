import Foundation
import Metal
import Testing
import simd

@testable import BlastCore
@testable import BlastModel

/// The transport hub sample (`ScenarioPreset.transportHub`): the train shed's frames, Vierendeel
/// trusses, purlins and glass meshed as shells and beams, and the concourse beside it an envelope
/// glazed with laminated glass.
@Suite("Transport hub", .gpuThreads)
struct TransportHubTests {
    @Test("The hub runs in the air: its time step reasonable, the shed's roof stirred")
    func runs() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let scenario = ScenarioPreset.transportHub.scenario
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.5)
        let shells = try #require(solver.shells)
        print("Hub shell step \(shells.criticalTimeStep * 1e6) µs")
        #expect(shells.criticalTimeStep > 5e-6)
        // The wave reaches the shed's open end, 20 m off, at about 25 ms.
        solver.advance(until: 0.06)
        let roof = shells.nearestNode(to: SIMD3(54, 41, 15))
        let moved = simd_length(shells.node(roof).displacement)
        print("Shed roof's front edge moved \(moved * 1000) mm")
        #expect(moved.isFinite && moved > 1e-4)
    }
}
