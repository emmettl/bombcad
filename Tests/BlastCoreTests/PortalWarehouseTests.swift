import Foundation
import Metal
import Testing
import simd

@testable import BlastCore
@testable import BlastModel

/// The portal-frame warehouse sample (`ScenarioPreset.portalWarehouse`): its frames, purlins, rails
/// and profiled sheeting meshed as shells and run in the air.
@Suite("Portal-frame warehouse", .gpuThreads)
struct PortalWarehouseTests {
    @Test("The warehouse runs in the air: its time step reasonable, its front gable pushed in")
    func runs() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let scenario = ScenarioPreset.portalWarehouse.scenario
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.5)
        let shells = try #require(solver.shells)
        print("Warehouse shell step \(shells.criticalTimeStep * 1e6) µs")
        #expect(shells.criticalTimeStep > 5e-6)
        // The wave reaches the front gable, 30 m off, at about 50 ms.
        solver.advance(until: 0.09)
        let front = shells.nearestNode(to: SIMD3(35, 40, 4))
        let push = shells.node(front).displacement.y
        print(
            "Front gable's middle moved \(push * 1000) mm; \(shells.linksReleased) of \(shells.linkCount) screw links let go"
        )
        #expect(push.isFinite && push > 0.001)
        #expect(shells.linkCount > 1000)
    }
}
