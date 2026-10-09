import BlastCore
import DocumentKit
import Foundation
import Observation

struct SimulationInputs: Equatable, Sendable {
    var scenario: Scenario
    var settings: ProjectRunSettings
    /// The fragments flown alongside, for undo; sweep cases leave the project's as they are.
    var fragments: FragmentSpec?

    func validate() throws {
        try ProjectDocument.validate(scenario)
        guard ([scenario.charge] + (scenario.additionalCharges ?? [])).allSatisfy({ $0.energy.isFinite })
        else {
            throw ProjectFileError.invalid(
                "Charge energy exceeds the numerical range supported by the solver.")
        }
        try settings.validate()
        try ProjectDocument.validateGrid(scenario, resolution: Resolution(rawValue: settings.resolution)!)
    }
}

struct ParameterSweepPlan: Sendable {
    enum Parameter: Sendable {
        case chargeMass([Float])
        case grid([Resolution])
    }
    struct Case: Sendable {
        var name: String
        var inputs: SimulationInputs
    }
    var prefix: String
    var parameter: Parameter
    var count: Int {
        switch parameter {
        case .chargeMass(let values): values.count
        case .grid(let values): values.count
        }
    }

    func prepare(from baseline: SimulationInputs) throws -> [Case] {
        let name = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80, (1...8).contains(count) else {
            throw ProjectFileError.invalid("Choose a sweep name and between one and eight distinct cases.")
        }
        try baseline.validate()
        let cases: [Case]
        switch parameter {
        case .chargeMass(let values):
            guard Set(values).count == values.count,
                values.allSatisfy({ $0.isFinite && $0 >= 0 && ($0 * Charge.energyPerKilogram).isFinite })
            else {
                throw ProjectFileError.invalid(
                    "Charge masses must be distinct, finite and nonnegative, in kg TNT.")
            }
            cases = values.map { value in
                var inputs = baseline
                inputs.scenario.charge.mass = value
                return Case(name: "\(name) · \(value) kg", inputs: inputs)
            }
        case .grid(let values):
            guard Set(values).count == values.count else {
                throw ProjectFileError.invalid("Choose each grid resolution once.")
            }
            cases = try values.map { value in
                try Task.checkCancellation()
                var inputs = baseline
                inputs.scenario = try baseline.scenario.resamplingImports(cellSize: value.cellSize)
                inputs.settings.resolution = value.rawValue
                if (baseline.scenario.importedModels ?? []).contains(where: {
                    $0.isAttached && $0.preview.cellSize != value.cellSize
                }), let body = inputs.scenario.structure {
                    inputs.settings.solidElementSize = body.elementSize
                }
                return Case(name: "\(name) · \(value.rawValue)", inputs: inputs)
            }
        }
        for item in cases {
            try Task.checkCancellation()
            try item.inputs.validate()
        }
        return cases
    }
}

@MainActor @Observable
final class ParameterSweep {
    private weak var model: SimulationModel?
    private(set) var baseline: SimulationInputs?
    private(set) var message = ""
    private(set) var completed = 0
    private(set) var total = 0
    /// Cases another Mac ran, in this sweep or the last.
    private(set) var remoteCompleted = 0
    var isActive: Bool { baseline != nil }
    /// Starts a worker on another Mac to share the next sweep, if set (see `RemoteSweepWorker`).
    @ObservationIgnored var remoteWorker: (@MainActor () async throws -> SweepWorkerClient)?
    /// How many times longer the other Mac is expected to take over a case, until measured.
    @ObservationIgnored var remoteRatio = 3.5
    @ObservationIgnored private var localStatus = ""
    @ObservationIgnored private var remoteStatus = ""
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var token = UUID()
    @ObservationIgnored private var previousSpeed = PlaybackSpeed.x100

    init(model: SimulationModel) { self.model = model }

    func start(_ plan: ParameterSweepPlan) throws {
        guard let model, !isActive, model.experimentIsReady else {
            throw ProjectFileError.invalid("Reset to a ready simulation before starting a sweep.")
        }
        guard model.savedRuns.count + plan.count <= SavedSimulationRun.maximumRuns,
            (1...8).contains(plan.count)
        else {
            throw ProjectFileError.invalid("Make room for every sweep case within the 16 saved-run limit.")
        }
        let original = model.currentInputs
        model.recordEdit()
        baseline = original
        previousSpeed = model.speed
        completed = 0
        remoteCompleted = 0
        total = plan.count
        localStatus = ""
        remoteStatus = ""
        message = "Checking sweep inputs…"
        let generation = UUID()
        token = generation
        task = Task { [weak self] in
            guard let self else { return }
            var outcome = "Sweep complete"
            do {
                let preparation = Task.detached(priority: .userInitiated) { try plan.prepare(from: original) }
                let cases = try await withTaskCancellationHandler(
                    operation: { try await preparation.value },
                    onCancel: { preparation.cancel() })
                try Task.checkCancellation()
                guard self.token == generation, let model = self.model else { return }
                guard
                    cases.allSatisfy({ item in
                        !model.savedRuns.contains {
                            $0.name.localizedCaseInsensitiveCompare(item.name) == .orderedSame
                        }
                    })
                else {
                    throw ProjectFileError.invalid(
                        "Sweep result names already exist. Choose another sweep name.")
                }
                let budget = Double(model.device?.recommendedMaxWorkingSetSize ?? 0) * 0.7
                for item in cases {
                    let estimate = ImportMemoryEstimate(
                        domain: item.inputs.scenario.domainSize,
                        cellSize: Resolution(rawValue: item.inputs.settings.resolution)!.cellSize,
                        detailed: item.inputs.settings.detailedCharge,
                        refined: item.inputs.settings.sharpShocks, budget: budget)
                    guard estimate.fits else {
                        throw ProjectFileError.invalid(
                            "\(item.name) exceeds the estimated air-memory budget. Choose a coarser grid or smaller domain."
                        )
                    }
                }
                try await self.run(cases, on: model)
                if self.remoteCompleted > 0 {
                    outcome += " (\(self.remoteCompleted) on \(self.remoteStatusName))"
                }
            } catch is CancellationError {
                outcome = "Sweep cancelled"
            } catch {
                outcome = "Sweep stopped: \(error.localizedDescription)"
            }
            guard self.token == generation, let model = self.model else { return }
            model.applyExperimentInputs(original)
            model.speed = self.previousSpeed
            self.baseline = nil
            self.message = "\(outcome) · \(self.completed) results kept."
            self.task = nil
        }
    }

    /// Runs the cases here and, when a worker is set, on another Mac at the same time, each where
    /// `SweepSchedule` sends it; keeps their results in the plan's order.
    private func run(_ cases: [ParameterSweepPlan.Case], on model: SimulationModel) async throws {
        var schedule = SweepSchedule(costs: cases.map { SweepSchedule.cost($0.inputs) })
        schedule.ratio = remoteRatio
        let shared = Shared(schedule)
        defer { model.orderRuns(cases.map(\.name)) }
        let remote = remoteWorker.map { connect in
            Task { await self.runRemote(cases, shared, connect, on: model) }
        }
        do {
            try await withTaskCancellationHandler {
                try await runLocal(cases, shared, on: model)
            } onCancel: {
                remote?.cancel()
            }
            await remote?.value
        } catch {
            remote?.cancel()
            await remote?.value
            throw error
        }
    }

    private func runLocal(_ cases: [ParameterSweepPlan.Case], _ shared: Shared, on model: SimulationModel)
        async throws
    {
        while true {
            try Task.checkCancellation()
            guard let index = shared.schedule.nextLocal() else {
                // The other Mac may yet fail a case back to this one.
                if shared.remoteBusy {
                    try await Task.sleep(for: .milliseconds(50))
                    continue
                }
                break
            }
            let item = cases[index]
            let cost = SweepSchedule.cost(item.inputs)
            shared.local = (cost, 0)
            status(local: "Preparing \(item.name)")
            model.applyExperimentInputs(item.inputs)
            try await waitUntil { model.experimentIsReady }
            status(local: "Running \(item.name)")
            let start = ContinuousClock.now
            model.speed = .unlimited
            model.run()
            try await waitUntil {
                shared.local = (cost, model.duration > 0 ? min(model.time / model.duration, 1) : 0)
                return !model.isRunning && !model.hasPendingGPUWork
            }
            try Task.checkCancellation()
            try model.keepRun(named: item.name)
            shared.local = nil
            shared.schedule.record(seconds: start.duration(to: .now).seconds, cost: cost, remote: false)
            completed += 1
        }
        status(local: "")
    }

    private func runRemote(
        _ cases: [ParameterSweepPlan.Case], _ shared: Shared,
        _ connect: @MainActor () async throws -> SweepWorkerClient, on model: SimulationModel
    ) async {
        status(remote: "Connecting to another Mac…")
        let worker: SweepWorkerClient
        do {
            worker = try await connect()
        } catch {
            status(remote: Task.isCancelled ? "" : "Running here only: \(error.localizedDescription)")
            return
        }
        remoteStatusName = worker.name
        defer { worker.close() }
        while !Task.isCancelled {
            let remaining = shared.local.map { $0.cost * (1 - $0.fraction) } ?? 0
            guard let index = shared.schedule.nextRemote(localRemaining: remaining) else { break }
            let item = cases[index]
            let cost = SweepSchedule.cost(item.inputs)
            shared.remoteBusy = true
            defer { shared.remoteBusy = false }
            status(remote: "\(item.name) on \(worker.name)")
            let start = ContinuousClock.now
            do {
                let run = try await worker.run(item) { [weak self] fraction in
                    self?.status(remote: "\(item.name) on \(worker.name), \(Int(fraction * 100))%")
                }
                try model.addRun(run)
                shared.schedule.record(seconds: start.duration(to: .now).seconds, cost: cost, remote: true)
                completed += 1
                remoteCompleted += 1
            } catch is CancellationError {
                return
            } catch {
                // This Mac runs it instead, and runs the rest.
                shared.schedule.requeue(index, cost: cost)
                status(remote: "\(worker.name) stopped: \(error.localizedDescription) Running the rest here.")
                return
            }
        }
        status(remote: "")
    }

    @ObservationIgnored private var remoteStatusName = "another Mac"

    private func status(local: String? = nil, remote: String? = nil) {
        if let local { localStatus = local }
        if let remote { remoteStatus = remote }
        let parts = [localStatus.isEmpty ? "" : "\(localStatus) here", remoteStatus].filter { !$0.isEmpty }
        message = "\(completed)/\(total) done" + (parts.isEmpty ? "" : " · " + parts.joined(separator: " · "))
    }

    /// What the two sides of a sweep share: the queue, this Mac's case and how far it has got,
    /// and whether the other Mac is busy.
    @MainActor private final class Shared {
        var schedule: SweepSchedule
        var local: (cost: Double, fraction: Double)?
        var remoteBusy = false

        init(_ schedule: SweepSchedule) { self.schedule = schedule }
    }

    func cancel() {
        guard let model, let baseline else { return }
        task?.cancel()
        message = "Cancelling sweep…"
        // Restore persisted inputs immediately, even if an old GPU batch is still finishing.
        model.applyExperimentInputs(baseline)
        model.speed = previousSpeed
    }

    /// Document replacement owns its own inputs; a cancelled task must not restore over them.
    func abandon() {
        token = UUID()
        task?.cancel()
        task = nil
        if isActive { model?.speed = previousSpeed }
        baseline = nil
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        while !predicate() {
            try Task.checkCancellation()
            if let error = model?.errorMessage { throw ProjectFileError.invalid(error) }
            try await Task.sleep(for: .milliseconds(5))
        }
        try Task.checkCancellation()
        if let error = model?.errorMessage { throw ProjectFileError.invalid(error) }
    }
}

extension Duration {
    fileprivate var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }
}
