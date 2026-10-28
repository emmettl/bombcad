import Foundation
import simd

/// `blastmodel glass-diagnose <district-scene's inputs> --runs mass:folder,… [--inside 0.85]
/// [--draws 100] [--terms deep-city-outline|deep-city|clear-top|fitted] [--strips strips.csv] [--sides sides.csv]
/// [--fronts fronts.csv [--fronts-every 4]]
/// [--out diagnosis.json]`: why the glass chances (`FacadeLoadSurrogate.glassProbabilities`) read
/// as they do against a district's runs (emmettl/bombcad-work#103; docs/glass-probability.md).
/// Each side's three glass states (some broken, blown out, thrown past condition 3b) worked out,
/// run by run, from its strips' loads taken apart one step at a time: the run's own histories (what
/// `glass-calibrate` judges); their positive part; their first positive phase; the surrogate's
/// triangle made of each strip's own peak, first impulse and rise (the pulse's shape, the run's
/// loads); the same with all the positive impulse; with the surrogate's rise; one load for the
/// whole side (the strips' geometric mean); the surrogate's own strips moved to the run's side
/// mean; and the surrogate's own loads. Each set beside the chances, by tenth of chance, so that
/// what the middle tenths lose is laid at the step that loses it. `--strips` writes each strip's
/// run and surrogate loads, by side, for fitting the spread within a side.
package enum GlassDiagnosis {
    /// The ways of loading the strips, in order.
    static let variants: [(name: String, words: String)] = [
        ("history", "the run's own histories (what the runs judge)"),
        ("positive", "their positive part only (no negative phase)"),
        ("first", "their first positive phase only (no later shocks)"),
        ("oracle", "a triangle of each strip's own peak, first impulse and rise"),
        ("oracle-all", "the same with all its positive impulse"),
        ("oracle-rise", "the oracle with the surrogate's rise share"),
        ("oracle-shock", "the oracle rising at once, as a shock"),
        ("side", "one load for the side: the oracle's peak and impulse, geometric means over its strips"),
        ("surrogate-side", "the surrogate's strips moved to the run's side mean"),
        ("surrogate", "the surrogate's own loads, without scatter"),
        ("oracle-front", "the oracle with the terms' glass front, if they have one"),
        ("surrogate-front", "the surrogate's own loads with its glass front, if any"),
    ]

    struct SideKey: Hashable {
        var object: Int
        var axis: Int
        var outward: Int
    }

    struct Row: Codable {
        var from: Double
        var to: Double
        var sides: Int
        var chance: Double
        /// Each variant's share, in `variants`' order.
        var shares: [Double]
    }

    struct State: Codable {
        var name: String
        var rows: [Row]
        /// Each variant's Brier score as a forecast of the runs' own (`history`) shares.
        var brier: [Double]
    }

    struct Report: Codable {
        var variants: [String]
        var states: [State]
        var spread: [Spread]
    }

    /// The spread of the logs of the strips' loads about their side's mean, by scaled distance:
    /// the run's own, and the run's over the surrogate's (what the surrogate's pattern within the
    /// side does not account for); with the whole scatter (the run over the surrogate, not about
    /// the side) beside it.
    struct Spread: Codable {
        var upToZ: Double
        var strips: Int
        var runPeak: Double
        var runImpulse: Double
        var residualPeak: Double
        var residualImpulse: Double
        var residualCorrelation: Double
        var totalPeak: Double
        var totalImpulse: Double
    }

    package static func run(_ args: [String]) throws {
        StudyOutput.lineBuffered()
        func value(_ name: String) -> String? { SurrogateBench.value(args, name) }
        guard let runsText = value("runs") else { throw BlastError.allocationFailed("--runs mass:folder,…") }
        let runs = runsText.split(separator: ",").map { part -> (mass: Double, folder: String) in
            let pieces = part.split(separator: ":", maxSplits: 1).map(String.init)
            return (Double(pieces[0]) ?? 0, pieces[1])
        }
        let draws = value("draws").flatMap(Int.init) ?? 100
        let share = Float(value("inside").flatMap(Double.init) ?? 0.85)
        let coefficients = try SurrogateBench.coefficients(args)
        let loadScatter = try SurrogateBench.loadScatter(args)
        print("Coefficients fitted to \(coefficients.fittedTo)")
        var references: [SurrogateBench.Reference] = []
        for run in runs {
            references.append(
                try SurrogateBench.Reference(args + ["--loads", run.folder, "--mass", String(run.mass)]))
        }
        let first = references[0]
        let scene = first.scene
        let objects = first.objects
        let charge = scene.charge.position
        let raster = first.raster
        let open = raster.openReach(around: charge)
        let mixes = Dictionary(
            uniqueKeysWithValues: [GlazingMix.olderLowRise, .apartments, .commercial, .industrial].map {
                ($0.name, $0)
            })
        func id(_ strip: (saved: Int, object: Int, component: EnvelopeComponent)) -> [Int32] {
            [Int32(strip.object)]
                + SurrogateBench.key(strip.component.region, strip.component.axis, strip.component.outward)
        }
        var common = Set(
            first.strips.filter {
                first.inside(FacadeLoadSurrogate.outerFace($0.component).centre, share: share)
            }.map(id))
        for reference in references.dropFirst() { common.formIntersection(reference.strips.map(id)) }
        let table = FacadeLoadSurrogate.GlassTable(binS: 0.7e-3)
        let count = variants.count
        // Each run's sides' outcomes, variant by variant.
        var outcomes: [[SideKey: [FacadeLoadSurrogate.GlassOutcome]]] = []
        var stripRows: [String] = []
        var frontRows: [String] = []
        // A prediction given the terms' glass front, if they have one, at scaled distance `z` from
        // a charge of `mass` kg.
        func fronted(_ p: FacadeLoadSurrogate.Prediction, _ z: Double, _ mass: Double)
            -> FacadeLoadSurrogate.Prediction
        {
            coefficients.forGlass(p, distanceM: z * cbrt(mass), mass: mass)
        }
        // Logs of the strips' loads about their side's mean, by run: (Z, run peak, run impulse,
        // residual peak, residual impulse, total peak, total impulse).
        var deviations:
            [(z: Double, rp: Double, ri: Double, ep: Double, ei: Double, tp: Double, ti: Double)] =
                []
        let clock = ContinuousClock.now
        for (r, reference) in references.enumerated() {
            let mass = runs[r].mass
            let mine = reference.strips.filter { common.contains(id($0)) }
            let objectsHere = reference.objects
            struct Strip {
                var key: SideKey
                var mix: GlazingMix
                var area: Double
                var binS: Double
                var net: [Double]
                var oracle: FacadeLoadSurrogate.Prediction
                var allImpulse: Double
                var firstEnd: Int
                var surrogate: FacadeLoadSurrogate.Prediction
                var z: Double
            }
            var strips = [Strip?](repeating: nil, count: mine.count)
            strips.withUnsafeMutableBufferPointer { out in
                SurrogateBench.concurrentlyEach(mine.count) { m in
                    let saved = reference.index.strips[mine[m].saved]
                    let key = SideKey(
                        object: mine[m].object, axis: mine[m].component.axis,
                        outward: mine[m].component.outward)
                    guard
                        let mix = mixes[reference.index.buildings[saved.building].mix]
                            ?? scene.envelopeConstruction(for: objectsHere[mine[m].object].id).glazing
                    else { return }
                    let net = reference.net(mine[m].saved)
                    let oracle = SurrogateBench.oracle(net, binS: saved.binS)
                    var end = net.count
                    if let peak = net.max(), peak > 0 {
                        var risen = false
                        for (n, p) in net.enumerated() {
                            if p >= 0.5 * peak { risen = true }
                            if risen, p < 0 {
                                end = n
                                break
                            }
                        }
                    }
                    var f = FacadeLoadSurrogate.features(
                        mine[m].component, owner: mine[m].object, charge: charge, raster: reference.raster)
                    f.chargeOpenM = open
                    let p = FacadeLoadSurrogate.predict(
                        f, mass: mass, cellSize: Double(reference.predictionCell), coefficients: coefficients)
                    out[m] = Strip(
                        key: key, mix: mix, area: saved.areaM2, binS: saved.binS, net: net, oracle: oracle,
                        allImpulse: net.reduce(0) { $0 + max($1, 0) } * saved.binS, firstEnd: end,
                        surrogate: p,
                        z: f.distanceM / cbrt(mass))
                }
            }
            let kept = strips.compactMap { $0 }
            // The sides' means of the logs, area-weighted: the run's oracle and the surrogate.
            var sums: [SideKey: (w: Double, rp: Double, ri: Double, rr: Double, sp: Double, si: Double)] = [:]
            for s in kept where s.oracle.peakPa > 0 && s.oracle.impulsePaS > 0 && s.surrogate.peakPa > 0 {
                var t = sums[s.key] ?? (0, 0, 0, 0, 0, 0)
                t.w += s.area
                t.rp += s.area * log(s.oracle.peakPa)
                t.ri += s.area * log(s.oracle.impulsePaS)
                t.rr += s.area * s.oracle.riseShare
                t.sp += s.area * log(s.surrogate.peakPa)
                t.si += s.area * log(s.surrogate.impulsePaS)
                sums[s.key] = t
            }
            var bySide = [SideKey: (n: Int, w: Double)]()
            for s in kept { bySide[s.key, default: (0, 0)].n += 1 }
            for s in kept where s.oracle.peakPa > 0 && s.oracle.impulsePaS > 0 && s.surrogate.peakPa > 0 {
                guard let t = sums[s.key], (bySide[s.key]?.n ?? 0) >= 2 else { continue }
                let mp = t.rp / t.w
                let mi = t.ri / t.w
                let lp = log(s.oracle.peakPa)
                let li = log(s.oracle.impulsePaS)
                let sp = log(s.surrogate.peakPa)
                let si = log(s.surrogate.impulsePaS)
                deviations.append(
                    (
                        s.z, lp - mp, li - mi, (lp - sp) - (mp - t.sp / t.w), (li - si) - (mi - t.si / t.w),
                        lp - sp, li - si
                    ))
            }
            if value("strips") != nil {
                // One pane type's 60 s stress under the history, the oracle and the oracle as a
                // shock (the apartments' 4 mm, 0.9 × 1.4 m pane); and the history's jump, the most it
                // rises over 2 ms, as a share of its peak.
                let pane = GlazingMix.apartments.panes[0]
                var rows = [String](repeating: "", count: kept.count)
                rows.withUnsafeMutableBufferPointer { out in
                    SurrogateBench.concurrentlyEach(kept.count) { m in
                        let s = kept[m]
                        func stress(_ p: [Double]) -> Double {
                            (p.max() ?? 0) > 50
                                ? GlazingMix.response(of: pane, netPa: p, binS: s.binS).stress : 0
                        }
                        var shock = s.oracle
                        shock.riseShare = 0
                        func pulse(_ p: FacadeLoadSurrogate.Prediction) -> [Double] {
                            FacadeLoadSurrogate.pulse(
                                peak: p.peakPa, impulse: p.impulsePaS, riseShare: p.riseShare, binS: s.binS)
                        }
                        let lag = max(1, Int((2e-3 / s.binS).rounded()))
                        var jump = 0.0
                        if s.net.count > lag {
                            for n in lag..<s.net.count { jump = max(jump, s.net[n] - s.net[n - lag]) }
                        }
                        // The history's mean over a window `w` s wide about each bin: what it is
                        // without what changes faster.
                        func smoothed(_ w: Double) -> [Double] {
                            let half = max(1, Int((0.5 * w / s.binS).rounded()))
                            var sums = [0.0]
                            for p in s.net { sums.append(sums.last! + p) }
                            return s.net.indices.map { n in
                                let a = max(0, n - half)
                                let b = min(s.net.count, n + half + 1)
                                return (sums[b] - sums[a]) / Double(b - a)
                            }
                        }
                        out[m] = String(
                            format:
                                "%.0f,%d,%d,%d,%.4f,%.3f,%.6g,%.6g,%.4f,%.6g,%.6g,%.4f,%.6g,%.6g,%.6g,%.4f,%.6g,%.6g\n",
                            mass, s.key.object, s.key.axis, s.key.outward, s.z, s.area, s.oracle.peakPa,
                            s.oracle.impulsePaS, s.oracle.riseShare, s.surrogate.peakPa,
                            s.surrogate.impulsePaS,
                            s.surrogate.riseShare, stress(s.net), stress(pulse(s.oracle)),
                            stress(pulse(shock)),
                            s.oracle.peakPa > 0 ? jump / s.oracle.peakPa : 0, stress(smoothed(0.01)),
                            stress(smoothed(0.03)))
                    }
                }
                stripRows += rows
            }
            // `--fronts fronts.csv`: every `--fronts-every`th strip's panes (its mix's), their 60 s
            // stress under the history and under the oracle given fronts of 0 to 0.7 of its peak,
            // for fitting the glass's front.
            if value("fronts") != nil {
                let every = max(1, value("fronts-every").flatMap(Int.init) ?? 4)
                let chosen = Array(stride(from: 0, to: kept.count, by: every))
                var rows = [String](repeating: "", count: chosen.count)
                rows.withUnsafeMutableBufferPointer { out in
                    SurrogateBench.concurrentlyEach(chosen.count) { c in
                        let s = kept[chosen[c]]
                        guard s.oracle.peakPa > 50, s.oracle.impulsePaS > 0 else { return }
                        var text = ""
                        for (q, pane) in s.mix.panes.enumerated() {
                            // Its 60 s stress, and whether a pane of it that breaks (at its median
                            // strength, or just under the stress where that is less, as `judged`
                            // takes it) is thrown worse than condition 3b.
                            func judged(_ p: [Double]) -> (Double, Int) {
                                let r = GlazingMix.response(of: pane, netPa: p, binS: s.binS)
                                let (a, b) = GlazingMix.sides(pane)
                                let median = GlassStrength.sixtySecond(area: a * b)
                                let broke = r.lost ? median : min(median, 0.99 * r.stress)
                                let thrown =
                                    s.mix.condition(pane, strength: broke, pressures: p, binS: s.binS)
                                    > .threeB
                                return (r.stress, thrown ? 1 : 0)
                            }
                            let history = judged(s.net)
                            let pulses = (0...7).map { k in
                                judged(
                                    FacadeLoadSurrogate.pulse(
                                        peak: s.oracle.peakPa, impulse: s.oracle.impulsePaS,
                                        riseShare: s.oracle.riseShare, front: Double(k) / 10, binS: s.binS))
                            }
                            text += String(
                                format: "%.0f,%.4f,%d,%d,%.6g", mass, s.z, s.mix.panes.count, q, history.0)
                            for p in pulses { text += String(format: ",%.6g", p.0) }
                            text += ",\(history.1)"
                            for p in pulses { text += ",\(p.1)" }
                            text += "\n"
                        }
                        out[c] = text
                    }
                }
                frontRows += rows
            }
            var each = [[FacadeLoadSurrogate.GlassOutcome]](repeating: [], count: kept.count)
            each.withUnsafeMutableBufferPointer { out in
                SurrogateBench.concurrentlyEach(kept.count) { m in
                    let s = kept[m]
                    func outcome(_ net: [Double]) -> FacadeLoadSurrogate.GlassOutcome {
                        FacadeLoadSurrogate.glassOutcome(s.mix, netPa: net, binS: s.binS, areaM2: s.area)
                    }
                    func triangle(_ p: FacadeLoadSurrogate.Prediction) -> FacadeLoadSurrogate.GlassOutcome {
                        table.outcome(s.mix, prediction: p, areaM2: s.area, strength: 1)
                    }
                    var all = s.oracle
                    all.impulsePaS = s.allImpulse
                    var rise = s.oracle
                    rise.riseShare = s.surrogate.riseShare
                    var shock = s.oracle
                    shock.riseShare = 0
                    var side = s.oracle
                    var moved = s.surrogate
                    if let t = sums[s.key], t.w > 0 {
                        side.peakPa = exp(t.rp / t.w)
                        side.impulsePaS = exp(t.ri / t.w)
                        side.riseShare = t.rr / t.w
                        moved.peakPa *= exp(t.rp / t.w - t.sp / t.w)
                        moved.impulsePaS *= exp(t.ri / t.w - t.si / t.w)
                    }
                    out[m] = [
                        outcome(s.net),
                        outcome(s.net.map { max($0, 0) }),
                        outcome(Array(s.net[0..<s.firstEnd])),
                        triangle(s.oracle),
                        triangle(all),
                        triangle(rise),
                        triangle(shock),
                        triangle(side),
                        triangle(moved),
                        triangle(s.surrogate),
                        triangle(fronted(s.oracle, s.z, mass)),
                        triangle(fronted(s.surrogate, s.z, mass)),
                    ]
                }
            }
            var sideOutcomes: [SideKey: [FacadeLoadSurrogate.GlassOutcome]] = [:]
            for (m, s) in kept.enumerated() {
                var sum =
                    sideOutcomes[s.key]
                    ?? [FacadeLoadSurrogate.GlassOutcome](repeating: .init(), count: count)
                for v in 0..<count { sum[v] = sum[v] + each[m][v] }
                sideOutcomes[s.key] = sum
            }
            outcomes.append(sideOutcomes)
            print(
                String(
                    format: "Run %.0f t: %d strips on %d sides, %.0f s", mass / 1000, kept.count,
                    sideOutcomes.count,
                    StudyClock.seconds(clock)))
        }

        // The chances, as glass-calibrate draws them, of the same sides.
        var sideStrips: [SideKey: [(features: FacadeLoadSurrogate.Features, areaM2: Double)]] = [:]
        for strip in first.strips where common.contains(id(strip)) {
            let key = SideKey(
                object: strip.object, axis: strip.component.axis, outward: strip.component.outward)
            var f = FacadeLoadSurrogate.features(
                strip.component, owner: strip.object, charge: charge, raster: raster)
            f.chargeOpenM = open
            let spans = strip.component.spans
            sideStrips[key, default: []].append((f, Double(spans.x * spans.y)))
        }
        let keys = sideStrips.keys.filter { key in
            scene.envelopeConstruction(for: objects[key.object].id).glazing != nil
                && outcomes.allSatisfy { $0[key] != nil }
        }.sorted { ($0.object, $0.axis, $0.outward) < ($1.object, $1.axis, $1.outward) }
        let sides = keys.map { key in
            FacadeLoadSurrogate.GlassSideStrips(
                owner: objects[key.object].id, ownerKey: objects[key.object].drawKey, axis: key.axis,
                outward: key.outward, mix: scene.envelopeConstruction(for: objects[key.object].id).glazing!,
                strips: sideStrips[key]!)
        }
        let uncertainty = FacadeLoadSurrogate.Uncertainty(
            masses: runs.map(\.mass), strengthLogSD: 0, loadScatter: loadScatter, samples: draws)
        let (chances, _) = FacadeLoadSurrogate.glassProbabilities(
            sides: sides, mass: runs[0].mass, cellSize: first.predictionCell, uncertainty: uncertainty,
            coefficients: coefficients)

        // Each side's share of runs in each state, variant by variant.
        func shares(_ state: (FacadeLoadSurrogate.GlassOutcome) -> Double) -> [[Double]] {
            keys.map { key in
                (0..<count).map { v in
                    outcomes.reduce(0) { $0 + state($1[key]![v]) } / Double(outcomes.count)
                }
            }
        }
        let states: [(String, [Double], [[Double]])] = [
            ("some broken", chances.map(\.someBroken), shares { $0.glass.anyBroken }),
            (
                "blown out", chances.map(\.blownOut),
                shares { $0.glass.fraction >= DistrictGlass.blownOutFraction ? 1 : 0 }
            ),
            ("thrown past 3b", chances.map(\.thrownPast3b), shares { $0.worse }),
        ]
        var report = Report(variants: variants.map(\.name), states: [], spread: [])
        for (n, v) in variants.enumerated() { print("  \(n): \(v.name), \(v.words)") }
        for (name, chance, observed) in states {
            let edges = [0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0001]
            var rows: [Row] = []
            for (a, b) in zip(edges, edges.dropFirst()) {
                let members = chance.indices.filter { chance[$0] >= a && chance[$0] < b }
                guard !members.isEmpty else { continue }
                let k = Double(members.count)
                rows.append(
                    Row(
                        from: a, to: min(b, 1), sides: members.count,
                        chance: members.reduce(0) { $0 + chance[$1] } / k,
                        shares: (0..<count).map { v in members.reduce(0) { $0 + observed[$1][v] } / k }))
            }
            let brier = (0..<count).map { v in
                observed.reduce(0) { $0 + pow($1[v] - $1[0], 2) } / Double(max(observed.count, 1))
            }
            let chanceBrier =
                zip(chance, observed).reduce(0) { $0 + pow($1.0 - $1.1[0], 2) }
                / Double(max(observed.count, 1))
            print("\n\(name): by tenth of chance (\(keys.count) sides), the share of runs under each loading")
            print(
                "  tenth      sides  chance  "
                    + (0..<count).map { String(format: "%6d", $0) }.joined(separator: " "))
            for row in rows {
                print(
                    String(format: "  %.1f–%.1f %7d   %.2f   ", row.from, row.to, row.sides, row.chance)
                        + row.shares.map { String(format: "%6.2f", $0) }.joined(separator: " "))
            }
            print(
                String(format: "  Brier against the histories' shares: the chances %.4f; ", chanceBrier)
                    + brier.enumerated().dropFirst().map { String(format: "%d %.4f", $0.offset, $0.element) }
                    .joined(separator: ", "))
            report.states.append(State(name: name, rows: rows, brier: [chanceBrier] + brier.dropFirst()))
        }

        // The spread within a side.
        print("\nSpread of the logs of the strips' loads about their side's mean (sides of 2+ strips)")
        print("  up to Z   strips   run peak/impulse   run over surrogate: peak/impulse (r)   whole scatter")
        var low = 0.0
        for high in [7.0, 10, 14, 20, 28, .infinity] {
            let g = deviations.filter { $0.z > low && $0.z <= high }
            low = high
            guard g.count >= 50 else { continue }
            let n = Double(g.count)
            func rms(_ f: (Int) -> Double) -> Double {
                (g.indices.reduce(0) { $0 + f($1) * f($1) } / n).squareRoot()
            }
            let ep = rms { g[$0].ep }
            let ei = rms { g[$0].ei }
            let spread = Spread(
                upToZ: high.isFinite ? high : 1e9, strips: g.count, runPeak: rms { g[$0].rp },
                runImpulse: rms { g[$0].ri },
                residualPeak: ep, residualImpulse: ei,
                residualCorrelation: g.reduce(0) { $0 + $1.ep * $1.ei } / n / max(ep * ei, 1e-12),
                totalPeak: rms { g[$0].tp }, totalImpulse: rms { g[$0].ti })
            report.spread.append(spread)
            print(
                String(
                    format:
                        "  %7.0f %8d   %.2f / %.2f          %.2f / %.2f (%.2f)                     %.2f / %.2f",
                    high, g.count, spread.runPeak, spread.runImpulse, ep, ei, spread.residualCorrelation,
                    spread.totalPeak, spread.totalImpulse))
        }
        // `--sides sides.csv`: each side's distance, chances and shares, variant by variant.
        if let path = value("sides") {
            var lines = ["object,axis,outward,distance,some,blown,thrown"]
            lines[0] += (0..<count).map { ",some\($0),blown\($0),thrown\($0)" }.joined()
            for (n, key) in keys.enumerated() {
                var line = String(
                    format: "%d,%d,%d,%.1f,%.4f,%.4f,%.4f", key.object, key.axis, key.outward,
                    chances[n].distanceM, chances[n].someBroken, chances[n].blownOut, chances[n].thrownPast3b)
                for v in 0..<count {
                    line += String(
                        format: ",%.4f,%.4f,%.4f", states[0].2[n][v], states[1].2[n][v], states[2].2[n][v])
                }
                lines.append(line)
            }
            try (lines.joined(separator: "\n") + "\n").write(
                to: URL(filePath: path), atomically: true, encoding: .utf8)
        }
        if let path = value("strips") {
            try
                ("mass,object,axis,outward,z,area,peak,impulse,rise,speak,simpulse,srise,stress,ostress,sstress,jump,stress10,stress30\n"
                + stripRows.joined())
                .write(to: URL(filePath: path), atomically: true, encoding: .utf8)
        }
        if let path = value("fronts") {
            try
                ("mass,z,panes,pane,history,f0,f1,f2,f3,f4,f5,f6,f7,thrown,t0,t1,t2,t3,t4,t5,t6,t7\n"
                + frontRows.joined()).write(
                    to: URL(filePath: path), atomically: true, encoding: .utf8)
        }
        if let path = value("out") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: URL(filePath: path))
        }
    }
}
