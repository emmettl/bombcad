import BlastCore
import Foundation
import simd

// The quick estimate's close calls refined by the solver in the background once a look is in
// (emmettl/bombcad-work#34): `ThresholdRefinement` chooses them and cuts the scene down round
// them, `ThresholdRefinementRun` runs it within a budget the user sees and can cancel, and each
// building's run result replaces the estimate's as it comes, outlined in the view.
extension SimulationModel {
    /// The budgets offered, s.
    static let closeCallBudgets: [Double] = [30, 60, 120, 300, 600]

    /// What a building's doubt is judged on: the chance the view is coloured by, or for the damage
    /// colouring the walls', roof's and blown-out windows'.
    var closeCallQuantities: Set<ThresholdRefinement.Quantity> {
        switch envelopeColouring {
        case .someBroken: [.someBroken]
        case .blownOut: [.blownOut]
        case .thrownPast3b: [.thrownPast3b]
        case .openingsBlownOut: [.openingsBlownOut]
        case .wallsModerate: [.wallsModerate]
        case .wallsHeavy: [.wallsHeavy]
        case .roofModerate: [.roofModerate]
        case .peopleHurt: [.blownOut]
        case .damage, .couldFlip: ThresholdRefinement.Quantity.damage
        }
    }

    /// After a full look at the scene with the charge where it is: its close calls run in the air,
    /// if asked for and nothing else is running.
    func refineCloseCalls(_ look: FacadeLoadSurrogate.Prepared.Look) {
        cancelCloseCalls(status: "")
        guard refinesCloseCalls, !look.preview, stepCount == 0, !isRunning, let device else { return }
        let scenario = settings.scenario
        let cellSize = settings.resolution.cellSize
        let budget = closeCallBudgetS
        let quantities = closeCallQuantities
        // The near scene's coarse air, a third of what the air may take, and its corridors' finer
        // air the rest of half.
        let memory = advisorMemory
        let maxCells = memory / 3 / 57
        var configuration = SolverConfiguration()
        ProjectRunSettings.configureAir(
            &configuration, detailedCharge: settings.detailedCharge, sharpShocks: true,
            shockLevels: max(settings.shockLevels, 1), gravity: settings.gravity,
            shockThreshold: settings.shockThreshold, terrainCutCells: settings.terrainCutCells,
            ground: settings.ground == .rigid ? nil : settings.ground, mappedStart: settings.mappedStart,
            refinementCeiling: settings.refinementCeiling,
            radiativeCooling: settings.radiativeCooling ? RadiativeCooling() : nil)
        configuration.refinementMemory = max(memory / 2 - maxCells * 57, 1 << 30)
        let uncertainty = FacadeLoadSurrogate.Uncertainty()
        let doubts = ThresholdRefinement.doubts(
            glass: look.glass, structure: look.structure, quantities: quantities)
        let plan: ThresholdRefinement.Plan
        do {
            plan = try ThresholdRefinement.plan(
                scene: scenario, cellSize: cellSize, doubts: doubts, maxCells: maxCells)
        } catch {
            closeCallStatus = "Close calls not refined: \(error)."
            return
        }
        let run = ThresholdRefinementRun(plan: plan, budgetS: budget)
        closeCallRun = run
        closeCallScene = scenario
        closeCallRefined = ThresholdRefinement.Refined()
        refinedBuildings = []
        closeCallProgress = 0
        closeCallStatus = String(
            format: "Refining %d close call%@ with the solver: a %.0f × %.0f m scene round the charge…",
            plan.buildings.count, plan.buildings.count == 1 ? "" : "s", plan.scene.domainSize.x,
            plan.scene.domainSize.y)
        isRefiningCloseCalls = true
        // Held weakly: a window closed meanwhile lets its model go, and the run's reports with it.
        let model = WeakModel(self)
        Task.detached(priority: .utility) {
            let (ending, final) = run.run(
                device: device, cellSize: cellSize, configuration: configuration, uncertainty: uncertainty
            ) { progress in
                Task { @MainActor in model.value?.closeCallsProgressed(run, progress) }
            }
            await MainActor.run { model.value?.closeCallsEnded(run, ending: ending, final: final) }
        }
    }

    /// Stops a refinement under way; what it has refined stays shown.
    func cancelCloseCalls(status: String? = nil) {
        guard let run = closeCallRun else {
            if let status { closeCallStatus = status }
            return
        }
        run.cancel()
        closeCallRun = nil
        isRefiningCloseCalls = false
        if let status { closeCallStatus = status }
    }

    private func closeCallsProgressed(
        _ run: ThresholdRefinementRun, _ progress: ThresholdRefinementRun.Progress
    ) {
        guard closeCallRun === run else { return }
        // The scene changed under it (an edit, a run begun): its results are for another scene.
        guard settings.scenario == closeCallScene, stepCount == 0, !isRunning else {
            cancelCloseCalls(status: "Close-call refinement stopped: the scene changed.")
            return
        }
        closeCallProgress = progress.untilS > 0 ? min(progress.simulatedS / progress.untilS, 1) : 0
        closeCallStatus = String(
            format:
                "Refining %d close calls with the solver: %.2f of %.2f s simulated, %.0f of %.0f s; %d refined.",
            run.plan.buildings.count, progress.simulatedS, progress.untilS, progress.wallS, progress.budgetS,
            progress.refined.buildings.count)
        if progress.refined.buildings.count > (closeCallRefined?.buildings.count ?? 0) {
            closeCallRefined = progress.refined
            mergeRefinedCloseCalls()
            refreshPeople()
            applyEnvelopeDamageColours()
        }
    }

    private func closeCallsEnded(
        _ run: ThresholdRefinementRun, ending: ThresholdRefinementRun.Ending,
        final: ThresholdRefinementRun.Progress
    ) {
        let current = closeCallRun === run
        if current {
            closeCallRun = nil
            isRefiningCloseCalls = false
        }
        guard settings.scenario == closeCallScene, stepCount == 0 else { return }
        if final.refined.buildings.count > (closeCallRefined?.buildings.count ?? 0) {
            closeCallRefined = final.refined
            mergeRefinedCloseCalls()
            refreshPeople()
            applyEnvelopeDamageColours()
        }
        let refined = final.refined.buildings.count
        let all = run.plan.buildings.count
        let left =
            run.plan.leftOut > 0 ? " \(run.plan.leftOut) further close calls were left to the estimate." : ""
        let what =
            "outlined in the view: their damage and chances are the run's, at the scene's charge (no yield drawn), in place of the estimate's."
        closeCallStatus =
            switch ending {
            case .finished:
                String(
                    format: "%d close call%@ refined by the solver in %.0f s, ", refined,
                    refined == 1 ? "" : "s", final.wallS)
                    + what + left
            case .budget:
                String(
                    format: "Budget of %.0f s reached: %d of %d close calls refined, ", final.budgetS,
                    refined, all)
                    + what + " The rest are the estimate's." + left
            case .cancelled:
                current || refined > 0
                    ? "Refinement cancelled: \(refined) of \(all) close calls refined; the rest are the estimate's."
                    : closeCallStatus
            case .failed(let why):
                "Close-call refinement failed (\(why)): \(refined) of \(all) refined; the rest are the estimate's."
            }
    }

    /// Puts the refined buildings' results in place of the estimate's, if the estimate shown is
    /// for the scene they were refined on.
    func mergeRefinedCloseCalls() {
        guard let refined = closeCallRefined, !refined.buildings.isEmpty, settings.scenario == closeCallScene,
            envelopeDamageIsEstimate, !envelopeEstimateIsPreview
        else { return }
        let ids = Set(refined.buildings)
        envelopeDamage = envelopeDamage.filter { !ids.contains($0.id) } + refined.damage
        envelopeGlassChances = envelopeGlassChances.filter { !ids.contains($0.owner) } + refined.glass
        envelopeStructureChances =
            envelopeStructureChances.filter { !ids.contains($0.owner) } + refined.structure
        refinedBuildings = ids
    }

    /// The refined buildings' outlines over the view: each one's footprint at its top.
    func refinedOutlines() -> [SIMD4<Float>] {
        guard showsEnvelopeDamage, !refinedBuildings.isEmpty, envelopeDamageIsEstimate else { return [] }
        let kind = Float(10)
        var lines: [SIMD4<Float>] = []
        for id in refinedBuildings {
            guard let box = settings.scenario.object(id: id)?.bounds else { continue }
            let z = box.max.z + 0.5
            let corners = [
                SIMD3(box.min.x, box.min.y, z), SIMD3(box.max.x, box.min.y, z),
                SIMD3(box.max.x, box.max.y, z),
                SIMD3(box.min.x, box.max.y, z),
            ]
            for n in 0..<4 {
                lines += [SIMD4(corners[n], kind), SIMD4(corners[(n + 1) % 4], 0)]
            }
        }
        return lines
    }
}

/// A model held weakly, to be reached from another thread's work and used on the main actor.
private final class WeakModel: @unchecked Sendable {
    weak var value: SimulationModel?
    init(_ value: SimulationModel) { self.value = value }
}
