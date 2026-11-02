import Foundation
import simd

/// `scenebench charge-from-damage` (and `blastmodel charge-from-damage`): the charge read back
/// from marked damage by the learned network (`ChargeFromDamage`, emmettl/bombcad-work#116;
/// docs/charge-inference.md, "The charge from marked damage, learned").
///
/// ```
/// charge-from-damage table <district-scene's inputs> [--scene-radius 2500] [--place-radius 500]
///     [--spacing 25] [--buildings 2500] [--yields 100,1.6,24] [--draws 32] [--name beirut]
///     [--geer Facade_damage.shp] [--structure a.dbf,b.dbf|folder] [--marks-out geer-marks.csv]
///     [--part k/n] [--full] [--masonry-only --objects i,j,…] --out table.bcct
/// charge-from-damage merge --out table.bcct part.bcct…
/// charge-from-damage merge-masonry --table t.bcct --masonry m.bcct --out u.bcct
/// charge-from-damage judge --tables a.bcct,b.bcct [--weights net.bccd] [--cases 300] [--counts 1,3,10,30]
///     [--seed 7] [--about-damage] [--weighing name] [--out judge.json]
/// charge-from-damage infer [--weights net.bccd] --marks marks.csv [--table table.bcct] [--subsets 1,3,10,30]
///     [--hold] [--weighing name]
/// ```
///
/// `table` works out the quick estimate's chances (`ChargeFromDamage.ChanceTable`) for a district's
/// chosen buildings: up to `--buildings`, spread over rings 100 m wide about the scene's charge (the
/// reference), every building GEER's surveys name among them; for charges on a grid `--spacing` m
/// apart over the square of half side `--place-radius` (a node beyond it each way), at the yields
/// `first,factor,count` kg, each chance drawn `--draws` times. `--part k/n` works out the k-th of n
/// slices of the nodes (from 0), for `merge` to join. With `--geer`/`--structure`, `--marks-out`
/// writes what GEER saw on the chosen buildings as marks. Each building is judged as a drag's
/// preview judges it (its nearest component of each group) unless `--full`. `--masonry-only` works
/// out the walls as masonry alone, from the full look, for the envelope buildings `--objects`
/// names: the preview's nearest strip is a masonry wall's strongest, the storeys over it pressing it,
/// and reads masonry 2–4 times too strong; `merge-masonry` puts them into a table.
///
/// `judge` draws held-out cases from each table (`ChanceTable.drawCase`, as training draws them,
/// from another seed) and judges the network against the truth and against the full posterior on
/// the same chances: how often the truth falls in each's 50% and 90% regions and intervals, how far
/// apart they are, how fast they firm up with the marks, and the time each takes.
///
/// `infer` weighs a file of marks: `building,east,north,height,footprint,built,walls,glass,seen`
/// (building: the table's index or −1; east and north about the reference, m; walls
/// concrete|masonry|other; glass -|whole|broken; seen -|undamaged|damaged|heavy).
package enum ChargeFromDamageStudy {
    package static func run(_ args: [String]) throws {
        StudyOutput.lineBuffered()
        guard let mode = args.first else {
            throw BlastError.allocationFailed(
                "charge-from-damage table|merge|merge-masonry|judge|infer|looks|judge-looks|survey")
        }
        let rest = Array(args.dropFirst())
        switch mode {
        case "table": try table(rest)
        case "merge": try merge(rest)
        case "merge-masonry": try mergeMasonry(rest)
        case "judge": try judge(rest)
        case "infer": try infer(rest)
        case "looks": try looks(rest)
        case "judge-looks": try judgeLooks(rest)
        case "survey": try survey(rest)
        default:
            throw BlastError.allocationFailed(
                "charge-from-damage table|merge|merge-masonry|judge|infer|looks|judge-looks|survey, not \(mode)"
            )
        }
    }

    static func value(_ args: [String], _ name: String) -> String? { SurrogateBench.value(args, name) }

    /// `--weighing name` (`ChargeFromDamage.Weighing.named`): how the marks are weighed together, the
    /// adopted weighing unless named; `independent` is stage 2's.
    static func weighing(_ args: [String]) throws -> ChargeFromDamage.Weighing {
        guard let name = value(args, "weighing") else { return .adopted }
        guard let w = ChargeFromDamage.Weighing.named(name) else {
            throw BlastError.allocationFailed(
                "no weighing \(name): independent, \(ChargeFromDamage.Weighing.adopted.name) or neighbours=…,rho=…,yield=…,place=…"
            )
        }
        return w
    }

    // MARK: - table

    static func table(_ args: [String]) throws {
        let start = ContinuousClock.now
        guard let out = value(args, "out") else { throw BlastError.allocationFailed("--out table.bcct") }
        let inputs = try DistrictInputs.read(args)
        let sceneRadius = Float(value(args, "scene-radius").flatMap(Double.init) ?? 2500)
        let (scene, _) = try inputs.scene(radius: sceneRadius)
        let dx = inputs.cellSize
        let placeRadius = value(args, "place-radius").flatMap(Double.init) ?? 500
        let spacing = value(args, "spacing").flatMap(Double.init) ?? 25
        let budget = value(args, "buildings").flatMap(Int.init) ?? 2500
        let draws = value(args, "draws").flatMap(Int.init) ?? 32
        let ladder = (value(args, "yields") ?? "100,1.6,24").split(separator: ",").compactMap { Double($0) }
        guard ladder.count == 3 else { throw BlastError.allocationFailed("--yields first,factor,count") }
        let yields = (0..<Int(ladder[2])).map { ladder[0] * pow(ladder[1], Double($0)) }
        let objects = scene.envelopeObjects
        let charge = scene.charge.position
        let reference = SIMD2<Double>(Double(charge.x), Double(charge.y))
        let terms = FacadeLoadSurrogate.TermSet.adopted
        let prepared = FacadeLoadSurrogate.Prepared(
            scene: scene, cellSize: dx, incidence: terms.coefficients.incidence)
        let all = ChargeFromDamage.buildings(scene: scene)
        print(
            String(
                format: "%d envelope buildings, %d components on the air, laid out in %.1f s",
                objects.count, prepared.componentCount, StudyClock.seconds(start)))

        // GEER's buildings first, then the rest by rings.
        var named:
            [Int: (glass: ChargeFromDamage.GlassSeen?, walls: ChargeFromDamage.WallsSeen?, masonry: Bool)] =
                [:]
        if value(args, "geer") != nil || value(args, "structure") != nil {
            named = try geerMarks(
                args, scene: scene, objects: objects, prepared: prepared, cellSize: dx,
                radius: sceneRadius)
        }
        let usable = objects.indices.filter { !prepared.components[$0].isEmpty }
        var chosen = Array(named.keys.filter { usable.contains($0) }).sorted()
        let ringWidth = 100.0
        let rings = Int((Double(sceneRadius) * 2.0.squareRoot() / ringWidth).rounded(.up))
        var byRing = [[Int]](repeating: [], count: rings + 1)
        let taken = Set(chosen)
        for n in usable where !taken.contains(n) {
            let d = simd_distance(SIMD2(all[n].east, all[n].north), reference)
            byRing[min(Int(d / ringWidth), rings)].append(n)
        }
        // Each ring's in an order of its own, then a share from each in turn.
        var random = ChargeFromDamage.SplitMix(seed: 116)
        for r in byRing.indices {
            byRing[r] = byRing[r].map { ($0, random.next()) }.sorted { $0.1 < $1.1 }.map(\.0)
        }
        var cursor = [Int](repeating: 0, count: byRing.count)
        while chosen.count < budget {
            var added = false
            for r in byRing.indices where cursor[r] < byRing[r].count && chosen.count < budget {
                chosen.append(byRing[r][cursor[r]])
                cursor[r] += 1
                added = true
            }
            if !added { break }
        }
        chosen.sort()
        // `--objects`: exactly these envelope buildings (their indices among the scene's), as
        // `--masonry-only` takes a table's subset.
        if let list = value(args, "objects") {
            chosen = list.split(separator: ",").compactMap { Int($0) }.filter { usable.contains($0) }.sorted()
        }
        let buildings = chosen.map { n -> ChargeFromDamage.Building in
            var b = all[n]
            b.east -= reference.x
            b.north -= reference.y
            return b
        }
        print("\(chosen.count) buildings chosen (\(named.count) of GEER's)")

        if let path = value(args, "marks-out") {
            var lines = ["building,east,north,height,footprint,built,walls,glass,seen,source"]
            for (k, n) in chosen.enumerated() {
                guard let seen = named[n] else { continue }
                var b = buildings[k]
                if seen.masonry { b.walls = .masonry }
                lines.append(
                    String(
                        format: "%d,%.1f,%.1f,%.1f,%.0f,%.3f,%@,%@,%@,GEER", k, b.east, b.north, b.heightM,
                        b.footprintM2, b.builtShare, wallsName(b.walls) as NSString,
                        (seen.glass.map { $0 == .whole ? "whole" : "broken" } ?? "-") as NSString,
                        (seen.walls.map {
                            $0 == .undamaged ? "undamaged" : $0 == .damaged ? "damaged" : "heavy"
                        }
                            ?? "-") as NSString))
            }
            try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            print("Wrote \(lines.count - 1) marks to \(path)")
        }

        // The nodes, and this part's slice of them.
        let count = Int((2 * placeRadius / spacing).rounded(.up)) + 3
        let origin = -placeRadius - spacing
        var first = 0
        var end = count * count
        if let part = value(args, "part") {
            let p = part.split(separator: "/").compactMap { Int($0) }
            guard p.count == 2, p[1] > 0, (0..<p[1]).contains(p[0]) else {
                throw BlastError.allocationFailed("--part k/n")
            }
            first = count * count * p[0] / p[1]
            end = count * count * (p[0] + 1) / p[1]
        }
        let chargeAbove = charge.z - (scene.terrain?.height(at: charge) ?? 0)
        let ownConstruction = { (id: UUID) in scene.envelopeConstruction(for: id) }
        let masonryConstruction = { (id: UUID) -> EnvelopeConstruction in
            var c = scene.envelopeConstruction(for: id)
            c.walls = .unreinforcedMasonry
            c.wallThicknessM = 0.5
            return c
        }
        let indexOf = Dictionary(uniqueKeysWithValues: chosen.enumerated().map { (objects[$1].id, $0) })
        let withMasonry = args.contains("--masonry")
        // `--masonry-only`: the walls as masonry alone, from the full look: a preview's nearest strip
        // of a side stands for its weakest badly there, a masonry wall's resistance growing with the
        // storeys over it (docs/charge-inference.md, "The charge from marked damage, learned").
        let masonryOnly = args.contains("--masonry-only")
        // A drag's preview of each building (its nearest component of each group) unless `--full`.
        let full = args.contains("--full") || masonryOnly
        let channelNames =
            masonryOnly
            ? Array(ChargeFromDamage.ChanceTable.channels.suffix(2))
            : Array(ChargeFromDamage.ChanceTable.channels.prefix(withMasonry ? 5 : 3))
        let channels = channelNames.count
        let perNode = yields.count * chosen.count * channels
        var values = [UInt8](repeating: 0, count: (end - first) * perNode)
        func byte(_ p: Double) -> UInt8 { UInt8(min(max((p * 255).rounded(), 0), 255)) }
        for node in first..<end {
            let clock = ContinuousClock.now
            let place = SIMD2<Float>(
                Float(reference.x + origin + Double(node % count) * spacing),
                Float(reference.y + origin + Double(node / count) * spacing))
            let at = SIMD3(place.x, place.y, (scene.terrain?.height(at: place) ?? 0) + chargeAbove)
            let (estimate, sides) =
                full
                ? {
                    let e = prepared.chosenFeatures(charge: at, chosen: chosen)
                    return (e, masonryOnly ? [] : prepared.glassSides(e))
                }() : prepared.chosenPreview(charge: at, chosen: chosen)
            let memo = SDOFResponseMemo()
            // A preview's coarser panes' table, which agrees with a full look's as closely
            // (`Prepared.previewQuantum`), and is far quicker over many charges.
            let responses = FacadeLoadSurrogate.GlassResponses(
                quantum: FacadeLoadSurrogate.Prepared.previewQuantum,
                strengthSteps: FacadeLoadSurrogate.Prepared.previewStrengthSteps)
            let base = (node - first) * perNode
            var spent = [0.0, 0.0, 0.0]
            // Yields upward: a building whose chance has reached 1 keeps it at every larger yield
            // (the chances draw the same scatter at each), so is not worked out again.
            var glassDone = Set<Int>()
            var wallsDone: [Int: Set<Int>] = [0: [], 1: [], 3: []]
            for (k, mass) in yields.enumerated() {
                var clock = ContinuousClock.now
                let uncertainty = FacadeLoadSurrogate.Uncertainty(masses: [mass], samples: draws, seed: 1)
                let passes: [(Int, (UUID) -> EnvelopeConstruction)] =
                    masonryOnly
                    ? [(0, masonryConstruction)]
                    : [(1, ownConstruction), (3, masonryConstruction)].filter { $0.0 + 1 < channels }
                for b in glassDone { values[base + (k * chosen.count + b) * channels] = 255 }
                // The glass: per building, the chance that some pane of some side breaks, its sides'
                // draws taken together (they share the building's strength).
                let open =
                    masonryOnly
                    ? [] : sides.filter { indexOf[$0.owner].map { !glassDone.contains($0) } ?? false }
                let (_, kept) = FacadeLoadSurrogate.glassProbabilities(
                    sides: open, mass: mass, cellSize: dx, uncertainty: uncertainty,
                    coefficients: terms.coefficients, keepDraws: true, responses: responses)
                var none: [Int: [Double]] = [:]
                for (s, side) in open.enumerated() {
                    guard let b = indexOf[side.owner], let outcomes = kept?[s] else { continue }
                    var row = none[b] ?? [Double](repeating: 1, count: draws)
                    for (d, o) in outcomes.enumerated() where d < draws { row[d] *= 1 - Double(o.someBroken) }
                    none[b] = row
                }
                for (b, row) in none {
                    let p = byte(1 - row.reduce(0, +) / Double(draws))
                    values[base + (k * chosen.count + b) * channels] = p
                    if p == 255 { glassDone.insert(b) }
                }
                spent[0] += StudyClock.seconds(clock)
                for (offset, constructions) in passes {
                    clock = .now
                    let done = wallsDone[offset] ?? []
                    for b in done {
                        values[base + (k * chosen.count + b) * channels + offset] = 255
                        values[base + (k * chosen.count + b) * channels + offset + 1] = 255
                    }
                    var subset = estimate
                    if !done.isEmpty {
                        let keep = estimate.owners.indices.filter {
                            !done.contains(indexOf[objects[estimate.owners[$0]].id] ?? -1)
                        }
                        subset.components = keep.map { estimate.components[$0] }
                        subset.owners = keep.map { estimate.owners[$0] }
                        subset.features = keep.map { estimate.features[$0] }
                    }
                    let (result, _) = SDOFResponseMemo.remembering(in: memo) {
                        FacadeLoadSurrogate.structureProbabilities(
                            subset, mass: mass, cellSize: dx, constructions: constructions,
                            uncertainty: uncertainty, coefficients: terms.coefficients)
                    }
                    for chance in result.chances {
                        guard let b = indexOf[chance.owner] else { continue }
                        let heavy = byte(chance.wallsHeavy)
                        values[base + (k * chosen.count + b) * channels + offset] = byte(chance.wallsModerate)
                        values[base + (k * chosen.count + b) * channels + offset + 1] = heavy
                        if heavy == 255 { wallsDone[offset, default: []].insert(b) }
                    }
                    spent[offset == 1 ? 1 : 2] += StudyClock.seconds(clock)
                }
            }
            print(
                String(
                    format:
                        "node %d of %d..<%d (%.0f, %.0f m): %.2f s (glass %.2f, walls %.2f, masonry %.2f)",
                    node,
                    first, end, Double(place.x) - reference.x, Double(place.y) - reference.y,
                    StudyClock.seconds(clock), spent[0], spent[1], spent[2]))
        }
        let header = ChargeFromDamage.ChanceTable.Header(
            format: ChargeFromDamage.ChanceTable.magic, district: value(args, "name") ?? "district",
            reference: [reference.x, reference.y], origin: [origin, origin], spacingM: spacing,
            columns: count,
            rows: count, yieldsKg: yields, channels: channelNames, buildings: buildings,
            objects: chosen, draws: draws, cellSizeM: Double(dx),
            terms: full ? "adopted" : "adopted, preview", placeRadiusM: placeRadius,
            sceneRadiusM: Double(sceneRadius), seconds: StudyClock.seconds(start), firstNode: first,
            nodeCount: end - first)
        try ChargeFromDamage.ChanceTable(header: header, values: values).write(to: URL(filePath: out))
        print(
            String(
                format: "Wrote %@: nodes %d..<%d of %d in %.0f s", out, first, end, count * count,
                StudyClock.seconds(start)))
    }

    static func wallsName(_ w: ChargeFromDamage.Walls) -> String {
        switch w {
        case .concrete: "concrete"
        case .masonry: "masonry"
        case .other: "other"
        }
    }

    /// GEER's façades and buildings put on the scene's buildings (by envelope index): each
    /// building's glass broken where any façade on it was classed W1 or worse, whole where all were
    /// W0; its walls by GEER's structural class (concrete D0–D1 undamaged, D2 damaged, D3 or worse
    /// heavy; stone, as masonry, D3 or worse heavy and the rest undamaged; a class straddling the
    /// line left out).
    static func geerMarks(
        _ args: [String], scene: Scenario, objects: [SceneObject], prepared: FacadeLoadSurrogate.Prepared,
        cellSize dx: Float, radius: Float
    ) throws -> [Int: (glass: ChargeFromDamage.GlassSeen?, walls: ChargeFromDamage.WallsSeen?, masonry: Bool)]
    {
        var marks:
            [Int: (glass: ChargeFromDamage.GlassSeen?, walls: ChargeFromDamage.WallsSeen?, masonry: Bool)] =
                [:]
        let centre = SurrogateBench.centre(args)
        let indexOf = Dictionary(uniqueKeysWithValues: objects.enumerated().map { ($1.id, $0) })
        if let path = value(args, "geer") {
            let (sides, matches, records) = try GlassCalibration.geerFacades(
                path, scene: scene, objects: objects, raster: prepared.raster, cellSize: dx, radius: radius,
                centre: centre)
            var broken: [Int: Bool] = [:]
            for m in matches {
                guard let n = indexOf[sides[m.side].owner] else { continue }
                broken[n] = (broken[n] ?? false) || m.observedClass >= 1
            }
            for (n, b) in broken { marks[n] = (b ? .broken : .whole, nil, false) }
            print("GEER façades: \(matches.count) of \(records.count) matched, on \(broken.count) buildings")
        }
        if let paths = value(args, "structure") {
            let metresPerDegree = ElevationGrid.metresPerDegree
            let corner = SIMD2(
                centre.x - Double(radius) / (metresPerDegree * cos(centre.y * .pi / 180)),
                centre.y - Double(radius) / metresPerDegree)
            let placement = MapBuildingPlacement(origin: corner, resolution: dx)
            let footprints = objects.map { object -> (SIMD2<Float>, SIMD2<Float>) in
                let (low, high) = SurrogateBench.bounds(object)
                return (SIMD2(low.x, low.y), SIMD2(high.x, high.y))
            }
            var used = 0
            var skipped = 0
            // Each file named, or each .dbf in a folder named.
            let files = try paths.split(separator: ",").map(String.init).flatMap { path -> [String] in
                var folder: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &folder), folder.boolValue
                else {
                    return [path]
                }
                return try FileManager.default.contentsOfDirectory(atPath: path).filter {
                    $0.hasSuffix(".dbf")
                }
                .sorted().map { URL(filePath: path).appending(path: $0).path }
            }
            for path in files {
                for record in try ChargeInferenceInputs.readDBF(URL(filePath: path)) {
                    func field(_ name: String) -> String? {
                        record[name]?.trimmingCharacters(in: .whitespaces)
                    }
                    guard let lat = field("Latitude").flatMap(Double.init),
                        let lon = field("Longitude").flatMap(Double.init),
                        let damage = field("Damage_Cla"), !damage.isEmpty
                    else {
                        skipped += 1
                        continue
                    }
                    if let visit = field("VID"), visit != "0" { continue }
                    guard
                        let (seen, stone) = ChargeFromDamage.geerStructure(
                            damage: damage, type: field("Str_Type"))
                    else {
                        skipped += 1
                        continue
                    }
                    let at = SIMD2<Float>(placement.position(SIMD2(lon, lat)))
                    var best: (Int, Float)?
                    for (n, (lo, hi)) in footprints.enumerated() {
                        let d = simd_length(simd_max(simd_max(lo - at, at - hi), .zero))
                        if d < (best?.1 ?? 15) { best = (n, d) }
                    }
                    guard let (n, _) = best, marks[n]?.walls == nil else {
                        skipped += 1
                        continue
                    }
                    marks[n] = (marks[n]?.glass, seen, stone)
                    used += 1
                }
            }
            print("GEER structure: \(used) buildings matched, \(skipped) left out")
        }
        return marks
    }

    // MARK: - merge

    static func merge(_ args: [String]) throws {
        guard let out = value(args, "out") else { throw BlastError.allocationFailed("--out table.bcct") }
        let paths = args.enumerated().filter {
            $0.element.hasSuffix(".bcct") && args[max($0.offset - 1, 0)] != "--out"
        }
        .map(\.element)
        let table = try ChargeFromDamage.ChanceTable.merge(
            paths.map { try .init(contentsOf: URL(filePath: $0)) })
        try table.write(to: URL(filePath: out))
        print("Wrote \(out): \(table.nodes) nodes from \(paths.count) parts, \(table.values.count) bytes")
    }

    /// `merge-masonry --table t.bcct --masonry m.bcct --out u.bcct`: a table's masonry channels
    /// replaced by a `--masonry-only` table's for the buildings it holds (matched by their objects),
    /// those buildings named in `masonryBuildings`; the rest no longer judged as masonry.
    static func mergeMasonry(_ args: [String]) throws {
        guard let path = value(args, "table"), let masonryPath = value(args, "masonry"),
            let out = value(args, "out")
        else { throw BlastError.allocationFailed("--table t.bcct --masonry m.bcct --out u.bcct") }
        var table = try ChargeFromDamage.ChanceTable(contentsOf: URL(filePath: path))
        let masonry = try ChargeFromDamage.ChanceTable(contentsOf: URL(filePath: masonryPath))
        guard table.hasMasonry,
            masonry.header.channels == Array(ChargeFromDamage.ChanceTable.channels.suffix(2)),
            masonry.header.yieldsKg == table.header.yieldsKg, masonry.nodes == table.nodes,
            masonry.header.nodeCount == masonry.nodes
        else { throw BlastError.allocationFailed("tables that do not match") }
        let indexOf = Dictionary(uniqueKeysWithValues: table.header.objects.enumerated().map { ($1, $0) })
        let pairs = masonry.header.objects.enumerated().compactMap { m, object in
            indexOf[object].map { (m, $0) }
        }
        let tableBuildings = table.buildingCount
        let masonryBuildings = masonry.buildingCount
        let yieldCount = table.header.yieldsKg.count
        for node in 0..<table.nodes {
            for k in 0..<yieldCount {
                for (m, b) in pairs {
                    let to = ((node * yieldCount + k) * tableBuildings + b) * 5
                    let from = ((node * yieldCount + k) * masonryBuildings + m) * 2
                    table.values[to + 3] = masonry.values[from]
                    table.values[to + 4] = masonry.values[from + 1]
                }
            }
        }
        table.header.masonryBuildings = pairs.map(\.1).sorted()
        table.header.terms += "; masonry from the full look for \(pairs.count) buildings"
        try table.write(to: URL(filePath: out))
        print("Wrote \(out): masonry for \(pairs.count) of \(tableBuildings) buildings")
    }

    // MARK: - judge

    /// A posterior judged against a case's truth.
    struct Judged {
        var placeIn50 = false
        var placeIn90 = false
        var yieldIn50 = false
        var yieldIn90 = false
        var yieldRatio = 1.0
        var placeOff = 0.0
        var yieldWidth90 = 0.0
        var placeRadius90 = 0.0
        /// From the likeliest cell's middle to the truth, m, and the yield's median against the
        /// truth as a factor (at least 1, either way).
        var likeliestOff = 0.0
        var yieldFactor = 1.0

        init(_ p: ChargeFromDamage.Posterior, place: SIMD2<Double>, logMass: Double) {
            placeIn50 = p.regionHolds(place, mass: 0.5)
            placeIn90 = p.regionHolds(place, mass: 0.9)
            let u = p.yieldCDF(exp(logMass))
            yieldIn50 = u >= 0.25 && u <= 0.75
            yieldIn90 = u >= 0.05 && u <= 0.95
            yieldRatio = p.yieldQuantile(0.5) / exp(logMass)
            placeOff = simd_distance(p.meanPlace, place)
            yieldWidth90 = p.yieldQuantile(0.95) / p.yieldQuantile(0.05)
            placeRadius90 = p.regionRadius(0.9)
            likeliestOff = simd_distance(p.mostProbablePlace, place)
            yieldFactor = exp(abs(log(yieldRatio)))
        }
    }

    static func median(_ v: [Double]) -> Double {
        let s = v.sorted()
        return s.isEmpty ? .nan : s[s.count / 2]
    }

    static func share(_ v: [Bool]) -> Double {
        v.isEmpty ? .nan : Double(v.filter { $0 }.count) / Double(v.count)
    }

    static func judge(_ args: [String]) throws {
        let start = ContinuousClock.now
        guard let tables = value(args, "tables")?.split(separator: ",").map(String.init) else {
            throw BlastError.allocationFailed("--tables a.bcct,b.bcct [--weights net.bccd]")
        }
        let network = try ChargeFromDamage.Network.named(value(args, "weights"))
        let h = network.header
        let cases = value(args, "cases").flatMap(Int.init) ?? 300
        let counts: [Int?] =
            [nil] + (value(args, "counts") ?? "1,3,10,30").split(separator: ",").compactMap { Int($0) }
        let seed = value(args, "seed").flatMap(UInt64.init) ?? 7
        // `--about-damage`: the marks chosen as a user at the panel would, from where the damage is.
        let aboutDamage = args.contains("--about-damage")
        if aboutDamage { print("Marks chosen about the damage, as a user marks them") }
        let weighing = try Self.weighing(args)
        print("Weighed as \(weighing.name)")
        print(
            "Network \(h.name): trained on \(h.trainedOn.joined(separator: ", ")), \(h.grid)² cells of \(String(format: "%.1f", 2 * h.halfWidthM / Double(h.grid))) m"
        )
        // Against PyTorch, on the cases the file carries.
        if let references = h.references, !references.isEmpty {
            var worst = 0.0
            for r in references {
                if network.summed {
                    let joint = network.joint(marks: r.marks, reference: .zero)
                    let bins = h.yieldBins ?? 1
                    let cells = r.cells ?? Array(0..<(joint.count / bins))
                    for (n, c) in cells.enumerated() {
                        for k in 0..<bins where joint[c * bins + k].isFinite {
                            let given = r.logits[n * bins + k]
                            worst = max(worst, abs(Double(joint[c * bins + k]) - given) / max(1, abs(given)))
                        }
                    }
                    continue
                }
                let (logits, mu, _) = network.outputs(marks: r.marks, reference: .zero)
                for c in logits.indices where logits[c].isFinite {
                    worst = max(worst, abs(logits[c] - r.logits[c]), abs(mu[c] - r.mu[c]))
                }
            }
            print(
                String(
                    format: "Against PyTorch on %d cases: %@ within %.2e", references.count,
                    (network.summed ? "log likelihoods (relative)" : "logits and log yields") as NSString,
                    worst))
        }
        var report: [[String: Any]] = []
        for path in tables {
            let table = try ChargeFromDamage.ChanceTable(contentsOf: URL(filePath: path))
            let name = table.header.district
            let held = !h.trainedOn.contains(name)
            print(
                "\n\(name)\(held ? " (never trained on)" : ""): \(table.buildingCount) buildings, \(table.nodes) nodes"
            )
            print(
                "marks    model    place in 50% / 90%   yield in 50% / 90%   median found/true (10–90%)   mean place off   90% yield hi/lo   90% place radius   time"
            )
            for count in counts {
                var random = ChargeFromDamage.SplitMix(seed: seed &* 1_000_003 &+ UInt64(count ?? 0))
                let drawn = (0..<cases).map { _ in
                    table.drawCase(
                        &random, grid: h.grid, halfWidthM: h.halfWidthM, placeRadiusM: h.placeRadiusM,
                        markCount: count, aboutDamage: aboutDamage)
                }
                var learned: [Judged] = []
                var full: [Judged] = []
                var apart: [(ratio: Double, distance: Double)] = []
                var learnedSeconds: [Double] = []
                var addedSeconds: [Double] = []
                var fullSeconds: [Double] = []
                for c in drawn {
                    let marks = c.marks.map(table.mark)
                    var clock = ContinuousClock.now
                    let p = network.posterior(marks: marks, reference: .zero, weighing: weighing)
                    learnedSeconds.append(StudyClock.seconds(clock))
                    // One more mark, added to the others' summed likelihood, as the app adds it.
                    if network.summed, let last = marks.last {
                        let others = network.joint(marks: Array(marks.dropLast()), reference: .zero)
                        clock = .now
                        let added = network.joint(marks: [last], reference: .zero)
                        _ = network.posterior(joint: zip(others, added).map { $0 + $1 }, reference: .zero)
                        addedSeconds.append(StudyClock.seconds(clock))
                    }
                    clock = .now
                    let q = table.posterior(
                        marks: c.marks, grid: h.grid, halfWidthM: h.halfWidthM, placeRadiusM: h.placeRadiusM)
                    fullSeconds.append(StudyClock.seconds(clock))
                    learned.append(Judged(p, place: c.place, logMass: c.logMass))
                    full.append(Judged(q, place: c.place, logMass: c.logMass))
                    apart.append(
                        (p.yieldQuantile(0.5) / q.yieldQuantile(0.5), simd_distance(p.meanPlace, q.meanPlace))
                    )
                }
                for (label, judged, seconds) in [
                    ("learned", learned, learnedSeconds), ("full", full, fullSeconds),
                ] {
                    let ratios = judged.map(\.yieldRatio).sorted()
                    let offs = judged.map(\.likeliestOff).sorted()
                    let factors = judged.map(\.yieldFactor).sorted()
                    print(
                        String(
                            format:
                                "%5@   %-7@     %.2f / %.2f          %.2f / %.2f          %.2f (%.2f–%.2f)            %4.0f m          %6.1f          %4.0f m        %.1f ms",
                            (count.map(String.init) ?? "1–64") as NSString, label as NSString,
                            share(judged.map(\.placeIn50)), share(judged.map(\.placeIn90)),
                            share(judged.map(\.yieldIn50)), share(judged.map(\.yieldIn90)), median(ratios),
                            ratios[ratios.count / 10], ratios[ratios.count * 9 / 10],
                            median(judged.map(\.placeOff)),
                            median(judged.map(\.yieldWidth90)), median(judged.map(\.placeRadius90)),
                            1000 * median(seconds)))
                    print(
                        String(
                            format:
                                "                 likeliest place off the truth %.0f m (median), %.0f m (90th); yield off by a factor %.2f (median), %.2f (90th)",
                            median(offs), offs[offs.count * 9 / 10], median(factors),
                            factors[factors.count * 9 / 10]))
                    report.append([
                        "district": name, "marks": count ?? -1, "model": label, "cases": judged.count,
                        "placeIn50": share(judged.map(\.placeIn50)),
                        "placeIn90": share(judged.map(\.placeIn90)),
                        "yieldIn50": share(judged.map(\.yieldIn50)),
                        "yieldIn90": share(judged.map(\.yieldIn90)),
                        "medianYieldRatio": median(ratios), "yieldRatio10": ratios[ratios.count / 10],
                        "yieldRatio90": ratios[ratios.count * 9 / 10],
                        "medianPlaceOffM": median(judged.map(\.placeOff)),
                        "medianYieldWidth90": median(judged.map(\.yieldWidth90)),
                        "medianPlaceRadius90M": median(judged.map(\.placeRadius90)),
                        "medianSeconds": median(seconds), "heldOutDistrict": held,
                        "medianLikeliestOffM": median(offs), "likeliestOff90M": offs[offs.count * 9 / 10],
                        "medianYieldFactor": median(factors),
                        "yieldFactor90": factors[factors.count * 9 / 10],
                        "aboutDamage": aboutDamage,
                    ])
                }
                if !addedSeconds.isEmpty {
                    print(
                        String(
                            format: "          learned, one mark added to the rest: %.2f ms (median)",
                            1000 * median(addedSeconds)))
                }
                let logs = apart.map { abs(log($0.ratio)) }
                print(
                    String(
                        format:
                            "          learned against full: yields' medians apart by a factor %.2f (median), %.2f (90th); mean places %.0f m apart (median), %.0f m (90th)",
                        exp(median(logs)), exp(logs.sorted()[logs.count * 9 / 10]),
                        median(apart.map(\.distance)),
                        apart.map(\.distance).sorted()[apart.count * 9 / 10]))
                report.append([
                    "district": name, "marks": count ?? -1, "model": "apart",
                    "medianYieldFactor": exp(median(logs)),
                    "yieldFactor90": exp(logs.sorted()[logs.count * 9 / 10]),
                    "medianPlaceApartM": median(apart.map(\.distance)),
                    "placeApart90M": apart.map(\.distance).sorted()[apart.count * 9 / 10],
                    "medianAddedMarkSeconds": addedSeconds.isEmpty ? -1 : median(addedSeconds),
                ])
            }
        }
        if let out = value(args, "out") {
            let data = try JSONSerialization.data(
                withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(filePath: out))
            print("\nWrote \(out)")
        }
        print(String(format: "In %.0f s", StudyClock.seconds(start)))
    }

    // MARK: - infer

    static func readMarks(_ path: String) throws -> [(index: Int, mark: ChargeFromDamage.Mark)] {
        ChargeFromDamage.readMarks(text: try String(contentsOfFile: path, encoding: .utf8))
    }

    static func infer(_ args: [String]) throws {
        guard let path = value(args, "marks") else {
            throw BlastError.allocationFailed("--marks marks.csv [--weights net.bccd]")
        }
        let network = try ChargeFromDamage.Network.named(value(args, "weights"))
        let h = network.header
        let all = try readMarks(path)
        let weighing = try Self.weighing(args)
        let table = try value(args, "table").map {
            try ChargeFromDamage.ChanceTable(contentsOf: URL(filePath: $0))
        }
        let kinds: [(String, (ChargeFromDamage.Mark) -> ChargeFromDamage.Mark?)] = [
            ("all marks", { $0 }),
            (
                "glass alone",
                { $0.glass == nil ? nil : ChargeFromDamage.Mark(building: $0.building, glass: $0.glass) }
            ),
            (
                "walls alone",
                { $0.walls == nil ? nil : ChargeFromDamage.Mark(building: $0.building, walls: $0.walls) }
            ),
            (
                "masonry walls alone",
                {
                    $0.walls == nil || $0.building.walls != .masonry
                        ? nil : ChargeFromDamage.Mark(building: $0.building, walls: $0.walls)
                }
            ),
        ]
        let subsets = (value(args, "subsets") ?? "1,3,10,30").split(separator: ",").compactMap { Int($0) }
        // `--hold`: the place held at the reference, the four cells round it (within a cell of it).
        let held: Set<Int>? =
            args.contains("--hold")
            ? Set(
                (0..<(h.grid * h.grid)).filter {
                    let m = ChargeFromDamage.Network.cellMiddle($0, grid: h.grid, halfWidthM: h.halfWidthM)
                    return max(abs(m.x), abs(m.y)) < 2 * h.halfWidthM / Double(h.grid)
                }) : nil
        if held != nil { print("The place held at the reference (the four cells round it)") }
        print("\(all.count) marks from \(path), weighed as \(weighing.name); \(ChargeFromDamage.standing)")
        for (label, keep) in kinds {
            let kept = all.compactMap { m in keep(m.mark).map { (m.index, $0) } }
            guard !kept.isEmpty else { continue }
            // In an order of their own, so that the first n are a fair draw of n.
            var random = ChargeFromDamage.SplitMix(seed: 40)
            let shuffled = kept.map { ($0, random.next()) }.sorted { $0.1 < $1.1 }.map(\.0)
            print("\n\(label): \(kept.count) marks")
            for n in subsets.filter({ $0 < kept.count }) + [kept.count] {
                let some = Array(shuffled.prefix(n))
                let clock = ContinuousClock.now
                let p =
                    network.summed
                    ? network.posterior(
                        marks: some.map(\.1), reference: .zero, weighing: weighing, only: held)
                    : network.posterior(marks: some.map(\.1), reference: .zero)
                let took = StudyClock.seconds(clock)
                print(String(format: "  %4d learned (%.1f ms): ", n, 1000 * took) + p.summary(standing: ""))
                if let table, some.allSatisfy({ $0.0 >= 0 }) {
                    let marks = some.map {
                        ChargeFromDamage.ChanceTable.TableMark(
                            building: $0.0, masonry: $0.1.building.walls == .masonry, glass: $0.1.glass,
                            walls: $0.1.walls)
                    }
                    let q = table.posterior(
                        marks: marks, grid: h.grid, halfWidthM: h.halfWidthM, placeRadiusM: h.placeRadiusM,
                        only: held)
                    print(
                        "  \(String(repeating: " ", count: 4)) full:             " + q.summary(standing: ""))
                }
            }
        }
    }
}
