import BlastCore
import Foundation
import simd

/// The façade load surrogate against BombCAD's own district runs (docs/surrogate-first-look.md).
///
/// `scenebench surrogate-extract <district-scene's inputs> [--radius 2500] --loads folder --out
/// strips.csv`: a run's saved façade strips (`district-compare --save-loads`), each with its
/// features and its recorded peak and impulse, for fitting (`Scripts/fit-surrogate.py`).
///
/// `scenebench surrogate-judge <inputs> [--radius 2500] --loads folder [--inside 0.85]
/// [--coefficients fit.json] [--first-look] [--run-wall s] [--out judged.json]`: each strip's damage from its recorded history and from the surrogate's pulse,
/// through the same SDOF, side by side; and the surrogate's whole first look, timed.
///
/// Strips saved before 19 October 2026 carry no boxes, so the scene is laid out again from the
/// same inputs and each building's strips matched to its laid-out ones: the recorder leaves out a
/// strip with no face on the air, found again here (`FacadeLoadSurrogate.facesAir`); a building
/// whose strips do not then match one for one is left out.
enum SurrogateBench {
    static func value(_ args: [String], _ name: String) -> String? {
        args.firstIndex(of: "--\(name)").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
    }

    /// A district run's saved strips, each found in the scene laid out again.
    struct Reference {
        var scene: Scenario
        var objects: [SceneObject]
        var raster: FacadeLoadSurrogate.Raster
        var index: DistrictGlass.Index
        var values: [Float16]
        /// Matched strips: the saved strip, its object and its component.
        var strips: [(saved: Int, object: Int, component: EnvelopeComponent)]
        var cellSize: Float
        var radius: Float

        init(_ args: [String]) throws {
            guard let path = SurrogateBench.value(args, "loads") else {
                throw BlastError.allocationFailed("--loads folder")
            }
            let inputs = try DistrictInputs.read(args)
            radius = Float(SurrogateBench.value(args, "radius").flatMap(Double.init) ?? 1000)
            (scene, _) = try inputs.scene(radius: radius)
            cellSize = inputs.cellSize
            objects = scene.envelopeObjects
            let dx = cellSize
            let raster = FacadeLoadSurrogate.Raster(objects: objects, terrain: scene.terrain, cell: dx)
            self.raster = raster
            let folder = URL(filePath: path)
            let index = try JSONDecoder().decode(
                DistrictGlass.Index.self, from: Data(contentsOf: folder.appending(path: "strips.json")))
            self.index = index
            let data = try Data(contentsOf: folder.appending(path: "net.f16"))
            values = data.withUnsafeBytes { Array($0.bindMemory(to: Float16.self)) }

            // The saved buildings are those with recorded loads, in the objects' order: matched by
            // their distance and height as district-compare measured them.
            let charge = scene.charge.position
            var objectOf = [Int](repeating: -1, count: index.buildings.count)
            var next = 0
            for (n, object) in objects.enumerated() where next < index.buildings.count {
                let (low, high) = SurrogateBench.bounds(object)
                let centre = 0.5 * (low + high)
                let distance = Double(simd_length(SIMD2(charge.x - centre.x, charge.y - centre.y)))
                let saved = index.buildings[next]
                if abs(distance - saved.distanceM) < 0.01, abs(high.z - low.z - saved.heightM) < 0.01 {
                    objectOf[next] = n
                    next += 1
                }
            }
            let byBuilding = Dictionary(grouping: index.strips.indices, by: { index.strips[$0].building })
            let objects = objects
            var matched = [[(Int, Int, EnvelopeComponent)]](repeating: [], count: index.buildings.count)
            var how = [Int](repeating: 0, count: index.buildings.count)
            matched.withUnsafeMutableBufferPointer { out in
                how.withUnsafeMutableBufferPointer { how in
                    SurrogateBench.concurrentlyEach(index.buildings.count) { b in
                        let n = objectOf[b]
                        guard n >= 0, let envelope = objects[n].envelope else { return }
                        let mine = byBuilding[b] ?? []
                        let laid = envelope.components(owner: objects[n].id, cellSize: dx).filter {
                            $0.kind == .facade
                        }
                        // Saved with their boxes: each the laid-out strip of that box.
                        if mine.allSatisfy({ index.strips[$0].low != nil }) {
                            let byBox = Dictionary(
                                laid.map { (SurrogateBench.key($0.region, $0.axis, $0.outward), $0) },
                                uniquingKeysWith: { a, _ in a })
                            out[b] = mine.compactMap { s in
                                let strip = index.strips[s]
                                return byBox[
                                    SurrogateBench.key(
                                        Box(min: strip.low!, max: strip.high!), strip.axis, strip.outward)
                                ].map { (s, n, $0) }
                            }
                            return
                        }
                        func same(_ list: [EnvelopeComponent]) -> Bool {
                            list.count == mine.count
                                && zip(list, mine).allSatisfy { component, s in
                                    let strip = index.strips[s]
                                    let spans = component.spans
                                    return component.axis == strip.axis && component.outward == strip.outward
                                        && abs(Double(spans.x * spans.y) - strip.areaM2) < 1e-3
                                            * max(1, strip.areaM2)
                                }
                        }
                        var list = laid
                        how[b] = 1
                        if !same(list) {
                            list = laid.filter { FacadeLoadSurrogate.facesAir($0, raster: raster) }
                            how[b] = 2
                            guard same(list) else {
                                how[b] = 3
                                return
                            }
                        }
                        out[b] = zip(mine, list).map { ($0, n, $1) }
                    }
                }
            }
            print(
                "Buildings' strips matched as laid out \(how.filter { $0 == 1 }.count), with the air test "
                    + "\(how.filter { $0 == 2 }.count), not \(how.filter { $0 == 3 }.count)")
            strips = matched.flatMap { $0 }.map { (saved: $0.0, object: $0.1, component: $0.2) }
            print(
                "\(objects.count) buildings, \(index.buildings.count) saved with \(index.strips.count) strips; "
                    + "\(strips.count) strips matched")
        }

        /// A saved strip's net pressures, Pa per bin.
        func net(_ saved: Int) -> [Double] {
            let strip = index.strips[saved]
            return values[strip.first..<(strip.first + strip.count)].map { Double($0) }
        }

        /// Whether a point lies within `share` of the half-side of the charge, in plan: outside
        /// it the run's far-field faces drain the blast.
        func inside(_ p: SIMD3<Float>, share: Float) -> Bool {
            let c = scene.charge.position
            return max(abs(p.x - c.x), abs(p.y - c.y)) < share * radius
        }
    }

    static func key(_ box: Box, _ axis: Int, _ outward: Int) -> [Int32] {
        let q = { (x: Float) in Int32((x * 100).rounded()) }
        return [
            q(box.min.x), q(box.min.y), q(box.min.z), q(box.max.x), q(box.max.y), q(box.max.z), Int32(axis),
            Int32(outward),
        ]
    }

    static func bounds(_ object: SceneObject) -> (SIMD3<Float>, SIMD3<Float>) {
        let blocks = object.envelope?.blocks ?? []
        let low = blocks.map(\.min).reduce(SIMD3<Float>(repeating: .greatestFiniteMagnitude)) {
            simd_min($0, $1)
        }
        let high = blocks.map(\.max).reduce(SIMD3<Float>(repeating: -.greatestFiniteMagnitude)) {
            simd_max($0, $1)
        }
        return (low, high)
    }

    static func extract(_ args: [String]) throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        guard let out = value(args, "out") else { throw BlastError.allocationFailed("--out strips.csv") }
        let start = ContinuousClock.now
        let reference = try Reference(args)
        let charge = reference.scene.charge.position
        let mass = Double(reference.scene.charge.mass)
        let root = cbrt(mass)
        var rows = [String](repeating: "", count: reference.strips.count)
        rows.withUnsafeMutableBufferPointer { rows in
            concurrentlyEach(reference.strips.count) { m in
                let (s, n, component) = reference.strips[m]
                let strip = reference.index.strips[s]
                let f = FacadeLoadSurrogate.features(
                    component, owner: n, charge: charge, raster: reference.raster)
                let net = reference.net(s)
                let peak = net.max() ?? 0
                let impulse = SurrogateBench.firstImpulse(net, binS: strip.binS)
                let rise = SurrogateBench.riseTime(net, binS: strip.binS)
                let (centre, _) = FacadeLoadSurrogate.outerFace(component)
                let kb = KingeryBulmash.point(at: f.distanceM / root)
                rows[m] =
                    [
                        "\(strip.building)", "\(n)", "\(s)", reference.index.buildings[strip.building].mix,
                        "\(component.axis)", "\(component.outward)", String(format: "%.2f", centre.x),
                        String(format: "%.2f", centre.y), String(format: "%.2f", centre.z),
                        String(format: "%.3f", strip.areaM2), String(format: "%.3f", f.distanceM),
                        String(format: "%.5f", f.cosIncidence), "\(f.buildingsCrossed)",
                        String(format: "%.2f", f.blockedM), String(format: "%.2f", f.ridgeM),
                        String(format: "%.2f", f.groundRiseM), String(format: "%.2f", f.heightM),
                        String(format: "%.1f", f.shadowM), String(format: "%.1f", f.frontM),
                        reference.inside(centre, share: 0.85) ? "1" : "0", String(format: "%.1f", peak),
                        String(format: "%.4f", impulse), String(format: "%.1f", kb?.incidentPressure ?? 0),
                        String(format: "%.4f", (kb?.scaledIncidentImpulse ?? 0) * root),
                        String(format: "%.1f", kb?.reflectedPressure ?? 0),
                        String(format: "%.4f", (kb?.scaledReflectedImpulse ?? 0) * root),
                        String(format: "%.3f", reference.cellSize), String(format: "%.5f", rise),
                    ].joined(separator: ",") + "\n"
            }
        }
        let header =
            "building,object,strip,mix,axis,outward,x,y,z,area,distance,cos,crossed,blocked,ridge,rise,height,"
            + "shadow,front,inside,peak,impulse,pso,iso,pr,ir,cell,rise\n"
        try (header + rows.joined()).write(to: URL(filePath: out), atomically: true, encoding: .utf8)
        print(
            String(
                format: "Wrote %@ in %.1f s; charge %.0f kg at %.1f, %.1f, %.1f m", out,
                DistrictBenchmark.seconds(start), mass, charge.x, charge.y, charge.z))
    }

    /// The impulse of a net history's first positive phase, Pa s: from the start to where it
    /// first falls below nothing after its peak's half. Later reflections add impulse a pane or
    /// wall has mostly answered by then, and a pulse packing them into the first phase would
    /// overload it.
    static func firstImpulse(_ net: [Double], binS: Double) -> Double {
        let peak = net.max() ?? 0
        guard peak > 0 else { return 0 }
        var impulse = 0.0
        var risen = false
        for p in net {
            if p >= 0.5 * peak { risen = true }
            if risen, p < 0 { break }
            impulse += max(p, 0) * binS
        }
        return impulse
    }

    /// How long a net history takes from a tenth of its peak to its peak, s.
    static func riseTime(_ net: [Double], binS: Double) -> Double {
        guard let peak = net.max(), peak > 0, let top = net.firstIndex(of: peak) else { return 0 }
        let start = net.firstIndex { $0 >= 0.1 * peak } ?? top
        return Double(top - start) * binS
    }

    /// A building side's glass state, against GEER's classes: none broken (W0), some (W1–W2), or
    /// blown out (W3, nine in ten of its panes expected broken).
    static func glassState(_ glass: GlazingBreakage) -> Int {
        if glass.fraction >= DistrictGlass.blownOutFraction { return 2 }
        return glass.anyBroken >= 0.5 ? 1 : 0
    }

    struct Agreement: Codable {
        /// Rows the run's state, columns the surrogate's.
        var confusion: [[Int]]
        var count: Int
        var exact: Double
        var withinOne: Double
        /// The surrogate's state above and below the run's.
        var over: Double
        var under: Double
        /// The same two shares over those either calls damaged (not both the first state), which
        /// the undamaged many would otherwise swamp; and how many those are.
        var damaged: Int
        var damagedExact: Double
        var damagedWithinOne: Double

        init(states: Int) {
            confusion = Array(repeating: Array(repeating: 0, count: states), count: states)
            count = 0
            exact = 0
            withinOne = 0
            over = 0
            under = 0
            damaged = 0
            damagedExact = 0
            damagedWithinOne = 0
        }

        mutating func add(_ run: Int, _ surrogate: Int) { confusion[run][surrogate] += 1 }

        mutating func finish() {
            count = confusion.joined().reduce(0, +)
            let n = Double(max(count, 1))
            var same = 0
            var near = 0
            var above = 0
            var below = 0
            for (r, row) in confusion.enumerated() {
                for (s, k) in row.enumerated() {
                    if r == s { same += k }
                    if abs(r - s) <= 1 { near += k }
                    if s > r { above += k }
                    if s < r { below += k }
                }
            }
            exact = Double(same) / n
            withinOne = Double(near) / n
            over = Double(above) / n
            under = Double(below) / n
            damaged = count - confusion[0][0]
            let m = Double(max(damaged, 1))
            damagedExact = Double(same - confusion[0][0]) / m
            damagedWithinOne = Double(near - confusion[0][0]) / m
        }
    }

    struct Group: Codable {
        var name: String
        var strips = 0
        var sides = 0
        /// The surrogate's peak and impulse over the run's: median and the standard deviation of
        /// the logarithm.
        var peakRatio = 0.0
        var peakLogSD = 0.0
        var impulseRatio = 0.0
        var impulseLogSD = 0.0
        var concrete = Agreement(states: EnvelopeDamageLevel.allCases.count)
        var stone = Agreement(states: EnvelopeDamageLevel.allCases.count)
        var glass = Agreement(states: 3)
    }

    struct Judged: Codable {
        var massKg: Double
        var strips: Int
        var inside: Double
        var groups: [Group]
        /// The surrogate's first look over every envelope: components, seconds for the loads and
        /// for the damage.
        var components: Int
        var loadsS: Double
        var damageS: Double
        var runWallS: Double?
        var bands: [Band]
    }

    struct Band: Codable {
        var from: Double
        var to: Double
        var runSidesAny: Double
        var surrogateSidesAny: Double
        var runSidesBlown: Double
        var surrogateSidesBlown: Double
        var geer: Double
        var geerBlown: Double
    }

    static func judge(_ args: [String]) throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let reference = try Reference(args)
        let share = Float(value(args, "inside").flatMap(Double.init) ?? 0.85)
        let scene = reference.scene
        let objects = reference.objects
        let mass = Double(scene.charge.mass)
        let charge = scene.charge.position

        let coefficients =
            try value(args, "coefficients").map {
                try JSONDecoder().decode(
                    FacadeLoadSurrogate.Coefficients.self, from: Data(contentsOf: URL(filePath: $0)))
            } ?? .fitted
        print("Coefficients fitted to \(coefficients.fittedTo)")
        // The surrogate's whole first look, timed: every envelope component's load, then damage.
        let estimate = FacadeLoadSurrogate.estimate(
            scene: scene, cellSize: reference.cellSize, coefficients: coefficients)
        let (damage, damageS, memo) = FacadeLoadSurrogate.damage(
            estimate, constructions: { scene.envelopeConstruction(for: $0) })
        print(
            String(
                format:
                    "First look: %d components' loads in %.1f s, their damage in %.1f s (%d buildings; %d SDOF responses integrated, %d reused)",
                estimate.loads.count, estimate.seconds, damageS, damage.count, memo.misses, memo.hits))
        if args.contains("--first-look") { return }

        // Each matched strip, inside the fair part of the run, judged both ways.
        let kept = reference.strips.indices.filter {
            reference.inside(
                FacadeLoadSurrogate.outerFace(reference.strips[$0].component).centre, share: share)
        }
        let tops = objects.map { Double(SurrogateBench.bounds($0).1.z) }
        let bases = objects.map { Double(SurrogateBench.bounds($0).0.z) }
        struct Outcome {
            var run: (concrete: Int, stone: Int, glass: GlazingBreakage, peak: Double, impulse: Double)
            var surrogate: (concrete: Int, stone: Int, glass: GlazingBreakage, peak: Double, impulse: Double)
            var crossed: Int
            var distance: Double
        }
        let mixes = Dictionary(
            uniqueKeysWithValues: [GlazingMix.olderLowRise, .apartments, .commercial, .industrial].map {
                ($0.name, $0)
            })
        let clockJudge = ContinuousClock.now
        var outcomes = [Outcome?](repeating: nil, count: kept.count)
        outcomes.withUnsafeMutableBufferPointer { out in
            concurrentlyEach(kept.count) { m in
                let (s, n, component) = reference.strips[kept[m]]
                let strip = reference.index.strips[s]
                let id = objects[n].id
                let concrete = scene.envelopeConstruction(for: id)
                let stone = EnvelopeConstruction(
                    objectID: id, walls: .unreinforcedMasonry, wallThicknessM: 0.5, source: .user,
                    detail: "stone 0.5 m, assumed for the comparison")
                let mix =
                    mixes[reference.index.buildings[strip.building].mix] ?? concrete.glazing ?? .apartments
                func judged(_ load: EnvelopeComponentLoad) -> (Int, Int, GlazingBreakage, Double, Double) {
                    let c = EnvelopeDamageAssessment.assess(
                        load, construction: concrete, buildingTop: tops[n], buildingBase: bases[n])
                    let st = EnvelopeDamageAssessment.assess(
                        load, construction: stone, buildingTop: tops[n], buildingBase: bases[n])
                    let net = load.netPa
                    return (
                        c?.levels.upperBound.rawValue ?? 0, st?.levels.upperBound.rawValue ?? 0,
                        mix.breakage(netPa: net, binS: load.binS, areaM2: strip.areaM2), net.max() ?? 0,
                        SurrogateBench.firstImpulse(net, binS: load.binS)
                    )
                }
                // Both judged alike: the same strip, its edges taken as held, only the load differing.
                let recorded = EnvelopeComponentLoad(
                    id: component.id, owner: id, kind: .facade, region: component.region,
                    axis: component.axis,
                    binS: strip.binS, outerPa: reference.net(s),
                    innerPa: Array(repeating: 0, count: strip.count),
                    supportEdges: nil, outward: component.outward)
                let f = FacadeLoadSurrogate.features(
                    component, owner: n, charge: charge, raster: reference.raster)
                var predicted = FacadeLoadSurrogate.load(
                    component,
                    FacadeLoadSurrogate.predict(
                        f, mass: mass, cellSize: Double(reference.cellSize), coefficients: coefficients),
                    binS: strip.binS)
                predicted.supportEdges = nil
                out[m] = Outcome(
                    run: judged(recorded), surrogate: judged(predicted), crossed: f.buildingsCrossed,
                    distance: f.distanceM)
            }
        }
        print(
            String(
                format: "Judged %d strips both ways in %.0f s", kept.count,
                DistrictBenchmark.seconds(clockJudge)))

        // Groups: all, by shielding, by distance band.
        let all = outcomes.map { $0! }
        let sideOf = kept.map { m -> [Int] in
            let (s, n, _) = reference.strips[m]
            let strip = reference.index.strips[s]
            return [n, strip.axis, strip.outward]
        }
        let root = cbrt(mass)
        var groups: [Group] = []
        func group(_ name: String, _ members: [Int]) {
            guard !members.isEmpty else { return }
            var g = Group(name: name)
            g.strips = members.count
            func logs(_ f: (Outcome) -> (Double, Double)) -> [Double] {
                members.compactMap {
                    let (a, b) = f(all[$0])
                    return a > 0 && b > 0 ? log(b / a) : nil
                }
            }
            func stats(_ l: [Double]) -> (Double, Double) {
                guard !l.isEmpty else { return (0, 0) }
                let sorted = l.sorted()
                let mean = l.reduce(0, +) / Double(l.count)
                let sd = (l.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(l.count)).squareRoot()
                return (exp(sorted[sorted.count / 2]), sd)
            }
            (g.peakRatio, g.peakLogSD) = stats(logs { ($0.run.peak, $0.surrogate.peak) })
            (g.impulseRatio, g.impulseLogSD) = stats(logs { ($0.run.impulse, $0.surrogate.impulse) })
            for m in members {
                g.concrete.add(all[m].run.concrete, all[m].surrogate.concrete)
                g.stone.add(all[m].run.stone, all[m].surrogate.stone)
            }
            // Glass by building side, as GEER judged it.
            let sides = Dictionary(grouping: members, by: { sideOf[$0] })
            g.sides = sides.count
            for (_, list) in sides {
                let run = list.reduce(GlazingBreakage()) { $0 + all[$1].run.glass }
                let surrogate = list.reduce(GlazingBreakage()) { $0 + all[$1].surrogate.glass }
                g.glass.add(glassState(run), glassState(surrogate))
            }
            g.concrete.finish()
            g.stone.finish()
            g.glass.finish()
            groups.append(g)
        }
        let indices = Array(all.indices)
        group("all", indices)
        group("in sight (no building in the way)", indices.filter { all[$0].crossed == 0 })
        group("shielded (1-3 buildings in the way)", indices.filter { (1...3).contains(all[$0].crossed) })
        group("deeply shielded (4 or more)", indices.filter { all[$0].crossed >= 4 })
        let edges = [0, 3, 5, 7, 10, 14, 20, 28, 40].map { Double($0) }
        for (lo, hi) in zip(edges, edges.dropFirst()) {
            group(
                String(format: "Z %.0f–%.0f m/kg^(1/3) (%.0f–%.0f m)", lo, hi, lo * root, hi * root),
                indices.filter { all[$0].distance / root >= lo && all[$0].distance / root < hi })
        }

        // GEER's bands, by building side over every matched strip (as district-glass).
        var bands: [Band] = []
        for band in DistrictGlass.geer {
            let members = indices.filter {
                let strip = reference.index.strips[reference.strips[kept[$0]].saved]
                let d = reference.index.buildings[strip.building].distanceM
                return d >= band.from && d < band.to
            }
            let sides = Dictionary(grouping: members, by: { sideOf[$0] })
            guard !sides.isEmpty else { continue }
            var counts = (0.0, 0.0, 0.0, 0.0)
            for (_, list) in sides {
                let run = list.reduce(GlazingBreakage()) { $0 + all[$1].run.glass }
                let surrogate = list.reduce(GlazingBreakage()) { $0 + all[$1].surrogate.glass }
                counts.0 += run.anyBroken
                counts.1 += surrogate.anyBroken
                counts.2 += run.fraction >= DistrictGlass.blownOutFraction ? 1 : 0
                counts.3 += surrogate.fraction >= DistrictGlass.blownOutFraction ? 1 : 0
            }
            let k = Double(sides.count)
            bands.append(
                Band(
                    from: band.from, to: band.to, runSidesAny: counts.0 / k, surrogateSidesAny: counts.1 / k,
                    runSidesBlown: counts.2 / k, surrogateSidesBlown: counts.3 / k, geer: band.damaged,
                    geerBlown: band.blownOut))
        }

        let names = EnvelopeDamageLevel.allCases.map(\.label)
        print("Surrogate against the run, by strip (structure) and by building side (glass):")
        print(
            "  group: strips, peak and impulse ratio (median, log sd); concrete, stone, glass: exact / within one"
        )
        for g in groups {
            print(
                String(
                    format:
                        "  %@: %d, peak %.2f (%.2f), impulse %.2f (%.2f); concrete %.2f / %.2f, stone %.2f / %.2f, glass %.2f / %.2f (%d sides)",
                    g.name as NSString, g.strips, g.peakRatio, g.peakLogSD, g.impulseRatio, g.impulseLogSD,
                    g.concrete.exact, g.concrete.withinOne, g.stone.exact, g.stone.withinOne, g.glass.exact,
                    g.glass.withinOne, g.sides))
        }
        if let g = groups.first {
            print(
                String(
                    format:
                        "Where either calls it damaged: concrete %d, %.2f / %.2f; stone %d, %.2f / %.2f; glass %d sides, %.2f / %.2f",
                    g.concrete.damaged, g.concrete.damagedExact, g.concrete.damagedWithinOne, g.stone.damaged,
                    g.stone.damagedExact, g.stone.damagedWithinOne, g.glass.damaged, g.glass.damagedExact,
                    g.glass.damagedWithinOne))
            for (title, a, labels) in [
                ("Concrete", g.concrete, names), ("Stone", g.stone, names),
                ("Glass", g.glass, ["W0", "W1-2", "W3"]),
            ] {
                print("\(title) (rows the run, columns the surrogate; \(labels.joined(separator: ", "))):")
                for row in a.confusion { print("  " + row.map { String(format: "%7d", $0) }.joined()) }
            }
        }
        print(
            "Sides with some glass broken, run / surrogate | GEER W1+; blown out, run / surrogate | GEER W3:")
        for b in bands {
            print(
                String(
                    format: "  %4.0f–%4.0f m  %.2f / %.2f | %.2f   %.2f / %.2f | %.2f", b.from, b.to,
                    b.runSidesAny,
                    b.surrogateSidesAny, b.geer, b.runSidesBlown, b.surrogateSidesBlown, b.geerBlown))
        }
        let result = Judged(
            massKg: mass, strips: kept.count, inside: Double(share), groups: groups,
            components: estimate.loads.count, loadsS: estimate.seconds, damageS: damageS,
            runWallS: value(args, "run-wall").flatMap(Double.init), bands: bands)
        if let out = value(args, "out") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(result).write(to: URL(filePath: out))
        }
    }

    /// `body` for each of `count` on every core.
    static func concurrentlyEach(_ count: Int, _ body: (Int) -> Void) {
        withoutActuallyEscaping(body) { body in
            nonisolated(unsafe) let shared = body
            DispatchQueue.concurrentPerform(iterations: count) { shared($0) }
        }
    }
}
