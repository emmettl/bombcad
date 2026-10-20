import BlastCore
import BlastRender
import Foundation
import Testing
import simd

@testable import BombCAD

/// Clicking a building in the view selects it for the sidebar's inspector, near or far, once there
/// is a judgement to show.
@MainActor
@Suite("Envelope picking", .serialized)
struct EnvelopePickingTests {
    @Test("A click picks the building under it, the scene's or the far set's, and outlines it")
    func picks() async throws {
        var scene = Scenario(
            name: "Picking", domainSize: SIMD3(100, 40, 20), boxes: [],
            charge: Charge(mass: 5, position: SIMD3(10, 20, 0.5)))
        let near = try scene.addEnvelopeObject(
            BuildingEnvelope(solids: [Box(min: SIMD3(40, 15, 0), max: SIMD3(50, 25, 9))]), name: "Near")
        var construction = EnvelopeConstruction(objectID: near, source: .user, detail: "glazed")
        construction.glazing = .apartments
        scene.setEnvelopeConstruction(construction)
        let farID = UUID()
        let farBox = Box(min: SIMD3(150, 15, 0), max: SIMD3(160, 25, 30))
        var document = ProjectDocument(scenario: scene)
        document.runSettings?.resolution = "coarse"
        document.farField = FarFieldSet(
            handoverM: 80,
            buildings: [.init(id: farID, name: "Far", envelope: try BuildingEnvelope(solids: [farBox]))],
            constructions: [], terrain: nil)
        let model = SimulationModel(document: document)
        // The view zooms out far enough to see the far building: three times its square about the domain.
        #expect(model.farthestZoom >= 3 * 2 * (160 - 50))
        func click(at target: SIMD3<Float>) {
            model.camera = OrbitCamera(target: target, distance: 60, azimuth: -2.6, elevation: 0.5)
            model.click(ndc: .zero, aspectRatio: 1)
        }
        // Nothing judged yet: nothing to inspect.
        click(at: SIMD3(45, 20, 4))
        #expect(model.inspectedEnvelope == nil)
        model.quickEstimate()
        while model.estimatingEnvelopeDamage { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!model.envelopeDamage.isEmpty)
        click(at: SIMD3(45, 20, 4))
        #expect(model.inspectedEnvelope == near)
        #expect(model.inspectedEnvelopeBuilding?.far == false)
        #expect(model.highlightedBox == Box(min: SIMD3(40, 15, 0), max: SIMD3(50, 25, 9)))
        // A far building: picked and outlined as one beyond the air.
        click(at: SIMD3(155, 20, 20))
        #expect(model.inspectedEnvelope == farID)
        #expect(
            model.inspectedEnvelopeBuilding?.name == "Far" && model.inspectedEnvelopeBuilding?.far == true)
        #expect(model.highlightedBox == farBox)
        // The sky: nothing.
        model.camera = OrbitCamera(target: SIMD3(45, 20, 200), distance: 10, azimuth: -2.6, elevation: 1.4)
        model.click(ndc: SIMD2(0, 0.9), aspectRatio: 1)
        #expect(model.inspectedEnvelope == nil)
    }
}
