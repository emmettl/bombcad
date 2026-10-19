import BlastCore
import Foundation
import simd

/// `scenebench protect (<district-scene's inputs> | --scene layout.json) [--dx 4] --inputs
/// protect.json [--samples posterior.csv [--sample-count 24]] [--confirm loads-folder] [--out
/// plans.json]`: the least costly glazing and stand-off changes that keep each building side's
/// chance of glass thrown worse than its target condition under the chance accepted
/// (docs/protective-design.md, "In BombCAD"). The inputs file gives the threat, the target and
/// the changes allowed with the user's costs (`ProtectionModel.Inputs`); `--samples` takes the
/// threat from `infer-charge --samples` instead (masses, and places about the scene's charge).
/// `--confirm` re-judges the plans that leave the threat where it is on a run's saved façade
/// histories (`district-compare --save-loads`) of the same scene, under each plan's glazing.
enum Protect {
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

    static func run(_ args: [String]) throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        func value(_ name: String) -> String? { SurrogateBench.value(args, name) }
        guard let inputsPath = value("inputs") else {
            throw BlastError.allocationFailed("--inputs protect.json")
        }
        var inputs = try JSONDecoder().decode(
            ProtectionModel.Inputs.self, from: Data(contentsOf: URL(filePath: inputsPath)))
        let scene: Scenario
        let cellSize: Float
        if let path = value("scene") {
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
        let model = try ProtectionModel.model(scene: scene, cellSize: cellSize, inputs: inputs)
        let problem = model.problem
        let options = problem.sides.first?.options.count ?? 0
        print(
            "\(problem.sides.count) glazed sides, \(options) options each, \(problem.site.count) site-wide changes, "
                + "\(inputs.threats.count) threat place\(inputs.threats.count == 1 ? "" : "s"), \(inputs.draws ?? 64) draws"
        )
        var plans: [(String, ProtectionSearch.Plan)] = []
        let built = ProtectionSearch.asBuilt(problem)
        if problem.site.count <= 12 {
            ProtectionModel.prepare(model)
            print(String(format: "Chances in %.1f s", DistrictBenchmark.seconds(start)))
            let all = ProtectionSearch.exact(problem)
            plans = ProtectionSearch.ranked(problem, plans: all).enumerated().map {
                ("\($0.offset + 1)", $0.element)
            }
        }
        plans.insert(("as built", built), at: 0)
        plans.append(("greedy", ProtectionSearch.greedy(problem)))
        plans.append(("annealing", ProtectionSearch.anneal(problem, seed: inputs.seed ?? 1)))
        let seconds = DistrictBenchmark.seconds(start)

        // Confirmation on a run's histories, for the plans that leave the threat in place.
        let confirmations = try value("confirm").map { folder in
            try confirm(
                args: args, folder: folder, scene: scene, model: model, inputs: inputs,
                plans: plans.map(\.1).filter { $0.site.isEmpty })
        }

        let target = problem.targetChance
        var out: [PlanJSON] = []
        print(
            String(
                format:
                    "Target: no pane thrown worse than the side's condition, except with a chance under %.0f%%",
                target * 100))
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

    /// Each plan's sides judged on a run's saved histories under its glazing: each building's
    /// glass strength drawn as the surrogate's chances draw it, the run's load as recorded.
    static func confirm(
        args: [String], folder: String, scene: Scenario, model: ProtectionModel.Model,
        inputs: ProtectionModel.Inputs,
        plans: [ProtectionSearch.Plan]
    ) throws -> [[Int]: Confirmation] {
        var a = args
        a += ["--loads", folder]
        let reference = try SurrogateBench.Reference(a)
        let objects = reference.objects
        // The run's strips by side, named as the model names them.
        var bySide: [String: [Int]] = [:]
        for (m, strip) in reference.strips.enumerated() {
            let c = strip.component
            let face = c.axis == 0 ? (c.outward > 0 ? "east" : "west") : (c.outward > 0 ? "north" : "south")
            bySide["\(objects[strip.object].name) \(face)", default: []].append(m)
        }
        let problem = model.problem
        let draws = max(1, inputs.draws ?? 64)
        let seed = inputs.seed ?? 1
        var out: [[Int]: Confirmation] = [:]
        for plan in plans where out[plan.choices] == nil {
            var chances = [Double?](repeating: nil, count: problem.sides.count)
            chances.withUnsafeMutableBufferPointer { result in
                SurrogateBench.concurrentlyEach(problem.sides.count) { s in
                    let name = model.names[s]
                    guard let members = bySide[name], !members.isEmpty else { return }
                    let option = plan.choices[s]
                    let glazing = option == 0 ? nil : inputs.glazing[option - 1]
                    if glazing?.kind == .infill {
                        result[s] = 0
                        return
                    }
                    let object = reference.strips[members[0]].object
                    // The run's scene is laid out again, its buildings' ids its own.
                    guard let mix = reference.scene.envelopeConstruction(for: objects[object].id).glazing
                    else {
                        return
                    }
                    let condition = model.condition[s]
                    var sum = 0.0
                    for k in 0..<draws {
                        let strength =
                            ProtectionModel.strength(seed: seed, draw: k, object: object)
                            * (glazing?.kind == .toughened ? (glazing?.strength ?? 4) : 1)
                        var logNone = 0.0
                        var worse = 0.0
                        for m in members {
                            let saved = reference.strips[m].saved
                            let strip = reference.index.strips[saved]
                            let net = reference.net(saved)
                            if glazing?.kind == .laminated {
                                for pane in mix.panes
                                where pane.areaM2 > 0 && pane.share > 0
                                    && FacadeLoadSurrogate.laminatedCondition(
                                        pane, laminate: glazing?.laminate ?? .facade, pressures: net,
                                        binS: strip.binS)
                                        > condition
                                {
                                    worse = 1
                                }
                            } else {
                                logNone +=
                                    FacadeLoadSurrogate.glassOutcome(
                                        mix, netPa: net, binS: strip.binS, areaM2: strip.areaM2,
                                        strength: strength,
                                        worseThan: condition
                                    ).logNoneWorse
                            }
                        }
                        sum += glazing?.kind == .laminated ? worse : 1 - exp(logNone)
                        // The run's load does not vary between draws: one draw is all a laminate needs.
                        if glazing?.kind == .laminated {
                            sum *= Double(draws)
                            break
                        }
                    }
                    result[s] = sum / Double(draws)
                }
            }
            let judged = chances.indices.compactMap { s in chances[s].map { (problem.sides[s].name, $0) } }
            out[plan.choices] = Confirmation(
                sides: judged.count, meets: judged.allSatisfy { $0.1 <= problem.targetChance },
                worst: judged.map(\.1).max() ?? 0, expectedFailing: judged.reduce(0) { $0 + $1.1 },
                chances: Dictionary(uniqueKeysWithValues: judged))
        }
        return out
    }
}
