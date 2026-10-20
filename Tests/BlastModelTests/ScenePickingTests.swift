import Foundation
import Testing
import simd

@testable import BlastModel

/// Clicking a building in the view (`ScenePicking.envelope`): the scene's envelopes and its far set's.
@Suite("Picking envelopes")
struct ScenePickingTests {
    /// A low block, an envelope behind it along +x, and a far building beyond both.
    static func scene() throws -> (scene: Scenario, far: FarFieldSet, near: UUID, farID: UUID) {
        var scene = Scenario(
            name: "Picking", domainSize: SIMD3(100, 40, 20),
            boxes: [Box(min: SIMD3(10, 15, 0), max: SIMD3(12, 25, 3))],
            charge: Charge(mass: 1, position: SIMD3(2, 20, 0.5)))
        let near = try scene.addEnvelopeObject(
            BuildingEnvelope(solids: [Box(min: SIMD3(40, 15, 0), max: SIMD3(50, 25, 9))]), name: "Near")
        let farID = UUID()
        let far = FarFieldSet(
            handoverM: 80,
            buildings: [
                .init(
                    id: farID, name: "Far",
                    envelope: try BuildingEnvelope(solids: [
                        Box(min: SIMD3(150, 15, 0), max: SIMD3(160, 25, 30))
                    ]))
            ], constructions: [], terrain: nil)
        return (scene, far, near, farID)
    }

    @Test("The nearest building along the ray, near or far; a block in the way hides what lies behind it")
    func picks() throws {
        let (scene, far, near, farID) = try Self.scene()
        let east = SIMD3<Float>(1, 0, 0)
        // Over the block, into the near building.
        #expect(ScenePicking.envelope(in: scene, far: far, origin: SIMD3(0, 20, 4), direction: east) == near)
        // Above the near building's roof, on to the far one.
        #expect(
            ScenePicking.envelope(in: scene, far: far, origin: SIMD3(0, 20, 20), direction: east) == farID)
        // Without the far set, nothing there.
        #expect(ScenePicking.envelope(in: scene, origin: SIMD3(0, 20, 20), direction: east) == nil)
        // Lower, the block first.
        #expect(ScenePicking.envelope(in: scene, far: far, origin: SIMD3(0, 20, 2), direction: east) == nil)
    }
}
