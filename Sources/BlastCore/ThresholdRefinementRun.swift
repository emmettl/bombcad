import BlastModel
import Foundation
import Metal

/// A threshold refinement's run (`ThresholdRefinement`, emmettl/bombcad-work#34): the near scene
/// in the air on a solver of its own, within a budget of wall-clock time, each building judged
/// from its loads as soon as the blast has passed it, and the rest left as the estimate gave them
/// when the budget runs out or the run is cancelled.
public final class ThresholdRefinementRun: @unchecked Sendable {
    /// Where the run is: the time simulated of the time it runs to, the wall-clock time taken of
    /// the budget, and the buildings judged so far, with their results.
    public struct Progress: Sendable {
        public var simulatedS: Double
        public var untilS: Double
        public var wallS: Double
        public var budgetS: Double
        public var refined: ThresholdRefinement.Refined
        /// When each building's result came, s of wall-clock time from the start.
        public var readyWallS: [UUID: Double]
    }

    /// How a run ended.
    public enum Ending: Sendable, Equatable {
        case finished
        case budget
        case cancelled
        case failed(String)
    }

    public let plan: ThresholdRefinement.Plan
    public let budgetS: Double
    private let lock = NSLock()
    private var isCancelled = false

    public init(plan: ThresholdRefinement.Plan, budgetS: Double) {
        self.plan = plan
        self.budgetS = budgetS
    }

    /// Stops the run at its next batch; what it has judged stays.
    public func cancel() {
        lock.lock()
        isCancelled = true
        lock.unlock()
    }

    public var cancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancelled
    }

    /// Runs the near scene on `device` on cells `cellSize` with `configuration` (its refinement
    /// confined to the plan's corridors here), telling `progress` after each batch and each time
    /// buildings are judged; blocks until it ends. Buildings are judged on a queue of their own,
    /// so that the air steps on meanwhile.
    public func run(
        device: MTLDevice, cellSize: Float, configuration: SolverConfiguration,
        uncertainty: FacadeLoadSurrogate.Uncertainty = FacadeLoadSurrogate.Uncertainty(),
        progress: @escaping @Sendable (Progress) -> Void
    ) -> (ending: Ending, progress: Progress) {
        let start = ContinuousClock.now
        @Sendable func wall() -> Double { (ContinuousClock.now - start) / .seconds(1) }
        let scene = plan.scene
        let plan = plan
        let shared = Shared(
            Progress(
                simulatedS: 0, untilS: plan.untilS, wallS: 0, budgetS: budgetS,
                refined: ThresholdRefinement.Refined(), readyWallS: [:]))
        var configuration = configuration
        configuration.refinementConfinedTo = configuration.refinement > 1 ? plan.corridors : nil
        let solver: BlastSolver
        do {
            solver = try autoreleasepool {
                let created = try BlastSolver(
                    device: device, scenario: scene, cellSize: cellSize, configuration: configuration)
                // Only the buildings refined are recorded, each from when the blast reaches it.
                let ids = Set(plan.buildings)
                try created.configureEnvelopeComponents(
                    objects: scene.envelopeObjects.filter { ids.contains($0.id) },
                    options: EnvelopeHistoryOptions(
                        windowS: ThresholdRefinement.holdS(mass: Double(scene.charge.mass)) * 1.5,
                        windowFromArrival: true))
                return created
            }
        } catch {
            return (.failed("\(error)"), shared.value)
        }
        solver.mappedStartLatest = plan.untilS / 2
        let judging = DispatchQueue(label: "threshold-refinement.judge", qos: .userInitiated)
        let group = DispatchGroup()
        var waiting = plan.buildings.sorted { (plan.readyAtS[$0] ?? 0) < (plan.readyAtS[$1] ?? 0) }
        var ending = Ending.finished
        var reported = -1.0
        while !waiting.isEmpty {
            if cancelled {
                ending = .cancelled
                break
            }
            if wall() >= budgetS {
                ending = .budget
                break
            }
            let next = plan.readyAtS[waiting[0]] ?? plan.untilS
            let batch = autoreleasepool { solver.advance(steps: 16, timeLimit: next) }
            guard batch.isStable else {
                ending = .failed("the air went unstable at \(String(format: "%.3f", solver.time)) s")
                break
            }
            // The buildings the blast has passed: judged away from the stepping, the rest waiting.
            let ready = waiting.filter { solver.time >= (plan.readyAtS[$0] ?? 0) * (1 - 1e-6) }
            if ready.isEmpty, batch.steps == 0 {
                ending = .failed("the air stopped at \(String(format: "%.3f", solver.time)) s")
                break
            }
            if !ready.isEmpty {
                waiting.removeAll { ready.contains($0) }
                let histories = (solver.envelopeComponentHistories() ?? []).filter {
                    ready.contains($0.component.owner)
                }
                judging.async(group: group) {
                    let judged = ThresholdRefinement.judge(
                        histories: histories, buildings: ready, plan: plan, uncertainty: uncertainty)
                    let now = shared.update { state in
                        state.refined.buildings += judged.buildings
                        state.refined.damage += judged.damage
                        state.refined.glass += judged.glass
                        state.refined.structure += judged.structure
                        state.wallS = wall()
                        for id in ready { state.readyWallS[id] = state.wallS }
                    }
                    progress(now)
                }
            }
            // How far the air has got, at most five times a second.
            let time = solver.time
            let now = shared.update {
                $0.simulatedS = time
                $0.wallS = wall()
            }
            if now.wallS - reported >= 0.2 {
                reported = now.wallS
                progress(now)
            }
        }
        // What was passed before the end is judged still, unless cancelled.
        if ending != .cancelled { group.wait() }
        return (ending, shared.update { $0.wallS = wall() })
    }

    /// The progress, shared between the stepping and the judging under a lock.
    private final class Shared: @unchecked Sendable {
        private let lock = NSLock()
        private var state: Progress
        init(_ state: Progress) { self.state = state }
        var value: Progress {
            lock.lock()
            defer { lock.unlock() }
            return state
        }
        func update(_ change: (inout Progress) -> Void) -> Progress {
            lock.lock()
            defer { lock.unlock() }
            change(&state)
            return state
        }
    }
}
