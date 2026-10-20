import BlastCore
import BlastRender
import Foundation
import Testing
import simd

@testable import BombCAD

/// Dragging the charge in the view with a quick estimate on screen (emmettl/bombcad-work#34): the
/// charge follows the pointer, the scene is loaded again only once it is let go, the estimate
/// follows as a preview of the colouring shown and is then made in full where it stopped.
@MainActor
@Suite("Dragging the charge", .serialized)
struct ChargeDragTests {
    @Test("The estimate follows the dragged charge as a preview, then in full where it is let go")
    func follows() async throws {
        var scene = Scenario(
            name: "Drag", domainSize: SIMD3(120, 60, 20), boxes: [],
            charge: Charge(mass: 50, position: SIMD3(20, 30, 0.5)))
        for x: Float in [50, 80] {
            let id = try scene.addEnvelopeObject(
                BuildingEnvelope(solids: [Box(min: SIMD3(x, 22, 0), max: SIMD3(x + 10, 38, 9))]))
            var construction = EnvelopeConstruction(objectID: id, source: .user, detail: "glazed")
            construction.glazing = .apartments
            scene.setEnvelopeConstruction(construction)
        }
        var document = ProjectDocument(scenario: scene)
        document.runSettings?.resolution = "coarse"
        let model = SimulationModel(document: document)
        func settle() async throws {
            while model.estimatingEnvelopeDamage || model.isLoadingInputs {
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        try await settle()
        model.quickEstimate()
        try await settle()
        #expect(model.envelopeDamageIsEstimate && !model.envelopeEstimateIsPreview)
        let before = model.envelopeLoads.map(\.outerPa)
        let edits = model.undoStack.count

        // Looking straight down, the middle of the view is the camera's target on the ground.
        func look(at x: Float) {
            model.camera = OrbitCamera(target: SIMD3(x, 30, 0), distance: 80, azimuth: -1.57, elevation: 1.5)
        }
        model.isPlacingCharge = true
        look(at: 22)
        #expect(model.beginDrag(ndc: .zero, aspectRatio: 1, modifiers: []))
        #expect(model.isDraggingCharge)
        for x: Float in [26, 30, 34] {
            look(at: x)
            model.drag(ndc: .zero, aspectRatio: 1, modifiers: [])
            #expect(abs(model.settings.chargePosition.x - x) < 0.3)
        }
        // While dragging the scene is not loaded again, and the estimate shown is a preview.
        while model.estimatingEnvelopeDamage { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.envelopeEstimateIsPreview)
        #expect(model.envelopeDamageStatus.hasPrefix("Preview while dragging"))
        #expect(model.undoStack.count == edits)

        model.endDrag()
        #expect(!model.isDraggingCharge)
        try await Task.sleep(for: .milliseconds(300))
        try await settle()
        // In full where it was let go, as a quick estimate there gives it, and one edit recorded.
        #expect(model.envelopeDamageIsEstimate && !model.envelopeEstimateIsPreview)
        #expect(model.undoStack.count == edits + 1)
        var moved = scene
        moved.charge.position = model.settings.chargePosition
        let estimate = FacadeLoadSurrogate.estimate(
            scene: moved, cellSize: model.settings.resolution.cellSize)
        let (expected, _, _) = FacadeLoadSurrogate.damage(
            estimate, constructions: { moved.envelopeConstruction(for: $0) })
        #expect(model.envelopeDamage.map(\.panesBroken) == expected.map(\.panesBroken))
        #expect(model.envelopeLoads.map(\.outerPa) == estimate.loads.map(\.outerPa))
        #expect(model.envelopeLoads.map(\.outerPa) != before)
    }
}
