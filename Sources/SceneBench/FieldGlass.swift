import BlastCore
import Foundation
import simd

/// `scenebench field-glass <district-compare's inputs> --loads folder --peaks peaks.csv
/// [--radius 1024] [--impulse-from name,name] [--out judged.json]`: glass by building side through the SDOF, as
/// `surrogate-judge` judges it, with the learned field model's peaks in place of the surrogate's
/// (Scripts/ml/judge_field.py, docs/learned-models.md).
///
/// `peaks.csv` (judge_field.py `--peaks-out`) lists the ground-floor strips judged there, by their
/// boxes, with each predictor's peak beside them (`peak:<name>` columns). For each such strip of
/// the run saved in `--loads` (a `district-compare --save-loads`), the glass is judged on:
///
/// - **run**: the recorder's own history;
/// - **surrogate**: the façade load surrogate's pulse;
/// - **each `peak:<name>`**: the surrogate's pulse with that peak in place of its own, its impulse
///   and rise kept (the triangle's length follows);
/// - **`<name>+impulse`**, for each name in `--impulse-from`: that peak and that impulse
///   (`impulse:<name>`), the surrogate's rise kept.
///
/// Glass is each building's mix, summed over the judged strips of each side, and each side's
/// state is GEER's (`SurrogateBench.glassState`). Only the ground floor is judged, since the field
/// model knows nothing above 2 m; the run is judged on the same strips. The confusions against the
/// run go to `--out`, overall and by the building's distance.
enum FieldGlass {
    static let bands: [Double] = [0, 200, 350, 500, 700, 1000, 1500, .infinity]

    struct Judged: Codable {
        var strips: Int
        var sides: Int
        var predictors: [String]
        /// By the band of the building's distance ("all" first): each predictor's agreement with
        /// the run, rows the run's state.
        var groups: [String: [String: SurrogateBench.Agreement]]
        /// Sides in each state, by predictor (and "run"), over all.
        var states: [String: [Int]]
        /// By band, each predictor's sum of |its share of panes broken − the run's| over the sides,
        /// and the sides (for the mean, summed over runs).
        var fractionError: [String: [String: Double]]
        var bandSides: [String: Int]
    }

    static func run(_ args: [String]) throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        guard let peaksPath = SurrogateBench.value(args, "peaks") else {
            throw BlastError.allocationFailed("--peaks peaks.csv")
        }
        let start = ContinuousClock.now
        let reference = try SurrogateBench.Reference(args)
        let scene = reference.scene
        let mass = Double(scene.charge.mass)
        let charge = scene.charge.position

        // The judged strips' peaks, by box (to a tenth of a metre, as judge_field.py keys them).
        let lines = try String(contentsOfFile: peaksPath, encoding: .utf8).split(separator: "\n")
        guard let head = lines.first?.split(separator: ",").map(String.init) else {
            throw BlastError.allocationFailed("a header in \(peaksPath)")
        }
        // Each variant: its name, its peak's column and, with its impulse, that column.
        let withImpulse = Set(
            SurrogateBench.value(args, "impulse-from")?.split(separator: ",").map(String.init) ?? [])
        var variants: [(name: String, peak: Int, impulse: Int?)] = []
        for (n, column) in head.enumerated() where column.hasPrefix("peak:") {
            let name = String(column.dropFirst(5))
            variants.append((name, n, nil))
            if withImpulse.contains(name), let i = head.firstIndex(of: "impulse:" + name) {
                variants.append((name + "+impulse", n, i))
            }
        }
        let predictors = variants.map(\.name)
        func key(_ axis: Int, _ outward: Int, _ values: [Float]) -> [Int32] {
            [Int32(axis), Int32(outward)] + values.map { Int32(($0 * 10).rounded()) }
        }
        var peaks: [[Int32]: [(peak: Double, impulse: Double?)]] = [:]
        for line in lines.dropFirst() {
            let cells = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard cells.count == head.count, let axis = Int(cells[0]), let outward = Int(cells[1]) else {
                continue
            }
            let box = cells[2..<8].compactMap { Float($0) }
            guard box.count == 6 else { continue }
            peaks[key(axis, outward, box)] = variants.map { v in
                (Double(cells[v.peak]) ?? 0, v.impulse.map { Double(cells[$0]) ?? 0 })
            }
        }

        let objects = reference.objects
        let mixes = Dictionary(
            uniqueKeysWithValues: [GlazingMix.olderLowRise, .apartments, .commercial, .industrial].map {
                ($0.name, $0)
            })
        let chosen = reference.strips.indices.compactMap { m -> (Int, [(peak: Double, impulse: Double?)])? in
            let strip = reference.index.strips[reference.strips[m].saved]
            guard let low = strip.low, let high = strip.high else { return nil }
            let k = key(strip.axis, strip.outward, [low.x, low.y, low.z, high.x, high.y, high.z])
            return peaks[k].map { (m, $0) }
        }
        print(
            "\(chosen.count) of \(peaks.count) judged strips found among the run's \(reference.strips.count)")
        // Per strip: the run's, the surrogate's and each predictor's glass.
        var outcomes = [[GlazingBreakage]?](repeating: nil, count: chosen.count)
        outcomes.withUnsafeMutableBufferPointer { out in
            SurrogateBench.concurrentlyEach(chosen.count) { c in
                let (m, override) = chosen[c]
                let (s, n, component) = reference.strips[m]
                let strip = reference.index.strips[s]
                let concrete = scene.envelopeConstruction(for: objects[n].id)
                let mix =
                    mixes[reference.index.buildings[strip.building].mix] ?? concrete.glazing ?? .apartments
                func glass(_ load: EnvelopeComponentLoad) -> GlazingBreakage {
                    mix.breakage(netPa: load.netPa, binS: load.binS, areaM2: strip.areaM2)
                }
                let net = reference.net(s)
                let recorded = EnvelopeComponentLoad(
                    id: component.id, owner: objects[n].id, kind: .facade, region: component.region,
                    axis: component.axis, binS: strip.binS, outerPa: net,
                    innerPa: Array(repeating: 0, count: net.count), supportEdges: nil,
                    outward: component.outward)
                let f = FacadeLoadSurrogate.features(
                    component, owner: n, charge: charge, raster: reference.raster)
                let prediction = FacadeLoadSurrogate.predict(
                    f, mass: mass, cellSize: Double(reference.cellSize))
                var list = [
                    glass(recorded), glass(FacadeLoadSurrogate.load(component, prediction, binS: strip.binS)),
                ]
                for value in override {
                    var p = prediction
                    p.peakPa = value.peak
                    if let impulse = value.impulse { p.impulsePaS = impulse }
                    list.append(glass(FacadeLoadSurrogate.load(component, p, binS: strip.binS)))
                }
                out[c] = list
            }
        }
        let names = ["surrogate"] + predictors
        // By building side, in a fixed order.
        var sides: [[Int]: [Int]] = [:]
        for (c, (m, _)) in chosen.enumerated() {
            let (s, n, _) = reference.strips[m]
            let strip = reference.index.strips[s]
            sides[[n, strip.axis, strip.outward], default: []].append(c)
        }
        var groups: [String: [String: SurrogateBench.Agreement]] = [:]
        var states: [String: [Int]] = ["run": [0, 0, 0]]
        var fractionError: [String: [String: Double]] = [:]
        var bandSides: [String: Int] = [:]
        for name in names { states[name] = [0, 0, 0] }
        func label(_ d: Double) -> String {
            for (lo, hi) in zip(bands, bands.dropFirst()) where d >= lo && d < hi {
                return hi.isFinite ? String(format: "%.0f-%.0f m", lo, hi) : String(format: ">%.0f m", lo)
            }
            return "?"
        }
        for (_, members) in sides.sorted(by: { $0.key.lexicographicallyPrecedes($1.key) }) {
            let strip = reference.index.strips[reference.strips[chosen[members[0]].0].saved]
            let distance = reference.index.buildings[strip.building].distanceM
            let summed = (0..<(names.count + 1)).map { v in
                members.reduce(GlazingBreakage()) { $0 + outcomes[$1]![v] }
            }
            let run = SurrogateBench.glassState(summed[0])
            states["run"]![run] += 1
            for group in ["all", label(distance)] { bandSides[group, default: 0] += 1 }
            for (v, name) in names.enumerated() {
                let state = SurrogateBench.glassState(summed[v + 1])
                states[name]![state] += 1
                for group in ["all", label(distance)] {
                    groups[group, default: [:]][name, default: SurrogateBench.Agreement(states: 3)].add(
                        run, state)
                    fractionError[group, default: [:]][name, default: 0] += abs(
                        summed[v + 1].fraction - summed[0].fraction)
                }
            }
        }
        for group in groups.keys {
            for name in names { groups[group]![name]?.finish() }
        }
        let judged = Judged(
            strips: chosen.count, sides: sides.count, predictors: names, groups: groups, states: states,
            fractionError: fractionError, bandSides: bandSides)
        print(
            String(
                format:
                    "Glass by side over %d ground-floor strips, %d sides, in %.0f s; against the run (exact / within one):",
                chosen.count, sides.count, DistrictBenchmark.seconds(start)))
        for group in ["all"] + zip(bands, bands.dropFirst()).map({ label($0.0) }) {
            guard let row = groups[group] else { continue }
            print(
                "  \(group): "
                    + names.map { name in
                        let a = row[name]!
                        return String(format: "%@ %.2f / %.2f", name, a.exact, a.withinOne)
                    }.joined(separator: ", "))
        }
        print(
            "Sides in each state (W0, W1-2, W3): "
                + (["run"] + names).map { "\($0) \(states[$0]!)" }.joined(separator: "; "))
        if let out = SurrogateBench.value(args, "out") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(judged).write(to: URL(filePath: out))
        }
    }
}
