import BlastCore
import Foundation
import Observation
import simd

/// Best for a Budget… (emmettl/bombcad-work#117, stage 2; `ProtectionBudget`; docs/protective-design.md):
/// the walls, the glass and the stand-off that leave fewest people hurt, or least glass thrown, for what
/// the user will spend. The search runs through the learned response, as a drag does, and is seen as
/// it goes; its finalists are then judged by the full estimate, as on a let-go, and the best by it is
/// put in the scene as a what-if, the project unchanged.
@MainActor @Observable
final class BudgetPlannerModel {
    var budget: Double = 200_000
    var costs = ProtectionBudget.Costs.illustrative
    var objective: ProtectionBudget.Objective = .peopleHurt
    var walls = true
    var film = true
    var laminated = true
    var usesStandOff = true
    /// The stand-off the scene offers (the explorer's square and street), and its words; else none.
    var standOff: ProtectionBudget.StandOff?
    var standOffPhrase = ""

    enum Phase: Equatable {
        case idle
        case searching
        case refereeing
        case done
    }
    private(set) var phase = Phase.idle
    private(set) var progress: ProtectionBudget.Progress?
    private(set) var refereeDone = 0
    private(set) var result: ProtectionBudget.Result?
    private(set) var refereed: ProtectionBudget.Refereed?
    private(set) var error: String?
    /// The finalist put in the scene, by its place in `refereed`.
    private(set) var shown: Int?
    /// The search's looks at most, for its progress bar.
    let looks = 600

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let stop = Flag()
    /// Where the charge was when the search began: a plan with a stand-off moves it, another puts it back.
    @ObservationIgnored private var threat: SIMD3<Float>?
    @ObservationIgnored private var placed: SIMD3<Float>?
    @ObservationIgnored private var problem: ProtectionBudget.Problem?

    /// A flag the search's thread reads.
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        var isRaised: Bool { lock.withLock { raised } }
        func set(_ value: Bool) { lock.withLock { raised = value } }
    }

    var isRunning: Bool { phase == .searching || phase == .refereeing }

    /// The scene's stand-off, from the explorer: its line from the protected building.
    func offer(standOff: ProtectionBudget.StandOff?, phrase: String) {
        self.standOff = standOff
        standOffPhrase = phrase
    }

    /// Searches the scene as built, the charge where it is now: through the learned response (the
    /// SDOF's preview where there is none), then its finalists judged by the full estimate.
    func find(in model: SimulationModel) {
        guard !isRunning else { return }
        var asBuilt = model.settings.scenario
        // The charge where it is, unless a plan shown here moved it: then where it was before.
        let now = model.settings.chargePosition
        let charge = threat.flatMap { placed == now ? $0 : nil } ?? now
        threat = charge
        placed = now
        asBuilt.charge.position = charge
        let scene = asBuilt
        var problem = ProtectionBudget.Problem(scene: scene, budget: max(budget, 0))
        problem.costs = costs
        problem.objective = objective
        problem.people = model.occupancy
        problem.maxBarriers = walls ? 2 : 0
        problem.glassOptions = (film ? [.film] : []) + (laminated ? [.laminated] : [])
        problem.standOff = usesStandOff ? standOff : nil
        problem.maxEvaluations = looks
        self.problem = problem
        let asked = problem
        let cellSize = model.settings.resolution.cellSize
        let terms = model.surrogateTerms
        let people = model.occupancy
        let within = model.quickEstimateYieldWithin
        let leaves = model.liveLeavesUntrainedToCPU
        // The district as laid out for the quick estimate, if it was laid out from this scene as built.
        var layout = scene
        layout.charge.position = .zero
        let known = model.preparedDistrict.flatMap {
            $0.cellSize == cellSize && $0.scene == layout
                && $0.prepared.raster.incidence == terms.coefficients.incidence
                ? $0.prepared : nil
        }
        phase = .searching
        progress = nil
        result = nil
        refereed = nil
        refereeDone = 0
        shown = nil
        error = nil
        stop.set(false)
        let stop = self.stop
        task = Task { [weak self] in
            let outcome: Result<(ProtectionBudget.Result, ProtectionBudget.Refereed?), Error> =
                await Task.detached(
                    priority: .userInitiated
                ) {
                    do {
                        let prepared =
                            known
                            ?? FacadeLoadSurrogate.Prepared(
                                scene: scene, cellSize: cellSize, incidence: terms.coefficients.incidence)
                        let (made, _) = SimulationModel.makeLiveModel()
                        let mode: ProtectionBudget.Look.Mode =
                            made.map { .live($0, leavesUntrainedToCPU: leaves) } ?? .preview
                        let live = ProtectionBudget.Look(
                            scene: scene, cellSize: cellSize, mode: mode, terms: terms, people: people,
                            yieldWithin: within, prepared: prepared)
                        var last = ContinuousClock.now
                        let result = try ProtectionBudget.optimise(asked, evaluator: live) { p in
                            // A few times a second to the sheet, and the best walls drawn in the view.
                            if ContinuousClock.now - last > .milliseconds(80) {
                                last = .now
                                Task { @MainActor [weak self] in self?.heard(p, in: model) }
                            }
                            return !stop.isRaised
                        }
                        guard !stop.isRaised || !result.cancelled else { return .success((result, nil)) }
                        await MainActor.run { [weak self] in self?.searched(result) }
                        let full = ProtectionBudget.Look(
                            scene: scene, cellSize: cellSize, mode: .full, terms: terms, people: people,
                            structure: true,
                            yieldWithin: within, prepared: prepared)
                        let refereed = try ProtectionBudget.referee(result, problem: asked, referee: full) {
                            done in
                            Task { @MainActor [weak self] in self?.refereeDone = done }
                            return !stop.isRaised
                        }
                        return .success((result, refereed))
                    } catch {
                        return .failure(error)
                    }
                }.value
            guard let self else { return }
            switch outcome {
            case .success(let (result, refereed)):
                self.result = result
                self.refereed = refereed
                self.phase = .done
                if let refereed, !refereed.finalists.isEmpty {
                    self.show(refereed.finalists[0].finalist, at: 0, in: model)
                } else {
                    model.barrierLines = model.quickEstimateWhatIf.barriers.flatMap {
                        SimulationModel.lines($0, in: model.settings.scenario)
                    }
                }
            case .failure(let error):
                self.error = "The search failed: \(error)"
                self.phase = .idle
            }
        }
    }

    private func heard(_ p: ProtectionBudget.Progress, in model: SimulationModel) {
        guard phase == .searching else { return }
        progress = p
        model.barrierLines = p.best.site.barriers.flatMap {
            SimulationModel.lines($0, in: model.settings.scenario)
        }
    }

    private func searched(_ result: ProtectionBudget.Result) {
        self.result = result
        phase = .refereeing
    }

    func cancel() {
        stop.set(true)
    }

    /// The plan put in the scene: its walls and glass as the quick estimate's what-if, the charge kept
    /// back if it buys a stand-off (else where it was); the preview, then the full estimate, follow.
    func show(_ finalist: ProtectionBudget.Finalist, at index: Int, in model: SimulationModel) {
        shown = index
        let plan = finalist.plan
        if let threat {
            var charge = threat
            if let d = plan.site.standOffM, let line = problem?.standOff { charge = line.kept(threat, at: d) }
            if charge != model.settings.chargePosition {
                model.settings.chargePosition = charge
                model.settingsChanged()
            }
            placed = charge
        }
        model.dragsBarrier = false
        model.quickEstimateWhatIf = plan.whatIf
        if !model.envelopeDamageIsEstimate || model.envelopeDamage.isEmpty { model.quickEstimate() }
    }

    /// The plans forgotten and the charge put back where the search began.
    func reset(in model: SimulationModel) {
        cancel()
        if let threat, threat != model.settings.chargePosition {
            model.settings.chargePosition = threat
            model.settingsChanged()
        }
        threat = nil
        result = nil
        refereed = nil
        shown = nil
        phase = .idle
        model.quickEstimateWhatIf = LiveResponse.WhatIf()
    }

    // MARK: Words

    /// The figure in words: "1,216 people hurt", "320 m² of glass thrown".
    func figure(_ outcome: ProtectionBudget.Outcome) -> String {
        objective == .peopleHurt
            ? OccupantInjury.count(outcome.hurt) + " hurt"
            : String(format: "%.0f m² of glass thrown", outcome.glassM2)
    }

    func value(_ outcome: ProtectionBudget.Outcome) -> Double {
        objective == .peopleHurt ? outcome.hurt : outcome.glassM2
    }

    /// "−5.3%" against the scene as built.
    static func change(_ value: Double, against base: Double) -> String {
        guard base > 0 else { return "" }
        return String(format: "%+.1f%%", 100 * (value / base - 1)).replacingOccurrences(of: "-", with: "−")
    }

    static func dollars(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(0)))
    }

    /// The search's progress in words.
    var progressText: String {
        switch phase {
        case .idle: return ""
        case .searching:
            guard let p = progress else { return "Looking at the scene as built…" }
            return String(
                format: "%@: %d plans looked at in %.1f s. Best so far: %@, %@ (%@ against as built).",
                p.stage,
                p.evaluations, p.seconds, p.best.label,
                objective == .peopleHurt
                    ? OccupantInjury.count(p.bestValue) + " hurt" : String(format: "%.0f m²", p.bestValue),
                Self.change(p.bestValue, against: p.asBuiltValue))
        case .refereeing:
            let n = result?.finalists.count ?? 0
            return "Checking the \(n) best plans with the full estimate: \(refereeDone) of \(n) done."
        case .done:
            guard let result else { return "" }
            return String(
                format:
                    "%d plans looked at by the learned response in %.1f s%@; the best %d judged again by the full estimate in %.0f s.",
                result.evaluations, result.seconds, result.cancelled ? " (stopped)" : "",
                result.finalists.count,
                refereed?.seconds ?? 0)
        }
    }
}
