import BlastCore
import Foundation
import Observation

/// Simulation ▸ Protective Design's state: the target, the changes allowed with the user's costs,
/// and the plans the search found (`ProtectionModel`, `ProtectionSearch`; docs/protective-design.md).
/// Kept on the model while the window is open, as the Infer Charge sheet's is.
@MainActor @Observable
final class ProtectionPlannerModel {
    /// A glazing the search may give a side, with its cost per square metre of glass.
    struct Change: Identifiable, Equatable {
        var kind: ProtectionModel.Glazing.Kind
        var name: String
        var allowed: Bool
        var costPerM2: Double
        var id: ProtectionModel.Glazing.Kind { kind }
    }

    /// The worst GSA condition allowed, and the largest chance accepted of passing it.
    var condition = GlazingHazard.Condition.threeB
    var chance = 0.1
    /// Buildings held to another condition, by name ("Store": "4").
    var conditions: [String: GlazingHazard.Condition] = [:]
    /// What may be changed, and at what cost. The costs are relative units, the prototype's
    /// illustrative order (film cheaper than toughened, laminated and infill dearer); set your own.
    var changes = [
        Change(kind: .filmed, name: "Security film, wet glazed", allowed: true, costPerM2: 2.5),
        Change(kind: .toughened, name: "Toughened glass", allowed: true, costPerM2: 4),
        Change(kind: .laminated, name: "Laminated glass", allowed: true, costPerM2: 5),
        Change(kind: .infill, name: "Fill the window in", allowed: true, costPerM2: 6),
    ]
    /// Draws of the load's scatter and the glass's strength for each side's chance.
    var draws = 32

    struct PlanRow: Identifiable {
        var id: Int
        var label: String
        var plan: ProtectionSearch.Plan
        var changes: String
        var narrow: Int
    }

    private(set) var isRunning = false
    private(set) var error: String?
    private(set) var plans: [PlanRow] = []
    private(set) var model: ProtectionModel.Model?
    private(set) var seconds = 0.0
    var selected: Int?
    private var task: Task<Void, Never>?

    /// The inputs the search takes for `scenario`'s charges.
    func inputs(_ scenario: Scenario) -> ProtectionModel.Inputs {
        let charges = [scenario.charge] + (scenario.additionalCharges ?? [])
        return ProtectionModel.Inputs(
            threats: charges.map {
                ProtectionModel.Threat(
                    mass: Double($0.mass), x: Double($0.position.x), y: Double($0.position.y))
            },
            target: .init(
                worseThan: condition.rawValue, chance: chance,
                buildings: conditions.isEmpty ? nil : conditions.mapValues { .init(worseThan: $0.rawValue) }),
            glazing: changes.filter(\.allowed).map {
                ProtectionModel.Glazing(name: $0.name, kind: $0.kind, costPerM2: $0.costPerM2)
            },
            standOffs: nil, barriers: nil, draws: draws, seed: 1)
    }

    /// Searches `scenario` on cells `cellSize` m across, off the main thread.
    func search(_ scenario: Scenario, cellSize: Float) {
        task?.cancel()
        isRunning = true
        error = nil
        let inputs = inputs(scenario)
        task = Task { [weak self] in
            let start = ContinuousClock.now
            let outcome = await Task.detached(priority: .userInitiated) {
                () -> Result<(ProtectionModel.Model, [ProtectionSearch.Plan], ProtectionSearch.Plan), Error>
                in
                do {
                    let model = try ProtectionModel.model(scene: scenario, cellSize: cellSize, inputs: inputs)
                    ProtectionModel.prepare(model)
                    let problem = model.problem
                    let ranked = ProtectionSearch.ranked(problem, plans: ProtectionSearch.exact(problem))
                    return .success((model, ranked, ProtectionSearch.asBuilt(problem)))
                } catch {
                    return .failure(error)
                }
            }.value
            guard let self, !Task.isCancelled else { return }
            self.isRunning = false
            let took = start.duration(to: .now)
            self.seconds = Double(took.components.seconds) + Double(took.components.attoseconds) * 1e-18
            switch outcome {
            case .failure(let failure):
                self.error = String(describing: failure)
                self.plans = []
                self.model = nil
            case .success(let (model, ranked, built)):
                self.model = model
                self.plans =
                    ([("As built", built)] + ranked.enumerated().map { ("\($0.offset + 1)", $0.element) })
                    .enumerated().map { n, row in
                        PlanRow(
                            id: n, label: row.0, plan: row.1, changes: Self.describe(row.1, model: model),
                            narrow: ProtectionSearch.narrow(row.1, target: model.problem.targetChance))
                    }
                self.selected = ranked.isEmpty ? nil : 1
            }
        }
    }

    /// A plan's changes in a few words: each glazing and how many sides take it.
    static func describe(_ plan: ProtectionSearch.Plan, model: ProtectionModel.Model) -> String {
        var counts: [String: Int] = [:]
        for (s, option) in plan.choices.enumerated() where option != 0 {
            counts[model.problem.sides[s].options[option].glazing, default: 0] += 1
        }
        guard !counts.isEmpty else { return "nothing" }
        return counts.sorted { $0.key < $1.key }.map {
            "\($0.key) on \($0.value) side\($0.value == 1 ? "" : "s")"
        }
        .joined(separator: "; ")
    }

    /// The selected plan's sides by building: (axis, outward, residual chance), for the view.
    var selectedChances: [UUID: [(axis: Int, outward: Int, chance: Double)]] {
        guard let selected, plans.indices.contains(selected), let model else { return [:] }
        let plan = plans[selected].plan
        var out: [UUID: [(axis: Int, outward: Int, chance: Double)]] = [:]
        for s in plan.choices.indices {
            out[model.owners[s], default: []].append((model.axes[s], model.outwards[s], plan.chances[s]))
        }
        return out
    }
}
