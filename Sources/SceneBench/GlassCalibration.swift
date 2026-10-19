import BlastCore
import Foundation
import simd

/// `scenebench glass-calibrate <district-scene's inputs> [--radius 2500] --runs mass:folder,…
/// [--masses samples.csv] [--geer Facade_damage.shp] [--draws 100] [--inside 0.85] [--out
/// calibration.json]`: how well the façade glass chances (`FacadeLoadSurrogate.glassProbabilities`,
/// docs/glass-probability.md) are calibrated.
///
/// (a) Against the district's own runs at several yields (`district-compare --save-loads`): each
/// building side's chance that some pane breaks, and that it is blown out, drawn over the runs'
/// yields and the surrogate's load scatter (the runs judge every pane at the flaw model's median, so
/// no strength scatter), against the share of the runs in which it did. (b) Against GEER's façade
/// survey (its shapefile): each surveyed façade matched to the side of a map building it lies on
/// and faces as, its chance from the yields of an inferred charge (`infer-charge --samples`), each
/// building's strength and the load scatter, against what the surveyors saw.
enum GlassCalibration {
    struct Bin: Codable {
        var from: Double
        var to: Double
        var count: Int
        var predicted: Double
        var observed: Double
    }

    struct Reliability: Codable {
        var name: String
        var count: Int
        var brier: Double
        /// The Brier score of the mean chance given to every side alike: the skill's reference.
        var climatology: Double
        var bins: [Bin]
    }

    struct Band: Codable {
        var from: Double
        var to: Double
        var facades: Int
        var observed: Double
        var predicted: Double
        var low: Double
        var high: Double
    }

    struct Report: Codable {
        var draws: Int
        var runs: [Reliability]
        var geer: [Reliability]
        var geerBands: [Band]
        var geerMatched: Int?
        var geerSurveyed: Int?
        var seconds: [String: Double]
    }

    static func reliability(_ name: String, predicted: [Double], observed: [Double]) -> Reliability {
        let n = Double(max(predicted.count, 1))
        let brier = zip(predicted, observed).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) } / n
        let mean = observed.reduce(0, +) / n
        let climatology = observed.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / n
        // Deciles, as the protective-design report's test reads them.
        let edges = [0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0001]
        var bins: [Bin] = []
        for (a, b) in zip(edges, edges.dropFirst()) {
            let members = predicted.indices.filter { predicted[$0] >= a && predicted[$0] < b }
            guard !members.isEmpty else { continue }
            let k = Double(members.count)
            bins.append(
                Bin(
                    from: a, to: min(b, 1), count: members.count,
                    predicted: members.reduce(0) { $0 + predicted[$1] } / k,
                    observed: members.reduce(0) { $0 + observed[$1] } / k))
        }
        return Reliability(
            name: name, count: predicted.count, brier: brier, climatology: climatology, bins: bins)
    }

    /// The protective-design report's test (cloud-reports/2026-10-19/protective-design.md, §4,
    /// stage 1): every decile with 200 sides or more within 0.1 of the diagonal.
    static func passes(_ r: Reliability) -> Bool {
        r.bins.filter { $0.count >= 200 }.allSatisfy { abs($0.predicted - $0.observed) <= 0.1 }
    }

    static func show(_ r: Reliability) {
        print(
            String(
                format:
                    "%@: %d sides, Brier %.3f (%.3f giving each the mean), skill %.2f; deciles of 200+ within 0.1: %@",
                r.name as NSString, r.count, r.brier, r.climatology,
                r.climatology > 0 ? 1 - r.brier / r.climatology : 0,
                (passes(r) ? "pass" : "fail") as NSString))
        for b in r.bins {
            print(
                String(
                    format: "    %.2f–%.2f: %6d, predicted %.2f, observed %.2f", b.from, b.to, b.count,
                    b.predicted,
                    b.observed))
        }
    }

    static func seconds(_ start: ContinuousClock.Instant) -> Double { DistrictBenchmark.seconds(start) }

    static func run(_ args: [String]) throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        func value(_ name: String) -> String? { SurrogateBench.value(args, name) }
        guard let runsText = value("runs") else { throw BlastError.allocationFailed("--runs mass:folder,…") }
        let runs = runsText.split(separator: ",").map { part -> (mass: Double, folder: String) in
            let pieces = part.split(separator: ":", maxSplits: 1).map(String.init)
            return (Double(pieces[0]) ?? 0, pieces[1])
        }
        let draws = value("draws").flatMap(Int.init) ?? 100
        let share = Float(value("inside").flatMap(Double.init) ?? 0.85)
        var timings: [String: Double] = [:]

        // (a) The runs: each side's glass in each, from its strips' recorded histories.
        var references: [SurrogateBench.Reference] = []
        for run in runs {
            var a = args
            a += ["--loads", run.folder, "--mass", String(run.mass)]
            references.append(try SurrogateBench.Reference(a))
        }
        let first = references[0]
        let scene = first.scene
        let objects = first.objects
        let charge = scene.charge.position
        let dx = first.cellSize
        let mixes = Dictionary(
            uniqueKeysWithValues: [GlazingMix.olderLowRise, .apartments, .commercial, .industrial].map {
                ($0.name, $0)
            })
        // Strips in every run, inside the fair part, by their building and box (each run's scene is
        // laid out again, its buildings' ids new).
        func id(_ strip: (saved: Int, object: Int, component: EnvelopeComponent)) -> [Int32] {
            [Int32(strip.object)]
                + SurrogateBench.key(strip.component.region, strip.component.axis, strip.component.outward)
        }
        var common = Set(
            first.strips.filter {
                first.inside(FacadeLoadSurrogate.outerFace($0.component).centre, share: share)
            }.map(id))
        for reference in references.dropFirst() { common.formIntersection(reference.strips.map(id)) }
        struct SideKey: Hashable {
            var object: Int
            var axis: Int
            var outward: Int
        }
        var clock = ContinuousClock.now
        var reliabilities: [Reliability] = []
        let raster = first.raster
        // `--skip-runs`: GEER alone, the scene from the first run's inputs.
        if !args.contains("--skip-runs") {
            // Each run's glass by side.
            var runGlass: [[SideKey: FacadeLoadSurrogate.GlassOutcome]] = []
            // Each run's sides' peak net loads, for the openings' fragility.
            var runPeak: [[SideKey: Double]] = []
            for reference in references {
                let mine = reference.strips.filter { common.contains(id($0)) }
                var glass = [FacadeLoadSurrogate.GlassOutcome](repeating: .init(), count: mine.count)
                glass.withUnsafeMutableBufferPointer { out in
                    SurrogateBench.concurrentlyEach(mine.count) { m in
                        let strip = reference.index.strips[mine[m].saved]
                        let mix =
                            mixes[reference.index.buildings[strip.building].mix]
                            ?? scene.envelopeConstruction(for: objects[mine[m].object].id).glazing
                            ?? .apartments
                        out[m] = FacadeLoadSurrogate.glassOutcome(
                            mix, netPa: reference.net(mine[m].saved), binS: strip.binS, areaM2: strip.areaM2)
                    }
                }
                var bySide: [SideKey: FacadeLoadSurrogate.GlassOutcome] = [:]
                var peaks: [SideKey: Double] = [:]
                for (m, strip) in mine.enumerated() {
                    let key = SideKey(
                        object: strip.object, axis: strip.component.axis, outward: strip.component.outward)
                    bySide[key, default: .init()] = bySide[key, default: .init()] + glass[m]
                    peaks[key] = max(peaks[key] ?? 0, reference.net(strip.saved).map(abs).max() ?? 0)
                }
                runGlass.append(bySide)
                runPeak.append(peaks)
            }
            timings["runs' glass"] = seconds(clock)
            print(
                String(
                    format: "Judged %d runs' glass on %d strips in %.0f s", runs.count, common.count,
                    seconds(clock)))

            // The same sides for the surrogate, from the same strips.
            var sideStrips: [SideKey: [(features: FacadeLoadSurrogate.Features, areaM2: Double)]] = [:]
            for strip in first.strips where common.contains(id(strip)) {
                let key = SideKey(
                    object: strip.object, axis: strip.component.axis, outward: strip.component.outward)
                let f = FacadeLoadSurrogate.features(
                    strip.component, owner: strip.object, charge: charge, raster: raster)
                let spans = strip.component.spans
                sideStrips[key, default: []].append((f, Double(spans.x * spans.y)))
            }
            let keys = sideStrips.keys.sorted {
                ($0.object, $0.axis, $0.outward) < ($1.object, $1.axis, $1.outward)
            }
            let sides = keys.compactMap { key -> FacadeLoadSurrogate.GlassSideStrips? in
                guard let mix = scene.envelopeConstruction(for: objects[key.object].id).glazing else {
                    return nil
                }
                return FacadeLoadSurrogate.GlassSideStrips(
                    owner: objects[key.object].id, axis: key.axis, outward: key.outward, mix: mix,
                    strips: sideStrips[key]!)
            }
            let sideKeys = keys.filter {
                scene.envelopeConstruction(for: objects[$0.object].id).glazing != nil
            }
            var observedSome: [Double] = []
            var observedBlown: [Double] = []
            var observedThrown: [Double] = []
            var observedOpenings: [Double] = []
            for key in sideKeys {
                observedOpenings.append(
                    runPeak.reduce(0) {
                        $0 + FacadeLoadSurrogate.OpeningsFragility.chance(peakPa: $1[key] ?? 0)
                    }
                        / Double(runPeak.count))
                let outcomes = runGlass.map { $0[key] ?? .init() }
                observedThrown.append(outcomes.reduce(0) { $0 + $1.worse } / Double(outcomes.count))
                let glasses = outcomes.map(\.glass)
                observedSome.append(glasses.reduce(0) { $0 + $1.anyBroken } / Double(glasses.count))
                observedBlown.append(
                    Double(glasses.filter { $0.fraction >= DistrictGlass.blownOutFraction }.count)
                        / Double(glasses.count))
            }
            let yields = runs.map(\.mass)
            for (name, uncertainty) in [
                (
                    "with the load scatter",
                    FacadeLoadSurrogate.Uncertainty(masses: yields, strengthLogSD: 0, samples: draws)
                ),
                (
                    "without it",
                    FacadeLoadSurrogate.Uncertainty(
                        masses: yields, strengthLogSD: 0, loadScatter: [], samples: draws)
                ),
            ] {
                clock = .now
                let (p, _) = FacadeLoadSurrogate.glassProbabilities(
                    sides: sides, mass: yields[0], cellSize: dx, uncertainty: uncertainty)
                timings["chances, \(name)"] = seconds(clock)
                print(
                    String(
                        format: "Chances of %d sides, %@, %d draws, in %.1f s", sides.count, name, draws,
                        seconds(clock)))
                reliabilities.append(
                    reliability(
                        "runs, some broken, \(name)", predicted: p.map(\.someBroken), observed: observedSome))
                reliabilities.append(
                    reliability(
                        "runs, blown out, \(name)", predicted: p.map(\.blownOut), observed: observedBlown))
                reliabilities.append(
                    reliability(
                        "runs, thrown worse than condition 3b, \(name)", predicted: p.map(\.thrownPast3b),
                        observed: observedThrown))
                reliabilities.append(
                    reliability(
                        "runs, openings blown out (fitted), \(name)", predicted: p.map(\.openingsBlownOut),
                        observed: observedOpenings))
            }
            reliabilities.forEach(show)
        }

        // (b) GEER's façades.
        var geer: [Reliability] = []
        var geerBands: [Band] = []
        var matchedCount: Int?
        var surveyed: Int?
        if let path = value("geer") {
            let masses: [Double] =
                try value("masses").map { file in
                    let lines = try String(contentsOf: URL(filePath: file), encoding: .utf8).split(
                        whereSeparator: \.isNewline)
                    return lines.dropFirst().compactMap { line in
                        line.split(separator: ",").first.flatMap { Double($0) }.map { pow(10, $0) }
                    }
                } ?? [Double(scene.charge.mass)]
            // Every map building's sides with their strips, and where each lies.
            clock = .now
            struct Placed {
                var side: FacadeLoadSurrogate.GlassSideStrips
                var face: Float
                var span: ClosedRange<Float>
            }
            var placed = [[Placed]](repeating: [], count: objects.count)
            placed.withUnsafeMutableBufferPointer { out in
                SurrogateBench.concurrentlyEach(objects.count) { n in
                    guard let mix = scene.envelopeConstruction(for: objects[n].id).glazing,
                        let envelope = objects[n].envelope
                    else { return }
                    let strips = envelope.components(owner: objects[n].id, cellSize: dx)
                        .filter { $0.kind == .facade && FacadeLoadSurrogate.facesAir($0, raster: raster) }
                    for (key, members) in Dictionary(
                        grouping: strips, by: { $0.axis * 2 + ($0.outward > 0 ? 1 : 0) })
                    {
                        let axis = key / 2
                        let along = 1 - axis
                        let face = FacadeLoadSurrogate.outerFace(members[0]).centre[axis]
                        let low = members.map { $0.region.min[along] }.min()!
                        let high = members.map { $0.region.max[along] }.max()!
                        out[n].append(
                            Placed(
                                side: FacadeLoadSurrogate.GlassSideStrips(
                                    owner: objects[n].id, axis: axis, outward: key % 2 == 1 ? 1 : -1,
                                    mix: mix,
                                    strips: members.map {
                                        (
                                            FacadeLoadSurrogate.features(
                                                $0, owner: n, charge: charge, raster: raster),
                                            Double($0.spans.x * $0.spans.y)
                                        )
                                    }), face: face, span: low...high))
                    }
                }
            }
            let all = placed.flatMap { $0 }
            // GEER's façades in the scene's metres, and the side each lies on.
            let url = URL(filePath: path)
            let centres = try ChargeInferenceInputs.readShapeCentres(url)
            let records = try ChargeInferenceInputs.readDBF(
                url.deletingPathExtension().appendingPathExtension("dbf"))
            surveyed = records.count
            let radius = first.radius
            let metresPerDegree = ElevationGrid.metresPerDegree
            let centre = SurrogateBench.centre(args)
            let corner = SIMD2(
                centre.x - Double(radius) / (metresPerDegree * cos(centre.y * .pi / 180)),
                centre.y - Double(radius) / metresPerDegree)
            let placement = MapBuildingPlacement(origin: corner, resolution: dx)
            // A grid of the sides by where they lie, 50 m cells.
            var grid: [SIMD2<Int32>: [Int]] = [:]
            for (n, p) in all.enumerated() {
                let axis = p.side.axis
                for t in stride(from: p.span.lowerBound, through: p.span.upperBound, by: 25) {
                    var point = SIMD2<Float>(repeating: 0)
                    point[axis] = p.face
                    point[1 - axis] = t
                    grid[SIMD2<Int32>((point / 50).rounded(.down)), default: []].append(n)
                }
            }
            var matches: [(side: Int, observedClass: Int, distance: Double, record: Int)] = []
            for (recordIndex, (centreLL, record)) in zip(centres, records).enumerated() {
                guard centreLL.x.isFinite,
                    let level = record["Facade_num"].flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }
                    ),
                    let azimuth = record["Azimuth_N"].flatMap({
                        Double($0.trimmingCharacters(in: .whitespaces))
                    })
                else { continue }
                let at = SIMD2<Float>(placement.position(centreLL))
                let normal = SIMD2<Float>(Float(sin(azimuth * .pi / 180)), Float(cos(azimuth * .pi / 180)))
                let cell = SIMD2<Int32>((at / 50).rounded(.down))
                var best: (Int, Float)?
                for dj in -1...1 {
                    for di in -1...1 {
                        for n in grid[cell &+ SIMD2(Int32(di), Int32(dj))] ?? [] {
                            let p = all[n]
                            var sideNormal = SIMD2<Float>.zero
                            sideNormal[p.side.axis] = Float(p.side.outward)
                            guard simd_dot(sideNormal, normal) > 0.5 else { continue }
                            let along = min(max(at[1 - p.side.axis], p.span.lowerBound), p.span.upperBound)
                            var nearest = SIMD2<Float>.zero
                            nearest[p.side.axis] = p.face
                            nearest[1 - p.side.axis] = along
                            let d = simd_distance(nearest, at)
                            if d < (best?.1 ?? 25) { best = (n, d) }
                        }
                    }
                }
                guard let (n, _) = best else { continue }
                let toCharge = simd_distance(at, SIMD2(charge.x, charge.y))
                matches.append((n, level, Double(toCharge), recordIndex))
            }
            matchedCount = matches.count
            print("GEER: \(matches.count) of \(records.count) façades matched to a side")
            // `--trace file.csv`: each matched façade, what GEER saw, and each run's response of each
            // pane type on each strip of its side, for tracing the glass model against the survey.
            if let tracePath = value("trace") {
                let objectOf = Dictionary(uniqueKeysWithValues: objects.enumerated().map { ($1.id, $0) })
                let stripsOf: [[SideKey: [Int]]] = references.map { reference in
                    var map: [SideKey: [Int]] = [:]
                    for (m, strip) in reference.strips.enumerated() {
                        map[
                            SideKey(
                                object: strip.object, axis: strip.component.axis,
                                outward: strip.component.outward), default: []
                        ].append(m)
                    }
                    return map
                }
                var rowsOut = [String](repeating: "", count: matches.count)
                rowsOut.withUnsafeMutableBufferPointer { out in
                    SurrogateBench.concurrentlyEach(matches.count) { k in
                        let match = matches[k]
                        let side = all[match.side].side
                        guard let object = objectOf[side.owner] else { return }
                        let key = SideKey(object: object, axis: side.axis, outward: side.outward)
                        var lines: [String] = []
                        for (r, reference) in references.enumerated() {
                            for m in stripsOf[r][key] ?? [] {
                                let strip = reference.strips[m]
                                let saved = reference.index.strips[strip.saved]
                                let net = reference.net(strip.saved)
                                let peak = net.map(abs).max() ?? 0
                                let impulse = net.reduce(0) { $0 + max($1, 0) } * saved.binS
                                for (q, pane) in side.mix.panes.enumerated() {
                                    var stress = 0.0
                                    var lost = false
                                    if peak > 50 {
                                        (lost, stress) = GlazingMix.response(
                                            of: pane, netPa: net, binS: saved.binS)
                                    }
                                    let count =
                                        Double(side.mix.glazedFraction * pane.share) * saved.areaM2
                                        / Double(pane.areaM2)
                                    lines.append(
                                        String(
                                            format:
                                                "%d,%d,%.1f,%d,%d,%d,%d,%.3f,%.1f,%.1f,%.1f,%.0f,%d,%.2f,%.2f,%.4f,%.4f,%@",
                                            k, match.observedClass, match.distance, r, m, q, object,
                                            Float(saved.low?.z ?? -1), peak, impulse, saved.areaM2, stress,
                                            lost ? 1 : 0, count, pane.widthM, pane.heightM, pane.thicknessM,
                                            side.mix.name.replacingOccurrences(of: ",", with: ";")))
                                }
                            }
                        }
                        out[k] = lines.joined(separator: "\n")
                    }
                }
                let header =
                    "match,class,distance,run,strip,pane,object,z,peak_pa,impulse_pas,area_m2,stress60_pa,lost,count,width,height,thickness,mix"
                try ([header] + rowsOut.filter { !$0.isEmpty }).joined(separator: "\n").write(
                    toFile: tracePath, atomically: true, encoding: .utf8)
                // The matches' GEER records, in order: what each saw.
                var matchLines = ["match,class,distance,side_axis,side_outward,object,record,damage"]
                for (k, match) in matches.enumerated() {
                    let side = all[match.side].side
                    let damage =
                        records[match.record]["Facade_dam"]?.trimmingCharacters(in: .whitespaces) ?? ""
                    matchLines.append(
                        "\(k),\(match.observedClass),\(match.distance),\(side.axis),\(side.outward),\(objectOf[side.owner] ?? -1),\(match.record),\(damage)"
                    )
                }
                try matchLines.joined(separator: "\n").write(
                    toFile: tracePath + ".matches.csv", atomically: true, encoding: .utf8)
                print("Traced \(matches.count) façades to \(tracePath)")
            }
            let used = Array(Set(matches.map(\.side))).sorted()
            let index = Dictionary(uniqueKeysWithValues: used.enumerated().map { ($1, $0) })
            let (p, kept) = FacadeLoadSurrogate.glassProbabilities(
                sides: used.map { all[$0].side }, mass: Double(scene.charge.mass), cellSize: dx,
                uncertainty: FacadeLoadSurrogate.Uncertainty(
                    masses: masses, strengthMedian: value("strength-median").flatMap(Double.init) ?? 1,
                    strengthLogSD: value("strength-sd").flatMap(Double.init) ?? 0.25, samples: draws),
                keepDraws: true)
            timings["GEER chances"] = seconds(clock)
            print(
                String(format: "Chances of %d sides for GEER's façades in %.1f s", used.count, seconds(clock))
            )
            // Only the openings' state is judged against GEER: its classes are openings (frames and
            // doors with the windows), seen two months on, not glass broken (docs/glass-probability.md).
            let predictedOpenings = matches.map { p[index[$0.side]!].openingsBlownOut }
            geer.append(
                reliability(
                    "GEER, openings W3 (seen two months on), openings blown out (fitted)",
                    predicted: predictedOpenings, observed: matches.map { $0.observedClass >= 3 ? 1 : 0 }))
            geer.forEach(show)
            // By GEER's bands: the share surveyed against the draws' shares.
            print(
                "GEER's bands: façades, observed openings W3 (seen two months on) against openings blown out (predicted mean, 5–95% over draws)"
            )
            for band in DistrictGlass.geer {
                let members = matches.indices.filter {
                    matches[$0].distance >= band.from && matches[$0].distance < band.to
                }
                guard !members.isEmpty, let kept else { continue }
                for (label, observed, outcome) in [
                    (
                        "W3", { (c: Int) in c >= 3 },
                        { (o: FacadeLoadSurrogate.GlassDraw) in Double(o.openingsOut) }
                    )
                ] {
                    let seen =
                        Double(members.filter { observed(matches[$0].observedClass) }.count)
                        / Double(members.count)
                    let shares = (0..<draws).map { k in
                        members.reduce(0.0) { $0 + outcome(kept[index[matches[$1].side]!][k]) }
                            / Double(members.count)
                    }.sorted()
                    let mean = shares.reduce(0, +) / Double(draws)
                    let low = shares[Int(0.05 * Double(draws - 1))]
                    let high = shares[Int((0.95 * Double(draws - 1)).rounded(.up))]
                    geerBands.append(
                        Band(
                            from: band.from, to: band.to, facades: members.count, observed: seen,
                            predicted: mean, low: low,
                            high: high))
                    print(
                        String(
                            format: "  %4.0f–%4.0f m %@  %5d  observed %.2f  predicted %.2f (%.2f–%.2f)%@",
                            band.from,
                            band.to, label as NSString, members.count, seen, mean, low, high,
                            (seen >= low && seen <= high ? "" : "  outside") as NSString))
                }
            }
        }
        let report = Report(
            draws: draws, runs: reliabilities, geer: geer, geerBands: geerBands, geerMatched: matchedCount,
            geerSurveyed: surveyed, seconds: timings)
        if let out = value("out") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: URL(filePath: out))
        }
    }
}
