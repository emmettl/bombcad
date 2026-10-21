import BlastCore
import Foundation
import SceneRender
import simd

// Dragging the charge, with a quick estimate on screen following it (emmettl/bombcad-work#34).
extension SimulationModel {
    /// The draws a preview takes while dragging, for the glass's chances and for the walls' and
    /// roofs': fewer than a full estimate's 100, so a frame stays near a second on a large district.
    static let previewDraws = (glass: 10, structure: 20)

    /// With Place Charge on, a press on the ground takes the drag: the charge follows the pointer
    /// and, if a quick estimate is on screen, so does it, as a preview; the scene is loaded again
    /// once the charge is let go.
    func beginDrag(ndc: SIMD2<Float>, aspectRatio: Float, modifiers: DragModifiers) -> Bool {
        guard isPlacingCharge, !sweep.isActive, !isRunning, time == 0 else { return false }
        if case .gauge = selection { return false }
        guard let point = camera.groundPoint(ndc: ndc, aspectRatio: aspectRatio) else { return false }
        isDraggingCharge = true
        // A refinement under way is for where the charge was.
        cancelCloseCalls(status: "")
        closeCallRefined = nil
        refinedBuildings = []
        estimateFollowsCharge = envelopeDamageIsEstimate && !envelopeDamage.isEmpty
        moveDraggedCharge(to: point)
        return true
    }

    func drag(ndc: SIMD2<Float>, aspectRatio: Float, modifiers: DragModifiers) {
        guard isDraggingCharge, let point = camera.groundPoint(ndc: ndc, aspectRatio: aspectRatio) else {
            return
        }
        moveDraggedCharge(to: point)
    }

    func endDrag() {
        guard isDraggingCharge else { return }
        isDraggingCharge = false
        // Loaded again once, now, and recorded as one edit; the preview kept on screen meanwhile.
        restoresFollowedLook = estimateFollowsCharge
        settingsChanged()
        if estimateFollowsCharge { requestLook(preview: false) }
    }

    /// Moves the charge to `point` on the ground, snapped as a click places it; a preview follows.
    private func moveDraggedCharge(to point: SIMD3<Float>) {
        let size = settings.scenario.domainSize
        // Snap to 0.25 m so the charge stays aligned with every grid resolution.
        let snapped = (point * Float(4)).rounded(.toNearestOrEven) / Float(4)
        let x = min(max(snapped.x, 1), size.x - 1)
        let y = min(max(snapped.y, 1), size.y - 1)
        guard x != settings.chargePosition.x || y != settings.chargePosition.y else { return }
        settings.chargePosition.x = x
        settings.chargePosition.y = y
        if estimateFollowsCharge { requestLook(preview: true) }
    }

    /// What a preview works out: only what the view is coloured by.
    var previewParts: FacadeLoadSurrogate.Prepared.Parts {
        envelopeColouring.isChance ? .glass : envelopeColouring.isStructure ? .structure : .damage
    }

    /// Asks for a look at the scene with the charge where it is now: a preview while dragging,
    /// or the full estimate. One is worked out at a time, away from the main thread; while it is,
    /// only the latest place asked for waits (a full look is not displaced by a preview).
    func requestLook(preview: Bool) {
        if !preview || lookWaiting?.preview != false {
            lookWaiting = (settings.chargePosition, preview)
        }
        startWaitingLook()
    }

    private func startWaitingLook() {
        guard !lookInFlight, let waiting = lookWaiting else { return }
        lookWaiting = nil
        let scenario = settings.scenario
        let cellSize = settings.resolution.cellSize
        // The district laid out once for every place of the charge: the scene without it.
        var layout = scenario
        layout.charge.position = .zero
        let known = preparedDistrict.flatMap {
            $0.scene == layout && $0.cellSize == cellSize ? $0.prepared : nil
        }
        let parts: FacadeLoadSurrogate.Prepared.Parts = waiting.preview ? previewParts : .all
        let within = quickEstimateYieldWithin
        let draws = Self.previewDraws
        lookInFlight = true
        estimatingEnvelopeDamage = true
        if !waiting.preview { envelopeDamageStatus = "Estimating…" }
        Task { [weak self] in
            let (prepared, look) = await Task.detached(priority: .userInitiated) {
                // The previews' kept responses grow with each place: begun again past a few
                // hundred thousand.
                let prepared =
                    known.flatMap { $0.memo.misses < 400_000 ? $0 : nil }
                    ?? FacadeLoadSurrogate.Prepared(scene: scenario, cellSize: cellSize)
                // Nine times in ten within the factor: 1.645 standard deviations of its logarithm.
                let logSD = log(within) / 1.645
                let samples =
                    !waiting.preview
                    ? 100 : parts == .glass ? draws.glass : draws.structure
                var uncertainty = FacadeLoadSurrogate.Uncertainty(yieldLogSD: logSD, samples: samples)
                // A preview's few yields spread evenly, not drawn: drawn, they share one error.
                uncertainty.stratified = waiting.preview
                let look = prepared.look(
                    charge: waiting.charge, mass: Double(scenario.charge.mass),
                    constructions: { scenario.envelopeConstruction(for: $0) },
                    uncertainty: uncertainty,
                    preview: waiting.preview, parts: parts)
                return (prepared, look)
            }.value
            guard let self else { return }
            self.lookInFlight = false
            self.preparedDistrict = (layout, cellSize, prepared)
            self.estimatingEnvelopeDamage = self.lookWaiting != nil
            // Shown only for the scene as it is now, before any run.
            var now = self.settings.scenario
            now.charge.position = .zero
            if now == layout, self.settings.chargePosition == look.charge, self.stepCount == 0,
                self.settings.scenario.charge.mass == scenario.charge.mass
            {
                self.followedLook = (self.settings.scenario, look, parts)
                self.applyLook(look, parts: parts)
                if !waiting.preview { self.refineCloseCalls(look) }
            } else if !waiting.preview, self.lookWaiting == nil {
                self.envelopeDamageStatus = ""
            }
            self.startWaitingLook()
        }
    }

    /// Shows `look`: the parts it worked out replace the estimate's; the rest stay until a full
    /// look replaces them, and a preview says so.
    func applyLook(_ look: FacadeLoadSurrogate.Prepared.Look, parts: FacadeLoadSurrogate.Prepared.Parts) {
        if parts.contains(.damage) { envelopeDamage = look.damage }
        if parts.contains(.glass) { envelopeGlassChances = look.glass }
        if parts.contains(.structure) { envelopeStructureChances = look.structure }
        envelopeDamageIsEstimate = true
        envelopeEstimateIsPreview = look.preview
        if look.preview {
            envelopeDamageStatus = String(
                format:
                    "Preview while dragging, %.1f s: each building side judged by its component nearest the charge, %@. The full estimate follows when you let go.",
                look.totalSeconds,
                parts == .glass
                    ? "the glass's chances alone, \(Self.previewDraws.glass) draws"
                    : parts == .structure
                        ? "the walls' and roofs' chances alone, \(Self.previewDraws.structure) draws"
                        : "the damage alone")
        } else {
            envelopeLoads = look.estimate.loads
            envelopeDamageStatus = String(
                format: "Quick estimate in %.1f s: not a run. Run the scene for its damage.",
                look.totalSeconds)
            if look.estimate.outsideFit > 0 {
                envelopeDamageStatus += String(
                    format:
                        " %d of %d components lie nearer or further than the distances it was fitted over: their loads are extrapolated.",
                    look.estimate.outsideFit, look.estimate.loads.count)
            }
            // The close calls refined for this scene, back in place over it.
            mergeRefinedCloseCalls()
        }
        applyEnvelopeDamageColours()
    }

    /// After the scene is loaded again (which clears every result), the estimate that followed the
    /// charge there, if it is still for this scene and place.
    func restoreFollowedLook() {
        guard restoresFollowedLook else { return }
        restoresFollowedLook = false
        guard let (scene, look, parts) = followedLook, settings.scenario == scene, stepCount == 0 else {
            return
        }
        applyLook(look, parts: parts)
    }
}
