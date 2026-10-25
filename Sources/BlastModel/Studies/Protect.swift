import Foundation
import simd

/// `scenebench protect (<district-scene's inputs> | --scene layout.json) [--dx 4] --inputs
/// protect.json [--samples posterior.csv [--sample-count 24]] [--confirm loads-folder] [--out
/// plans.json] [--terms clear-top|fitted] [--margin flag:2.5] [--option-table table.csv]`: the
/// least costly glazing and stand-off changes that keep each building side's chance of glass
/// thrown worse than its target condition under the chance accepted
/// (docs/protective-design.md, "In BombCAD"). The inputs file gives the threat, the target and
/// the changes allowed with the user's costs (`ProtectionModel.Inputs`); `--samples` takes the
/// threat from `infer-charge --samples` instead (masses, and places about the scene's charge).
/// `--confirm` re-judges the plans that leave the threat where it is on a run's saved façade
/// histories (`district-compare --save-loads`) of the same scene, under each plan's glazing.
/// `--margin target:<chance>|quantile:<sd>|flag:<sd>` (or the inputs' `margin`) searches with a
/// margin for the loads' scatter from side to side (`ProtectionModel.Margin`,
/// emmettl/bombcad-work#101); none without it.
package enum Protect {
    struct PlanJSON: Codable {
        var plan: String
        var cost: Double
        var meets: Bool
        var expectedFailing: Double
        var worst: Double
        var narrow: Int
        var changes: String
        var site: [String]
        var sides: [String: String]
        var chances: [String: Double]
        var level: EvidenceLevel
        var standing: [String]
        var confirmed: Confirmation?
    }

    struct Confirmation: Codable {
        var sides: Int
        var meets: Bool
        var worst: Double
        var expectedFailing: Double
        var chances: [String: Double]
    }

    package static func run(_ args: [String]) throws {
        StudyOutput.lineBuffered()
        func value(_ name: String) -> String? { SurrogateBench.value(args, name) }
        guard let inputsPath = value("inputs") else {
            throw BlastError.allocationFailed("--inputs protect.json")
        }
        var inputs = try JSONDecoder().decode(
            ProtectionModel.Inputs.self, from: Data(contentsOf: URL(filePath: inputsPath)))
        var scene: Scenario
        let cellSize: Float
        // Confirming on a run: the scene as the run's strips are matched to it, so that its
        // buildings' ids are the ones the plans' constructions name.
        let reference = try value("confirm").map { folder -> SurrogateBench.Reference in
            var a = args
            a += ["--loads", folder]
            return try SurrogateBench.Reference(a)
        }
        if let reference {
            scene = reference.scene
            cellSize = reference.cellSize
        } else if let path = value("scene") {
            scene = try JSONDecoder().decode(Scenario.self, from: Data(contentsOf: URL(filePath: path)))
            cellSize = Float(value("dx").flatMap(Double.init) ?? 4)
        } else {
            let district = try DistrictInputs.read(args)
            (scene, _) = try district.scene(radius: Float(value("radius").flatMap(Double.init) ?? 1000))
            cellSize = district.cellSize
        }
        if let path = value("samples") {
            // The posterior's samples: log10 mass, then east and north of the reference, which is
            // the scene's charge.
            let lines = try String(contentsOf: URL(filePath: path), encoding: .utf8).split(
                whereSeparator: \.isNewline)
            let rows = lines.dropFirst().compactMap { line -> [Double]? in
                let f = line.split(separator: ",").compactMap { Double($0) }
                return f.count >= 3 ? f : nil
            }
            let count = min(rows.count, value("sample-count").flatMap(Int.init) ?? 24)
            let charge = scene.charge.position
            inputs.threats = (0..<count).map { k in
                let row = rows[k * rows.count / count]
                return ProtectionModel.Threat(
                    mass: pow(10, row[0]), x: Double(charge.x) + row[1], y: Double(charge.y) + row[2])
            }
        }
        let start = ContinuousClock.now
        // `--terms clear-top|fitted`: the façade terms and load scatter; the planner's own pin (those
        // of 23 October, emmettl/bombcad-work#100) without it.
        let terms = try SurrogateBench.termSet(args, otherwise: .fitted)
        print("Façade terms: \(terms.rawValue)")
        if let text = value("margin") {
            guard let margin = ProtectionModel.Margin(text) else {
                throw BlastError.allocationFailed("--margin target:<chance>|quantile:<sd>|flag:<sd>")
            }
            inputs.margin = margin
        }
        print("Margin for the scatter between sides: \(inputs.margin?.description ?? "none")")
        let model = try ProtectionModel.model(scene: scene, cellSize: cellSize, inputs: inputs, terms: terms)
        let problem = model.problem
        if let path = value("option-table") {
            try optionTable(
                path: path, scene: scene, cellSize: cellSize, inputs: inputs, terms: terms, model: model,
                reference: reference)
            return
        }
        let options = problem.sides.first?.options.count ?? 0
        print(
            "\(problem.sides.count) glazed sides, \(options) options each, \(problem.site.count) site-wide changes, "
                + "\(inputs.threats.count) threat place\(inputs.threats.count == 1 ? "" : "s"), \(inputs.draws ?? 64) draws"
        )
        var plans: [(String, ProtectionSearch.Plan)] = []
        let built = ProtectionSearch.asBuilt(problem)
        if problem.site.count <= 12 {
            ProtectionModel.prepare(model)
            print(String(format: "Chances in %.1f s", StudyClock.seconds(start)))
            let all = ProtectionSearch.exact(problem)
            plans = ProtectionSearch.ranked(problem, plans: all).enumerated().map {
                ("\($0.offset + 1)", $0.element)
            }
        }
        plans.insert(("as built", built), at: 0)
        plans.append(("greedy", ProtectionSearch.greedy(problem)))
        plans.append(("annealing", ProtectionSearch.anneal(problem, seed: inputs.seed ?? 1)))
        let seconds = StudyClock.seconds(start)

        // Confirmation on a run's histories, for the plans that leave the threat in place.
        let confirmations = reference.map { reference in
            confirm(reference: reference, model: model, plans: plans.map(\.1).filter { $0.site.isEmpty })
        }

        let target = model.accepted
        var out: [PlanJSON] = []
        print(
            String(
                format:
                    "Target: no pane thrown worse than the side's condition, except with a chance under %.0f%%",
                target * 100))
        if problem.targetChance != target {
            print(String(format: "The search holds each side to %.1f%%", problem.targetChance * 100))
        }
        print("| Plan | Cost | Meets | Sides expected to fail | Worst | Narrow | Changes | Standing |")
        print("|---|---:|---|---:|---:|---:|---|---|")
        for (label, plan) in plans {
            var counts: [String: Int] = [:]
            var sides: [String: String] = [:]
            var chances: [String: Double] = [:]
            for (s, side) in problem.sides.enumerated() {
                let option = side.options[plan.choices[s]]
                sides[side.name] = option.glazing
                chances[side.name] = plan.chances[s]
                if plan.choices[s] != 0 { counts[option.glazing, default: 0] += 1 }
            }
            let changes =
                (plan.site.map { problem.site[$0].name }
                + counts.sorted { $0.key < $1.key }.map {
                    "\($0.key) on \($0.value) side\($0.value == 1 ? "" : "s")"
                })
                .joined(separator: "; ")
            let narrow = ProtectionSearch.narrow(plan, target: target)
            let confirmed = plan.site.isEmpty ? confirmations?[plan.choices] : nil
            var standing = [
                "Costs and threat are the user's; the loads the façade load surrogate's (an estimate), the glass's "
                    + "chances a run's spread, not the event's (docs/glass-probability.md).",
                "Glass only: walls and roofs are not judged.",
            ]
            if narrow > 0 {
                standing.append(
                    "\(narrow) side\(narrow == 1 ? " passes" : "s pass") narrowly: confirm with a run.")
            }
            if let confirmed {
                standing.append(
                    String(
                        format: "On the run's histories: %@, worst side %.0f%%.",
                        confirmed.meets ? "meets the target" : "misses it",
                        confirmed.worst * 100))
            }
            // Confirmed only where the run judged every side and the plan meets the target on it.
            let level: EvidenceLevel =
                plan.meets && confirmed?.meets == true && confirmed?.sides == problem.sides.count
                ? .approximation : .illustrative
            out.append(
                PlanJSON(
                    plan: label, cost: plan.cost, meets: plan.meets, expectedFailing: plan.expectedFailing,
                    worst: plan.worst, narrow: narrow, changes: changes.isEmpty ? "nothing" : changes,
                    site: plan.site.map { problem.site[$0].name }, sides: sides, chances: chances,
                    level: level,
                    standing: standing, confirmed: confirmed))
            print(
                String(
                    format: "| %@ | %.0f | %@ | %.2f | %.0f%% | %d | %@ | %@ |", label as NSString, plan.cost,
                    plan.meets ? "yes" : "no", plan.expectedFailing, plan.worst * 100, narrow,
                    (changes.isEmpty ? "nothing" : changes) as NSString, level.rawValue as NSString))
        }
        print(String(format: "(%.1f s)", seconds))
        if let path = value("out") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(out).write(to: URL(filePath: path))
        }
    }

    /// `--option-table table.csv`, for tracing a margin (emmettl/bombcad-work#101): each side's cost
    /// and chance under each option, without the site-wide changes; its chance again with the load
    /// held at each of `quantiles` standard deviations of its scatter; and, with `--confirm`, its
    /// chance on the run's histories. A side's chances are its own, so any per-side rule's plan can
    /// be found from the table.
    static func optionTable(
        path: String, scene: Scenario, cellSize: Float, inputs: ProtectionModel.Inputs,
        terms: FacadeLoadSurrogate.TermSet, model: ProtectionModel.Model,
        reference: SurrogateBench.Reference?,
        quantiles: [Double] = [-2, -1.5, -1, -0.5, 0, 0.5, 1, 1.25, 1.5, 1.75, 2, 2.25, 2.5, 2.75, 3]
    ) throws {
        var plain = inputs
        plain.margin = nil
        let models =
            try [ProtectionModel.model(scene: scene, cellSize: cellSize, inputs: plain, terms: terms)]
            + quantiles.map { z in
                var held = plain
                held.margin = .init(kind: .quantile, value: z)
                return try ProtectionModel.model(scene: scene, cellSize: cellSize, inputs: held, terms: terms)
            }
        for m in models { ProtectionModel.prepare(m) }
        let problem = models[0].problem
        let options = problem.sides.first?.options.count ?? 0
        // Every side under each option at once: a plan per option, judged on the run.
        let uniform = (0..<options).map {
            ProtectionSearch.evaluate(
                problem, site: [], choices: Array(repeating: $0, count: problem.sides.count),
                method: "uniform")
        }
        let run = reference.map { confirm(reference: $0, model: model, plans: uniform) }
        var rows = [
            "side,name,glazedM2,option,glazing,cost,chance,"
                + quantiles.map { String(format: "q%+.2f", $0) }.joined(separator: ",") + ",run"
        ]
        for (s, side) in problem.sides.enumerated() {
            for (o, option) in side.options.enumerated() {
                let held = models.dropFirst().map { String(format: "%.6g", $0.problem.chance([], s, o)) }
                let judged =
                    run?[uniform[o].choices]?.chances[side.name].map { String(format: "%.6g", $0) } ?? ""
                rows.append(
                    "\(s),\"\(side.name)\",\(String(format: "%.3f", model.glazedM2[s])),\(o),\(option.glazing),"
                        + String(format: "%.4f,%.6g,", option.cost, problem.chance([], s, o))
                        + held.joined(separator: ",") + ",\(judged)")
            }
        }
        try rows.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        print("Wrote \(problem.sides.count) sides' \(options) options to \(path)")
    }

    /// Each plan's sides judged on a run's saved façade histories by `EnvelopeDamageAssessment`
    /// itself, its buildings under the plan's constructions (`ProtectionModel.constructions`): each
    /// side's chance that some pane is thrown worse than its condition, as the assessment gives it
    /// (`GlazingBreakage.worse`), averaged over each building's glass strength drawn as the chances
    /// drew it (`ProtectionModel.strength`), with E1300's scatter from pane to pane within each draw.
    static func confirm(
        reference: SurrogateBench.Reference, model: ProtectionModel.Model, plans: [ProtectionSearch.Plan]
    ) -> [[Int]: Confirmation] {
        let scene = reference.scene
        let objects = reference.objects
        let loads = reference.strips.map { strip -> EnvelopeComponentLoad in
            let saved = reference.index.strips[strip.saved]
            let c = strip.component
            return EnvelopeComponentLoad(
                id: c.id, owner: objects[strip.object].id, kind: .facade, region: c.region, axis: c.axis,
                binS: saved.binS, outerPa: reference.net(strip.saved),
                innerPa: Array(repeating: 0, count: saved.count), supportEdges: c.supportEdges,
                outward: c.outward)
        }
        let problem = model.problem
        let target = model.accepted
        let object = Dictionary(zip(model.owners, model.objects), uniquingKeysWith: { a, _ in a })
        var out: [[Int]: Confirmation] = [:]
        for plan in plans where out[plan.choices] == nil {
            let changed = Dictionary(
                uniqueKeysWithValues: ProtectionModel.constructions(plan, model: model, scene: scene).map {
                    ($0.objectID, $0)
                })
            var chances = [Double?](repeating: nil, count: problem.sides.count)
            // Each building's glass drawn as its sides' chances drew it, the run's loads as they were.
            for condition in Set(model.condition) {
                for draw in 0..<model.draws {
                    let assessed = EnvelopeDamageAssessment.assess(
                        loads: loads, constructions: { changed[$0] ?? scene.envelopeConstruction(for: $0) },
                        hazard: condition,
                        glassStrength: { owner in
                            object[owner].map {
                                ProtectionModel.strength(seed: model.seed, draw: draw, object: $0)
                            } ?? 1
                        })
                    let byOwner = Dictionary(uniqueKeysWithValues: assessed.map { ($0.id, $0) })
                    for s in problem.sides.indices where model.condition[s] == condition {
                        let side = byOwner[model.owners[s]]?.facadeGlass?.first {
                            $0.axis == model.axes[s] && $0.outward == model.outwards[s]
                        }
                        if let side {
                            chances[s] = (chances[s] ?? 0) + (side.glass.worse ?? 0) / Double(model.draws)
                        }
                    }
                }
            }
            let judged = chances.indices.compactMap { s in chances[s].map { (problem.sides[s].name, $0) } }
            out[plan.choices] = Confirmation(
                sides: judged.count, meets: judged.allSatisfy { $0.1 <= target },
                worst: judged.map(\.1).max() ?? 0, expectedFailing: judged.reduce(0) { $0 + $1.1 },
                chances: Dictionary(judged, uniquingKeysWith: { a, b in max(a, b) }))
        }
        return out
    }
}
