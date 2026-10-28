import BlastCore
import Foundation
import simd

/// `scenebench field-refs <district-scene's inputs> [--radius 1320] --runs mass:folder,…
/// --variants surrogate,name=weights.bcfw,name=upper.bcfw+ground.bcfw[@own],… [--inside 0.85] [--draws 50]
/// [--scatter-tables tables.json] [--coefficients terms.json | --terms deep-city-outline|deep-city|clear-top|fitted] [--out judged.json]`:
/// the quick estimate's glass by building side and its façade peaks at every storey, judged against
/// a district's own runs at several yields (`district-compare --save-loads`; Beirut's near boxes on
/// air refined to 2 m, emmettl/bombcad-work#19 and #69), as the app's estimate gives them:
/// `FacadeLoadSurrogate.Prepared.estimate` with each variant's `LearnedField.Estimator`.
///
/// Each variant is the surrogate alone (`surrogate`), the surrogate under other terms
/// (`name=coefficients.json`, `scenebench surrogate-coefficients`' or `Scripts/fit-surrogate.py`'s;
/// emmettl/bombcad-work#56), a network (`name=weights.bcfw`, every level it has, as the app reaches
/// them), or a network above with another at the ground floor (`name=upper.bcfw+ground.bcfw`). Each run is read, judged and let go before the next, so that one
/// yield's loads are held at a time.
///
/// Glass is judged as `field-glass` judges it: each strip's breakage on the run's history and on the
/// variant's triangle, each building's mix, summed over a side's strips, and each side's state
/// GEER's (`SurrogateBench.glassState`). Ground-floor strips (`LearnedField.isGroundFloor`) and
/// those above form their sides apart. The glass's chances too, as the app draws them
/// (`glassProbabilities`, `--draws` at each run's own yield, the load scatter alone; with `@own`
/// on a variant, the networks' own scatter where their peak is used, `LearnedField.Scatter`):
/// some pane broken and blown out, by Brier, skill and the deciles' test. The peaks: each strip's
/// predicted peak over the run's, by the storey's height level, median and log-SD. With `@own`, the
/// out file also keeps each run's sums of the log peak error by level, facing and scaled distance
/// where the network's peak is used, banded as `LearnedField.Scatter` is, to measure that scatter
/// on 2 m runs; `--scatter-tables` judges tables so measured (`ScatterTables`).
enum FieldReferences {
    /// The storeys' height levels, m over the ground, as the levels' models were trained on.
    static let levels: [Float] = [6, 10, 14, 18, 22, 26, 30]

    struct Glass: Codable {
        /// Rows the run's state, columns the variant's.
        var confusion = [[Int]](repeating: [0, 0, 0], count: 3)
        var fractionError = 0.0
        var sides = 0

        var exact: Double {
            Double((0..<3).reduce(0) { $0 + confusion[$1][$1] }) / Double(max(sides, 1))
        }

        /// Heidke's skill score of the confusion (Scripts/ml/app_peaks.py's `heidke`).
        var heidke: Double {
            let n = Double(confusion.joined().reduce(0, +))
            guard n > 0 else { return .nan }
            let po = Double((0..<3).reduce(0) { $0 + confusion[$1][$1] }) / n
            let pe =
                (0..<3).reduce(0.0) { sum, i in
                    sum + Double(confusion[i].reduce(0, +))
                        * Double((0..<3).reduce(0) { $0 + confusion[$1][i] })
                } / n / n
            return pe < 1 ? (po - pe) / (1 - pe) : .nan
        }

        static func + (a: Glass, b: Glass) -> Glass {
            var sum = a
            for r in 0..<3 { for c in 0..<3 { sum.confusion[r][c] += b.confusion[r][c] } }
            sum.fractionError += b.fractionError
            sum.sides += b.sides
            return sum
        }
    }

    struct Judged: Codable {
        var mass: Double
        /// By variant, then by group ("ground", "upper", "every" and their distance bands).
        var glass: [String: [String: Glass]]
        /// By variant, then by level: each strip's log of predicted over recorded peak.
        var logRatios: [String: [String: [Float]]]
        /// By variant, then by "ground|upper|level …/front|side|back|all/band": over the strips
        /// whose peak is the network's (`Features.learnedPeakScatter` set, a variant with `@own`),
        /// the count, sum and sum of squares of the log of predicted over recorded peak, the bands
        /// `LearnedField.Scatter`'s (0 to Z 7, … 5 beyond 28).
        var scatter: [String: [String: [Double]]] = [:]
    }

    static func run(_ args: [String]) throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        func value(_ name: String) -> String? { SurrogateBench.value(args, name) }
        guard let runsText = value("runs"), let variantsText = value("variants") else {
            throw BlastError.allocationFailed("--runs mass:folder,… --variants surrogate,name=weights.bcfw,…")
        }
        let runs = runsText.split(separator: ",").map { part -> (mass: Double, folder: String) in
            let pieces = part.split(separator: ":", maxSplits: 1).map(String.init)
            return (Double(pieces[0]) ?? 0, pieces[1])
        }
        let share = Float(value("inside").flatMap(Double.init) ?? 0.85)
        let radius = Float(value("radius").flatMap(Double.init) ?? 1000)
        let start = ContinuousClock.now

        // The first run's layout, for the estimates: every run's is the same district.
        var first: SurrogateBench.Reference? = try SurrogateBench.Reference(
            args, loads: runs[0].folder, radius: radius)
        let scene = first!.scene
        let cellSize = first!.cellSize
        let prepared = FacadeLoadSurrogate.Prepared(
            scene: scene, cellSize: cellSize, incidence: SurrogateBench.incidence(args))
        // `--coefficients terms.json`: the terms the surrogate alone and the networks' variants
        // (their impulse and rise, and every strip they don't read) are judged under; `--terms`'
        // without it (the adopted ones without either).
        let baseTerms = try SurrogateBench.coefficients(args)
        // The load scatter the chances draw: `--terms`' (or `--load-scatter`'s).
        let loadScatter = try SurrogateBench.loadScatter(args)
        let variants:
            [(
                name: String, estimator: LearnedField.Estimator?,
                coefficients: FacadeLoadSurrogate.Coefficients
            )] = try variantsText.split(separator: ",").map { spec in
                let parts = spec.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { return (parts[0], nil, baseTerms) }
                // `name=coefficients.json`: the surrogate under those terms (emmettl/bombcad-work#56).
                if parts[1].hasSuffix(".json") {
                    let terms = try JSONDecoder().decode(
                        FacadeLoadSurrogate.Coefficients.self, from: Data(contentsOf: URL(filePath: parts[1]))
                    )
                    return (parts[0], nil, terms)
                }
                // `…@own`: the chances draw the networks' own measured scatter where their peak is used.
                let own = parts[1].hasSuffix("@own")
                let files = parts[1].replacingOccurrences(of: "@own", with: "").split(separator: "+").map(
                    String.init)
                let network = try LearnedFieldNetwork(contentsOf: URL(filePath: files[0]))
                let ground =
                    try files.count > 1 ? LearnedFieldNetwork(contentsOf: URL(filePath: files[1])) : nil
                func measured(_ path: String) throws -> LearnedField.Scatter? {
                    try ScatterTables.measured(forWeights: path, args)
                }
                let scatter =
                    !own
                    ? nil
                    : files.count > 1
                        ? LearnedField.Scatter.combining(
                            ground: try measured(files[1]), upper: try measured(files[0]))
                        : try measured(files[0])
                return (
                    parts[0],
                    LearnedField.Estimator(
                        scene: scene, network: network, groundNetwork: ground, scatter: scatter),
                    baseTerms
                )
            }
        // The glass's chances by side (`glassProbabilities`), `--draws` of them at each run's own
        // yield over the load scatter alone (the runs judge every pane at its median), against the
        // run's: some pane broken, and blown out.
        let draws = value("draws").flatMap(Int.init) ?? 50
        // By variant, then by "group/outcome": the chances and what the runs gave.
        var chancePredicted: [String: [String: [Double]]] = [:]
        var chanceObserved: [String: [String: [Double]]] = [:]
        let charge = scene.charge.position
        let mixes = Dictionary(
            uniqueKeysWithValues: [GlazingMix.olderLowRise, .apartments, .commercial, .industrial].map {
                ($0.name, $0)
            })
        let bands: [Double] = [0, 350, 500, 700, 1000, .infinity]
        func band(_ d: Double) -> String {
            for (lo, hi) in zip(bands, bands.dropFirst()) where d >= lo && d < hi {
                return hi.isFinite ? String(format: "%.0f-%.0f m", lo, hi) : String(format: ">%.0f m", lo)
            }
            return "?"
        }
        func level(_ component: EnvelopeComponent) -> String {
            if LearnedField.isGroundFloor(component, terrain: scene.terrain) { return "ground" }
            let ground = scene.terrain?.height(at: FacadeLoadSurrogate.outerFace(component).centre) ?? 0
            for l in levels {
                let at = ground + l
                if component.region.min.z <= at + 0.01, at - 0.01 <= component.region.max.z {
                    return String(format: "%.0f m", l)
                }
            }
            return "above"
        }

        var judgedRuns: [Judged] = []
        for (j, run) in runs.enumerated() {
            let reference =
                try first
                ?? SurrogateBench.Reference(
                    args + ["--mass", String(run.mass)], loads: run.folder, radius: radius)
            first = nil
            // Each variant's estimate at this run's yield, as the app's look makes it.
            let estimates = try variants.map { v in
                prepared.estimate(
                    charge: charge, mass: run.mass, coefficients: v.coefficients,
                    learned: try v.estimator.map { try $0.peaks(charge: charge, mass: run.mass) })
            }
            let byKey = Dictionary(
                estimates[0].components.indices.compactMap { k -> ([Int32], Int)? in
                    let c = estimates[0].components[k]
                    guard c.kind == .facade else { return nil }
                    return (SurrogateBench.key(c.region, c.axis, c.outward), k)
                }, uniquingKeysWith: { a, _ in a })
            // The judged strips: recorded, inside the fair part, laid out in the estimate.
            let chosen = reference.strips.indices.compactMap { m -> (m: Int, k: Int)? in
                let (s, _, component) = reference.strips[m]
                guard !reference.net(s).isEmpty,
                    reference.inside(FacadeLoadSurrogate.outerFace(component).centre, share: share),
                    let k = byKey[SurrogateBench.key(component.region, component.axis, component.outward)]
                else { return nil }
                return (m, k)
            }
            // Per strip: the run's glass and peak, and each variant's.
            var glass = [[GlazingBreakage]](repeating: [], count: chosen.count)
            var peaks = [[Double]](repeating: [], count: chosen.count)
            glass.withUnsafeMutableBufferPointer { glassOut in
                peaks.withUnsafeMutableBufferPointer { peaksOut in
                    SurrogateBench.concurrentlyEach(chosen.count) { c in
                        let (m, k) = chosen[c]
                        let (s, n, component) = reference.strips[m]
                        let strip = reference.index.strips[s]
                        let mix =
                            mixes[reference.index.buildings[strip.building].mix]
                            ?? scene.envelopeConstruction(for: reference.objects[n].id).glazing ?? .apartments
                        let net = reference.net(s)
                        var g = [mix.breakage(netPa: net, binS: strip.binS, areaM2: strip.areaM2)]
                        var p = [net.max() ?? 0]
                        for estimate in estimates {
                            let prediction = estimate.predictions[k]
                            let load = FacadeLoadSurrogate.load(component, prediction, binS: strip.binS)
                            g.append(mix.breakage(netPa: load.netPa, binS: strip.binS, areaM2: strip.areaM2))
                            p.append(prediction.peakPa)
                        }
                        glassOut[c] = g
                        peaksOut[c] = p
                    }
                }
            }
            // By side, the ground floor's strips and the rest's apart, and all together.
            var sides: [[Int]: [Int]] = [:]
            var levelOf = [String](repeating: "", count: chosen.count)
            for (c, (m, _)) in chosen.enumerated() {
                let (s, n, component) = reference.strips[m]
                let strip = reference.index.strips[s]
                levelOf[c] = level(component)
                let floor = levelOf[c] == "ground" ? 0 : 1
                sides[[n, strip.axis, strip.outward, floor], default: []].append(c)
                sides[[n, strip.axis, strip.outward, 2], default: []].append(c)
            }
            var judged = Judged(mass: run.mass, glass: [:], logRatios: [:])
            for (side, members) in sides {
                let strip = reference.index.strips[reference.strips[chosen[members[0]].m].saved]
                let distance = reference.index.buildings[strip.building].distanceM
                let group = ["ground", "upper", "every"][side[3]]
                let summed = (0...variants.count).map { v in
                    members.reduce(GlazingBreakage()) { $0 + glass[$1][v] }
                }
                let truth = SurrogateBench.glassState(summed[0])
                for (v, variant) in variants.enumerated() {
                    let state = SurrogateBench.glassState(summed[v + 1])
                    for name in [group, group + " " + band(distance)] {
                        var g = judged.glass[variant.name, default: [:]][name, default: Glass()]
                        g.confusion[truth][state] += 1
                        g.fractionError += abs(summed[v + 1].fraction - summed[0].fraction)
                        g.sides += 1
                        judged.glass[variant.name, default: [:]][name] = g
                    }
                }
            }
            // The chances, each side as the estimate gives its strips.
            let sideKeys = sides.keys.sorted { $0.lexicographicallyPrecedes($1) }
            for (v, variant) in variants.enumerated() {
                let glassSides = sideKeys.map { side -> FacadeLoadSurrogate.GlassSideStrips in
                    let members = sides[side]!
                    let (m0, _) = chosen[members[0]]
                    let n = reference.strips[m0].object
                    let strip0 = reference.index.strips[reference.strips[m0].saved]
                    let mix =
                        mixes[reference.index.buildings[strip0.building].mix]
                        ?? scene.envelopeConstruction(for: reference.objects[n].id).glazing ?? .apartments
                    return FacadeLoadSurrogate.GlassSideStrips(
                        owner: reference.objects[n].id, ownerKey: reference.objects[n].drawKey, axis: side[1],
                        outward: side[2], mix: mix,
                        strips: members.map { c in
                            let (m, k) = chosen[c]
                            return (
                                estimates[v].features[k],
                                reference.index.strips[reference.strips[m].saved].areaM2
                            )
                        })
                }
                let (chances, _) = FacadeLoadSurrogate.glassProbabilities(
                    sides: glassSides, mass: run.mass, cellSize: cellSize,
                    uncertainty: FacadeLoadSurrogate.Uncertainty(
                        masses: [run.mass], strengthLogSD: 0, loadScatter: loadScatter, samples: draws),
                    coefficients: variant.coefficients)
                for (s, side) in sideKeys.enumerated() {
                    let truth = sides[side]!.reduce(GlazingBreakage()) { $0 + glass[$1][0] }
                    let group = ["ground", "upper", "every"][side[3]]
                    for (outcome, predicted, observed) in [
                        ("some broken", chances[s].someBroken, truth.anyBroken),
                        (
                            "blown out", chances[s].blownOut,
                            truth.fraction >= DistrictGlass.blownOutFraction ? 1.0 : 0
                        ),
                    ] {
                        chancePredicted[variant.name, default: [:]][group + ", " + outcome, default: []]
                            .append(
                                predicted)
                        chanceObserved[variant.name, default: [:]][group + ", " + outcome, default: []]
                            .append(
                                observed)
                    }
                }
            }
            for (c, (m, _)) in chosen.enumerated() {
                let recorded = peaks[c][0]
                guard recorded > 0 else { continue }
                let strip = reference.index.strips[reference.strips[m].saved]
                let distance = reference.index.buildings[strip.building].distanceM
                for (v, variant) in variants.enumerated() where peaks[c][v + 1] > 0 {
                    let r = Float(log(peaks[c][v + 1] / recorded))
                    let features = estimates[v].features[chosen[c].k]
                    if features.learnedPeakScatter != nil {
                        let z = features.distanceM / cbrt(run.mass)
                        let b = [7.0, 10, 14, 20, 28].firstIndex { z <= $0 } ?? 5
                        let facing =
                            features.cosIncidence > 1.0 / 3
                            ? "front" : features.cosIncidence < -1.0 / 3 ? "back" : "side"
                        let floor = levelOf[c] == "ground" ? "ground" : "upper"
                        for key in [
                            "\(floor)/\(facing)/\(b)", "\(floor)/all/\(b)", "level \(levelOf[c])/all/\(b)",
                        ] {
                            var a = judged.scatter[variant.name]?[key] ?? [0, 0, 0]
                            a[0] += 1
                            a[1] += Double(r)
                            a[2] += Double(r) * Double(r)
                            judged.scatter[variant.name, default: [:]][key] = a
                        }
                    }
                    judged.logRatios[variant.name, default: [:]][levelOf[c], default: []].append(r)
                    if distance >= 50, distance < 700 {
                        judged.logRatios[variant.name, default: [:]][levelOf[c] + " 50-700 m", default: []]
                            .append(r)
                    }
                }
            }
            let strips = chosen.count
            print(
                String(
                    format: "%.0f t (%d of %d): %d strips judged, %d ground-floor sides; in %.0f s",
                    run.mass / 1000,
                    j + 1, runs.count, strips, judged.glass[variants[0].name]?["ground"]?.sides ?? 0,
                    DistrictBenchmark.seconds(start)))
            judgedRuns.append(judged)
        }

        // Over every run.
        let names = variants.map(\.name)
        print(
            "\nGlass by side over \(runs.count) runs: exact / Heidke skill / mean |share broken error| (sides)"
        )
        let groups = Set(judgedRuns.flatMap { $0.glass.values.flatMap(\.keys) }).sorted()
        print("group | sides | " + names.joined(separator: " | "))
        for group in groups {
            let totals = names.map { name in
                judgedRuns.reduce(Glass()) { $0 + ($1.glass[name]?[group] ?? Glass()) }
            }
            print(
                "\(group) | \(totals[0].sides) | "
                    + totals.map {
                        String(
                            format: "%.3f / %.2f / %.3f", $0.exact, $0.heidke,
                            $0.fractionError / Double(max($0.sides, 1)))
                    }.joined(separator: " | "))
        }
        print(
            "\nGlass chances by side over \(runs.count) runs (\(draws) draws at each run's yield, load scatter only): "
                + "Brier / skill / deciles of 200+ sides within 0.1 (sides)")
        let outcomes = Set(chancePredicted.values.flatMap(\.keys)).sorted()
        print("group | sides | " + names.joined(separator: " | "))
        for outcome in outcomes {
            let judged = names.map { name in
                GlassCalibration.reliability(
                    outcome, predicted: chancePredicted[name]?[outcome] ?? [],
                    observed: chanceObserved[name]?[outcome] ?? [])
            }
            print(
                "\(outcome) | \(judged[0].count) | "
                    + judged.map { r in
                        let passes = r.bins.filter { $0.count >= 200 }.allSatisfy {
                            abs($0.predicted - $0.observed) <= 0.1
                        }
                        return String(
                            format: "%.4f / %.2f / %@", r.brier,
                            r.climatology > 0 ? 1 - r.brier / r.climatology : 0,
                            passes ? "pass" : "fail")
                    }.joined(separator: " | "))
            for (name, r) in zip(names, judged) {
                print(
                    "    \(name): "
                        + r.bins.map {
                            String(format: "%.1f %d %.2f/%.2f", $0.from, $0.count, $0.predicted, $0.observed)
                        }
                        .joined(separator: ", "))
            }
        }
        print("\nPeaks by storey, predicted over the run's: median / log-SD (strips)")
        let levelNames = Set(judgedRuns.flatMap { $0.logRatios.values.flatMap(\.keys) }).sorted()
        print("level | strips | " + names.joined(separator: " | "))
        for level in levelNames {
            let cells = names.map { name -> (Int, String) in
                let all = judgedRuns.flatMap { $0.logRatios[name]?[level] ?? [] }.sorted()
                guard !all.isEmpty else { return (0, "–") }
                let median = all[all.count / 2]
                let mean = all.reduce(0, +) / Float(all.count)
                let sd = (all.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(all.count)).squareRoot()
                return (all.count, String(format: "%.2f / %.2f", exp(median), sd))
            }
            print("\(level) | \(cells[0].0) | " + cells.map(\.1).joined(separator: " | "))
        }
        print(String(format: "In %.0f s", DistrictBenchmark.seconds(start)))
        if let out = value("out") {
            // The glass's confusions only: the peaks' ratios are millions of numbers.
            let kept = judgedRuns.map {
                Judged(mass: $0.mass, glass: $0.glass, logRatios: [:], scatter: $0.scatter)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(kept).write(to: URL(filePath: out))
        }
    }
}
