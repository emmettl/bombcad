import BlastCore
import Foundation
import simd

/// `scenebench field-walls <district-compare's inputs> --loads folder --peaks peaks.csv
/// [--roof-peaks roofs.csv] [--variants surrogate,a:b,…] [--factors 0.8,1,1.3] [--scales 0,0.5,1]
/// [--draws 50] [--inside 0.85] [--out judged.json]`: the walls' and roofs' chances (`FacadeLoadSurrogate.structureProbabilities`,
/// emmettl/bombcad-work#19) with the learned field model's loads in place of the surrogate's, against
/// the run's own histories (Scripts/ml/judge_field.py, docs/learned-models.md).
///
/// `peaks.csv` (judge_field.py `--peaks-out`) lists the ground-floor strips judged there, by their
/// boxes, with each predictor's peak and impulse (`peak:<name>`, `impulse:<name>`). Each variant is
/// `a:b`, the peak from column `a` and the impulse from column `b` (`surrogate` for the surrogate's
/// own), the surrogate's rise kept; `surrogate` alone is the surrogate's pulse.
///
/// Only the ground floor's walls are judged, since the field model knows nothing above 2 m: each
/// building's worst wall over its judged ground-floor strips. The truth is the run's: those strips'
/// recorded histories through the same SDOF at the constructions' nominal strength, as
/// `wall-calibrate` judges them, and its worst roof over the roofs inside `--inside` of the half
/// side. The field model knows nothing of roofs either, so a roof's variant is a proxy: the roof's
/// own surrogate pulse (on the roofs' terms) scaled by the building's geometric mean of the
/// variant's over the surrogate's peak and impulse at its ground-floor strips.
///
/// With `--roof-peaks` (judge_field.py `--roofs-out`, a field model trained on the roof level,
/// emmettl/bombcad-work#69), a roof listed there takes a variant's peak and impulse from its columns
/// where it has them (`peak:<name>`, `impulse:<name>`), in place of the proxy; the surrogate's
/// roof pulse for the rest. The strips of `peaks.csv` may then be of any storey: each building's
/// walls are its worst over the strips listed.
///
/// The chances are drawn as `structureProbabilities` draws them at a known yield: a load scatter for
/// each building side (shared by its strips) and each roof, the surrogate's leave-one-out scatter
/// by scaled distance with its correlation, scaled by each `--scales` and the loads multiplied by
/// each `--factors`; no strength scatter (the runs have none). Every variant and pair shares the
/// same draws. Each building's chances by variant and pair go to `--out`, for
/// `judge_field.py walls` to choose each pair on the other charge points and judge.
enum FieldWalls {
    struct Building: Codable {
        var object: Int
        var distanceM: Double
        var walls: String
        /// The run's worst ground-floor wall and worst roof (levels; nil where none was judged).
        var wall: Int?
        var roof: Int?
        /// Each variant's chances, one for each pair of the grid.
        var wallsModerate: [String: [Double]]
        var wallsHeavy: [String: [Double]]
        var roofModerate: [String: [Double]]
    }

    struct Judged: Codable {
        var massKg: Double
        var draws: Int
        /// The grid's pairs: load factor, scatter scale.
        var grid: [[Double]]
        var variants: [String]
        var buildings: [Building]
        var seconds: Double
    }

    /// A standard normal draw for (`stream`, `k`, `item`): splitmix64, then Box–Muller.
    static func normal(_ stream: UInt64, _ k: Int, _ item: UInt64) -> Double {
        func mix(_ x: UInt64) -> UInt64 {
            var z = x &+ 0x9E37_79B9_7F4A_7C15
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        let h = mix(mix(mix(stream) ^ UInt64(k)) ^ item)
        let u1 = (Double(h >> 11) + 0.5) / Double(1 << 53)
        let u2 = (Double(mix(h) >> 11) + 0.5) / Double(1 << 53)
        return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
    }

    static func run(_ args: [String]) throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        func value(_ name: String) -> String? { SurrogateBench.value(args, name) }
        guard let peaksPath = value("peaks") else { throw BlastError.allocationFailed("--peaks peaks.csv") }
        let start = ContinuousClock.now
        let reference = try SurrogateBench.Reference(args)
        let scene = reference.scene
        let mass = Double(scene.charge.mass)
        let charge = scene.charge.position
        let open = reference.raster.openReach(around: charge)
        let cell = Double(reference.cellSize)
        let draws = value("draws").flatMap(Int.init) ?? 50
        let share = Float(value("inside").flatMap(Double.init) ?? 0.85)
        let factors = (value("factors") ?? "1").split(separator: ",").compactMap { Double($0) }
        let scales = (value("scales") ?? "1").split(separator: ",").compactMap { Double($0) }
        let grid = factors.flatMap { f in scales.map { [f, $0] } }
        let names = (value("variants") ?? "surrogate").split(separator: ",").map(String.init)
        // The roofs' own loads, by box, where a model knows the roof level.
        var roofHead: [String] = []
        var roofRows: [[Int32]: [Double]] = [:]
        if let path = value("roof-peaks") {
            let lines = try String(contentsOfFile: path, encoding: .utf8).split(whereSeparator: \.isNewline)
            roofHead =
                lines.first?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
            for line in lines.dropFirst() {
                let cells = line.split(separator: ",", omittingEmptySubsequences: false).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                let box = cells.prefix(6).compactMap { Float($0) }
                guard cells.count == roofHead.count, box.count == 6 else { continue }
                roofRows[[2, 1] + box.map { Int32(($0 * 10).rounded()) }] = cells.map { Double($0) ?? 0 }
            }
        }
        /// Each variant's roof columns: its peak's and its impulse's, where the roofs' file has them.
        let roofColumns: [(peak: Int?, impulse: Int?)] = names.map { name in
            let parts = name.split(separator: ":").map(String.init)
            func column(_ part: String, _ q: String) -> Int? {
                part == "surrogate" ? nil : roofHead.firstIndex(of: q + ":" + part)
            }
            return (column(parts[0], "peak"), column(parts.count > 1 ? parts[1] : "surrogate", "impulse"))
        }

        // The judged strips' columns, by box (to a tenth of a metre, as judge_field.py keys them).
        let lines = try String(contentsOfFile: peaksPath, encoding: .utf8).split(whereSeparator: \.isNewline)
        guard
            let head = lines.first?.split(separator: ",").map({
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            })
        else {
            throw BlastError.allocationFailed("a header in \(peaksPath)")
        }
        func column(_ name: String, _ q: String) throws -> Int? {
            guard name != "surrogate" else { return nil }
            guard let i = head.firstIndex(of: q + ":" + name) else {
                throw BlastError.allocationFailed("\(q):\(name) in \(peaksPath)")
            }
            return i
        }
        let variants: [(name: String, peak: Int?, impulse: Int?)] = try names.map { name in
            let parts = name.split(separator: ":").map(String.init)
            return (
                name, try column(parts[0], "peak"),
                try column(parts.count > 1 ? parts[1] : "surrogate", "impulse")
            )
        }
        func key(_ axis: Int, _ outward: Int, _ values: [Float]) -> [Int32] {
            [Int32(axis), Int32(outward)] + values.map { Int32(($0 * 10).rounded()) }
        }
        var rows: [[Int32]: [Double]] = [:]
        for line in lines.dropFirst() {
            let cells = line.split(separator: ",", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard cells.count == head.count, let axis = Int(cells[0]), let outward = Int(cells[1]) else {
                continue
            }
            let box = cells[2..<8].compactMap { Float($0) }
            guard box.count == 6 else { continue }
            rows[key(axis, outward, box)] = cells.map { Double($0) ?? 0 }
        }

        // Each building's judged ground-floor strips and its roofs inside the fair part of the run.
        var wallsOf: [Int: [(m: Int, row: [Double])]] = [:]
        for (m, entry) in reference.strips.enumerated() {
            let strip = reference.index.strips[entry.saved]
            guard let low = strip.low, let high = strip.high,
                let row = rows[key(strip.axis, strip.outward, [low.x, low.y, low.z, high.x, high.y, high.z])]
            else { continue }
            wallsOf[entry.object, default: []].append((m, row))
        }
        var roofsOf: [Int: [Int]] = [:]
        for (m, entry) in reference.otherStrips.enumerated() where entry.component.kind == .roof {
            guard reference.inside(FacadeLoadSurrogate.outerFace(entry.component).centre, share: share) else {
                continue
            }
            roofsOf[entry.object, default: []].append(m)
        }
        let owners = wallsOf.keys.sorted()
        print(
            "\(wallsOf.values.reduce(0) { $0 + $1.count }) of \(rows.count) judged strips found, on \(owners.count) buildings; "
                + "\(owners.filter { roofsOf[$0] != nil }.count) of them with roofs judged")

        let objects = reference.objects
        let tops = objects.map { Double(SurrogateBench.bounds($0).1.z) }
        let bases = objects.map { Double(SurrogateBench.bounds($0).0.z) }
        let root = cbrt(mass)
        let binS = 0.7e-3
        // `--terms` or `--coefficients`: the surrogate's terms (the adopted ones without either), the
        // walls on their own rise; and their load scatter (or `--load-scatter`'s).
        let coefficients = try SurrogateBench.coefficients(args)
        let loadScatter = try SurrogateBench.loadScatter(args)
        var results = [Building?](repeating: nil, count: owners.count)
        _ = SDOFResponseMemo.remembering {
            results.withUnsafeMutableBufferPointer { out in
                SurrogateBench.concurrentlyEach(owners.count) { b in
                    let n = owners[b]
                    let construction = scene.envelopeConstruction(for: objects[n].id)
                    func assess(_ load: EnvelopeComponentLoad) -> Int {
                        EnvelopeDamageAssessment.assess(
                            load, construction: construction, buildingTop: tops[n], buildingBase: bases[n]
                        )?.levels.upperBound.rawValue ?? 0
                    }
                    func recorded(_ component: EnvelopeComponent, _ net: [Double], _ bin: Double) -> Int {
                        let kind = EnvelopeComponentLoad.Kind(rawValue: component.kind.rawValue) ?? .wall
                        return assess(
                            EnvelopeComponentLoad(
                                id: component.id, owner: objects[n].id, kind: kind, region: component.region,
                                axis: component.axis, binS: bin, outerPa: net,
                                innerPa: Array(repeating: 0, count: net.count),
                                supportEdges: component.supportEdges, outward: component.outward))
                    }
                    // The parts: each its component, the surrogate's prediction, its side's group and
                    // its scatter, and each variant's peak and impulse.
                    struct Part {
                        var id: Int
                        var component: EnvelopeComponent
                        var prediction: FacadeLoadSurrogate.Prediction
                        var group: Int
                        var scatter: FacadeLoadSurrogate.Uncertainty.LoadScatter?
                        var loads: [(peak: Double, impulse: Double)]
                    }
                    func scatter(_ f: FacadeLoadSurrogate.Features) -> FacadeLoadSurrogate.Uncertainty
                        .LoadScatter?
                    {
                        loadScatter.first { f.distanceM / root <= $0.upToZ }
                    }
                    var walls: [Part] = []
                    var wallTruth = 0
                    var logRatios = [SIMD2<Double>](repeating: .zero, count: variants.count)
                    for (m, row) in wallsOf[n]! {
                        let (s, _, component) = reference.strips[m]
                        wallTruth = max(
                            wallTruth, recorded(component, reference.net(s), reference.index.strips[s].binS))
                        var f = FacadeLoadSurrogate.features(
                            component, owner: n, charge: charge, raster: reference.raster)
                        f.chargeOpenM = open
                        let p = FacadeLoadSurrogate.predict(
                            f, mass: mass, cellSize: cell, coefficients: coefficients.forStructures)
                        let loads = variants.map { v in
                            (v.peak.map { row[$0] } ?? p.peakPa, v.impulse.map { row[$0] } ?? p.impulsePaS)
                        }
                        for (v, load) in loads.enumerated() where p.peakPa > 0 && p.impulsePaS > 0 {
                            logRatios[v] += SIMD2(log(load.0 / p.peakPa), log(load.1 / p.impulsePaS))
                        }
                        walls.append(
                            Part(
                                id: walls.count, component: component, prediction: p,
                                group: component.axis * 2 + (component.outward > 0 ? 1 : 0),
                                scatter: scatter(f),
                                loads: loads))
                    }
                    let ratios = logRatios.map { exp($0 / Double(walls.count)) }
                    var roofs: [Part] = []
                    var roofTruth: Int?
                    for m in roofsOf[n] ?? [] {
                        let (s, _, component) = reference.otherStrips[m]
                        roofTruth = max(
                            roofTruth ?? 0,
                            recorded(component, reference.otherNet(s), reference.others!.strips[s].binS))
                        let f = FacadeLoadSurrogate.features(
                            component, owner: n, charge: charge, raster: reference.raster)
                        let p = FacadeLoadSurrogate.predict(
                            f, mass: mass, cellSize: cell, coefficients: .roofs)
                        // By the saved box, as judge_field.py lists the roofs.
                        let saved = reference.others!.strips[s]
                        let own = (saved.low.flatMap { low in saved.high.map { (low, $0) } }).flatMap { box in
                            roofRows[
                                [2, 1]
                                    + [box.0.x, box.0.y, box.0.z, box.1.x, box.1.y, box.1.z].map {
                                        Int32(($0 * 10).rounded())
                                    }]
                        }
                        let loads = ratios.enumerated().map { v, ratio -> (peak: Double, impulse: Double) in
                            // The roof's own load where the roofs' file gives the variant's, else
                            // the proxy (or, with a roofs' file, the surrogate's own for that part).
                            guard !roofHead.isEmpty else {
                                return (p.peakPa * ratio.x, p.impulsePaS * ratio.y)
                            }
                            guard let own else { return (p.peakPa, p.impulsePaS) }
                            let c = roofColumns[v]
                            return (
                                c.peak.map { own[$0] } ?? p.peakPa, c.impulse.map { own[$0] } ?? p.impulsePaS
                            )
                        }
                        roofs.append(
                            Part(
                                id: 100_000 + roofs.count, component: component, prediction: p, group: 6,
                                scatter: scatter(f), loads: loads))
                    }
                    // A part's level under variant v's load times (peak, impulse).
                    // The pulse rounds its peak and impulse to `quantum`, so its level is
                    // remembered by the part and the rounded pair, the same to the bit.
                    var known: [SIMD3<Int64>: Int] = [:]
                    let step = log(1 + FacadeLoadSurrogate.quantum)
                    func level(_ part: Part, _ v: Int, _ peak: Double, _ impulse: Double) -> Int {
                        var p = part.prediction
                        p.peakPa = part.loads[v].peak * peak
                        p.impulsePaS = part.loads[v].impulse * impulse
                        guard p.peakPa > 0, p.impulsePaS > 0 else { return 0 }
                        let key = SIMD3(
                            Int64(part.id), Int64((log(p.peakPa) / step).rounded()),
                            Int64((log(p.impulsePaS) / step).rounded()))
                        if let found = known[key] { return found }
                        var load = FacadeLoadSurrogate.load(part.component, p, binS: binS)
                        load.kind =
                            EnvelopeComponentLoad.Kind(rawValue: part.component.kind.rawValue) ?? .wall
                        let reached = assess(load)
                        known[key] = reached
                        return reached
                    }
                    // Each draw's errors by group (the first part of the group sets its scatter),
                    // standard normals, shared by every variant and pair.
                    let item = UInt64(n) &* 16
                    var normals: [Int: [(Double, Double)]] = [:]
                    for part in walls + roofs where normals[part.group] == nil {
                        normals[part.group] = (0..<draws).map {
                            (
                                normal(3, $0, item &+ UInt64(part.group)),
                                normal(4, $0, item &+ UInt64(part.group))
                            )
                        }
                    }
                    func errors(_ part: Part, _ k: Int, _ scale: Double) -> SIMD2<Double> {
                        guard let s = part.scatter, scale > 0 else { return .zero }
                        let (a, c) = normals[part.group]![k]
                        let r = s.correlation
                        return scale * SIMD2(s.peak * a, s.impulse * (r * a + (1 - r * r).squareRoot() * c))
                    }
                    // The chances of `parts` under variant v and the grid's pairs: the share of
                    // draws whose worst part reaches moderate, and heavy.
                    func chances(_ parts: [Part], _ v: Int) -> [(moderate: Double, heavy: Double)] {
                        grid.map { pair in
                            let (factor, scale) = (pair[0], pair[1])
                            // Those that can reach moderate at the scatter's high end.
                            let possible = parts.filter { part in
                                let s = part.scatter
                                let peak = exp(2.5 * scale * (s?.peak ?? 0)) * factor
                                let impulse = exp(2.5 * scale * (s?.impulse ?? 0)) * factor
                                return level(part, v, peak, impulse) > 0
                            }
                            .sorted { level($0, v, factor, factor) > level($1, v, factor, factor) }
                            guard !possible.isEmpty else { return (0, 0) }
                            let count = scale > 0 ? draws : 1
                            var moderate = 0
                            var heavy = 0
                            for k in 0..<count {
                                var worst = 0
                                for part in possible where worst < EnvelopeDamageLevel.heavy.rawValue {
                                    let e = errors(part, k, scale)
                                    worst = max(worst, level(part, v, exp(e.x) * factor, exp(e.y) * factor))
                                }
                                moderate += worst >= EnvelopeDamageLevel.moderate.rawValue ? 1 : 0
                                heavy += worst >= EnvelopeDamageLevel.heavy.rawValue ? 1 : 0
                            }
                            return (Double(moderate) / Double(count), Double(heavy) / Double(count))
                        }
                    }
                    var building = Building(
                        object: n,
                        distanceM: reference.index.buildings[
                            reference.index.strips[reference.strips[wallsOf[n]![0].m].saved].building
                        ].distanceM,
                        walls: construction.walls.rawValue, wall: wallTruth, roof: roofTruth,
                        wallsModerate: [:],
                        wallsHeavy: [:], roofModerate: [:])
                    for (v, variant) in variants.enumerated() {
                        let c = chances(walls, v)
                        building.wallsModerate[variant.name] = c.map(\.moderate)
                        building.wallsHeavy[variant.name] = c.map(\.heavy)
                        if !roofs.isEmpty {
                            building.roofModerate[variant.name] = chances(roofs, v).map(\.moderate)
                        }
                    }
                    out[b] = building
                }
            }
        }
        let buildings = results.compactMap { $0 }
        let seconds = DistrictBenchmark.seconds(start)
        let judged = Judged(
            massKg: mass, draws: draws, grid: grid, variants: names, buildings: buildings, seconds: seconds)
        let wallsDamaged = buildings.filter { ($0.wall ?? 0) >= EnvelopeDamageLevel.moderate.rawValue }.count
        let roofsDamaged = buildings.filter { ($0.roof ?? 0) >= EnvelopeDamageLevel.moderate.rawValue }.count
        print(
            String(
                format:
                    "%d buildings, %d with a ground-floor wall and %d with a roof damaged moderately or worse in the run; %.0f s",
                buildings.count, wallsDamaged, roofsDamaged, seconds))
        if let out = value("out") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(judged).write(to: URL(filePath: out))
        }
    }
}
