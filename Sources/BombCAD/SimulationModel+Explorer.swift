import BlastCore
import Foundation
import simd

/// The explorer's colouring over the envelopes (`SimulationModel.explorerColouring`).
enum ExplorerColouring: Equatable {
    /// Each side's glass as one score: windows hold, some break, blown in (`ExplorerColours.glassScore`).
    case glass
    /// Each building better, the same or worse than the picture pinned, by its glass or its walls.
    case change(ExplorerSnapshot, ExplorerSnapshot.Measure)
}

// What the explorer asks of the model (emmettl/bombcad-work#114; docs/explorer.md): the charge put at a
// named place or given a size as a choice, the estimate following as a drag's does.
extension SimulationModel {
    /// The workbench's own colours and drag again, the explorer's settings undone.
    func leaveExplorer() {
        explorerColouring = nil
        explorerHidesLiveWave = false
        explorerLines = []
        explorerWarmRamp = false
        renderSettings.chargeMarkerOutlined = false
        previewsWhileDragging = true
        liveWaveDragCoarsening = 2
        liveWaveDragRefines = true
    }

    /// The quick estimate's picture as it stands, to pin or compare.
    var explorerSnapshot: ExplorerSnapshot {
        ExplorerSnapshot(
            sides: envelopeGlassChances, structure: envelopeStructureChances, charge: settings.chargePosition,
            massKg: settings.chargeMass)
    }

    /// Moves the charge to `point` on the ground as a drag let go there would: a preview at once, if an
    /// estimate is on screen, the scene loaded again, then the full estimate.
    func placeCharge(at point: SIMD3<Float>) {
        guard !isRunning, time == 0, !sweep.isActive else { return }
        let size = settings.scenario.domainSize
        let snapped = (point * Float(4)).rounded(.toNearestOrEven) / Float(4)
        let x = min(max(snapped.x, 1), size.x - 1)
        let y = min(max(snapped.y, 1), size.y - 1)
        guard x != settings.chargePosition.x || y != settings.chargePosition.y else { return }
        cancelCloseCalls(status: "")
        closeCallRefined = nil
        refinedBuildings = []
        let follows = envelopeDamageIsEstimate && !envelopeDamage.isEmpty && stepCount == 0
        settings.chargePosition.x = x
        settings.chargePosition.y = y
        settledEstimateChange(follows: follows)
    }

    /// Gives the charge `kg` of TNT as a choice, not a slider: a preview at once, then the full estimate.
    func setChargeMass(_ kg: Float) {
        guard !isRunning, time == 0, !sweep.isActive else { return }
        let mass = SimulationSettings.roundedMass(Double(kg))
        guard mass != settings.chargeMass else { return }
        let follows = envelopeDamageIsEstimate && !envelopeDamage.isEmpty && stepCount == 0
        settings.chargeMass = mass
        settledEstimateChange(follows: follows)
    }

    /// After a change made at once: a preview for the new settings, the scene loaded again (which keeps
    /// the preview, `restoreFollowedLook`), and the full estimate.
    private func settledEstimateChange(follows: Bool) {
        if follows {
            requestLook(preview: true)
            restoresFollowedLook = true
        }
        settingsChanged()
        if follows { requestLook(preview: false) }
    }
}
