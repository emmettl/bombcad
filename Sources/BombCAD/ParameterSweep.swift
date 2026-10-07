import BlastCore
import DocumentKit
import Foundation
import Observation

struct SimulationInputs: Equatable, Sendable {
    var scenario: Scenario
    var settings: ProjectRunSettings

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
    var isActive: Bool { baseline != nil }
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
        total = plan.count
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
                for (index, item) in cases.enumerated() {
                    try Task.checkCancellation()
                    self.message = "Preparing \(index + 1)/\(cases.count): \(item.name)"
                    model.applyExperimentInputs(item.inputs)
                    try await self.waitUntil { model.experimentIsReady }
                    self.message = "Running \(index + 1)/\(cases.count): \(item.name)"
                    model.speed = .unlimited
                    model.run()
                    try await self.waitUntil { !model.isRunning && !model.hasPendingGPUWork }
                    try Task.checkCancellation()
                    try model.keepRun(named: item.name)
                    self.completed += 1
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
