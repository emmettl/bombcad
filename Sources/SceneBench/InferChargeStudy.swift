import BlastCore
import Foundation
import Metal

/// `scenebench infer-charge-study`: how well `ChargeInference` finds known charges.
///
/// ```
/// scenebench infer-charge-study --synthetic 200 [--spread 0.05] [--frame 0.0333] [--observers 25]
///     [--grid-checks 6] [--misses]
/// scenebench infer-charge-study --forward [--fixture Fixtures/SyntheticDistrict] [--dx 2] [--frame 0.00833] [--passes 3]
/// ```
///
/// `--synthetic N`: N charges of random mass (100 kg to 1 kt) and place (within 300 m of the
/// reference), seen by observers at random scaled distances (5 to 40 m/kg^(1/3)) whose arrivals are
/// Kingery–Bulmash's off by a normal fraction `--spread` and rounded up to a video frame: the share
/// of charges whose mass and place fall inside the posterior's 68% and 90% intervals, which a
/// calibrated inference gives as 68% and 90%. Its model is the data's own, so it checks the
/// inference, not the model.
///
/// `--forward`: charges on the made-up New District (Fixtures/SyntheticDistrict), run by BombCAD
/// with the recommended air on `--dx` cells, observers 2 m above the ground in its streets and
/// yards, each arrival (500 Pa above the first sample) rounded up to a frame; then inferred by
/// Kingery–Bulmash alone, as for an event where nothing is known of the charge. Its model is not the
/// data's: the buildings, the ground and the grid each move the arrivals.
enum InferChargeStudy {
    static func run(_ args: [String]) throws {
        func value(_ name: String) -> String? {
            args.firstIndex(of: "--" + name).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        if let count = value("synthetic").flatMap(Int.init) {
            synthetic(
                count: count, spread: value("spread").flatMap(Double.init) ?? 0.05,
                frame: value("frame").flatMap(Double.init) ?? 1.0 / 30,
                observers: value("observers").flatMap(Int.init) ?? 25,
                gridChecks: value("grid-checks").flatMap(Int.init) ?? 0, showMisses: args.contains("--misses")
            )
        }
        sideLoad = value("side-load") ?? "glass"
        if args.contains("--forward-damage") {
            try forwardDamage(
                fixture: URL(filePath: value("fixture") ?? "Fixtures/SyntheticDistrict"),
                cellSize: Float(value("dx").flatMap(Double.init) ?? 4),
                frame: value("frame").flatMap(Double.init) ?? 1.0 / 120,
                only: value("charges").map { $0.split(separator: ",").compactMap { Int($0) } },
                passes: value("passes").flatMap(Int.init) ?? 0)
            return
        }
        if args.contains("--damage-probe") {
            try damageProbe(
                fixture: URL(filePath: value("fixture") ?? "Fixtures/SyntheticDistrict"),
                cellSize: Float(value("dx").flatMap(Double.init) ?? 2),
                spacing: value("spacing").flatMap(Double.init) ?? 20)
            return
        }
        if args.contains("--forward") {
            try forward(
                fixture: URL(filePath: value("fixture") ?? "Fixtures/SyntheticDistrict"),
                cellSize: Float(value("dx").flatMap(Double.init) ?? 2),
                frame: value("frame").flatMap(Double.init) ?? 1.0 / 120,
                passes: value("passes").flatMap(Int.init) ?? 3)
        }
    }

    /// Whether `truth` lies in the posterior's intervals of parameter `name`: (68%, 90%).
    static func covered(_ posterior: ChargeInference.Posterior, _ name: String, _ truth: Double) -> (
        Bool, Bool
    ) {
        guard let s = posterior.summary(name) else { return (false, false) }
        return ((s.p16...s.p84).contains(truth), (s.p05...s.p95).contains(truth))
    }

    static func synthetic(
        count: Int, spread: Double, frame: Double, observers: Int, gridChecks: Int = 0,
        showMisses: Bool = false
    ) {
        var random = SplitMixGenerator(seed: 2026)
        var settings = ChargeInference.Settings()
        settings.massRange = 10...1e7
        settings.placeRadius = 600
        settings.steps = 1500
        settings.walkers = 32
        var massIn = (0, 0)
        var placeIn = (0, 0)
        var ratios: [Double] = []
        var misses: [Double] = []
        print("Synthetic: \(count) charges, \(observers) observers each, spread \(spread), frame \(frame) s")
        for trial in 0..<count {
            let mass = pow(10, Double.random(in: 2...6, using: &random))
            let r = 300 * Double.random(in: 0...1, using: &random).squareRoot()
            let angle = Double.random(in: 0..<(2 * Double.pi), using: &random)
            let east = r * cos(angle)
            let north = r * sin(angle)
            let places = (0..<observers).map { _ -> SIMD2<Double> in
                let range = Double.random(in: 5...40, using: &random) * cbrt(mass)
                let a = Double.random(in: 0..<(2 * Double.pi), using: &random)
                return SIMD2(east + range * cos(a), north + range * sin(a))
            }
            let arrivals = ChargeInference.syntheticArrivals(
                massKg: mass, east: east, north: north, places: places, spread: spread, frame: frame,
                seed: UInt64(trial + 1))
            settings.seed = UInt64(trial + 1)
            let posterior = ChargeInference.infer(arrivals: arrivals, settings: settings)
            let m = covered(posterior, "log10MassKg", log10(mass))
            massIn.0 += m.0 ? 1 : 0
            massIn.1 += m.1 ? 1 : 0
            placeIn.0 +=
                posterior.placeShare(within: posterior.placeRadius(holding: 0.68), ofEast: east, north: north)
                    > 0 && distanceFromMedian(posterior, east, north) <= posterior.placeRadius(holding: 0.68)
                ? 1 : 0
            placeIn.1 +=
                distanceFromMedian(posterior, east, north) <= posterior.placeRadius(holding: 0.9) ? 1 : 0
            if !m.1, showMisses {
                let s = posterior.summary("log10MassKg")!
                print(
                    String(
                        format:
                            "    miss: %.0f kg at %.0f m; found %.0f (90%%: %.0f–%.0f), spread %.3f, R-hat %.3f, acceptance %.2f, place off %.0f m",
                        mass, r, pow(10, s.median), pow(10, s.p05), pow(10, s.p95),
                        exp(posterior.summary("logSpread")!.median), posterior.rHat, posterior.acceptance,
                        distanceFromMedian(posterior, east, north)))
                let me = posterior.summary("east")!.median
                let mn = posterior.summary("north")!.median
                print(
                    String(
                        format: "      log likelihood at the truth %.1f, at the found %.1f",
                        ChargeInference.arrivalLogLikelihood(
                            massKg: mass, east: east, north: north, spread: spread, arrivals: arrivals,
                            settings: settings),
                        ChargeInference.arrivalLogLikelihood(
                            massKg: pow(10, s.median), east: me, north: mn,
                            spread: exp(posterior.summary("logSpread")!.median), arrivals: arrivals,
                            settings: settings)))
                if mass > 1e5 {
                    for a in arrivals.prefix(5) {
                        let r1 = hypot(a.east - east, a.north - north)
                        let r2 = hypot(a.east - me, a.north - mn)
                        print(
                            String(
                                format: "      %.0f m: window %.3f–%.3f, truth %.3f, found %.3f", r1,
                                a.earliest,
                                a.latest, ChargeInference.arrival(massKg: mass, range: r1),
                                ChargeInference.arrival(massKg: pow(10, s.median), range: r2)))
                    }
                }
            }
            if trial < gridChecks {
                // The marginal of log mass on a grid about the samples (±5 of their 68% half-widths),
                // against the sampler's quantiles.
                let s = posterior.summary("log10MassKg")!
                let e = posterior.summary("east")!
                let nn = posterior.summary("north")!
                let sp = posterior.summary("logSpread")!
                func axis(_ q: ChargeInference.Summary, _ count: Int) -> [Double] {
                    let half = max(q.p84 - q.p16, 1e-3) / 2
                    return (0..<count).map {
                        q.median - 5 * half + 10 * half * Double($0) / Double(count - 1)
                    }
                }
                let ms = axis(s, 81)
                let es = axis(e, 41)
                let ns = axis(nn, 41)
                let ss = axis(sp, 21)
                var marginal = [Double](repeating: 0, count: ms.count)
                var peak = -Double.infinity
                var logs: [Double] = []
                logs.reserveCapacity(ms.count * es.count * ns.count * ss.count)
                for m in ms {
                    for x in es {
                        for y in ns {
                            for z in ss {
                                logs.append(
                                    hypot(x, y) <= settings.placeRadius
                                        && settings.spreadRange.contains(exp(z))
                                        ? ChargeInference.arrivalLogLikelihood(
                                            massKg: pow(10, m), east: x, north: y, spread: exp(z),
                                            arrivals: arrivals,
                                            settings: settings) : -.infinity)
                            }
                        }
                    }
                }
                peak = logs.max() ?? 0
                for i in 0..<ms.count {
                    let block = logs[
                        (i * es.count * ns.count * ss.count)..<((i + 1) * es.count * ns.count * ss.count)]
                    marginal[i] = block.reduce(0) { $0 + exp($1 - peak) }
                }
                let total = marginal.reduce(0, +)
                var running = 0.0
                var quantiles: [Double] = []
                var targets = [0.05, 0.16, 0.5, 0.84, 0.95]
                for i in 0..<ms.count {
                    running += marginal[i] / total
                    while let t = targets.first, running >= t {
                        quantiles.append(ms[i])
                        targets.removeFirst()
                    }
                }
                print(
                    String(
                        format:
                            "    grid check %d: log10 mass, sampler 5/16/50/84/95%% %.3f %.3f %.3f %.3f %.3f; grid %@; truth %.3f",
                        trial, s.p05, s.p16, s.median, s.p84, s.p95,
                        quantiles.map { String(format: "%.3f", $0) }.joined(separator: " "), log10(mass)))
            }
            ratios.append(pow(10, posterior.summary("log10MassKg")!.median) / mass)
            misses.append(distanceFromMedian(posterior, east, north) / cbrt(mass))
        }
        ratios.sort()
        misses.sort()
        print(
            String(
                format:
                    "  mass inside 68%%: %.2f, inside 90%%: %.2f; place inside 68%%: %.2f, inside 90%%: %.2f",
                Double(massIn.0) / Double(count), Double(massIn.1) / Double(count),
                Double(placeIn.0) / Double(count),
                Double(placeIn.1) / Double(count)))
        print(
            String(
                format:
                    "  median mass found / true: %.3f (10%%–90%%: %.3f–%.3f); place off by %.2f m/kg^(1/3) (90%%: %.2f)",
                ratios[count / 2], ratios[count / 10], ratios[9 * count / 10], misses[count / 2],
                misses[9 * count / 10]))
    }

    static func distanceFromMedian(_ posterior: ChargeInference.Posterior, _ east: Double, _ north: Double)
        -> Double
    {
        hypot(
            (posterior.summary("east")?.median ?? 0) - east, (posterior.summary("north")?.median ?? 0) - north
        )
    }

    /// The charges run: TNT mass (kg) and place in the fixture's metres (east, north of 0° 0°), each
    /// in a street or yard (the blocks are 24 × 16 m on a 100 m grid).
    static let charges: [(mass: Float, east: Double, north: Double)] = [
        (500, 650, 650), (2_000, 455, 705), (5_000, 700, 450), (1_000, 560, 380),
    ]

    /// The made-up district, ready to lay a charge on.
    struct District {
        var buildings: [MapBuilding]
        var heights: ElevationGrid
        var ground: ElevationGrid
        var device: MTLDevice
        var cellSize: Float
        var reach: Float = 350

        /// BombCAD's arrival (500 Pa above the first sample, s) at each of `observers` (the fixture's
        /// metres) from `mass` kg of TNT at (`east`, `north`), with the recommended air; nil where the
        /// shock did not come.
        func arrivals(mass: Float, east: Double, north: Double, observers: [SIMD2<Double>]) throws
            -> [Double?]
        {
            let metres = ElevationGrid.metresPerDegree
            var layout = DistrictLayout(
                buildings: buildings, charge: SIMD2(east / metres, north / metres), mass: mass)
            layout.heights = heights
            layout.ground = DistrictLayout.ground(ground, openingM: 0, seaM: 1)
            let half = layout.halfSide(radius: reach, cellSize: cellSize)
            var (scene, _) = try layout.scene(halfSide: half, cellSize: cellSize)
            let positions = observers.map { SIMD2(Float($0.x - east) + half, Float($0.y - north) + half) }
            let inside = positions.indices.filter { k in
                positions[k].x > cellSize && positions[k].y > cellSize && positions[k].x < 2 * half - cellSize
                    && positions[k].y < 2 * half - cellSize
            }
            scene.gauges = inside.prefix(BlastSolver.maxGauges).map { k in
                let p = positions[k]
                return Gauge("o\(k)", at: SIMD3(p.x, p.y, (scene.terrain?.height(at: p) ?? 0) + 2))
            }
            let solver = try BlastSolver(
                device: device, scenario: scene, cellSize: cellSize, configuration: .recommended)
            let points = scene.gauges.map(\.position)
            let cells = points.map { p -> (i: Int, j: Int, k: Int) in
                let i = Int(p.x / cellSize)
                let j = Int(p.y / cellSize)
                var k = Int(p.z / cellSize)
                while k < solver.grid.nz - 1, solver.isSolid(i, j, k) { k += 1 }
                return (i, j, k)
            }
            solver.setGauges(cells: cells, points: points)
            let farthest = observers.map { hypot($0.x - east, $0.y - north) }.max() ?? Double(reach)
            let until = farthest / 300 + 0.05
            while solver.time < until {
                let batch = solver.advance(until: until)
                guard batch.steps > 0, batch.isStable else { break }
            }
            var result = [Double?](repeating: nil, count: observers.count)
            for (slot, k) in inside.prefix(BlastSolver.maxGauges).enumerated() {
                let samples = solver.gaugeHistories[slot]
                guard let first = samples.first?.pressure else { continue }
                result[k] = samples.first(where: { $0.pressure - first > 500 })?.time
            }
            return result
        }
    }

    /// One line of the forward study: the found mass and place against the truth.
    static func line(
        _ label: String, _ posterior: ChargeInference.Posterior,
        truth: (mass: Float, east: Double, north: Double)
    ) -> String {
        let mass = posterior.summary("log10MassKg")!
        let hit = covered(posterior, "log10MassKg", log10(Double(truth.mass)))
        return String(
            format:
                "    %@: %.0f kg (90%%: %.0f–%.0f; truth inside 68%%/90%%: %@/%@), place off %.1f m (90%% radius %.1f m), spread %.1f%%",
            label, pow(10, mass.median), pow(10, mass.p05), pow(10, mass.p95), hit.0 ? "yes" : "no",
            hit.1 ? "yes" : "no",
            distanceFromMedian(posterior, truth.east, truth.north), posterior.placeRadius(holding: 0.9),
            100 * exp(posterior.summary("logSpread")!.median))
    }

    /// `--damage-probe`: the surrogate's own glass damage (each side drawn from its chance) from
    /// each of `charges`, scored back by `ChargeInference.SurrogateDamage` over masses at the true
    /// place and places at the true mass: where its likelihood peaks, and what an evaluation costs.
    static func damageProbe(fixture: URL, cellSize: Float, spacing: Double) throws {
        let buildings = try MapBuilding.read(contentsOf: fixture.appending(path: "district.osm"))
        let metres = ElevationGrid.metresPerDegree
        let reference = SIMD2(600.0, 600.0)
        var layout = DistrictLayout(
            buildings: buildings, charge: SIMD2(reference.x / metres, reference.y / metres), mass: 1000)
        layout.heights = try ElevationGrid(contentsOf: fixture.appending(path: "heights.asc"))
        layout.ground = DistrictLayout.ground(
            try ElevationGrid(contentsOf: fixture.appending(path: "ground.asc")), openingM: 0, seaM: 1)
        let half = layout.halfSide(radius: 500, cellSize: cellSize)
        let (scene, _) = try layout.scene(halfSide: half, cellSize: cellSize)
        let centre = SIMD2<Float>(half, half)
        let everySide = scene.envelopeObjects.flatMap { object in
            [(0, -1), (0, 1), (1, -1), (1, 1)].map {
                (owner: object.id, axis: $0.0, outward: $0.1, damaged: false)
            }
        }
        let probe = ChargeInference.SurrogateDamage(
            scene: scene, observed: everySide, reference: centre, placeRadius: 300, spacing: spacing,
            cellSize: cellSize)
        print(
            String(
                format: "%d sides, grid %.0f m: features and tables in %.1f s", probe.sides.count, spacing,
                probe.seconds))
        var generator = SplitMixGenerator(seed: 11)
        for charge in charges {
            let east = charge.east - reference.x
            let north = charge.north - reference.y
            let chances = probe.chances(massKg: Double(charge.mass), east: east, north: north)
            let observed = zip(probe.sides, chances).map { side, p in
                (
                    owner: scene.envelopeObjects[side.owner].id, axis: side.axis, outward: side.outward,
                    damaged: Double.random(in: 0..<1, using: &generator) < p
                )
            }
            let damage = ChargeInference.SurrogateDamage(
                scene: scene, observed: observed, reference: centre, placeRadius: 300, spacing: spacing,
                cellSize: cellSize)
            let start = ContinuousClock.now
            let masses = stride(from: -1.0, through: 1.0, by: 0.1).map {
                Double(charge.mass) * pow(10, $0 * 0.7)
            }
            let perSide = CommandLine.arguments.contains("--per-side")
            let byMass = masses.map {
                (
                    mass: $0,
                    value: damage.logLikelihood(massKg: $0, east: east, north: north, perSide: perSide)
                )
            }
            let perEvaluation = DistrictBenchmark.seconds(start) / Double(masses.count)
            var best = (east: east, north: north, value: -Double.infinity)
            for dx in stride(from: -150.0, through: 150.0, by: 10) {
                for dy in stride(from: -150.0, through: 150.0, by: 10) {
                    let value = damage.logLikelihood(
                        massKg: Double(charge.mass), east: east + dx, north: north + dy, perSide: perSide)
                    if value > best.value { best = (east + dx, north + dy, value) }
                }
            }
            let peak = byMass.max { $0.value < $1.value }!
            print(
                String(
                    format:
                        "  %.0f kg at (%.0f, %.0f): %d of %d sides broken; best mass %.0f kg (%.2f of the truth); best place off %.0f m; %.2f ms an evaluation",
                    charge.mass, charge.east, charge.north, observed.filter(\.damaged).count, observed.count,
                    peak.mass, peak.mass / Double(charge.mass), hypot(best.east - east, best.north - north),
                    1000 * perEvaluation))
        }
    }

    /// `--forward-damage`: each of `charges` run by BombCAD on the made-up district, its arrivals
    /// at the observers and its glass broken building side by building side; the charge then
    /// inferred from the glass alone (the scene's own surrogate as the forward model,
    /// `ChargeInference.SurrogateDamage`), from the arrivals alone (Kingery–Bulmash), and from both.
    static func forwardDamage(fixture: URL, cellSize: Float, frame: Double, only: [Int]?, passes: Int) throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { throw BlastError.allocationFailed("Metal") }
        let buildings = try MapBuilding.read(contentsOf: fixture.appending(path: "district.osm"))
        let heights = try ElevationGrid(contentsOf: fixture.appending(path: "heights.asc"))
        let ground = try ElevationGrid(contentsOf: fixture.appending(path: "ground.asc"))
        let district = District(
            buildings: buildings, heights: heights, ground: ground, device: device, cellSize: cellSize)
        // The scene the glass is weighed on: the district about its centre, which no charge moves.
        let metres = ElevationGrid.metresPerDegree
        let reference = SIMD2(600.0, 600.0)
        var layout = DistrictLayout(
            buildings: buildings, charge: SIMD2(reference.x / metres, reference.y / metres), mass: 1000)
        layout.heights = heights
        layout.ground = DistrictLayout.ground(ground, openingM: 0, seaM: 1)
        let half = layout.halfSide(radius: 500, cellSize: cellSize)
        let (scene, _) = try layout.scene(halfSide: half, cellSize: cellSize)
        let byName = Dictionary(grouping: scene.envelopeObjects, by: \.name).compactMapValues {
            $0.count == 1 ? $0[0].id : nil
        }
        var generator = SplitMixGenerator(seed: 7)
        let scatter = (0..<400).map { _ in
            SIMD2(
                Double.random(in: 150...1050, using: &generator),
                Double.random(in: 150...1050, using: &generator))
        }
        var settings = ChargeInference.Settings()
        settings.massRange = 10...1e6
        settings.placeRadius = 300
        print("Forward with damage: the New District, \(cellSize) m cells, frame \(frame) s")
        for (n, charge) in charges.enumerated() where only?.contains(n) ?? true {
            let start = ContinuousClock.now
            let observers = Array(
                scatter.filter { p in
                    let d = hypot(p.x - charge.east, p.y - charge.north)
                    return d >= 40 && d <= Double(district.reach)
                }.prefix(40))
            let (times, glass, _) = try district.run(
                mass: charge.mass, east: charge.east, north: charge.north, observers: observers)
            var arrivals: [ChargeInference.Arrival] = []
            for (k, p) in observers.enumerated() {
                guard let at = times[k] else { continue }
                let latest = (at / frame).rounded(.up) * frame
                arrivals.append(
                    ChargeInference.Arrival(
                        name: "o\(k)", east: p.x - reference.x, north: p.y - reference.y,
                        earliest: latest - frame,
                        latest: latest))
            }
            let observed = glass.flatMap { name, sides in
                sides.compactMap { side -> (owner: UUID, axis: Int, outward: Int, damaged: Bool)? in
                    byName[name].map {
                        (owner: $0, axis: side.axis, outward: side.outward, damaged: side.broken)
                    }
                }
            }
            let damage = ChargeInference.SurrogateDamage(
                scene: scene, observed: observed, reference: SIMD2(half, half),
                placeRadius: settings.placeRadius,
                spacing: 20, cellSize: cellSize)
            let truth = (charge.mass, charge.east - reference.x, charge.north - reference.y)
            print(
                String(
                    format:
                        "  %.0f kg at (%.0f, %.0f) m from the centre: %d arrivals; %d sides seen, %d broken (run %.0f s, features %.1f s)",
                    charge.mass, truth.1, truth.2, arrivals.count, damage.sides.count,
                    damage.sides.filter(\.damaged).count, DistrictBenchmark.seconds(start), damage.seconds))
            settings.seed = UInt64(n + 1)
            let started = ContinuousClock.now
            let fromDamage = ChargeInference.infer(arrivals: [], damage: damage, settings: settings)
            print(
                line("Damage alone", fromDamage, truth: truth)
                    + String(format: " (%.0f s)", DistrictBenchmark.seconds(started)))
            var both: ChargeInference.Posterior?
            if arrivals.count >= 5 {
                print(
                    line(
                        "Arrivals alone", ChargeInference.infer(arrivals: arrivals, settings: settings),
                        truth: truth))
                both = ChargeInference.infer(arrivals: arrivals, damage: damage, settings: settings)
                print(line("Arrivals and damage", both!, truth: truth))
            }
            // Further passes, as `--forward`'s: BombCAD run at the last estimate, its loads on each
            // side over the surrogate's there taken as the side's correction (and with the arrivals,
            // their ratios), until the yield moves under 5% (at most `passes` runs). The glass alone
            // is run at its own estimates, the two together at theirs.
            func estimate(_ posterior: ChargeInference.Posterior) -> (
                mass: Float, east: Double, north: Double
            ) {
                (
                    Float(pow(10, posterior.summary("log10MassKg")!.median)),
                    posterior.summary("east")!.median + reference.x,
                    posterior.summary("north")!.median + reference.y
                )
            }
            func corrected(_ found: (mass: Float, east: Double, north: Double)) throws -> (
                damage: ChargeInference.SurrogateDamage, arrivals: [ChargeInference.Arrival]
            ) {
                let seen = arrivals.map { SIMD2($0.east + reference.x, $0.north + reference.y) }
                let (again, _, loads) = try district.run(
                    mass: found.mass, east: found.east, north: found.north, observers: seen)
                var run: [Int: (peak: Double, impulse: Double)] = [:]
                var runGlass: [Int: Double] = [:]
                let index = Dictionary(
                    damage.sides.indices.map {
                        ("\(damage.sides[$0].owner)/\(damage.sides[$0].axis)/\(damage.sides[$0].outward)", $0)
                    }, uniquingKeysWith: { a, _ in a })
                let owners = Dictionary(
                    scene.envelopeObjects.enumerated().map { ($0.element.name, $0.offset) },
                    uniquingKeysWith: { a, _ in a })
                for (name, sides) in loads {
                    guard byName[name] != nil, let owner = owners[name] else { continue }
                    for side in sides {
                        if let k = index["\(owner)/\(side.axis)/\(side.outward)"] {
                            run[k] = (side.peak, side.impulse)
                            if let logNone = side.logNoneBroken { runGlass[k] = logNone }
                        }
                    }
                }
                var fixed = damage
                if InferChargeStudy.sideLoad.hasPrefix("glass") {
                    fixed.correct(
                        towardGlass: runGlass, massKg: Double(found.mass), east: found.east - reference.x,
                        north: found.north - reference.y, common: InferChargeStudy.sideLoad == "glass-common")
                } else {
                    fixed.correct(
                        toward: run, massKg: Double(found.mass), east: found.east - reference.x,
                        north: found.north - reference.y)
                }
                var timed = arrivals
                for (k, p) in seen.enumerated() {
                    guard let at = again[k] else { continue }
                    let kb = ChargeInference.arrival(
                        massKg: Double(found.mass), range: hypot(p.x - found.east, p.y - found.north))
                    timed[k].ratios = [(Double(found.mass), at / kb)]
                }
                let shifts = (fixed.corrections ?? []).map(\.x).sorted()
                print(
                    String(
                        format:
                            "      run at %.0f kg (%.0f, %.0f): %d of %d sides loaded, %d telling, peak corrections %.2f (%.2f–%.2f)",
                        found.mass, found.east - reference.x, found.north - reference.y, run.count,
                        damage.sides.count, fixed.informativeSides,
                        exp(shifts.isEmpty ? 0 : shifts[shifts.count / 2]),
                        exp(shifts.isEmpty ? 0 : shifts[shifts.count / 10]),
                        exp(shifts.isEmpty ? 0 : shifts[shifts.count * 9 / 10])))
                return (fixed, timed)
            }
            var last = fromDamage
            for pass in 1...max(passes, 1) where passes > 0 {
                let started = ContinuousClock.now
                let next = ChargeInference.infer(
                    arrivals: [], damage: try corrected(estimate(last)).damage, settings: settings)
                print(
                    line("Damage, BombCAD's loads at estimate \(pass)", next, truth: truth)
                        + String(format: " (%.0f s)", DistrictBenchmark.seconds(started)))
                let moved = abs(next.summary("log10MassKg")!.median - last.summary("log10MassKg")!.median)
                last = next
                if moved < log10(1.05) { break }
            }
            if var joint = both, passes > 0 {
                for pass in 1...passes {
                    let fixed = try corrected(estimate(joint))
                    let next = ChargeInference.infer(
                        arrivals: fixed.arrivals, damage: fixed.damage, settings: settings)
                    print(line("Both, BombCAD's loads and ratios at estimate \(pass)", next, truth: truth))
                    let moved = abs(
                        next.summary("log10MassKg")!.median - joint.summary("log10MassKg")!.median)
                    joint = next
                    if moved < log10(1.05) { break }
                }
            }
        }
    }

    /// `--side-load mean|peak|glass|glass-common`: how a run corrects a side's load: its strips'
    /// mean load, the most loaded strip's peak, the load whose glass is the run's, or those loads'
    /// median for every side.
    nonisolated(unsafe) static var sideLoad = "glass"

    static func forward(fixture: URL, cellSize: Float, frame: Double, passes: Int) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw BlastError.allocationFailed("Metal") }
        let district = District(
            buildings: try MapBuilding.read(contentsOf: fixture.appending(path: "district.osm")),
            heights: try ElevationGrid(contentsOf: fixture.appending(path: "heights.asc")),
            ground: try ElevationGrid(contentsOf: fixture.appending(path: "ground.asc")), device: device,
            cellSize: cellSize)
        // Observers: a fixed scatter over the district (east, north in the fixture's metres).
        var generator = SplitMixGenerator(seed: 7)
        let scatter = (0..<400).map { _ in
            SIMD2(
                Double.random(in: 150...1050, using: &generator),
                Double.random(in: 150...1050, using: &generator))
        }
        var settings = ChargeInference.Settings()
        settings.massRange = 10...1e6
        settings.placeRadius = 500
        // The district's centre (600, 600) is the reference.
        let reference = SIMD2(600.0, 600.0)
        print("Forward: \(charges.count) charges on the New District, \(cellSize) m cells, frame \(frame) s")
        for (n, charge) in charges.enumerated() {
            let start = ContinuousClock.now
            let observers = Array(
                scatter.filter { p in
                    let d = hypot(p.x - charge.east, p.y - charge.north)
                    return d >= 40 && d <= Double(district.reach)
                }.prefix(40))
            let times = try district.arrivals(
                mass: charge.mass, east: charge.east, north: charge.north, observers: observers)
            var arrivals: [ChargeInference.Arrival] = []
            var seen: [SIMD2<Double>] = []
            var modelRatios: [Double] = []
            for (k, p) in observers.enumerated() {
                guard let at = times[k] else { continue }
                let latest = (at / frame).rounded(.up) * frame
                arrivals.append(
                    ChargeInference.Arrival(
                        name: "o\(k)", east: p.x - reference.x, north: p.y - reference.y,
                        earliest: latest - frame,
                        latest: latest))
                seen.append(p)
                modelRatios.append(
                    at
                        / ChargeInference.arrival(
                            massKg: Double(charge.mass), range: hypot(p.x - charge.east, p.y - charge.north)))
            }
            modelRatios.sort()
            let truth = (charge.mass, charge.east - reference.x, charge.north - reference.y)
            print(
                String(
                    format:
                        "  %.0f kg at (%.0f, %.0f) m from the centre: %d arrivals, BombCAD over Kingery–Bulmash %.3f (%.3f–%.3f)",
                    charge.mass, truth.1, truth.2, arrivals.count,
                    modelRatios.isEmpty ? 0 : modelRatios[modelRatios.count / 2],
                    modelRatios.first ?? 0, modelRatios.last ?? 0))
            guard arrivals.count >= 5 else { continue }
            settings.seed = UInt64(n + 1)
            let first = ChargeInference.infer(arrivals: arrivals, settings: settings)
            print(line("Kingery–Bulmash alone", first, truth: truth))
            // Further passes, as an investigator would: BombCAD run at the last estimate, its arrivals
            // over Kingery–Bulmash's there taken as each observer's ratio, until the yield moves
            // under 5% (at most `passes` runs).
            var last = first
            for pass in 1...passes {
                let found = (
                    mass: Float(pow(10, last.summary("log10MassKg")!.median)),
                    east: last.summary("east")!.median + reference.x,
                    north: last.summary("north")!.median + reference.y
                )
                let again = try district.arrivals(
                    mass: found.mass, east: found.east, north: found.north, observers: seen)
                var corrected = arrivals
                for (k, p) in seen.enumerated() {
                    guard let at = again[k] else { continue }
                    let kb = ChargeInference.arrival(
                        massKg: Double(found.mass), range: hypot(p.x - found.east, p.y - found.north))
                    corrected[k].ratios = [(Double(found.mass), at / kb)]
                }
                let next = ChargeInference.infer(arrivals: corrected, settings: settings)
                print(line("BombCAD's ratios at estimate \(pass)", next, truth: truth))
                let moved = abs(next.summary("log10MassKg")!.median - last.summary("log10MassKg")!.median)
                last = next
                if moved < log10(1.05) { break }
            }
            print(String(format: "    (%.0f s)", DistrictBenchmark.seconds(start)))
        }
    }
}

/// A seeded generator for the study's fixed scatter of observers.
struct SplitMixGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension InferChargeStudy.District {
    /// As `arrivals`, and each building side's glass as the run judges it (broken where its chance
    /// that some pane breaks is over a half), by its building's name: the run's envelope components recorded and judged as the
    /// app judges them (`EnvelopeDamageAssessment`).
    func run(mass: Float, east: Double, north: Double, observers: [SIMD2<Double>]) throws -> (
        arrivals: [Double?], glass: [String: [(axis: Int, outward: Int, broken: Bool)]],
        loads: [String: [(axis: Int, outward: Int, peak: Double, impulse: Double, logNoneBroken: Double?)]]
    ) {
        let metres = ElevationGrid.metresPerDegree
        var layout = DistrictLayout(
            buildings: buildings, charge: SIMD2(east / metres, north / metres), mass: mass)
        layout.heights = heights
        layout.ground = DistrictLayout.ground(ground, openingM: 0, seaM: 1)
        let half = layout.halfSide(radius: reach, cellSize: cellSize)
        var (scene, _) = try layout.scene(halfSide: half, cellSize: cellSize)
        let positions = observers.map { SIMD2(Float($0.x - east) + half, Float($0.y - north) + half) }
        let inside = positions.indices.filter { k in
            positions[k].x > cellSize && positions[k].y > cellSize && positions[k].x < 2 * half - cellSize
                && positions[k].y < 2 * half - cellSize
        }
        scene.gauges = inside.prefix(BlastSolver.maxGauges).map { k in
            let p = positions[k]
            return Gauge("o\(k)", at: SIMD3(p.x, p.y, (scene.terrain?.height(at: p) ?? 0) + 2))
        }
        let solver = try BlastSolver(
            device: device, scenario: scene, cellSize: cellSize, configuration: .recommended)
        let points = scene.gauges.map(\.position)
        let cells = points.map { p -> (i: Int, j: Int, k: Int) in
            let i = Int(p.x / cellSize)
            let j = Int(p.y / cellSize)
            var k = Int(p.z / cellSize)
            while k < solver.grid.nz - 1, solver.isSolid(i, j, k) { k += 1 }
            return (i, j, k)
        }
        solver.setGauges(cells: cells, points: points)
        try solver.configureEnvelopeComponents(
            objects: scene.envelopeObjects,
            options: EnvelopeHistoryOptions(windowS: 0.2, memoryBudget: 1024 << 20, windowFromArrival: true))
        // Until the blast has crossed the domain's corners and their window has passed.
        let until = Double(half) * 1.5 / 300 + 0.25
        while solver.time < until {
            let batch = solver.advance(until: until)
            guard batch.steps > 0, batch.isStable else { break }
        }
        var arrivals = [Double?](repeating: nil, count: observers.count)
        for (slot, k) in inside.prefix(BlastSolver.maxGauges).enumerated() {
            let samples = solver.gaugeHistories[slot]
            guard let first = samples.first?.pressure else { continue }
            arrivals[k] = samples.first(where: { $0.pressure - first > 500 })?.time
        }
        let loads = (solver.envelopeComponentHistories() ?? []).filter { !$0.invalid }.map(
            EnvelopeComponentLoad.init)
        let judged = EnvelopeDamageAssessment.assess(
            loads: loads, constructions: { scene.envelopeConstruction(for: $0) })
        let names = Dictionary(uniqueKeysWithValues: scene.envelopeObjects.map { ($0.id, $0.name) })
        var glass: [String: [(axis: Int, outward: Int, broken: Bool)]] = [:]
        var glassLog: [String: [Int: Double]] = [:]
        for building in judged {
            guard let name = names[building.id], let sides = building.facadeGlass else { continue }
            for side in sides where side.axis < 2 {
                glassLog[name, default: [:]][side.axis * 2 + (side.outward > 0 ? 1 : 0)] =
                    side.glass.logNoneBroken
            }
            glass[name] = sides.filter { $0.axis < 2 }.map {
                ($0.axis, $0.outward, $0.glass.logNoneBroken < log(0.5))
            }
        }
        // Each side's load as the surrogate gives it: its façade strips' peak net loads and first
        // positive impulses (`SurrogateBench`), their logs averaged by area, or with
        // `--side-load peak` the peak the most loaded strip's; and its glass as the run judges it.
        var sides: [String: [Int: (area: Double, logPeak: Double, logImpulse: Double, top: Double)]] = [:]
        for load in loads where load.kind == .facade && load.axis < 2 {
            guard let name = names[load.owner] else { continue }
            let net = load.netPa
            let peak = net.max() ?? 0
            let impulse = SurrogateBench.firstImpulse(net, binS: load.binS)
            guard peak > 0, impulse > 0 else { continue }
            let spans = load.spans
            let area = Double(spans.short * spans.long)
            let key = load.axis * 2 + (load.outward > 0 ? 1 : 0)
            var side = sides[name, default: [:]][key] ?? (0, 0, 0, 0)
            side.area += area
            side.logPeak += area * log(peak)
            side.logImpulse += area * log(impulse)
            side.top = max(side.top, peak)
            sides[name, default: [:]][key] = side
        }
        let perSide = Dictionary(
            uniqueKeysWithValues: sides.map { name, bySide in
                (
                    name,
                    bySide.sorted { $0.key < $1.key }.map { key, side in
                        (
                            axis: key / 2, outward: key % 2 == 1 ? 1 : -1,
                            peak: InferChargeStudy.sideLoad == "peak"
                                ? side.top : exp(side.logPeak / side.area),
                            impulse: exp(side.logImpulse / side.area), logNoneBroken: glassLog[name]?[key]
                        )
                    }
                )
            })
        return (arrivals, glass, perSide)
    }
}
