import BlastCore
import Foundation

/// `scenebench wall-calibrate <district-scene's inputs> [--radius 1320] --runs mass:folder,…
/// [--draws 100] [--inside 0.85] [--walls stone] [--arching] [--bands 400,700,…] [--coefficients fit.json | --terms clear-top|fitted]
/// [--learned weights.bcfw [--learned-ground ground.bcfw] [--own-scatter [--scatter-tables tables.json]]] [--out calibration.json]`: how well the walls' and roofs' chances
/// (`FacadeLoadSurrogate.structureProbabilities`, Horizons 4) are calibrated against the district's
/// own runs at several yields (`district-compare --save-loads`, with walls and roofs saved). Each
/// building's worst wall and worst roof in each run, judged on the run's histories at the
/// constructions' nominal strength, against its chances drawn over the runs' yields and the
/// surrogate's load scatter (no strength scatter: the runs have none).
enum WallCalibration {
    static func run(_ args: [String]) throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        func value(_ name: String) -> String? { SurrogateBench.value(args, name) }
        guard let runsText = value("runs") else { throw BlastError.allocationFailed("--runs mass:folder,…") }
        let runs = runsText.split(separator: ",").map { part -> (mass: Double, folder: String) in
            let pieces = part.split(separator: ":", maxSplits: 1).map(String.init)
            return (Double(pieces[0]) ?? 0, pieces[1])
        }
        let draws = value("draws").flatMap(Int.init) ?? 100
        // `--walls stone`: every building's walls and roof taken as 0.5 m stone, as surrogate-judge
        // compares them (the map gives Beirut's all as concrete).
        let stone = value("walls") == "stone"
        // `--arching`: masonry walls arch between their returns (`EnvelopeConstruction.masonryArching`).
        let arching = args.contains("--arching")
        func construction(_ scene: Scenario, _ id: UUID) -> EnvelopeConstruction {
            var c = scene.envelopeConstruction(for: id)
            if arching { c.masonryArching = true }
            guard stone else { return c }
            c.walls = .unreinforcedMasonry
            c.wallThicknessM = 0.5
            return c
        }
        let share = Float(value("inside").flatMap(Double.init) ?? 0.85)
        let start = ContinuousClock.now

        // Each run's worst wall and roof by building (its index in the layout, the same in every
        // run: the buildings within the radius), inside the fair part of the run.
        var references: [SurrogateBench.Reference] = []
        var worst: [[Int: (wall: Int, roof: Int)]] = []
        for run in runs {
            var a = args
            a += ["--loads", run.folder, "--mass", String(run.mass)]
            let reference = try SurrogateBench.Reference(a)
            // Only the first is used after its run is judged (its layout, for the chances): the
            // others' loads, a few GB each on Beirut, are let go once judged, so that ten yields
            // never sit in memory at once.
            if references.isEmpty { references.append(reference) }
            let scene = reference.scene
            let tops = reference.objects.map { Double(SurrogateBench.bounds($0).1.z) }
            let bases = reference.objects.map { Double(SurrogateBench.bounds($0).0.z) }
            var levels: [Int: (wall: Int, roof: Int)] = [:]
            func judge(
                _ strip: (saved: Int, object: Int, component: EnvelopeComponent), net: [Double], binS: Double
            ) {
                let component = strip.component
                guard reference.inside(FacadeLoadSurrogate.outerFace(component).centre, share: share) else {
                    return
                }
                let n = strip.object
                let kind = EnvelopeComponentLoad.Kind(rawValue: component.kind.rawValue) ?? .wall
                let load = EnvelopeComponentLoad(
                    id: component.id, owner: reference.objects[n].id, kind: kind, region: component.region,
                    axis: component.axis, binS: binS, outerPa: net,
                    innerPa: Array(repeating: 0, count: net.count),
                    supportEdges: component.supportEdges, outward: component.outward)
                let level =
                    EnvelopeDamageAssessment.assess(
                        load, construction: construction(scene, reference.objects[n].id),
                        buildingTop: tops[n], buildingBase: bases[n]
                    )?.levels.upperBound.rawValue ?? 0
                var current = levels[n] ?? (0, 0)
                if kind == .roof {
                    current.roof = max(current.roof, level)
                } else {
                    current.wall = max(current.wall, level)
                }
                levels[n] = current
            }
            for strip in reference.strips {
                judge(strip, net: reference.net(strip.saved), binS: reference.index.strips[strip.saved].binS)
            }
            for strip in reference.otherStrips where strip.component.kind != .slab {
                judge(
                    strip, net: reference.otherNet(strip.saved),
                    binS: reference.others!.strips[strip.saved].binS)
            }
            worst.append(levels)
            let fallen = levels.values.filter { $0.wall >= EnvelopeDamageLevel.failed.rawValue }.count
            print(
                String(
                    format: "%.0f t: %d buildings judged on the run's histories, %d with a wall failed",
                    run.mass / 1000, levels.count, fallen))
        }

        // The chances, on the first run's layout, drawn over the runs' yields (all, or all but one).
        let first = references[0]
        // `--coefficients fit.json` or `--terms`: the façades' terms to judge, the adopted ones
        // without either; and `--terms`' load scatter (or `--load-scatter`'s).
        let coefficients = try SurrogateBench.coefficients(args)
        let loadScatter = try SurrogateBench.loadScatter(args)
        let surrogateEstimate = FacadeLoadSurrogate.estimate(
            scene: first.scene, cellSize: first.cellSize, coefficients: coefficients)
        // `--learned weights.bcfw`: the learned field model's peak at the ground-floor façade strips
        // (emmettl/bombcad-work#67), as the app's quick estimate takes it with the option on; its
        // peaks are for one yield, so each yield's chances take an estimate of their own.
        // `--learned-ground ground.bcfw`: that network's 2 m field at the ground floor instead,
        // `--learned`'s at the storeys above (emmettl/bombcad-work#69).
        // `--own-scatter`: the chances draw each network's own measured peak scatter where its peak
        // is used (`LearnedField.Scatter.measured`, by the weights' file names), not the surrogate's.
        let ownScatter = args.contains("--own-scatter")
        // `--scatter-tables tables.json`: tables measured otherwise in their place (`ScatterTables`).
        func measured(_ path: String?) throws -> LearnedField.Scatter? {
            try path.flatMap { try ScatterTables.measured(forWeights: $0, args) }
        }
        let learned = try value("learned").map { path in
            let ground = value("learned-ground")
            return LearnedField.Estimator(
                scene: first.scene, network: try LearnedFieldNetwork(contentsOf: URL(filePath: path)),
                groundNetwork: try ground.map { try LearnedFieldNetwork(contentsOf: URL(filePath: $0)) },
                scatter: !ownScatter
                    ? nil
                    : ground == nil
                        ? try measured(path)
                        : LearnedField.Scatter.combining(
                            ground: try measured(ground), upper: try measured(path)))
        }
        if ownScatter {
            let s = learned?.scatter
            print(
                "Own scatter: ground floor \(s?.ground != nil ? "measured" : "none"), above \(s?.upper != nil ? "measured" : "none")"
            )
        }
        let prepared = learned.map { _ in
            FacadeLoadSurrogate.Prepared(scene: first.scene, cellSize: first.cellSize)
        }
        var learnedEstimates: [Double: FacadeLoadSurrogate.Estimate] = [:]
        func estimate(at mass: Double) throws -> FacadeLoadSurrogate.Estimate {
            guard let learned, let prepared else { return surrogateEstimate }
            if let known = learnedEstimates[mass] { return known }
            let charge = first.scene.charge.position
            let made = prepared.estimate(
                charge: charge, mass: mass, coefficients: coefficients,
                learned: try learned.peaks(charge: charge, mass: mass))
            learnedEstimates[mass] = made
            return made
        }
        let index = Dictionary(uniqueKeysWithValues: first.objects.enumerated().map { ($1.id, $0) })
        // With no factor, each building's calibration (`structureCalibration`). `ratio`, the
        // impulse's own factor over the load's.
        func chances(_ masses: [Double], factor: Double?, scale: Double = 1, ratio: Double = 1) throws
            -> [Int:
            FacadeLoadSurrogate.StructureChance]
        {
            let (drawn, seconds) = FacadeLoadSurrogate.structureProbabilities(
                try estimate(at: masses[0]), mass: masses[0], cellSize: first.cellSize,
                constructions: { construction(first.scene, $0) },
                uncertainty: FacadeLoadSurrogate.Uncertainty(
                    masses: masses, loadScatter: loadScatter, samples: draws),
                coefficients: coefficients, strengthScatter: false,
                loadFactor: factor.map { ($0, $0) }, scatterScale: factor == nil ? nil : (scale, scale),
                impulseRatio: ratio == 1 ? nil : (ratio, ratio), learnedPeaks: learned != nil)
            print(
                String(
                    format:
                        "  chances of %d buildings, %d draws, load ×%@, scatter ×%@, impulse ×%.3f, in %.1f s",
                    drawn.count, draws,
                    factor.map { String(format: "%.2f", $0) } ?? "calibrated",
                    factor == nil ? "calibrated" : String(format: "%.2f", scale), ratio, seconds))
            return Dictionary(uniqueKeysWithValues: drawn.compactMap { c in index[c.owner].map { ($0, c) } })
        }
        // `--factors 1,1.2,...`: each tried on every yield, and each yield's chances from the factor
        // that did best (least Brier, walls and roofs at moderate or worse) on the others.
        // `--scales 0.5,1`: the load scatter scaled too, each pair tried.
        // `--impulse-ratios 1,0.83`: the impulse's own factor over the load's, each tried too.
        let factorList = (value("factors") ?? "1").split(separator: ",").compactMap { Double($0) }
        let scaleList = (value("scales") ?? "1").split(separator: ",").compactMap { Double($0) }
        let ratioList = (value("impulse-ratios") ?? "1").split(separator: ",").compactMap { Double($0) }
        let pairs = factorList.flatMap { f in scaleList.flatMap { s in ratioList.map { (f, s, $0) } } }
        let factors = pairs.map(\.0)
        let byIndex = try chances(runs.map(\.mass), factor: factors[0], scale: pairs[0].1, ratio: pairs[0].2)

        // Each building judged in every run, its chances against the share of runs.
        let judged = Set(worst[0].keys).filter { n in worst.allSatisfy { $0[n] != nil } }.sorted()
        let materials = first.objects.map { construction(first.scene, $0.id).walls }
        func reliability(
            _ name: String, _ members: [Int], chance: (FacadeLoadSurrogate.StructureChance) -> Double,
            happened: ((wall: Int, roof: Int)) -> Bool
        ) -> GlassCalibration.Reliability {
            let kept = members.filter { byIndex[$0] != nil }
            let predicted = kept.map { chance(byIndex[$0]!) }
            let observed = kept.map { n in
                Double(worst.filter { happened($0[n]!) }.count) / Double(worst.count)
            }
            return GlassCalibration.reliability(name, predicted: predicted, observed: observed)
        }
        let concrete = judged.filter { [.reinforcedConcrete, .reinforcedBlockwork].contains(materials[$0]) }
        let masonry = judged.filter { materials[$0] == .unreinforcedMasonry }
        let moderate = EnvelopeDamageLevel.moderate.rawValue
        let heavy = EnvelopeDamageLevel.heavy.rawValue
        let results = [
            reliability("concrete walls, moderate or worse", concrete, chance: \.wallsModerate) {
                $0.wall >= moderate
            },
            reliability("concrete walls, heavy or worse", concrete, chance: \.wallsHeavy) {
                $0.wall >= heavy
            },
            reliability("masonry walls, heavy or worse", masonry, chance: \.wallsHeavy) { $0.wall >= heavy },
            reliability("roofs, moderate or worse", judged, chance: \.roofModerate) { $0.roof >= moderate },
        ]
        print(
            "Buildings judged in all \(runs.count) runs: \(judged.count) (concrete \(concrete.count), masonry \(masonry.count))"
        )
        for r in results { show(r) }

        // Each yield held out: its chances at its own yield, on the load factor that did best on
        // the other yields' runs.
        // `--held-out`: this block with a single pair too; `--walls-pair f:s:r` and `--roofs-pair
        // f:s:r` hold the walls' or roofs' choice to that pair of the grid, every yield alike.
        if factors.count > 1 || args.contains("--held-out") {
            let scaleOf = pairs.map(\.1)
            let ratioOf = pairs.map(\.2)
            let atYield: [[[Int: FacadeLoadSurrogate.StructureChance]]] = try factors.indices.map { f in
                try runs.map {
                    try chances([$0.mass], factor: factors[f], scale: scaleOf[f], ratio: ratioOf[f])
                }
            }
            func fixed(_ name: String) -> Int? {
                guard let text = value(name) else { return nil }
                let v = text.split(separator: ":").compactMap { Double($0) }
                return pairs.firstIndex {
                    abs($0.0 - v[0]) < 1e-9 && abs($0.1 - v[1]) < 1e-9
                        && abs($0.2 - (v.count > 2 ? v[2] : 1)) < 1e-9
                }
            }
            let fixedWalls = fixed("walls-pair")
            let fixedRoofs = fixed("roofs-pair")
            // Walls and roofs each choose their own pair, by their own Brier at moderate or worse.
            func brier(_ f: Int, _ j: Int, roofs: Bool) -> Double {
                var sum = 0.0
                for n in judged {
                    guard let c = atYield[f][j][n], let w = worst[j][n] else { continue }
                    let chance = roofs ? c.roofModerate : c.wallsModerate
                    let happened = Double((roofs ? w.roof : w.wall) >= moderate ? 1 : 0)
                    sum += (chance - happened) * (chance - happened)
                }
                return sum
            }
            for f in factors.indices {
                print(
                    String(
                        format:
                            "Load ×%.2f, scatter ×%.2f, impulse ×%.3f, every yield at its own: Brier sum walls %.1f, roofs %.1f",
                        factors[f], scaleOf[f], ratioOf[f],
                        runs.indices.reduce(0) { $0 + brier(f, $1, roofs: false) },
                        runs.indices.reduce(0) { $0 + brier(f, $1, roofs: true) }))
            }
            // Each yield's chances on the pair `choose` gives it (walls, roofs), every building judged
            // against that yield's run, the categories' reliability printed under `title`.
            func judgeAll(_ title: String, choose: (Int) -> (walls: Int, roofs: Int)) {
                var predicted: [String: [Double]] = [:]
                var observed: [String: [Double]] = [:]
                for i in runs.indices {
                    let (walls, roofs) = choose(i)
                    for n in judged {
                        guard let w = worst[i][n], let cw = atYield[walls][i][n],
                            let cr = atYield[roofs][i][n]
                        else { continue }
                        let concreteWalls = [.reinforcedConcrete, .reinforcedBlockwork].contains(materials[n])
                        for (name, chance, happened) in [
                            (
                                concreteWalls
                                    ? "concrete walls, moderate or worse"
                                    : "masonry walls, moderate or worse",
                                cw.wallsModerate, w.wall >= moderate
                            ),
                            (
                                concreteWalls
                                    ? "concrete walls, heavy or worse" : "masonry walls, heavy or worse",
                                cw.wallsHeavy, w.wall >= heavy
                            ),
                            ("roofs, moderate or worse", cr.roofModerate, w.roof >= moderate),
                        ] {
                            predicted[name, default: []].append(chance)
                            observed[name, default: []].append(happened ? 1 : 0)
                        }
                    }
                }
                print(title)
                for name in predicted.keys.sorted() {
                    show(
                        GlassCalibration.reliability(
                            name, predicted: predicted[name]!, observed: observed[name]!))
                }
            }
            judgeAll("Each yield held out, at its own yield (buildings × yields):") { i in
                func best(roofs: Bool) -> Int {
                    if let held = roofs ? fixedRoofs : fixedWalls { return held }
                    return factors.indices.min { a, b in
                        runs.indices.filter { $0 != i }.reduce(0) { $0 + brier(a, $1, roofs: roofs) }
                            < runs.indices.filter { $0 != i }.reduce(0) { $0 + brier(b, $1, roofs: roofs) }
                    }!
                }
                let (walls, roofs) = (best(roofs: false), best(roofs: true))
                print(
                    String(
                        format:
                            "  %.0f t held out: walls load ×%.2f, scatter ×%.2f, impulse ×%.3f; roofs load ×%.2f, scatter ×%.2f, impulse ×%.3f",
                        runs[i].mass / 1000, factors[walls], scaleOf[walls], ratioOf[walls], factors[roofs],
                        scaleOf[roofs], ratioOf[roofs]))
                return (walls, roofs)
            }
            // `--fixed name=f:s:r/f:s:r,…`: each a choice for the walls and the roofs, pairs of the
            // grid, every yield alike, judged as above.
            for choice in (value("fixed") ?? "").split(separator: ",") {
                let parts = choice.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                let sides = parts[1].split(separator: "/").map { side in
                    side.split(separator: ":").compactMap { Double($0) }
                }
                func find(_ v: [Double]) -> Int? {
                    pairs.firstIndex {
                        abs($0.0 - v[0]) < 1e-9 && abs($0.1 - v[1]) < 1e-9
                            && abs($0.2 - (v.count > 2 ? v[2] : 1)) < 1e-9
                    }
                }
                guard sides.count == 2, let walls = find(sides[0]), let roofs = find(sides[1]) else {
                    print("Fixed choice \(parts[0]): not in the grid")
                    continue
                }
                judgeAll("Fixed \(parts[0]) (walls \(sides[0]), roofs \(sides[1])), every yield at its own:")
                { _ in
                    (walls, roofs)
                }
            }
        }
        // `--bands 400,700,1000,1320`: by distance band, each run's count of buildings whose walls
        // and roof it damages moderately or worse against the chances' sum at that yield, on the
        // calibration the app uses (the band test of emmettl/bombcad-work#10).
        if let bandsText = value("bands") {
            let edges = bandsText.split(separator: ",").compactMap { Double($0) }
            var nearest = [Double](repeating: .infinity, count: first.objects.count)
            for (k, component) in surrogateEstimate.components.enumerated() {
                guard let n = index[component.owner] else { continue }
                nearest[n] = min(nearest[n], surrogateEstimate.features[k].distanceM)
            }
            func band(_ n: Int) -> Int? { edges.firstIndex { nearest[n] < $0 } }
            print(
                "By distance band, buildings damaged moderately or worse: the run's count / the chances' sum")
            for (j, run) in runs.enumerated() {
                let drawn = try chances([run.mass], factor: nil)
                var counts = [[Double]](repeating: [0, 0, 0, 0], count: edges.count)
                for n in judged {
                    guard let b = band(n), let w = worst[j][n], let c = drawn[n] else { continue }
                    counts[b][0] += w.wall >= moderate ? 1 : 0
                    counts[b][1] += c.wallsModerate
                    counts[b][2] += w.roof >= moderate ? 1 : 0
                    counts[b][3] += c.roofModerate
                }
                for (b, edge) in edges.enumerated() {
                    let c = counts[b]
                    print(
                        String(
                            format:
                                "  %5.0f t, to %4.0f m: walls %4.0f / %6.1f (%.2f), roofs %4.0f / %6.1f (%.2f)",
                            run.mass / 1000, edge, c[0], c[1], c[0] > 0 ? c[1] / c[0] : 0, c[2], c[3],
                            c[2] > 0 ? c[3] / c[2] : 0))
                }
            }
        }
        print(String(format: "In %.0f s", DistrictBenchmark.seconds(start)))
        if let out = value("out") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(results).write(to: URL(filePath: out))
        }
    }

    /// As `GlassCalibration.show`, its test read over buildings: every tenth of chance holding 50
    /// buildings or more within 0.1 of the share of runs.
    static func show(_ r: GlassCalibration.Reliability) {
        let passes = r.bins.filter { $0.count >= 50 }.allSatisfy { abs($0.predicted - $0.observed) <= 0.1 }
        print(
            String(
                format:
                    "%@: %d buildings, Brier %.4f (%.4f giving each the mean), skill %.3f; tenths of 50+ within 0.1: %@",
                r.name as NSString, r.count, r.brier, r.climatology,
                r.climatology > 0 ? 1 - r.brier / r.climatology : 0,
                (passes ? "pass" : "fail") as NSString))
        for b in r.bins {
            print(
                String(
                    format: "    %.2f–%.2f: %6d, predicted %.2f, observed %.2f", b.from, b.to, b.count,
                    b.predicted,
                    b.observed))
        }
    }
}
