import Foundation
import simd

/// The live blast wave (`LiveWave`) against BombCAD's own 4 m district runs (docs/live-wave.md).
///
/// `blastmodel live-wave-judge --runs dir[,dir…] [--only id,id…] [--layouts beirut|made]
/// [--coefficients fitted|none|file.json] [--samples out.tsv [--every 5]] [--out judged.json]`:
/// each run folder that `scenebench field-export` wrote (its plan in `inputs.npy`, its peak at 2 m
/// in `targets.npy` and `mask.npy`, and with `--arrival` its arrival in `arrival.npy`), the live
/// wave worked out on the run's own plan and set against it, cell by cell, by distance and by
/// whether the cell is in sight of the charge (the straight line over the plan clears every
/// building) or shielded. Kingery–Bulmash along the straight line is judged beside it, as the
/// baseline the paths have to beat. `--samples` writes every `--every`th cell's features and the
/// run's values for `Scripts/fit-live-wave.py`.
package enum LiveWaveJudge {
    /// One run's plan and what it recorded there.
    struct Run {
        var id: String
        var layout: String
        var mass: Double
        var charge: SIMD3<Float>
        var plan: LiveWave.Plan
        var peak: [Float]
        var impulse: [Float]
        var mask: [Float]
        var arrival: [Float]?
    }

    static func read(_ folder: URL) throws -> Run {
        let meta =
            try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appending(path: "meta.json")))
            as? [String: Any] ?? [:]
        guard let columns = meta["columns"] as? Int, let rows = meta["rows"] as? Int,
            let cell = (meta["cellSizeM"] as? NSNumber)?.floatValue,
            let charge = meta["charge"] as? [String: Any],
            let mass = (charge["massKg"] as? NSNumber)?.doubleValue,
            let position = charge["positionM"] as? [NSNumber], position.count == 3
        else { throw BlastError.allocationFailed("a field-export meta.json in \(folder.path)") }
        let plan = columns * rows
        let inputs = try LearnedField.readNPY(folder.appending(path: "inputs.npy")).values
        let targets = try LearnedField.readNPY(folder.appending(path: "targets.npy")).values
        let mask = try LearnedField.readNPY(folder.appending(path: "mask.npy")).values
        let arrivalURL = folder.appending(path: "arrival.npy")
        let arrival =
            FileManager.default.fileExists(atPath: arrivalURL.path)
            ? try LearnedField.readNPY(arrivalURL).values : nil
        // The ground is given over the ground under the charge, which is on it.
        let x = position[0].floatValue
        let y = position[1].floatValue
        return Run(
            id: meta["id"] as? String ?? folder.lastPathComponent,
            layout: meta["layout"] as? String ?? "", mass: mass, charge: SIMD3(x, y, 0),
            plan: LiveWave.Plan(
                columns: columns, rows: rows, cell: cell, height: Array(inputs[0..<plan]),
                ground: Array(inputs[plan..<(2 * plan)])),
            peak: Array(targets[0..<plan]), impulse: Array(targets[plan..<(2 * plan)]), mask: mask,
            arrival: arrival)
    }

    /// Whether the straight line from `charge` to `above` over cell `n`'s surface clears the plan's
    /// buildings and ground.
    static func inSight(_ plan: LiveWave.Plan, charge: SIMD3<Float>, cell n: Int) -> Bool {
        let h = plan.cell
        let i = n % plan.columns
        let j = n / plan.columns
        let end = SIMD3(
            (Float(i) + 0.5) * h, (Float(j) + 0.5) * h, plan.ground[n] + plan.height[n] + LiveWave.above)
        let span = simd_distance(SIMD2(end.x, end.y), SIMD2(charge.x, charge.y))
        let samples = Int(span / (0.5 * h))
        guard samples > 1 else { return true }
        for s in 1..<samples {
            let t = Float(s) / Float(samples)
            let p = charge + t * (end - charge)
            let pi = Int(p.x / h)
            let pj = Int(p.y / h)
            guard pi >= 0, pj >= 0, pi < plan.columns, pj < plan.rows else { continue }
            let m = pi + plan.columns * pj
            if m == n { continue }
            if plan.ground[m] + plan.height[m] > p.z { return false }
        }
        return true
    }

    /// `plan` on cells `k` times as large: each the tallest of its cells' buildings, as the plan of
    /// the same scene on those cells would hold a building over its centre, and their mean ground.
    static func coarsened(_ plan: LiveWave.Plan, by k: Int) -> LiveWave.Plan {
        let nx = plan.columns / k
        let ny = plan.rows / k
        var height = [Float](repeating: 0, count: nx * ny)
        var ground = [Float](repeating: 0, count: nx * ny)
        for j in 0..<ny {
            for i in 0..<nx {
                var top: Float = 0
                var sum: Float = 0
                for b in 0..<k {
                    for a in 0..<k {
                        let n = (i * k + a) + plan.columns * (j * k + b)
                        top = max(top, plan.height[n])
                        sum += plan.ground[n]
                    }
                }
                height[i + nx * j] = top
                ground[i + nx * j] = sum / Float(k * k)
            }
        }
        return LiveWave.Plan(
            columns: nx, rows: ny, cell: plan.cell * Float(k), height: height, ground: ground)
    }

    /// A field worked out on cells `k` times as large, read back at `plan`'s: each cell takes its
    /// coarse cell's, its straight line its own.
    static func refined(_ coarse: LiveWave.Field, to plan: LiveWave.Plan, charge: SIMD3<Float>, by k: Int)
        -> LiveWave.Field
    {
        var field = coarse
        let count = plan.columns * plan.rows
        let (_, straight) = (0, LiveWave.paths(plan: plan, charge: charge).straight)
        field.arrival = [Float](repeating: .infinity, count: count)
        field.peak = [Float](repeating: 0, count: count)
        field.duration = [Float](repeating: 0, count: count)
        field.decay = [Float](repeating: 0, count: count)
        field.path = [Float](repeating: .infinity, count: count)
        field.straight = straight
        for j in 0..<plan.rows {
            for i in 0..<plan.columns {
                let (ci, cj) = (min(i / k, coarse.columns - 1), min(j / k, coarse.rows - 1))
                let m = ci + coarse.columns * cj
                let n = i + plan.columns * j
                field.arrival[n] = coarse.arrival[m]
                field.peak[n] = coarse.peak[m]
                field.duration[n] = coarse.duration[m]
                field.decay[n] = coarse.decay[m]
                field.path[n] = coarse.path[m]
            }
        }
        return field
    }

    /// Distance bands, m, the tables are by.
    static let bands: [Double] = [0, 100, 200, 400, 700, 1000, 1500, 2000, 1e9]

    struct Tally: Codable {
        var cells = 0
        var peakLogs: [Double] = []
        var baselinePeakLogs: [Double] = []
        var arrivalLogs: [Double] = []
        var baselineArrivalLogs: [Double] = []
        var impulseLogs: [Double] = []
        var baselineImpulseLogs: [Double] = []

        mutating func add(_ other: Tally) {
            cells += other.cells
            peakLogs += other.peakLogs
            baselinePeakLogs += other.baselinePeakLogs
            arrivalLogs += other.arrivalLogs
            baselineArrivalLogs += other.baselineArrivalLogs
            impulseLogs += other.impulseLogs
            baselineImpulseLogs += other.baselineImpulseLogs
        }
    }

    struct Summary: Codable {
        var cells: Int
        /// The live wave's peak over the run's: the median ratio, the share within ×1.25 and ×1.5.
        var peakMedian: Double?
        var peakWithin125: Double?
        var peakWithin150: Double?
        /// Kingery–Bulmash on the straight line, the same.
        var baselinePeakMedian: Double?
        var baselinePeakWithin125: Double?
        /// The arrival over the run's: the median ratio and the mean absolute error, as shares.
        var arrivalMedian: Double?
        var arrivalMeanError: Double?
        var arrivalWithin5: Double?
        var baselineArrivalMedian: Double?
        var baselineArrivalMeanError: Double?
        var arrivalCells: Int
        /// The impulse of the wave's Friedlander pulse over the run's: the median ratio and the
        /// share within ×1.25; Kingery–Bulmash on the straight line's beside it.
        var impulseMedian: Double?
        var impulseWithin125: Double?
        var baselineImpulseMedian: Double?
        var baselineImpulseWithin125: Double?

        init(_ tally: Tally) {
            func median(_ logs: [Double]) -> Double? {
                guard !logs.isEmpty else { return nil }
                let sorted = logs.sorted()
                return exp(sorted[sorted.count / 2])
            }
            func within(_ logs: [Double], _ factor: Double) -> Double? {
                logs.isEmpty ? nil : Double(logs.filter { abs($0) < log(factor) }.count) / Double(logs.count)
            }
            func meanError(_ logs: [Double]) -> Double? {
                logs.isEmpty ? nil : logs.map { abs(exp($0) - 1) }.reduce(0, +) / Double(logs.count)
            }
            cells = tally.cells
            peakMedian = median(tally.peakLogs)
            peakWithin125 = within(tally.peakLogs, 1.25)
            peakWithin150 = within(tally.peakLogs, 1.5)
            baselinePeakMedian = median(tally.baselinePeakLogs)
            baselinePeakWithin125 = within(tally.baselinePeakLogs, 1.25)
            arrivalMedian = median(tally.arrivalLogs)
            arrivalMeanError = meanError(tally.arrivalLogs)
            arrivalWithin5 = within(tally.arrivalLogs, 1.05)
            baselineArrivalMedian = median(tally.baselineArrivalLogs)
            baselineArrivalMeanError = meanError(tally.baselineArrivalLogs)
            arrivalCells = tally.arrivalLogs.count
            impulseMedian = median(tally.impulseLogs)
            impulseWithin125 = within(tally.impulseLogs, 1.25)
            baselineImpulseMedian = median(tally.baselineImpulseLogs)
            baselineImpulseWithin125 = within(tally.baselineImpulseLogs, 1.25)
        }
    }

    struct Judged: Codable {
        var runs: [String]
        var coefficients: String
        /// By band (its lower edge, m) then "sight" or "shielded".
        var bands: [String: [String: Summary]]
        var overall: [String: Summary]
        var recomputeSeconds: [Double]
        /// The learned refinement's weights, when it was taken (`--learned`).
        var refinement: String?
    }

    /// A refinement of the wave worked out on a plan, for a charge's place and mass: the learned
    /// one (`LiveWave.Refinement`), from `scenebench live-wave-judge --learned`, which runs it on
    /// the GPU.
    package typealias Refine =
        @Sendable (LiveWave.Field, LiveWave.Plan, SIMD3<Float>, Double) throws -> LiveWave.Field

    package static func run(_ args: [String]) throws { try run(args, refine: nil) }

    package static func run(_ args: [String], refine: Refine?) throws {
        let value = { (name: String) in SurrogateBench.value(args, name) }
        guard let dirs = value("runs") else {
            throw BlastError.allocationFailed("--runs folder[,folder…] of field-export runs")
        }
        let coefficients: LiveWave.Coefficients
        let coefficientName = value("coefficients") ?? "fitted"
        switch coefficientName {
        case "fitted": coefficients = .fitted
        case "none": coefficients = .none
        default:
            coefficients = try JSONDecoder().decode(
                LiveWave.Coefficients.self, from: Data(contentsOf: URL(filePath: coefficientName)))
        }
        let only = value("only").map { Set($0.split(separator: ",").map(String.init)) }
        let layouts = value("layouts")
        var folders: [URL] = []
        for dir in dirs.split(separator: ",") {
            let url = URL(filePath: String(dir))
            if FileManager.default.fileExists(atPath: url.appending(path: "meta.json").path) {
                folders.append(url)
                continue
            }
            for name in try FileManager.default.contentsOfDirectory(atPath: url.path).sorted() {
                let folder = url.appending(path: name)
                guard FileManager.default.fileExists(atPath: folder.appending(path: "meta.json").path) else {
                    continue
                }
                if let only, !only.contains(name) { continue }
                if layouts == "beirut", !name.hasPrefix("beirut") { continue }
                if layouts == "made", name.hasPrefix("beirut") { continue }
                folders.append(folder)
            }
        }
        let every = value("every").flatMap(Int.init) ?? 5
        var samples = value("samples").map { _ in
            "run\tlayout\tmassKg\tstraightM\tpathM\tinSight\theightM\trunPeakPa\trunArrivalS\tlivePeakPa\tliveArrivalS\tkbPeakStraightPa\tkbArrivalStraightS\n"
        }
        var tallies: [String: [String: Tally]] = [:]
        var times: [Double] = []
        var judgedRuns: [String] = []
        for folder in folders {
            let run = try read(folder)
            // `--coarsen k`: worked out on cells k times as large, as the app does on a large
            // district while the charge is dragged, and read back at the run's cells.
            let coarsen = value("coarsen").flatMap(Int.init) ?? 1
            let worked = coarsen > 1 ? coarsened(run.plan, by: coarsen) : run.plan
            var coarse = LiveWave.field(
                plan: worked, charge: run.charge, mass: run.mass, coefficients: coefficients)
            if let refine { coarse = try refine(coarse, worked, run.charge, run.mass) }
            // The same once more, timed alone (the first fills the table and builds the network).
            var timed = LiveWave.field(
                plan: worked, charge: run.charge, mass: run.mass, coefficients: coefficients)
            if let refine { timed = try refine(timed, worked, run.charge, run.mass) }
            times.append(timed.seconds)
            let field = coarsen > 1 ? refined(coarse, to: run.plan, charge: run.charge, by: coarsen) : coarse
            judgedRuns.append(run.id)
            let root = cbrt(run.mass)
            let count = run.plan.columns * run.plan.rows
            // In sight or not, for the cells judged, across the cores.
            var sight = [UInt8](repeating: 0, count: count)
            sight.withUnsafeMutableBufferPointer { out in
                concurrently(iterations: run.plan.rows) { j in
                    for i in 0..<run.plan.columns {
                        let n = i + run.plan.columns * j
                        guard run.mask[n] > 0 else { continue }
                        out[n] = inSight(run.plan, charge: run.charge, cell: n) ? 1 : 2
                    }
                }
            }
            var local: [String: [String: Tally]] = [:]
            var shown = 0
            for n in 0..<count where run.mask[n] > 0 && run.peak[n] > 0 {
                let distance = Double(field.straight[n])
                guard let band = bands.lastIndex(where: { $0 <= distance }) else { continue }
                let key = String(Int(bands[band]))
                let kind = sight[n] == 1 ? "sight" : "shielded"
                let z = max(distance, 0.5 * Double(run.plan.cell)) / root
                let kb = LiveWave.Table.shared.at(logZ: log(z))
                var tally = local[key, default: [:]][kind, default: Tally()]
                tally.cells += 1
                tally.peakLogs.append(log(Double(field.peak[n]) / Double(run.peak[n])))
                tally.baselinePeakLogs.append(log(kb.peak / Double(run.peak[n])))
                if run.impulse[n] > 0, field.duration[n] > 0 {
                    let impulse =
                        Double(field.peak[n]) * Double(field.duration[n])
                        * LiveWave.DecayTable.share(Double(field.decay[n]))
                    tally.impulseLogs.append(log(impulse / Double(run.impulse[n])))
                    let kbImpulse =
                        kb.peak * kb.scaledDuration * root * LiveWave.DecayTable.share(kb.decay)
                    tally.baselineImpulseLogs.append(log(kbImpulse / Double(run.impulse[n])))
                }
                let runArrival = run.arrival.map { $0[n] } ?? .nan
                if runArrival.isFinite, runArrival > 0, field.arrival[n].isFinite {
                    tally.arrivalLogs.append(log(Double(field.arrival[n]) / Double(runArrival)))
                    tally.baselineArrivalLogs.append(log(kb.scaledArrival * root / Double(runArrival)))
                }
                local[key, default: [:]][kind] = tally
                if samples != nil {
                    shown += 1
                    if shown % every == 0 {
                        samples! +=
                            [
                                run.id, run.layout, String(run.mass), String(field.straight[n]),
                                String(field.path[n]), sight[n] == 1 ? "1" : "0", String(run.plan.height[n]),
                                String(run.peak[n]), String(runArrival), String(field.peak[n]),
                                String(field.arrival[n]), String(kb.peak), String(kb.scaledArrival * root),
                            ].joined(separator: "\t") + "\n"
                    }
                }
            }
            for (band, kinds) in local {
                for (kind, tally) in kinds { tallies[band, default: [:]][kind, default: Tally()].add(tally) }
            }
            let all = local.values.flatMap(\.values).reduce(into: Tally()) { $0.add($1) }
            let summary = Summary(all)
            print(
                String(
                    format:
                        "%@ (%@, %.0f t, %d × %d): peak median ×%.2f, within ×1.25 %.0f%% (straight-line KB %.0f%%); arrival median ×%.3f, mean error %.1f%% (KB %.1f%%) over %d cells; impulse within ×1.25 %.0f%%; recompute %.0f ms (paths %.0f, refinement %.0f)",
                    run.id, run.layout, run.mass / 1000, run.plan.columns, run.plan.rows,
                    summary.peakMedian ?? .nan, 100 * (summary.peakWithin125 ?? .nan),
                    100 * (summary.baselinePeakWithin125 ?? .nan), summary.arrivalMedian ?? .nan,
                    100 * (summary.arrivalMeanError ?? .nan),
                    100 * (summary.baselineArrivalMeanError ?? .nan),
                    summary.arrivalCells, 100 * (summary.impulseWithin125 ?? .nan), 1000 * timed.seconds,
                    1000 * timed.pathSeconds, 1000 * timed.refinementSeconds))
        }
        guard !judgedRuns.isEmpty else { throw BlastError.allocationFailed("runs to judge under \(dirs)") }
        var bandSummaries: [String: [String: Summary]] = [:]
        var overall: [String: Tally] = [:]
        print("\nBy distance and sight (live wave; Kingery–Bulmash on the straight line in brackets):")
        print(
            "band m\tkind\tcells\tpeak ×\twithin 1.25\twithin 1.5\t(KB ×, within 1.25)\tarrival ×\tmean error\twithin 5%\t(KB ×, error)\timpulse ×\twithin 1.25\t(KB ×, within 1.25)"
        )
        for band in bands.dropLast().map({ String(Int($0)) }) {
            for kind in ["sight", "shielded"] {
                guard let tally = tallies[band]?[kind] else { continue }
                overall[kind, default: Tally()].add(tally)
                let s = Summary(tally)
                bandSummaries[band, default: [:]][kind] = s
                print(
                    String(
                        format:
                            "%@\t%@\t%d\t%.2f\t%.0f%%\t%.0f%%\t(%.2f, %.0f%%)\t%.3f\t%.1f%%\t%.0f%%\t(%.3f, %.1f%%)\t%.2f\t%.0f%%\t(%.2f, %.0f%%)",
                        band, kind, s.cells, s.peakMedian ?? .nan, 100 * (s.peakWithin125 ?? .nan),
                        100 * (s.peakWithin150 ?? .nan), s.baselinePeakMedian ?? .nan,
                        100 * (s.baselinePeakWithin125 ?? .nan), s.arrivalMedian ?? .nan,
                        100 * (s.arrivalMeanError ?? .nan), 100 * (s.arrivalWithin5 ?? .nan),
                        s.baselineArrivalMedian ?? .nan, 100 * (s.baselineArrivalMeanError ?? .nan),
                        s.impulseMedian ?? .nan, 100 * (s.impulseWithin125 ?? .nan),
                        s.baselineImpulseMedian ?? .nan, 100 * (s.baselineImpulseWithin125 ?? .nan)))
            }
        }
        let overallSummaries = overall.mapValues(Summary.init)
        for (kind, s) in overallSummaries.sorted(by: { $0.key > $1.key }) {
            print(
                String(
                    format:
                        "all\t%@\t%d\t%.2f\t%.0f%%\t%.0f%%\t(%.2f, %.0f%%)\t%.3f\t%.1f%%\t%.0f%%\t(%.3f, %.1f%%)\t%.2f\t%.0f%%\t(%.2f, %.0f%%)",
                    kind,
                    s.cells, s.peakMedian ?? .nan, 100 * (s.peakWithin125 ?? .nan),
                    100 * (s.peakWithin150 ?? .nan),
                    s.baselinePeakMedian ?? .nan, 100 * (s.baselinePeakWithin125 ?? .nan),
                    s.arrivalMedian ?? .nan,
                    100 * (s.arrivalMeanError ?? .nan), 100 * (s.arrivalWithin5 ?? .nan),
                    s.baselineArrivalMedian ?? .nan, 100 * (s.baselineArrivalMeanError ?? .nan),
                    s.impulseMedian ?? .nan, 100 * (s.impulseWithin125 ?? .nan),
                    s.baselineImpulseMedian ?? .nan, 100 * (s.baselineImpulseWithin125 ?? .nan)))
        }
        let sorted = times.sorted()
        print(
            String(
                format: "Recompute: median %.0f ms, range %.0f–%.0f ms over %d runs",
                1000 * sorted[sorted.count / 2],
                1000 * sorted.first!, 1000 * sorted.last!, sorted.count))
        if let path = value("samples"), let samples {
            try Data(samples.utf8).write(to: URL(filePath: path))
        }
        if let path = value("out") {
            let judged = Judged(
                runs: judgedRuns, coefficients: coefficientName, bands: bandSummaries,
                overall: overallSummaries,
                recomputeSeconds: times, refinement: value("learned"))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(judged).write(to: URL(filePath: path))
        }
    }

    /// `blastmodel live-wave-time <district-scene's inputs> [--radius 2500] [--mass kg]
    /// [--drag 0,5,…] [--cells 4,8]`: what the live wave costs on a laid-out district, as the app
    /// works it out: the plan laid out once, then for each place of the charge moved east, the
    /// field on each of `--cells`, timed.
    package static func time(_ args: [String]) throws { try time(args, refine: nil) }

    package static func time(_ args: [String], refine: Refine?) throws {
        let value = { (name: String) in SurrogateBench.value(args, name) }
        let inputs = try DistrictInputs.read(args)
        let radius = Float(value("radius").flatMap(Double.init) ?? 2500)
        var clock = ContinuousClock.now
        let (scene, report) = try inputs.scene(radius: radius)
        print(report.summary)
        print(
            String(
                format: "Laid out %d buildings on %.0f × %.0f m in %.1f s", scene.envelopeObjects.count,
                scene.domainSize.x, scene.domainSize.y, (ContinuousClock.now - clock) / .seconds(1)))
        let mass = value("mass").flatMap(Double.init) ?? Double(scene.charge.mass)
        let moves = (value("drag") ?? "0,5,10,15,20,25,30,35,40,45,50").split(separator: ",").compactMap {
            Float($0)
        }
        let cells = (value("cells") ?? "4,8").split(separator: ",").compactMap { Float($0) }
        for cell in cells {
            clock = .now
            let plan = LiveWave.Plan(scene: scene, cell: cell)
            let planS = (ContinuousClock.now - clock) / .seconds(1)
            var times: [Double] = []
            var paths: [Double] = []
            var refinements: [Double] = []
            var last: Float = 0
            for move in moves {
                var charge = scene.charge.position
                charge.x += move
                var field = LiveWave.field(plan: plan, charge: charge, mass: mass)
                if let refine { field = try refine(field, plan, charge, mass) }
                times.append(field.seconds)
                paths.append(field.pathSeconds)
                refinements.append(field.refinementSeconds)
                last = field.lastArrival
            }
            // The first fills the table; the rest are the drag's.
            let later = Array(times.dropFirst()).sorted()
            let laterPaths = Array(paths.dropFirst()).sorted()
            let laterRefinements = Array(refinements.dropFirst()).sorted()
            print(
                String(
                    format:
                        "%.0f m cells, %d × %d (%.2f M): plan %.0f ms; first field %.0f ms, later median %.0f ms (%.0f–%.0f), paths %.0f ms, refinement %.0f ms; last arrival %.2f s",
                    cell, plan.columns, plan.rows, Double(plan.columns * plan.rows) / 1e6, 1000 * planS,
                    1000 * times[0], 1000 * (later.isEmpty ? times[0] : later[later.count / 2]),
                    1000 * (later.first ?? times[0]), 1000 * (later.last ?? times[0]),
                    1000 * (laterPaths.isEmpty ? paths[0] : laterPaths[laterPaths.count / 2]),
                    1000
                        * (laterRefinements.isEmpty
                            ? refinements[0] : laterRefinements[laterRefinements.count / 2]),
                    last))
        }
    }
}
