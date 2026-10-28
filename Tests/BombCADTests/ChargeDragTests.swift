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
    @Test("Hazards follow the editable charge, with live stand-off crossing feedback")
    func hazardsFollow() async throws {
        var scene = Scenario(
            name: "Hazard drag", domainSize: SIMD3(120, 60, 20), boxes: [],
            charge: Charge(mass: 50, position: SIMD3(20, 30, 0.5)))
        scene.standOffLines = [
            StandOffLine(name: "Fence", points: [SIMD2(40, 0), SIMD2(40, 60)], guardsLeft: false)
        ]
        var document = ProjectDocument(scenario: scene)
        document.runSettings?.resolution = "coarse"
        let model = SimulationModel(document: document)
        while model.isLoadingInputs { try await Task.sleep(for: .milliseconds(20)) }
        let expected = BlastInjury.freeFieldRadii(kilograms: 50)
        #expect(model.previewInjuryRadii == expected)
        #expect(model.blastHazardSummary.contains { $0.contains("surface-burst reference") })
        let initial = model.blastHazardLines()
        model.isDraggingCharge = true
        model.settings.chargePosition.x = 50
        // The loaded scene stays at 20 m during a drag, but policy and injury rings move now.
        #expect(model.scenario.charge.position.x == 20)
        let moved = model.blastHazardLines()
        #expect(abs(moved[0].x - initial[0].x - 30) < 0.001)
        let lungCode = Float(HazardOverlay.Kind.lung.rawValue)
        let initialLung = try #require(initial.first { $0.w == lungCode })
        let movedLung = try #require(moved.first { $0.w == lungCode })
        #expect(abs(movedLung.x - initialLung.x - 30) < 0.001)
        #expect(abs(movedLung.x - 50 - Float(try #require(expected[.lethality50]))) < 0.001)
        #expect(moved.contains(SIMD4(40, 0, 0.4, Float(HazardOverlay.Kind.eardrum.rawValue))))
        #expect(model.blastHazardSummary.contains { $0.contains("Fence: 10.0 m") && $0.contains("inside") })
        #expect(model.settings.scenario.chargesInsideStandOff == [0])
        model.settings.scenario.additionalCharges = [Charge(mass: 10, position: SIMD3(10, 10, 0.5))]
        #expect(model.previewInjuryRadii.isEmpty)
        #expect(model.blastHazardSummary.contains { $0.contains("unavailable for multiple") })
        // Once a run starts, references disappear and the loaded scene governs the overlay.
        model.stepCount = 1
        #expect(model.previewInjuryRadii.isEmpty)
        #expect(model.hazardScenario.charge.position.x == 20)
        #expect(!model.blastHazardSummary.contains { $0.contains("Injury preview") })
    }

    @Test("The estimate takes the outline's terms unless the terms of 23, 25 or 25–28 October are chosen")
    func termToggles() throws {
        // emmettl/bombcad-work#109: the deep-city-outline terms are the default, the glass front an
        // option on them; the deep-city terms facing as the cells (25–28 October), the clear-top
        // terms of 25 October and those of 23 October stay as toggles, the earlier taking
        // precedence.
        let temporary = try TemporaryDefaults()
        defer { temporary.remove() }
        let model = SimulationModel(
            document: ProjectDocument(
                scenario: Scenario(
                    name: "Terms", domainSize: SIMD3(repeating: 4), boxes: [],
                    charge: Charge(mass: 0.01, position: SIMD3(2, 2, 1)))))
        model.learnedDefaults = temporary.defaults
        model.quickEstimateFirstFitTerms = false
        model.quickEstimateClearTopTerms = false
        model.quickEstimateCellsFacingTerms = false
        model.quickEstimateGlassFront = false
        #expect(model.surrogateTerms == .adopted && model.surrogateTerms == .deepCityOutline)
        model.quickEstimateGlassFront = true
        #expect(model.surrogateTerms == .deepCityOutlineFront)
        model.quickEstimateCellsFacingTerms = true
        #expect(model.surrogateTerms == .deepCityFront)
        #expect(temporary.defaults.bool(forKey: SimulationModel.cellsFacingTermsKey))
        model.quickEstimateGlassFront = false
        #expect(model.surrogateTerms == .deepCity)
        // A choice of the outline's candidate before its adoption does not turn the cells' on.
        #expect(SimulationModel.cellsFacingTermsKey != "quickEstimate.outlineFacing")
        model.quickEstimateGlassFront = true
        model.quickEstimateClearTopTerms = true
        #expect(model.surrogateTerms == .clearTopFront)
        model.quickEstimateGlassFront = false
        #expect(model.surrogateTerms == .clearTop)
        #expect(temporary.defaults.bool(forKey: SimulationModel.clearTopTermsKey))
        model.quickEstimateFirstFitTerms = true
        #expect(model.surrogateTerms == .fitted)
    }

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
        // The estimate alone: its close calls are refined in `closeCalls`.
        model.refinesCloseCalls = false
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

    @Test("Once the full estimate is in, its close calls are run in the air and their results shown in place")
    func closeCalls() async throws {
        var scene = Scenario(
            name: "Close calls", domainSize: SIMD3(160, 60, 20), boxes: [],
            charge: Charge(mass: 50, position: SIMD3(20, 30, 0.5)))
        for x: Float in [40, 60, 90, 120] {
            let id = try scene.addEnvelopeObject(
                BuildingEnvelope(solids: [Box(min: SIMD3(x, 22, 0), max: SIMD3(x + 10, 38, 9))]))
            var construction = EnvelopeConstruction(objectID: id, source: .user, detail: "glazed")
            construction.glazing = .apartments
            scene.setEnvelopeConstruction(construction)
        }
        var document = ProjectDocument(scenario: scene)
        document.runSettings?.resolution = "coarse"
        let model = SimulationModel(document: document)
        while model.isLoadingInputs { try await Task.sleep(for: .milliseconds(20)) }
        model.showsEnvelopeDamage = true
        // Coloured by the chance some glass breaks, with the yield known only to within ×3.
        model.envelopeColouring = .someBroken
        model.quickEstimateYieldWithin = 3
        model.quickEstimate()
        while model.estimatingEnvelopeDamage { try await Task.sleep(for: .milliseconds(20)) }
        let estimated = model.envelopeGlassChances
        #expect(model.isRefiningCloseCalls, "\(model.closeCallStatus)")
        while model.isRefiningCloseCalls { try await Task.sleep(for: .milliseconds(50)) }
        #expect(model.closeCallStatus.contains("refined by the solver"), "\(model.closeCallStatus)")
        let refined = try #require(model.closeCallRefined)
        #expect(!refined.buildings.isEmpty && model.refinedBuildings == Set(refined.buildings))
        // The refined buildings' sides are the run's; the rest still the estimate's.
        for side in model.envelopeGlassChances {
            let from = model.refinedBuildings.contains(side.owner) ? refined.glass : estimated
            #expect(from.contains(side))
        }
        #expect(Set(model.envelopeDamage.map(\.id)) == Set(scene.envelopeObjects.map(\.id)))
        #expect(model.refinedOutlines().count == 8 * refined.buildings.count)
        // A new drag is for somewhere else: the refined results go.
        model.isPlacingCharge = true
        model.camera = OrbitCamera(target: SIMD3(22, 30, 0), distance: 80, azimuth: -1.57, elevation: 1.5)
        #expect(model.beginDrag(ndc: .zero, aspectRatio: 1, modifiers: []))
        #expect(model.refinedBuildings.isEmpty && model.refinedOutlines().isEmpty)
        model.endDrag()
    }
}
