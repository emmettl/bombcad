import Foundation
import simd

/// `charge-from-damage looks` and `judge-looks` (emmettl/bombcad-work#116, stage 3;
/// docs/charge-inference.md, "Marks that err together"): the network judged through the app's own
/// path, headless. `looks` makes the quick estimate (the full look, as the app's Quick Estimate
/// makes it) for charges drawn over a district and marks its damage as the panel's Mark from the
/// Damage Shown does (`ChargeFromDamage.seen`); `judge-looks` weighs 3, 10, 30 and all of those marks,
/// chosen at random or about the damage as a user would, under one weighing or several, and says how
/// often the 50% and 90% regions and intervals hold the truth and how far off the likeliest place
/// and the yield's median are.
///
/// ```
/// charge-from-damage looks <district's inputs> [--scene-radius 600] [--charges 100] [--seed 3]
///     [--charge-radius 350] [--yields 200,1e6] --name made-mixed-s7 --out looks.json
/// charge-from-damage judge-looks --looks a.json,b.json|--looks-in folder --districts a,b [--weighings independent;yield=0.5,…]
///     [--counts 3,10,30] [--choose random,damage] [--seed 5] [--out judged.json]
/// charge-from-damage survey <district's inputs> [--scene-radius 2500] --survey file-or-folder
///     [--corner lon,lat] [--weighings …] [--hold]
/// ```
///
/// `survey` loads a survey as the panel's Load a Survey does (`ChargeFromDamage.readSurvey`,
/// `match`) onto the district's scene, its corner from the centre unless `--corner` gives it, and
/// weighs it all, its glass alone, its walls alone and its stone walls alone, about the scene's
/// charge (`--hold`: the place held there).
extension ChargeFromDamageStudy {
    struct LookCase: Codable {
        var place: [Double]
        var massKg: Double
        var marks: [ChargeFromDamage.Mark]
        var seconds: Double
    }

    struct LookFile: Codable {
        var district: String
        var reference: [Double]
        var buildings: Int
        var cases: [LookCase]
    }

    static func looks(_ args: [String]) throws {
        let start = ContinuousClock.now
        guard let out = value(args, "out") else { throw BlastError.allocationFailed("--out looks.json") }
        let inputs = try DistrictInputs.read(args)
        let sceneRadius = Float(value(args, "scene-radius").flatMap(Double.init) ?? 600)
        let (scene, _) = try inputs.scene(radius: sceneRadius)
        let dx = inputs.cellSize
        let terms = FacadeLoadSurrogate.TermSet.adopted
        let prepared = FacadeLoadSurrogate.Prepared(
            scene: scene, cellSize: dx, incidence: terms.coefficients.incidence)
        let objects = scene.envelopeObjects
        let buildings = ChargeFromDamage.buildings(scene: scene)
        let index = Dictionary(objects.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        let centre = SIMD2(Double(scene.charge.position.x), Double(scene.charge.position.y))
        let charges = value(args, "charges").flatMap(Int.init) ?? 100
        let radius = value(args, "charge-radius").flatMap(Double.init) ?? 350
        let yields = (value(args, "yields") ?? "200,1e6").split(separator: ",").compactMap { Double($0) }
        let name = value(args, "name") ?? "district"
        print(
            String(
                format: "%@: %d envelope buildings, laid out in %.1f s", name as NSString, objects.count,
                StudyClock.seconds(start)))
        var random = ChargeFromDamage.SplitMix(seed: value(args, "seed").flatMap(UInt64.init) ?? 3)
        var cases: [LookCase] = []
        let uncertainty = FacadeLoadSurrogate.Uncertainty(loadScatter: terms.loadScatter)
        for k in 0..<charges {
            let angle = 2 * Double.pi * random.uniform()
            let r = radius * random.uniform().squareRoot()
            let place = centre + r * SIMD2(cos(angle), sin(angle))
            let mass = exp(log(yields[0]) + random.uniform() * (log(yields[1]) - log(yields[0])))
            var charge = SIMD3(Float(place.x), Float(place.y), 0)
            charge.z = (scene.terrain?.height(at: charge) ?? 0) + 1
            let clock = ContinuousClock.now
            let look = prepared.look(
                charge: charge, mass: mass, constructions: { scene.envelopeConstruction(for: $0) },
                uncertainty: uncertainty, parts: [.damage], terms: terms)
            var marks: [ChargeFromDamage.Mark] = []
            for damage in look.damage {
                guard let n = index[damage.id], buildings[n].footprintM2 > 0 else { continue }
                let (glass, walls) = ChargeFromDamage.seen(damage)
                guard glass != nil || walls != nil else { continue }
                marks.append(ChargeFromDamage.Mark(building: buildings[n], glass: glass, walls: walls))
            }
            let seconds = StudyClock.seconds(clock)
            cases.append(LookCase(place: [place.x, place.y], massKg: mass, marks: marks, seconds: seconds))
            print(
                String(
                    format: "charge %3d: %4.0f m from the middle, %@: %d marks (%d glass broken) in %.1f s",
                    k,
                    r, ChargeFromDamage.Posterior.mass(mass) as NSString, marks.count,
                    marks.filter { $0.glass == .broken }.count, seconds))
        }
        let file = LookFile(
            district: name, reference: [centre.x, centre.y], buildings: objects.count, cases: cases)
        let encoder = JSONEncoder()
        try encoder.encode(file).write(to: URL(filePath: out))
        print(String(format: "Wrote %@ in %.0f s", out as NSString, StudyClock.seconds(start)))
    }

    /// `count` of `marks` chosen as a user would: at random, or about the damage (a focus drawn
    /// among the buildings seen damaged, then the buildings drawn without replacement by
    /// e^(−distance / L), L e^U(ln 100, ln 500) m, as `ChanceTable.drawCase` draws them).
    static func chosen(
        _ marks: [ChargeFromDamage.Mark], count: Int, aboutDamage: Bool,
        _ random: inout ChargeFromDamage.SplitMix
    ) -> [Int] {
        guard count < marks.count else { return Array(marks.indices) }
        var focus = SIMD2<Double>.zero
        var length = 1e9
        if aboutDamage {
            let weights = marks.map { m -> Double in
                (m.glass == .broken ? 1 : 0) + (m.walls == .damaged || m.walls == .heavy ? 1 : 0)
            }
            let total = weights.reduce(0, +)
            var u = random.uniform() * (total > 0 ? total : Double(marks.count))
            for (n, w) in weights.enumerated() {
                u -= total > 0 ? w : 1
                if u <= 0 || n == marks.count - 1 {
                    focus = SIMD2(marks[n].building.east, marks[n].building.north)
                    break
                }
            }
            length = exp(log(100.0) + random.uniform() * (log(500.0) - log(100.0)))
        }
        let keys = marks.indices.map { n -> (Double, Int) in
            let d = simd_distance(SIMD2(marks[n].building.east, marks[n].building.north), focus)
            let weight = aboutDamage ? exp(-d / length) : 1
            return (weight > 0 ? -log(max(random.uniform(), 1e-300)) / weight : .infinity, n)
        }
        return keys.sorted { $0.0 < $1.0 }.prefix(count).map(\.1)
    }

    static func judgeLooks(_ args: [String]) throws {
        let start = ContinuousClock.now
        // `--looks a.json,b.json`, or `--looks-in folder --districts a,b` (each `folder/a/looks.json`).
        let paths =
            value(args, "looks")?.split(separator: ",").map(String.init)
            ?? value(args, "looks-in").map { folder in
                (value(args, "districts") ?? "").split(separator: ",").map { "\(folder)/\($0)/looks.json" }
            }
        guard let paths, !paths.isEmpty else {
            throw BlastError.allocationFailed("--looks a.json,b.json, or --looks-in folder --districts a,b")
        }
        let network = try ChargeFromDamage.Network.named(value(args, "weights"))
        let weighings = try (value(args, "weighings") ?? "independent").split(separator: ";").map {
            guard let w = ChargeFromDamage.Weighing.named(String($0)) else {
                throw BlastError.allocationFailed("no weighing \($0)")
            }
            return w
        }
        let counts = (value(args, "counts") ?? "3,10,30").split(separator: ",").compactMap { Int($0) } + [-1]
        let choices = (value(args, "choose") ?? "random,damage").split(separator: ",").map { $0 == "damage" }
        let seed = value(args, "seed").flatMap(UInt64.init) ?? 5
        let limit = value(args, "cases").flatMap(Int.init)
        var report: [[String: Any]] = []
        // Each weighing's judgement of each count, pooled over the files.
        var pooled: [String: [Judged]] = [:]
        for path in paths {
            var file = try JSONDecoder().decode(LookFile.self, from: Data(contentsOf: URL(filePath: path)))
            if let limit { file.cases = Array(file.cases.prefix(limit)) }
            let reference = SIMD2(file.reference[0], file.reference[1])
            print("\n\(file.district): \(file.cases.count) charges, \(file.buildings) buildings")
            // Each case's subsets once, the same for every weighing.
            var subsets: [(choice: Bool, count: Int, picks: [[Int]])] = []
            for aboutDamage in choices {
                for count in counts {
                    var random = ChargeFromDamage.SplitMix(
                        seed: seed &* 1_000_003 &+ UInt64(max(count, 0)) &+ (aboutDamage ? 77 : 0))
                    let picks = file.cases.map {
                        chosen($0.marks, count: count < 0 ? .max : count, aboutDamage: aboutDamage, &random)
                    }
                    if count < 0 && aboutDamage { continue }  // all marks: one set, however chosen
                    subsets.append((aboutDamage, count, picks))
                }
            }
            // judged[subset][weighing][case]
            var judged = [[[Judged?]]](
                repeating: [[Judged?]](
                    repeating: [Judged?](repeating: nil, count: file.cases.count), count: weighings.count),
                count: subsets.count)
            let cases = file.cases
            judged.withUnsafeMutableBufferPointer { out in
                let lock = NSLock()
                concurrently(iterations: cases.count) { n in
                    let c = cases[n]
                    let truth = SIMD2(c.place[0], c.place[1])
                    let places = c.marks.map { SIMD2($0.building.east, $0.building.north) }
                    for (s, subset) in subsets.enumerated() {
                        let picks = subset.picks[n]
                        guard !picks.isEmpty else { continue }
                        // The sums by the neighbours' weighing they take.
                        var sums: [String: ([Float], Double)] = [:]
                        for (k, w) in weighings.enumerated() {
                            let key = "\(w.neighbourLengthM),\(w.neighbourPower)"
                            if sums[key] == nil {
                                let weights = w.weights(picks.map { places[$0] })
                                let bins = network.header.yieldBins ?? 1
                                var joint = [Float](
                                    repeating: 0, count: network.header.grid * network.header.grid * bins)
                                for (p, weight) in zip(picks, weights) {
                                    network.addDistance(
                                        c.marks[p], reference: reference, to: &joint, weight: Float(weight))
                                }
                                for cell in 0..<(network.header.grid * network.header.grid)
                                where !network.inDisc[cell] {
                                    for b in 0..<bins { joint[cell * bins + b] = -.infinity }
                                }
                                sums[key] = (joint, weights.reduce(0, +))
                            }
                            let (joint, total) = sums[key]!
                            let p = network.posterior(
                                joint: joint, reference: reference, scale: w.sharedScale(count: total),
                                weighing: w)
                            let j = Judged(p, place: truth, logMass: log(c.massKg))
                            lock.lock()
                            out[s][k][n] = j
                            lock.unlock()
                        }
                    }
                }
            }
            for (s, subset) in subsets.enumerated() {
                let label =
                    subset.count < 0
                    ? "all" : "\(subset.count) \(subset.choice ? "about the damage" : "at random")"
                print("  \(label):")
                for (k, w) in weighings.enumerated() {
                    let list = judged[s][k].compactMap { $0 }
                    pooled["\(w.name)|\(label)", default: []] += list
                    let line = Self.coverageLine(list)
                    print("    \(w.name.padding(toLength: 44, withPad: " ", startingAt: 0)) \(line)")
                    report.append(
                        Self.coverageRow(list, district: file.district, label: label, weighing: w.name))
                }
            }
        }
        if paths.count > 1 {
            print("\nAll districts together:")
            let labels = Set(pooled.keys.map { String($0.split(separator: "|")[1]) }).sorted()
            for label in labels {
                print("  \(label):")
                var scored: [(Double, String)] = []
                for w in weighings {
                    let list = pooled["\(w.name)|\(label)"] ?? []
                    print(
                        "    \(w.name.padding(toLength: 44, withPad: " ", startingAt: 0)) \(Self.coverageLine(list))"
                    )
                    report.append(Self.coverageRow(list, district: "all", label: label, weighing: w.name))
                    scored.append((0, w.name))
                }
            }
            // Each weighing's calibration over every count and choice: the coverages' root mean
            // square miss from their nominal shares.
            print(
                "\nCalibration, root mean square of each coverage's miss from 0.5 and 0.9, over every subset:"
            )
            var ranked: [(Double, String)] = []
            for w in weighings {
                var misses: [Double] = []
                for label in labels {
                    let list = pooled["\(w.name)|\(label)"] ?? []
                    guard !list.isEmpty else { continue }
                    misses += [
                        share(list.map(\.placeIn50)) - 0.5, share(list.map(\.placeIn90)) - 0.9,
                        share(list.map(\.yieldIn50)) - 0.5, share(list.map(\.yieldIn90)) - 0.9,
                    ]
                }
                ranked.append(
                    (
                        (misses.map { $0 * $0 }.reduce(0, +) / Double(max(misses.count, 1))).squareRoot(),
                        w.name
                    ))
            }
            for (score, name) in ranked.sorted(by: { $0.0 < $1.0 }) {
                print(String(format: "    %.3f  %@", score, name as NSString))
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

    static func survey(_ args: [String]) throws {
        let start = ContinuousClock.now
        guard let path = value(args, "survey") else {
            throw BlastError.allocationFailed("--survey file-or-folder")
        }
        let inputs = try DistrictInputs.read(args)
        let radius = value(args, "scene-radius").flatMap(Double.init) ?? 2500
        let (scene, _) = try inputs.scene(radius: Float(radius))
        let centre = inputs.centre
        let corner =
            value(args, "corner").map { $0.split(separator: ",").compactMap { Double($0) } }.flatMap {
                $0.count == 2 ? SIMD2($0[0], $0[1]) : nil
            }
            ?? SIMD2(
                centre.x - radius / (ElevationGrid.metresPerDegree * cos(centre.y * .pi / 180)),
                centre.y - radius / ElevationGrid.metresPerDegree)
        let objects = scene.envelopeObjects
        let buildings = ChargeFromDamage.buildings(scene: scene)
        let footprints = objects.map { object in
            (object.envelope?.blocks ?? []).map {
                (
                    low: SIMD2(Double($0.min.x), Double($0.min.y)),
                    high: SIMD2(Double($0.max.x), Double($0.max.y))
                )
            }
        }
        let charge = SIMD2(Double(scene.charge.position.x), Double(scene.charge.position.y))
        let survey = try ChargeFromDamage.readSurvey(URL(filePath: path), corner: corner, charge: charge)
        let match = ChargeFromDamage.match(survey, footprints: footprints)
        print(
            String(
                format: "%d envelope buildings in %.0f s; the corner %.6f, %.6f", objects.count,
                StudyClock.seconds(start), corner.x, corner.y))
        print(
            "Survey: \(survey.parts.joined(separator: ", ")); \(match.matched) of \(survey.entries.count) entries matched, on \(match.marks.count) buildings; \(match.unmatched) unmatched; \(survey.skipped) records left out; \(match.repeated) walls repeated"
        )
        var marks: [ChargeFromDamage.Mark] = []
        for (n, seen) in match.marks.sorted(by: { $0.key < $1.key }) where buildings[n].footprintM2 > 0 {
            var building = buildings[n]
            if seen.masonry { building.walls = .masonry }
            marks.append(ChargeFromDamage.Mark(building: building, glass: seen.glass, walls: seen.walls))
        }
        let network = try ChargeFromDamage.Network.named(value(args, "weights"))
        let h = network.header
        let held: Set<Int>? =
            args.contains("--hold")
            ? Set(
                (0..<(h.grid * h.grid)).filter {
                    let m = ChargeFromDamage.Network.cellMiddle($0, grid: h.grid, halfWidthM: h.halfWidthM)
                    return max(abs(m.x), abs(m.y)) < 2 * h.halfWidthM / Double(h.grid)
                }) : nil
        if held != nil { print("The place held at the scene's charge (the four cells round it)") }
        let weighings = try
            (value(args, "weighings") ?? "independent;\(ChargeFromDamage.Weighing.adopted.name)")
            .split(separator: ";").map {
                guard let w = ChargeFromDamage.Weighing.named(String($0)) else {
                    throw BlastError.allocationFailed("no weighing \($0)")
                }
                return w
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
                "stone walls alone",
                {
                    $0.walls == nil || $0.building.walls != .masonry
                        ? nil : ChargeFromDamage.Mark(building: $0.building, walls: $0.walls)
                }
            ),
        ]
        for (label, keep) in kinds {
            let some = marks.compactMap(keep)
            guard !some.isEmpty else { continue }
            print("\n\(label): \(some.count) marks")
            for w in weighings {
                let clock = ContinuousClock.now
                let p = network.posterior(marks: some, reference: charge, weighing: w, only: held)
                let off = p.mostProbablePlace - charge
                print(
                    String(
                        format:
                            "  %@ (%.0f ms): yield %@ (50%%: %@–%@; 90%%: %@–%@); likeliest %.0f m from the scene's charge (%.0f m east, %.0f m north); the charge in the 50%% region %@, the 90%% %@; 90%% region %.0f m in radius",
                        w.name as NSString, 1000 * StudyClock.seconds(clock),
                        ChargeFromDamage.Posterior.mass(p.yieldQuantile(0.5)) as NSString,
                        ChargeFromDamage.Posterior.mass(p.yieldQuantile(0.25)) as NSString,
                        ChargeFromDamage.Posterior.mass(p.yieldQuantile(0.75)) as NSString,
                        ChargeFromDamage.Posterior.mass(p.yieldQuantile(0.05)) as NSString,
                        ChargeFromDamage.Posterior.mass(p.yieldQuantile(0.95)) as NSString, simd_length(off),
                        off.x,
                        off.y, (p.regionHolds(charge, mass: 0.5) ? "yes" : "no") as NSString,
                        (p.regionHolds(charge, mass: 0.9) ? "yes" : "no") as NSString, p.regionRadius(0.9)))
            }
        }
    }

    static func quantile(_ v: [Double], _ q: Double) -> Double {
        let s = v.sorted()
        return s.isEmpty ? .nan : s[min(Int(q * Double(s.count)), s.count - 1)]
    }

    static func coverageLine(_ list: [Judged]) -> String {
        String(
            format:
                "place in 50%% %.2f, 90%% %.2f; yield in 50%% %.2f, 90%% %.2f; off %4.0f m (90th %4.0f), ×%.2f (90th ×%.2f); 90%% yield hi/lo %.1f, place radius %.0f m; %d",
            share(list.map(\.placeIn50)), share(list.map(\.placeIn90)), share(list.map(\.yieldIn50)),
            share(list.map(\.yieldIn90)), quantile(list.map(\.likeliestOff), 0.5),
            quantile(list.map(\.likeliestOff), 0.9), quantile(list.map(\.yieldFactor), 0.5),
            quantile(list.map(\.yieldFactor), 0.9), quantile(list.map(\.yieldWidth90), 0.5),
            quantile(list.map(\.placeRadius90), 0.5), list.count)
    }

    static func coverageRow(_ list: [Judged], district: String, label: String, weighing: String) -> [String:
        Any]
    {
        [
            "district": district, "marks": label, "weighing": weighing, "cases": list.count,
            "placeIn50": share(list.map(\.placeIn50)), "placeIn90": share(list.map(\.placeIn90)),
            "yieldIn50": share(list.map(\.yieldIn50)), "yieldIn90": share(list.map(\.yieldIn90)),
            "medianLikeliestOffM": quantile(list.map(\.likeliestOff), 0.5),
            "likeliestOff90M": quantile(list.map(\.likeliestOff), 0.9),
            "medianYieldFactor": quantile(list.map(\.yieldFactor), 0.5),
            "yieldFactor90": quantile(list.map(\.yieldFactor), 0.9),
            "medianYieldWidth90": quantile(list.map(\.yieldWidth90), 0.5),
            "medianPlaceRadius90M": quantile(list.map(\.placeRadius90), 0.5),
        ]
    }
}
