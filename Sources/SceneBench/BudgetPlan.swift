import BlastCore
import Foundation
import simd

/// `scenebench budget-plan --explorer square|street|beirut [--place name] --budgets 50000,200000
/// [--objective people|glass] [--people kummer|bowen] [--structure] [--engine cpu] [--judge]
/// [--ranking 12] [--evaluations 400] [--seconds 30]`: the best protection for each budget
/// (emmettl/bombcad-work#117, stage 2; `ProtectionBudget`), searched through the learned response as the
/// app's sheet searches, timed. With `--judge`, the pick, the scene as built and a few hand-placed plans
/// of the same budget, each by the live model and by the full estimate, as on a let-go; with
/// `--ranking n`, the n best site-wide plans the search tried, each looked at by both, and how often
/// the two order a pair alike.
enum BudgetPlanBench {
    static func run(_ args: [String]) throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        func value(_ name: String) -> String? { SurrogateBench.value(args, name) }
        let (district, dx) = try ResponseData.district(args)
        var scene = district
        let origin = district.charge.position
        let explorer = value("explorer").flatMap(ExplorerScene.init(rawValue:))
        if let name = value("place") {
            guard let place = explorer?.place(name) else {
                throw BlastError.allocationFailed("--place: one of the explorer scene's places")
            }
            scene.charge.position.x = origin.x + place.offset.x
            scene.charge.position.y = origin.y + place.offset.y
        }
        let charge = scene.charge.position
        let terms = try SurrogateBench.termSet(args)
        var people = OccupantInjury.Assumptions()
        if value("people") == "bowen" { people.glass = .thrownGlass }
        let objective: ProtectionBudget.Objective = value("objective") == "glass" ? .glassThrown : .peopleHurt
        let structure = args.contains("--structure")
        let budgets = (value("budgets") ?? "50000,200000,1000000").split(separator: ",").compactMap {
            Double($0)
        }
        guard let weights = LiveResponse.Weights.builtIn else {
            throw BlastError.allocationFailed("no weights")
        }
        let engine: LiveResponse.Engine =
            value("engine") == "cpu"
            ? LiveResponse.CPUEngine(weights: weights) : try LiveDragGPU(weights: weights)
        let model = LiveResponse.Model(
            weights: weights, engine: engine, ranges: LiveResponse.TrainingRanges.forBuiltInWeights)
        let leaves = !(explorer?.keepsLearnedResponse ?? false)

        let laying = ContinuousClock.now
        let prepared = FacadeLoadSurrogate.Prepared(
            scene: scene, cellSize: dx, incidence: terms.coefficients.incidence
        ).withFacadeBands(value("bands").flatMap(Int.init) ?? FacadeLoadSurrogate.Prepared.defaultFacadeBands)
        print(
            String(
                format:
                    "%@: %d buildings, %d glazed, prepared in %.2f s; charge %.0f kg at (%.0f, %.0f); %@, %@%@",
                scene.name as NSString, scene.envelopeObjects.count, ProtectionBudget.buildings(scene).count,
                DistrictBenchmark.seconds(laying), Double(scene.charge.mass), charge.x - origin.x,
                charge.y - origin.y,
                objective.label as NSString, people.glass.label as NSString,
                structure ? ", walls counted" : ""))
        let live = ProtectionBudget.Look(
            scene: scene, cellSize: dx, mode: .live(model, leavesUntrainedToCPU: leaves), terms: terms,
            people: people, structure: structure, prepared: prepared)
        let full = ProtectionBudget.Look(
            scene: scene, cellSize: dx, mode: .full, terms: terms, people: people, structure: true,
            prepared: prepared)
        let judge = args.contains("--judge")
        let ranking = value("ranking").flatMap(Int.init) ?? 0
        let names = Dictionary(uniqueKeysWithValues: scene.envelopeObjects.map { ($0.id, $0.name) })
        let standOff = explorer?.standOff?.budget(origin: origin)

        func figure(_ o: ProtectionBudget.Outcome) -> Double { objective == .peopleHurt ? o.hurt : o.glassM2 }
        func fullOf(_ plan: ProtectionBudget.Plan) throws -> ProtectionBudget.Outcome {
            let c = plan.site.standOffM.flatMap { d in standOff.map { $0.kept(charge, at: d) } } ?? charge
            return try full.evaluate(barriers: plan.site.barriers, charge: c, glass: plan.glass)
        }
        func liveOf(_ plan: ProtectionBudget.Plan) throws -> ProtectionBudget.Outcome {
            let c = plan.site.standOffM.flatMap { d in standOff.map { $0.kept(charge, at: d) } } ?? charge
            return try live.evaluate(barriers: plan.site.barriers, charge: c, glass: plan.glass)
        }
        let clock = ContinuousClock.now
        let fullAsBuilt =
            judge || ranking > 0 ? try full.evaluate(barriers: [], charge: charge, glass: [:]) : nil
        if let fullAsBuilt {
            print(
                String(
                    format: "Full estimate as built: %.1f (in %.1f s)", figure(fullAsBuilt),
                    DistrictBenchmark.seconds(clock)))
        }

        // `--follow east,north;…`: how closely the learned response follows its own CPU preview, side by
        // side, and both the full estimate, with the charge at each place (the scene as built).
        if let places = value("follow") {
            var u = FacadeLoadSurrogate.Uncertainty(
                yieldLogSD: log(1.5) / 1.645, loadScatter: terms.loadScatter, samples: 10)
            u.stratified = true
            var uf = FacadeLoadSurrogate.Uncertainty(
                yieldLogSD: log(1.5) / 1.645, loadScatter: terms.loadScatter, samples: 100)
            uf.stratified = false
            struct Key: Hashable {
                var o: UUID
                var a: Int
                var w: Int
            }
            func sides(_ g: [FacadeLoadSurrogate.SideGlass]) -> [Key: FacadeLoadSurrogate.SideGlass] {
                Dictionary(
                    g.map { (Key(o: $0.owner, a: $0.axis, w: $0.outward), $0) },
                    uniquingKeysWith: { a, _ in a })
            }
            func within(_ pairs: [(Double, Double)]) -> String {
                guard !pairs.isEmpty else { return "none" }
                let n = Double(pairs.count)
                return String(
                    format: "%.1f%% within 0.1, mean |d| %.3f",
                    100 * Double(pairs.filter { abs($0.0 - $0.1) <= 0.1 }.count) / n,
                    pairs.reduce(0) { $0 + abs($1.0 - $1.1) } / n)
            }
            var all: [String: [(Double, Double)]] = [:]
            for place in places.split(separator: ";") {
                let xy = place.split(separator: ",").compactMap { Float($0) }
                guard xy.count == 2 else { continue }
                var c = charge
                c.x = origin.x + xy[0]
                c.y = origin.y + xy[1]
                let mass = Double(scene.charge.mass)
                let clock = ContinuousClock.now
                guard
                    let lv = try prepared.livePreview(
                        charge: c, mass: mass, uncertainty: u, parts: .glass, terms: terms, model: model,
                        leavesUntrainedToCPU: false)?.look
                else { throw BlastError.allocationFailed("no live look") }
                let liveS = DistrictBenchmark.seconds(clock)
                // The app's path: what lies outside the training left to the CPU.
                let appClock = ContinuousClock.now
                if let app = try prepared.livePreview(
                    charge: c, mass: mass, uncertainty: u, parts: .glass, terms: terms, model: model,
                    leavesUntrainedToCPU: true)?.look
                {
                    print(
                        String(
                            format:
                                "  the app's path: %d of %d buildings left to the CPU, %.1f ms; people hurt %.1f",
                            app.leftToCPU, app.liveBuildings + app.leftToCPU,
                            1000 * DistrictBenchmark.seconds(appClock),
                            OccupantInjury.estimate(
                                scene: scene, glass: app.glass, structure: [], charge: c, mass: mass,
                                assumptions: people, preview: true, draws: 40
                            ).expected))
                }
                let cpuClock = ContinuousClock.now
                let pv = prepared.look(
                    charge: c, mass: mass, constructions: { scene.envelopeConstruction(for: $0) },
                    uncertainty: u,
                    preview: true, parts: .glass, terms: terms)
                let cpuS = DistrictBenchmark.seconds(cpuClock)
                let fl = prepared.look(
                    charge: c, mass: mass, constructions: { scene.envelopeConstruction(for: $0) },
                    uncertainty: uf,
                    parts: .glass, terms: terms)
                let (l, p, f) = (sides(lv.glass), sides(pv.glass), sides(fl.glass))
                for (name, get) in [
                    ("some broken", { (x: FacadeLoadSurrogate.SideGlass) in x.someBroken }),
                    ("blown out", { $0.blownOut }), ("fraction broken", { $0.fractionBroken }),
                    ("thrown past 3b", { $0.thrownPast3b }), ("thrown hurt", { $0.thrownHurt ?? 0 }),
                ] {
                    let lp = l.compactMap { k, x in p[k].map { (get(x), get($0)) } }
                    let pf = p.compactMap { k, x in f[k].map { (get(x), get($0)) } }
                    let lf = l.compactMap { k, x in f[k].map { (get(x), get($0)) } }
                    all["live/cpu " + name, default: []] += lp
                    all["cpu/full " + name, default: []] += pf
                    all["live/full " + name, default: []] += lf
                    print(
                        String(
                            format:
                                "At (%.0f, %.0f) %@: live against CPU preview %@; CPU preview against full %@",
                            xy[0], xy[1], name as NSString, within(lp) as NSString, within(pf) as NSString))
                }
                print(
                    String(
                        format: "  live look %.1f ms, CPU preview %.1f ms (glass only, after the first)",
                        1000 * liveS, 1000 * cpuS))
                func hurt(_ g: [FacadeLoadSurrogate.SideGlass], _ preview: Bool) -> Double {
                    OccupantInjury.estimate(
                        scene: scene, glass: g, structure: [], charge: c, mass: mass, assumptions: people,
                        preview: preview, draws: preview ? 40 : 200
                    ).expected
                }
                print(
                    String(
                        format: "  people hurt: live %.1f, CPU preview %.1f, full %.1f", hurt(lv.glass, true),
                        hurt(pv.glass, true), hurt(fl.glass, false)))
            }
            for key in all.keys.sorted() { print("All places, \(key): \(within(all[key]!))") }
            return
        }
        // `--diagnose east,north;…`: the CPU's preview against the full estimate building by building,
        // with the charge at each place: the people, the share of glass broken, and the worst buildings.
        if let places = value("diagnose") {
            var u = FacadeLoadSurrogate.Uncertainty(
                yieldLogSD: log(1.5) / 1.645, loadScatter: terms.loadScatter, samples: 10)
            u.stratified = true
            var uf = FacadeLoadSurrogate.Uncertainty(
                yieldLogSD: log(1.5) / 1.645, loadScatter: terms.loadScatter, samples: 100)
            uf.stratified = false
            for place in places.split(separator: ";") {
                let xy = place.split(separator: ",").compactMap { Float($0) }
                guard xy.count == 2 else { continue }
                var c = charge
                c.x = origin.x + xy[0]
                c.y = origin.y + xy[1]
                let pv = prepared.look(
                    charge: c, mass: Double(scene.charge.mass),
                    constructions: { scene.envelopeConstruction(for: $0) },
                    uncertainty: u, preview: true, parts: .glass, terms: terms)
                let fl = prepared.look(
                    charge: c, mass: Double(scene.charge.mass),
                    constructions: { scene.envelopeConstruction(for: $0) },
                    uncertainty: uf, parts: .glass, terms: terms)
                let pp = OccupantInjury.estimate(
                    scene: scene, glass: pv.glass, structure: [], charge: c, mass: Double(scene.charge.mass),
                    assumptions: people, preview: true, draws: 40)
                let fp = OccupantInjury.estimate(
                    scene: scene, glass: fl.glass, structure: [], charge: c, mass: Double(scene.charge.mass),
                    assumptions: people, draws: 200)
                let fb = Dictionary(uniqueKeysWithValues: fp.buildings.map { ($0.owner, $0) })
                let rows = pp.buildings.compactMap { b in fb[b.owner].map { (b, $0) } }
                let over = rows.map { $0.0.expected - $0.1.expected }
                print(
                    String(
                        format:
                            "At (%.0f, %.0f): people preview %.1f, full %.1f; broken share mean preview %.3f, full %.3f; buildings over by >1 person %d, under %d",
                        xy[0], xy[1], pp.expected, fp.expected,
                        rows.reduce(0) { $0 + $1.0.broken } / Double(max(rows.count, 1)),
                        rows.reduce(0) { $0 + $1.1.broken } / Double(max(rows.count, 1)),
                        over.filter { $0 > 1 }.count, over.filter { $0 < -1 }.count))
                // Sides: the preview's strips against the full estimate's, by the side's distance.
                struct Key: Hashable {
                    var o: UUID
                    var a: Int
                    var w: Int
                }
                let fs = Dictionary(
                    fl.glass.map { (Key(o: $0.owner, a: $0.axis, w: $0.outward), $0) },
                    uniquingKeysWith: { a, _ in a })
                var bands: [Int: (n: Int, p: Double, f: Double)] = [:]
                for side in pv.glass {
                    guard let f = fs[Key(o: side.owner, a: side.axis, w: side.outward)] else { continue }
                    let band = min(Int(f.distanceM / 25), 12)
                    let e = bands[band] ?? (0, 0, 0)
                    bands[band] = (e.n + 1, e.p + side.fractionBroken, e.f + f.fractionBroken)
                }
                for band in bands.keys.sorted() {
                    let e = bands[band]!
                    print(
                        String(
                            format: "  sides %3d–%3d m: %4d, broken share preview %.3f, full %.3f", band * 25,
                            band * 25 + 25, e.n, e.p / Double(e.n), e.f / Double(e.n)))
                }
                let worst = rows.sorted {
                    abs($0.0.expected - $0.1.expected) > abs($1.0.expected - $1.1.expected)
                }
                .prefix(5)
                for (p, f) in worst {
                    print(
                        String(
                            format:
                                "  %@ at %.0f m: preview %.1f hurt (broken %.2f), full %.1f (broken %.2f)",
                            (names[p.owner] ?? "?") as NSString, p.distanceM, p.expected, p.broken,
                            f.expected, f.broken))
                }
            }
            return
        }
        // `--compare-at east,north;…`: the scene as built with the charge at each place (metres from the
        // scene's first charge), by the live model, the CPU's preview and the full estimate.
        if let places = value("compare-at") {
            let cpu = ProtectionBudget.Look(
                scene: scene, cellSize: dx, mode: .preview, terms: terms, people: people,
                structure: structure,
                prepared: prepared)
            let liveWalls = ProtectionBudget.Look(
                scene: scene, cellSize: dx, mode: .live(model, leavesUntrainedToCPU: leaves), terms: terms,
                people: people, structure: true, prepared: prepared)
            var calibration: [UUID: Double]?
            for place in places.split(separator: ";") {
                let xy = place.split(separator: ",").compactMap { Float($0) }
                guard xy.count == 2 else { continue }
                var c = charge
                c.x = origin.x + xy[0]
                c.y = origin.y + xy[1]
                let a = try live.evaluate(barriers: [], charge: c, glass: [:])
                let w = try liveWalls.evaluate(barriers: [], charge: c, glass: [:])
                let b = try cpu.evaluate(barriers: [], charge: c, glass: [:])
                let f = try full.evaluate(barriers: [], charge: c, glass: [:])
                // Each building's live figure scaled by the full's against the live's at the first place.
                if calibration == nil {
                    calibration = a.buildings.mapValues { _ in 1 }
                    for (id, l) in a.buildings where l.hurt > 0 {
                        calibration?[id] = (f.buildings[id]?.hurt ?? 0) / l.hurt
                    }
                }
                let calibrated = a.buildings.reduce(0.0) { $0 + $1.value.hurt * (calibration?[$1.key] ?? 1) }
                print(
                    String(
                        format:
                            "At (%.0f, %.0f): live %.1f, live with walls %.1f, CPU preview %.1f, full %.1f, live calibrated at the first %.1f",
                        xy[0], xy[1], figure(a), figure(w), figure(b), figure(f), calibrated))
            }
            return
        }
        for budget in budgets {
            var problem = ProtectionBudget.Problem(scene: scene, budget: budget)
            problem.objective = objective
            problem.people = people
            problem.standOff = standOff
            problem.maxEvaluations = value("evaluations").flatMap(Int.init) ?? 400
            problem.timeLimitS = value("seconds").flatMap(Double.init) ?? 30
            var firstBest: (Int, Double)?
            let result = try ProtectionBudget.optimise(problem, evaluator: live) { p in
                if firstBest == nil || p.bestValue < firstBest!.1 - 1e-9 {
                    firstBest = (p.evaluations, p.bestValue)
                }
                return true
            }
            let plan = result.plan
            print(
                String(
                    format:
                        "\nBudget $%.0f: %@ for $%.0f (walls %.0f, glass %.0f, stand-off %.0f); live %.1f against %.1f as built (%+.1f%%); %d looks in %.2f s (%.1f ms a look)",
                    budget, plan.label as NSString, plan.cost.total, plan.cost.barriers, plan.cost.glass,
                    plan.cost.standOff, result.value, result.asBuiltValue,
                    100 * (result.value / max(result.asBuiltValue, 1e-9) - 1), result.evaluations,
                    result.seconds,
                    1000 * result.seconds / Double(max(result.evaluations, 1))))
            for wall in plan.site.barriers {
                print(
                    String(
                        format:
                            "  wall at (%.1f, %.1f) from the scene's first charge, along %@, %g m by %g m",
                        wall.centre.x - origin.x, wall.centre.y - origin.y, wall.alongX ? "x" : "y",
                        wall.lengthM,
                        wall.heightM))
            }
            let glassNames = plan.glass.keys.compactMap { names[$0] }.sorted().prefix(6)
            if !glassNames.isEmpty {
                print(
                    "  glass in: " + glassNames.joined(separator: ", ") + (plan.glass.count > 6 ? ", …" : ""))
            }
            for f in result.finalists {
                print(
                    String(
                        format: "  finalist, %@: %@, $%.0f, live %.1f", f.why as NSString,
                        f.plan.label as NSString,
                        f.plan.cost.total, figure(f.outcome)))
            }
            guard let fullAsBuilt else { continue }
            let refereed = try ProtectionBudget.referee(result, problem: problem, referee: full)
            print(
                String(
                    format: "  Refereed by the full estimate in %.1f s: %@ (%@), full %.1f (%+.1f%%)%@",
                    refereed.seconds, refereed.best.why as NSString, refereed.best.plan.label as NSString,
                    figure(refereed.finalists[0].judged),
                    100 * (figure(refereed.finalists[0].judged) / max(figure(fullAsBuilt), 1e-9) - 1),
                    refereed.keepsTheSearchsBest
                        ? "; the live search's best kept" : "; not the live search's best"))
            for (f, judged) in refereed.finalists {
                print(
                    String(
                        format: "    %@: live %.1f, full %.1f", f.why as NSString, figure(f.outcome),
                        figure(judged)))
            }

            // The hand-placed plans of the same budget.
            var plans: [(String, ProtectionBudget.Plan)] = [
                ("The optimiser's pick", refereed.best.plan)
            ]
            plans += baselines(problem, origin: origin, explorer: explorer)
            print("  Plan | cost | live | full | full against as built")
            var rows: [(String, Double, Double)] = []
            for (name, p) in plans {
                let picked = name == "The optimiser's pick"
                let l = picked ? refereed.finalists[0].finalist.outcome : try liveOf(p)
                let f = picked ? refereed.finalists[0].judged : try fullOf(p)
                rows.append((name, figure(l), figure(f)))
                print(
                    String(
                        format: "  %@ (%@) | $%.0f | %.1f | %.1f | %+.1f%%", name as NSString,
                        p.label as NSString,
                        p.cost.total, figure(l), figure(f),
                        100 * (figure(f) / max(figure(fullAsBuilt), 1e-9) - 1)))
            }
            let pick = rows[0].2
            let beaten = rows.dropFirst().filter { $0.2 < pick - 1e-9 }
            print(
                "  By the full estimate the pick is "
                    + (beaten.isEmpty
                        ? "the best of these" : "beaten by " + beaten.map(\.0).joined(separator: ", ")))

            if ranking > 1 {
                // The search's best site-wide plans, without glass, by both.
                let sites = Array(result.tried.prefix(ranking))
                var pairs: [(Double, Double, Bool)] = []
                for (site, _) in sites {
                    let p = ProtectionBudget.Plan(site: site, glass: [:], cost: .init())
                    pairs.append((figure(try liveOf(p)), figure(try fullOf(p)), site.standOffM == nil))
                }
                for (n, row) in rows.enumerated() {
                    pairs.append((row.1, row.2, plans[n].1.site.standOffM == nil))
                }
                print("  Ranking, all: " + concordance(pairs.map { ($0.0, $0.1) }))
                print(
                    "  Ranking, the charge where it is (walls and glass): "
                        + concordance(pairs.filter(\.2).map { ($0.0, $0.1) }))
            }
        }
    }

    /// How often the live and the full order a pair of plans alike, of the pairs the full tells apart
    /// by more than 0.5%.
    static func concordance(_ pairs: [(Double, Double)]) -> String {
        var agree = 0
        var total = 0
        for i in pairs.indices {
            for j in pairs.indices where j > i {
                let (a, b) = (pairs[i], pairs[j])
                guard abs(a.1 - b.1) > 0.005 * max(abs(a.1), abs(b.1), 1e-9) else { continue }
                total += 1
                if (a.0 - b.0) * (a.1 - b.1) > 0 { agree += 1 }
            }
        }
        return String(
            format: "%d plans, %d pairs told apart by the full estimate: the live orders %.0f%% alike",
            pairs.count,
            total, total > 0 ? 100 * Double(agree) / Double(total) : 100)
    }

    /// Plans a person might make by hand for the same budget: the explorer's wall in front of the
    /// protected building; film, or laminated glass, on the buildings nearest the charge until the
    /// money runs out; the stand-off as far as the budget buys; a 4 m wall close in front of the charge.
    static func baselines(_ problem: ProtectionBudget.Problem, origin: SIMD3<Float>, explorer: ExplorerScene?)
        -> [(String, ProtectionBudget.Plan)]
    {
        let scene = problem.scene
        let charge = scene.charge.position
        let q = SIMD2(charge.x, charge.y)
        let buildings = ProtectionBudget.buildings(scene)
        var out: [(String, ProtectionBudget.Plan)] = []
        func wallPlan(_ wall: LiveResponse.WhatIf.Barrier) -> ProtectionBudget.Plan? {
            let cost = Double(wall.lengthM * wall.heightM) * problem.costs.barrierPerM2
            guard cost <= problem.budget,
                ProtectionBudget.stands(
                    wall, in: scene, charge: charge, buildings: buildings, least: problem.leastWallM)
            else { return nil }
            return ProtectionBudget.Plan(
                site: ProtectionBudget.Site(barriers: [wall]), glass: [:],
                cost: .init(barriers: cost, glass: 0, standOff: 0))
        }
        // The explorer's "Put a Wall in Front".
        let target: SIMD2<Float> =
            explorer?.standOff.map { SIMD2(origin.x, origin.y) + $0.from } ?? SIMD2(origin.x, origin.y + 30)
        let d = simd_length(target - q)
        let share: Float =
            explorer?.standOff == nil ? (d > 1 ? min(15 / d, 0.5) : 0.5) : (d > 12 ? (d - 6) / d : 0.5)
        if let p = wallPlan(
            .across(from: q, to: d > 1 ? target : q + SIMD2(0, 30), at: share, lengthM: 30, heightM: 3))
        {
            out.append(("Wall in front", p))
        }
        // A 4 m wall as near the charge as a wall may stand, towards the nearest glazed building, as long
        // as affordable.
        if let nearest = buildings.min(by: {
            simd_length(SIMD2($0.bounds.centre.x, $0.bounds.centre.y) - q)
                < simd_length(SIMD2($1.bounds.centre.x, $1.bounds.centre.y) - q)
        }) {
            let to = SIMD2(nearest.bounds.centre.x, nearest.bounds.centre.y)
            let dist = simd_length(to - q)
            for length in problem.lengths.sorted().reversed() {
                let at = problem.leastWallM + 1
                if dist > at + 2,
                    let p = wallPlan(.across(from: q, to: to, at: at / dist, lengthM: length, heightM: 4))
                {
                    out.append(("Tall wall by the charge", p))
                    break
                }
            }
        }
        // Glass on the nearest buildings.
        let byDistance = buildings.sorted {
            simd_length(SIMD2($0.bounds.centre.x, $0.bounds.centre.y) - q)
                < simd_length(SIMD2($1.bounds.centre.x, $1.bounds.centre.y) - q)
        }
        for option in ProtectionBudget.GlassOption.allCases {
            var left = problem.budget
            var glass: [UUID: ProtectionBudget.GlassOption] = [:]
            for b in byDistance {
                let cost = b.glazedM2 * option.costPerM2(problem.costs)
                guard cost <= left else { break }
                left -= cost
                glass[b.id] = option
            }
            if !glass.isEmpty {
                out.append(
                    (
                        option == .film ? "Film on the nearest" : "Laminated on the nearest",
                        ProtectionBudget.Plan(
                            site: ProtectionBudget.Site(), glass: glass,
                            cost: .init(barriers: 0, glass: problem.budget - left, standOff: 0))
                    ))
            }
        }
        // The stand-off, as far as the budget buys.
        if let line = problem.standOff {
            var best: Float?
            for metres in stride(from: line.range.upperBound, through: line.range.lowerBound, by: -1)
            where Double(line.lineM(metres)) * problem.costs.bollardsPerM <= problem.budget {
                best = metres
                break
            }
            if let best, best > line.distance(charge) {
                out.append(
                    (
                        "Stand-off as far as it buys",
                        ProtectionBudget.Plan(
                            site: ProtectionBudget.Site(standOffM: best), glass: [:],
                            cost: .init(
                                barriers: 0, glass: 0,
                                standOff: Double(line.lineM(best)) * problem.costs.bollardsPerM))
                    ))
            }
        }
        return out
    }
}
