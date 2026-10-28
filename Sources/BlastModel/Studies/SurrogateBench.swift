import Foundation
import simd

/// The façade load surrogate against BombCAD's own district runs (docs/surrogate-first-look.md).
///
/// `scenebench surrogate-extract <district-scene's inputs> [--radius 2500] --loads folder --out
/// strips.csv`: a run's saved façade strips (`district-compare --save-loads`), each with its
/// features and its recorded peak and impulse, for fitting (`Scripts/fit-surrogate.py`).
///
/// `scenebench surrogate-judge <inputs> [--radius 2500] --loads folder [--inside 0.85]
/// [--coefficients fit.json | --terms deep-city|clear-top|fitted|…] [--first-look] [--run-wall s] [--sides-out sides.csv] [--by-angle] [--out judged.json]`: each strip's damage from its recorded history and from the surrogate's pulse,
/// through the same SDOF, side by side; and the surrogate's whole first look, timed. `--by-angle`
/// adds the groups and bands on the diagonal lines and balanced by angle to the cells
/// (`CellAngle`).
///
/// Strips saved before 19 October 2026 carry no boxes, so the scene is laid out again from the
/// same inputs and each building's strips matched to its laid-out ones: the recorder leaves out a
/// strip with no face on the air, found again here (`FacadeLoadSurrogate.facesAir`); a building
/// whose strips do not then match one for one is left out.
///
/// A refined run's strips are laid out on its base cells but loaded by its finest
/// (`--place-dx`): `--surrogate-dx m` predicts their loads as a run on those cells would give
/// them (the surrogate's cell term), where the air's cells are taken otherwise.
package enum SurrogateBench {
    package static func value(_ args: [String], _ name: String) -> String? {
        args.firstIndex(of: "--\(name)").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
    }

    /// `--terms deep-city|clear-top|fitted|…`: the named set of façade terms and load scatter to
    /// judge (`FacadeLoadSurrogate.TermSet`), `otherwise` without it: the adopted ones (deep-city
    /// since the evening of 25 October 2026, clear-top that morning) unless a consumer still pinned
    /// to others names its own.
    package static func termSet(
        _ args: [String], otherwise: FacadeLoadSurrogate.TermSet = .adopted
    ) throws -> FacadeLoadSurrogate.TermSet {
        guard let name = value(args, "terms") else { return otherwise }
        guard let set = FacadeLoadSurrogate.TermSet(rawValue: name) else {
            throw BlastError.allocationFailed(
                "--terms " + FacadeLoadSurrogate.TermSet.allCases.map(\.rawValue).joined(separator: "|"))
        }
        return set
    }

    /// The façade terms a bench judges: `--coefficients fit.json` (fit-surrogate.py's JSON), else
    /// those of `--terms`.
    package static func coefficients(_ args: [String]) throws -> FacadeLoadSurrogate.Coefficients {
        try value(args, "coefficients").map {
            try JSONDecoder().decode(
                FacadeLoadSurrogate.Coefficients.self, from: Data(contentsOf: URL(filePath: $0)))
        } ?? termSet(args).coefficients
    }

    /// Where a bench's façades face from (`FacadeLoadSurrogate.Incidence`;
    /// emmettl/bombcad-work#109): `--incidence cells|outline`, else that of the terms it judges
    /// (`coefficients`). With `.outline` the district is laid out with its buildings' outlines
    /// (`DistrictInputs.keepsOutlines`).
    package static func incidence(_ args: [String]) -> FacadeLoadSurrogate.Incidence {
        if let name = value(args, "incidence"), let incidence = FacadeLoadSurrogate.Incidence(rawValue: name)
        {
            return incidence
        }
        return (try? coefficients(args))?.incidence ?? .cells
    }

    /// The load scatter a bench's chances draw: `--load-scatter scatter.json` (a list of
    /// `Uncertainty.LoadScatter`), else that of `--terms`.
    package static func loadScatter(_ args: [String]) throws -> [FacadeLoadSurrogate.Uncertainty.LoadScatter]
    {
        try value(args, "load-scatter").map {
            try JSONDecoder().decode(
                [FacadeLoadSurrogate.Uncertainty.LoadScatter].self, from: Data(contentsOf: URL(filePath: $0)))
        } ?? termSet(args).loadScatter
    }

    /// `--centre lon,lat`, as `DistrictInputs` reads it.
    package static func centre(_ args: [String]) -> SIMD2<Double> {
        let parts = value(args, "centre").map { $0.split(separator: ",").compactMap { Double($0) } } ?? []
        return parts.count == 2 ? SIMD2(parts[0], parts[1]) : SIMD2(35.519042, 33.901425)
    }

    /// A district run's saved strips, each found in the scene laid out again.
    package struct Reference {
        package var scene: Scenario
        package var objects: [SceneObject]
        package var raster: FacadeLoadSurrogate.Raster
        package var index: DistrictGlass.Index
        var values: [Float16]
        /// Matched strips: the saved strip, its object and its component.
        package var strips: [(saved: Int, object: Int, component: EnvelopeComponent)]
        package var cellSize: Float
        /// The cells the surrogate predicts for (`--surrogate-dx`): a refined run's finest, which
        /// load its façades; the air's cells otherwise.
        package var predictionCell: Float
        package var radius: Float
        /// The walls', slabs' and roofs' saved loads (components.json, beside the façades' since 20
        /// October 2026), matched as the strips are; empty for older runs.
        package var others: DistrictGlass.Index?
        var otherValues: [Float16] = []
        package var otherStrips: [(saved: Int, object: Int, component: EnvelopeComponent)] = []

        package init(_ args: [String]) throws {
            guard let path = SurrogateBench.value(args, "loads") else {
                throw BlastError.allocationFailed("--loads folder")
            }
            try self.init(
                args, loads: path,
                radius: Float(SurrogateBench.value(args, "radius").flatMap(Double.init) ?? 1000))
        }

        /// The run whose strips are saved in `path`, laid out again from `args`' inputs on a
        /// square of half side `radius`.
        package init(_ args: [String], loads path: String, radius: Float) throws {
            let inputs = try DistrictInputs.read(args)
            self.radius = radius
            (scene, _) = try inputs.scene(radius: radius)
            cellSize = inputs.cellSize
            predictionCell = SurrogateBench.value(args, "surrogate-dx").flatMap(Float.init) ?? inputs.cellSize
            objects = scene.envelopeObjects
            let dx = cellSize
            let raster = FacadeLoadSurrogate.Raster(
                objects: objects, blocks: scene.boxes, terrain: scene.terrain, cell: dx,
                incidence: SurrogateBench.incidence(args))
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

            // The walls, slabs and roofs, by their boxes and kinds.
            let partsFile = folder.appending(path: "components.json")
            guard FileManager.default.fileExists(atPath: partsFile.path()) else { return }
            let parts = try JSONDecoder().decode(DistrictGlass.Index.self, from: Data(contentsOf: partsFile))
            others = parts
            otherValues = try Data(contentsOf: folder.appending(path: "components.f16")).withUnsafeBytes {
                Array($0.bindMemory(to: Float16.self))
            }
            let partsOf = Dictionary(grouping: parts.strips.indices, by: { parts.strips[$0].building })
            var found = [[(Int, Int, EnvelopeComponent)]](repeating: [], count: parts.buildings.count)
            found.withUnsafeMutableBufferPointer { out in
                SurrogateBench.concurrentlyEach(parts.buildings.count) { b in
                    guard b < objectOf.count, objectOf[b] >= 0, let envelope = objects[objectOf[b]].envelope
                    else { return }
                    let n = objectOf[b]
                    let byBox = Dictionary(
                        envelope.components(owner: objects[n].id, cellSize: dx).filter {
                            $0.kind != .facade && $0.kind != .pane
                        }.map {
                            (
                                SurrogateBench.key($0.region, $0.axis, $0.outward) + [
                                    Self.kindCode($0.kind.rawValue)
                                ], $0
                            )
                        },
                        uniquingKeysWith: { a, _ in a })
                    out[b] = (partsOf[b] ?? []).compactMap { s in
                        let strip = parts.strips[s]
                        guard let low = strip.low, let high = strip.high,
                            let kind = strip.kind.flatMap(EnvelopeComponent.Kind.init(rawValue:))
                        else { return nil }
                        return byBox[
                            SurrogateBench.key(Box(min: low, max: high), strip.axis, strip.outward)
                                + [Self.kindCode(kind.rawValue)]
                        ].map { (s, n, $0) }
                    }
                }
            }
            otherStrips = found.flatMap { $0 }.map { (saved: $0.0, object: $0.1, component: $0.2) }
            print("\(parts.strips.count) walls, slabs and roofs saved; \(otherStrips.count) matched")
        }

        static func kindCode(_ kind: String) -> Int32 { ["wall": 1, "slab": 2, "roof": 3][kind] ?? 0 }

        /// A saved wall's, slab's or roof's net pressures, Pa per bin.
        package func otherNet(_ saved: Int) -> [Double] {
            guard let others else { return [] }
            let strip = others.strips[saved]
            let scale = Double(others.scalePa ?? 1)
            return otherValues[strip.first..<(strip.first + strip.count)].map { Double($0) * scale }
        }

        /// A saved strip's net pressures, Pa per bin.
        package func net(_ saved: Int) -> [Double] {
            let strip = index.strips[saved]
            let scale = Double(index.scalePa ?? 1)
            return values[strip.first..<(strip.first + strip.count)].map { Double($0) * scale }
        }

        /// Whether a point lies within `share` of the half-side of the charge, in plan: outside
        /// it the run's far-field faces drain the blast.
        package func inside(_ p: SIMD3<Float>, share: Float) -> Bool {
            // The square's centre: the charge's, unless `--box-offset` moved the square.
            let c = scene.domainSize / 2
            return max(abs(p.x - c.x), abs(p.y - c.y)) < share * radius
        }
    }

    package static func key(_ box: Box, _ axis: Int, _ outward: Int) -> [Int32] {
        let q = { (x: Float) in Int32((x * 100).rounded()) }
        return [
            q(box.min.x), q(box.min.y), q(box.min.z), q(box.max.x), q(box.max.y), q(box.max.z), Int32(axis),
            Int32(outward),
        ]
    }

    package static func bounds(_ object: SceneObject) -> (SIMD3<Float>, SIMD3<Float>) {
        let blocks = object.envelope?.blocks ?? []
        let low = blocks.map(\.min).reduce(SIMD3<Float>(repeating: .greatestFiniteMagnitude)) {
            simd_min($0, $1)
        }
        let high = blocks.map(\.max).reduce(SIMD3<Float>(repeating: -.greatestFiniteMagnitude)) {
            simd_max($0, $1)
        }
        return (low, high)
    }

    package static func extract(_ args: [String]) throws {
        StudyOutput.lineBuffered()
        guard let out = value(args, "out") else { throw BlastError.allocationFailed("--out strips.csv") }
        let start = ContinuousClock.now
        let reference = try Reference(args)
        let charge = reference.scene.charge.position
        let mass = Double(reference.scene.charge.mass)
        let root = cbrt(mass)
        let open = reference.raster.openReach(around: charge)
        // `--parts roof` (or wall, slab): the saved components of that kind instead of the façades.
        let kind = value(args, "parts")
        let chosen: [(saved: Int, object: Int, component: EnvelopeComponent)] =
            kind.map { k in reference.otherStrips.filter { $0.component.kind.rawValue == k } }
            ?? reference.strips
        var rows = [String](repeating: "", count: chosen.count)
        rows.withUnsafeMutableBufferPointer { rows in
            concurrentlyEach(chosen.count) { m in
                let (s, n, component) = chosen[m]
                let strip = kind == nil ? reference.index.strips[s] : reference.others!.strips[s]
                var f = FacadeLoadSurrogate.features(
                    component, owner: n, charge: charge, raster: reference.raster)
                f.chargeOpenM = open
                let net = kind == nil ? reference.net(s) : reference.otherNet(s)
                let peak = net.max() ?? 0
                let impulse = SurrogateBench.firstImpulse(net, binS: strip.binS)
                let rise = SurrogateBench.riseTime(net, binS: strip.binS)
                let (centre, _) = FacadeLoadSurrogate.outerFace(component)
                let kb = KingeryBulmash.point(at: f.distanceM / root)
                rows[m] =
                    [
                        "\(strip.building)", "\(n)", "\(s)",
                        kind ?? reference.index.buildings[strip.building].mix,
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
                        f.edgeM.isFinite ? String(format: "%.2f", f.edgeM) : "-999",
                        String(format: "%.2f", f.edgeFromChargeM), String(format: "%.2f", f.edgeToTargetM),
                        String(format: "%.2f", f.edgeTopM), String(format: "%.2f", f.lastTopM),
                        String(format: "%.1f", f.canyonM), String(format: "%.2f", f.canyonHeightM),
                        String(format: "%.1f", f.edgeSideM), String(format: "%.1f", f.edgeWidthM),
                        String(format: "%.1f", f.chargeOpenM),
                    ].joined(separator: ",") + "\n"
            }
        }
        let header =
            "building,object,strip,mix,axis,outward,x,y,z,area,distance,cos,crossed,blocked,ridge,rise,height,"
            + "shadow,front,inside,peak,impulse,pso,iso,pr,ir,cell,risetime,edge,edgefrom,edgeto,edgetop,lasttop,"
            + "canyon,canyonheight,edgeside,edgewidth,chargeopen\n"
        try (header + rows.joined()).write(to: URL(filePath: out), atomically: true, encoding: .utf8)
        print(
            String(
                format: "Wrote %@ in %.1f s; charge %.0f kg at %.1f, %.1f, %.1f m", out,
                StudyClock.seconds(start), mass, charge.x, charge.y, charge.z))
    }

    /// The impulse of a net history's first positive phase, Pa s: from the start to where it
    /// first falls below nothing after its peak's half. Later reflections add impulse a pane or
    /// wall has mostly answered by then, and a pulse packing them into the first phase would
    /// overload it.
    package static func firstImpulse(_ net: [Double], binS: Double) -> Double {
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
    package static func glassState(_ glass: GlazingBreakage) -> Int {
        if glass.fraction >= DistrictGlass.blownOutFraction { return 2 }
        return glass.anyBroken >= 0.5 ? 1 : 0
    }

    package struct Agreement: Codable {
        /// Rows the run's state, columns the surrogate's.
        var confusion: [[Int]]
        var count: Int
        package var exact: Double
        package var withinOne: Double
        /// The surrogate's state above and below the run's.
        var over: Double
        var under: Double
        /// The same two shares over those either calls damaged (not both the first state), which
        /// the undamaged many would otherwise swamp; and how many those are.
        var damaged: Int
        var damagedExact: Double
        var damagedWithinOne: Double

        package init(states: Int) {
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

        package mutating func add(_ run: Int, _ surrogate: Int) { confusion[run][surrogate] += 1 }

        package mutating func finish() {
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
        /// The run against a triangle made of its own peak, first impulse and rise (the oracle):
        /// what the surrogate's pulse shape alone loses, whatever its loads.
        var oracleConcrete = Agreement(states: EnvelopeDamageLevel.allCases.count)
        var oracleStone = Agreement(states: EnvelopeDamageLevel.allCases.count)
    }

    /// The triangle the surrogate's pulse would be with the run's own peak, first impulse and rise.
    static func oracle(_ net: [Double], binS: Double) -> FacadeLoadSurrogate.Prediction {
        let peak = net.max() ?? 0
        let impulse = firstImpulse(net, binS: binS)
        let duration = peak > 0 ? 2 * impulse / peak : 0
        let rise = duration > 0 ? min(max(riseTime(net, binS: binS) / duration, 0), 1) : 0
        return FacadeLoadSurrogate.Prediction(peakPa: peak, impulsePaS: impulse, riseShare: rise, arrivalS: 0)
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
        /// The roofs (and the walls saved apart from the façades), by kind: the run against the
        /// surrogate and against its own triangle, with the surrogate's peak ratio (median, log sd).
        var parts: [String: PartsJudged]?
        /// With `--by-angle`: the groups and bands again on all lines, the diagonal ones and
        /// balanced by angle to the cells (emmettl/bombcad-work#107).
        var byAngle: ByAngle?
    }

    /// The judge split by the line's angle to the cells (`CellAngle`): each figure on all sides
    /// (or strips), on the diagonal lines alone, and balanced, each angle class weighted alike.
    struct ByAngle: Codable {
        struct Group: Codable {
            var name: String
            /// The surrogate's peak over the run's, median, by strip.
            var peakRatio: CellAngle.Figure
            /// Sides whose glass state the surrogate gives as the run does, and within one.
            var glassExact: CellAngle.Figure
            var glassWithinOne: CellAngle.Figure
        }

        struct Band: Codable {
            var from: Double
            var to: Double
            var peakRatio: CellAngle.Figure
            var runSidesAny: CellAngle.Figure
            var surrogateSidesAny: CellAngle.Figure
            var runSidesBlown: CellAngle.Figure
            var surrogateSidesBlown: CellAngle.Figure
            var glassExact: CellAngle.Figure
        }

        var groups: [Group] = []
        var bands: [Band] = []
    }

    struct PartsJudged: Codable {
        var count = 0
        var peakRatio = 0.0
        var peakLogSD = 0.0
        var surrogate = Agreement(states: EnvelopeDamageLevel.allCases.count)
        var oracle = Agreement(states: EnvelopeDamageLevel.allCases.count)
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

    package static func judge(_ args: [String]) throws {
        StudyOutput.lineBuffered()
        let reference = try Reference(args)
        let share = Float(value(args, "inside").flatMap(Double.init) ?? 0.85)
        let scene = reference.scene
        let objects = reference.objects
        let mass = Double(scene.charge.mass)
        let charge = scene.charge.position
        let open = reference.raster.openReach(around: charge)

        let coefficients = try SurrogateBench.coefficients(args)
        print("Coefficients fitted to \(coefficients.fittedTo)")
        // `--roof-coefficients file`: the roofs' own terms (fit-surrogate.py --drop facing on roofs).
        let roofCoefficients =
            try value(args, "roof-coefficients").map {
                try JSONDecoder().decode(
                    FacadeLoadSurrogate.Coefficients.self, from: Data(contentsOf: URL(filePath: $0)))
            } ?? .roofs
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
        // `--strips-out strips.csv`: each kept strip's run and surrogate peak and first-phase
        // impulse, and the surrogate's with its close-in branch off, for tracing where it errs
        // (emmettl/bombcad-work#56); with `--strips-only`, nothing else.
        if let path = value(args, "strips-out") {
            var withoutCloseIn = coefficients
            withoutCloseIn.closeIn = nil
            // The candidate: the branch for components in sight of the charge only.
            var inSight = coefficients
            inSight.closeIn?.inSightOnly = true
            var rows = [String](repeating: "", count: kept.count)
            rows.withUnsafeMutableBufferPointer { out in
                concurrentlyEach(kept.count) { m in
                    let (s, n, component) = reference.strips[kept[m]]
                    let strip = reference.index.strips[s]
                    let net = reference.net(s)
                    var f = FacadeLoadSurrogate.features(
                        component, owner: n, charge: charge, raster: reference.raster)
                    f.chargeOpenM = open
                    let p = FacadeLoadSurrogate.predict(
                        f, mass: mass, cellSize: Double(reference.predictionCell), coefficients: coefficients)
                    let q = FacadeLoadSurrogate.predict(
                        f, mass: mass, cellSize: Double(reference.predictionCell),
                        coefficients: withoutCloseIn)
                    let a = FacadeLoadSurrogate.predict(
                        f, mass: mass, cellSize: Double(reference.predictionCell), coefficients: inSight)
                    out[m] = String(
                        format:
                            "%d,%d,%d,%.2f,%.4f,%.2f,%.2f,%d,%.1f,%.1f,%.6g,%.6g,%.6g,%.6g,%.6g,%.6g,%.6g,%.6g,%.2f,%.1f,%.1f,%.1f,%.1f,%.1f",
                        n, strip.axis, strip.outward, f.distanceM, f.distanceM / cbrt(mass), f.heightM,
                        f.cosIncidence, f.buildingsCrossed, f.blockedM, f.canyonM, net.max() ?? 0,
                        SurrogateBench.firstImpulse(net, binS: strip.binS), p.peakPa, p.impulsePaS, q.peakPa,
                        q.impulsePaS, a.peakPa, a.impulsePaS, f.edgeM.isFinite ? f.edgeM : -999, f.shadowM,
                        f.lastTopM, f.edgeTopM, f.edgeSideM, f.edgeWidthM)
                }
            }
            let header =
                "object,axis,outward,distance,z,height,cos,crossed,blocked,canyon,run_peak,run_impulse,peak,impulse,peak_nobranch,impulse_nobranch,peak_insight,impulse_insight,edge,shadow,lasttop,edgetop,edgeside,edgewidth"
            try ([header] + rows).joined(separator: "\n").write(
                toFile: path, atomically: true, encoding: .utf8)
            print("Wrote \(kept.count) strips to \(path)")
            if args.contains("--strips-only") { return }
        }
        let tops = objects.map { Double(SurrogateBench.bounds($0).1.z) }
        let bases = objects.map { Double(SurrogateBench.bounds($0).0.z) }
        struct Outcome {
            var run: (concrete: Int, stone: Int, glass: GlazingBreakage, peak: Double, impulse: Double)
            var surrogate: (concrete: Int, stone: Int, glass: GlazingBreakage, peak: Double, impulse: Double)
            var oracle: (concrete: Int, stone: Int)
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
                // The glass under `glass` where given (the surrogate's pulse with the terms' glass
                // front), else under `load`, as the walls are.
                func judged(_ load: EnvelopeComponentLoad, glass: EnvelopeComponentLoad? = nil) -> (
                    Int, Int, GlazingBreakage, Double, Double
                ) {
                    let c = EnvelopeDamageAssessment.assess(
                        load, construction: concrete, buildingTop: tops[n], buildingBase: bases[n])
                    let st = EnvelopeDamageAssessment.assess(
                        load, construction: stone, buildingTop: tops[n], buildingBase: bases[n])
                    let net = load.netPa
                    return (
                        c?.levels.upperBound.rawValue ?? 0, st?.levels.upperBound.rawValue ?? 0,
                        mix.breakage(netPa: (glass ?? load).netPa, binS: load.binS, areaM2: strip.areaM2),
                        net.max() ?? 0, SurrogateBench.firstImpulse(net, binS: load.binS)
                    )
                }
                // Both judged alike: the same strip, its edges taken as held, only the load differing.
                let recorded = EnvelopeComponentLoad(
                    id: component.id, owner: id, kind: .facade, region: component.region,
                    axis: component.axis,
                    binS: strip.binS, outerPa: reference.net(s),
                    innerPa: Array(repeating: 0, count: strip.count),
                    supportEdges: nil, outward: component.outward)
                var f = FacadeLoadSurrogate.features(
                    component, owner: n, charge: charge, raster: reference.raster)
                f.chargeOpenM = open
                let prediction = FacadeLoadSurrogate.predict(
                    f, mass: mass, cellSize: Double(reference.predictionCell), coefficients: coefficients)
                var predicted = FacadeLoadSurrogate.load(component, prediction, binS: strip.binS)
                predicted.supportEdges = nil
                // With a glass front, the glass judged under its own pulse (emmettl/bombcad-work#103).
                let glassLoad = coefficients.glassFront.map { _ in
                    FacadeLoadSurrogate.load(
                        component, coefficients.forGlass(prediction, distanceM: f.distanceM, mass: mass),
                        binS: strip.binS)
                }
                var triangle = FacadeLoadSurrogate.load(
                    component, Self.oracle(recorded.netPa, binS: strip.binS), binS: strip.binS)
                triangle.supportEdges = nil
                let oracle = judged(triangle)
                out[m] = Outcome(
                    run: judged(recorded), surrogate: judged(predicted, glass: glassLoad),
                    oracle: (oracle.0, oracle.1),
                    crossed: f.buildingsCrossed, distance: f.distanceM)
            }
        }
        print(
            String(
                format: "Judged %d strips both ways in %.0f s", kept.count,
                StudyClock.seconds(clockJudge)))

        // Groups: all, by shielding, by distance band.
        let all = outcomes.map { $0! }
        let sideOf = kept.map { m -> [Int] in
            let (s, n, _) = reference.strips[m]
            let strip = reference.index.strips[s]
            return [n, strip.axis, strip.outward]
        }
        let root = cbrt(mass)
        var groups: [Group] = []
        var groupMembers: [[Int]] = []
        func group(_ name: String, _ members: [Int]) {
            guard !members.isEmpty else { return }
            groupMembers.append(members)
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
                g.oracleConcrete.add(all[m].run.concrete, all[m].oracle.concrete)
                g.oracleStone.add(all[m].run.stone, all[m].oracle.stone)
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
            g.oracleConcrete.finish()
            g.oracleStone.finish()
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
        var bandMembers: [[Int]] = []
        // `--sides-out sides.csv`: each building side in GEER's bands, where it stands against the
        // charge and its glass both ways, for tracing where the first look errs by direction
        // (emmettl/bombcad-work#106).
        var sideRows: [String] = []
        for band in DistrictGlass.geer {
            let members = indices.filter {
                let strip = reference.index.strips[reference.strips[kept[$0]].saved]
                let d = reference.index.buildings[strip.building].distanceM
                return d >= band.from && d < band.to
            }
            let sides = Dictionary(grouping: members, by: { sideOf[$0] })
            guard !sides.isEmpty else { continue }
            bandMembers.append(members)
            var counts = (0.0, 0.0, 0.0, 0.0)
            // In the sides' order, so that two runs sum alike (a dictionary's order is its process's).
            for (_, list) in sides.sorted(by: { $0.key.lexicographicallyPrecedes($1.key) }) {
                let run = list.reduce(GlazingBreakage()) { $0 + all[$1].run.glass }
                let surrogate = list.reduce(GlazingBreakage()) { $0 + all[$1].surrogate.glass }
                counts.0 += run.anyBroken
                counts.1 += surrogate.anyBroken
                counts.2 += run.fraction >= DistrictGlass.blownOutFraction ? 1 : 0
                counts.3 += surrogate.fraction >= DistrictGlass.blownOutFraction ? 1 : 0
                if value(args, "sides-out") != nil, let first = list.first {
                    let centre = FacadeLoadSurrogate.outerFace(reference.strips[kept[first]].component).centre
                    sideRows.append(
                        String(
                            format: "%.0f,%d,%d,%d,%.1f,%.1f,%.1f,%.4f,%.4f,%.4f,%.4f,%d",
                            band.from, sideOf[first][0], sideOf[first][1], sideOf[first][2],
                            all[first].distance,
                            Double(centre.x - charge.x), Double(centre.y - charge.y), run.fraction,
                            surrogate.fraction, run.anyBroken, surrogate.anyBroken, all[first].crossed))
                }
            }
            let k = Double(sides.count)
            bands.append(
                Band(
                    from: band.from, to: band.to, runSidesAny: counts.0 / k, surrogateSidesAny: counts.1 / k,
                    runSidesBlown: counts.2 / k, surrogateSidesBlown: counts.3 / k, geer: band.damaged,
                    geerBlown: band.blownOut))
        }
        if let path = value(args, "sides-out") {
            let header =
                "band,object,axis,outward,distance,dx,dy,run_fraction,surrogate_fraction,run_any,surrogate_any,crossed"
            try ([header] + sideRows).joined(separator: "\n").write(
                toFile: path, atomically: true, encoding: .utf8)
            print("Wrote \(sideRows.count) sides to \(path)")
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
            print(
                String(
                    format:
                        "The run's own triangle (oracle), where either calls it damaged: concrete %d, %.2f / %.2f; stone %d, %.2f / %.2f",
                    g.oracleConcrete.damaged, g.oracleConcrete.damagedExact,
                    g.oracleConcrete.damagedWithinOne,
                    g.oracleStone.damaged, g.oracleStone.damagedExact, g.oracleStone.damagedWithinOne))
            for (title, a, labels) in [
                ("Concrete", g.concrete, names), ("Stone", g.stone, names),
                ("Concrete, oracle", g.oracleConcrete, names), ("Stone, oracle", g.oracleStone, names),
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
        // The roofs and the walls saved apart from the façades, each by its own construction.
        var parts: [String: PartsJudged] = [:]
        if !reference.otherStrips.isEmpty {
            let keptParts = reference.otherStrips.indices.filter {
                reference.inside(
                    FacadeLoadSurrogate.outerFace(reference.otherStrips[$0].component).centre, share: share)
            }
            var judgedParts = [(kind: String, run: Int, surrogate: Int, oracle: Int, ratio: Double)?](
                repeating: nil, count: keptParts.count)
            judgedParts.withUnsafeMutableBufferPointer { out in
                concurrentlyEach(keptParts.count) { m in
                    let (s, n, component) = reference.otherStrips[keptParts[m]]
                    guard let parts = reference.others else { return }
                    let strip = parts.strips[s]
                    let id = objects[n].id
                    let construction = scene.envelopeConstruction(for: id)
                    let kind = EnvelopeComponentLoad.Kind(rawValue: component.kind.rawValue) ?? .wall
                    let net = reference.otherNet(s)
                    func level(_ load: EnvelopeComponentLoad) -> Int {
                        EnvelopeDamageAssessment.assess(
                            load, construction: construction, buildingTop: tops[n], buildingBase: bases[n]
                        )?.levels.upperBound.rawValue ?? 0
                    }
                    let recorded = EnvelopeComponentLoad(
                        id: component.id, owner: id, kind: kind, region: component.region,
                        axis: component.axis,
                        binS: strip.binS, outerPa: net, innerPa: Array(repeating: 0, count: net.count),
                        supportEdges: component.supportEdges, outward: component.outward)
                    var f = FacadeLoadSurrogate.features(
                        component, owner: n, charge: charge, raster: reference.raster)
                    f.chargeOpenM = open
                    let prediction = FacadeLoadSurrogate.predict(
                        f, mass: mass, cellSize: Double(reference.predictionCell),
                        coefficients: kind == .roof ? roofCoefficients : coefficients)
                    var predicted = FacadeLoadSurrogate.load(component, prediction, binS: strip.binS)
                    predicted.kind = kind
                    var triangle = FacadeLoadSurrogate.load(
                        component, Self.oracle(net, binS: strip.binS), binS: strip.binS)
                    triangle.kind = kind
                    let peak = net.max() ?? 0
                    out[m] = (
                        component.kind.rawValue, level(recorded), level(predicted), level(triangle),
                        peak > 0 && prediction.peakPa > 0 ? log(prediction.peakPa / peak) : .nan
                    )
                }
            }
            for (kind, list) in Dictionary(grouping: judgedParts.compactMap { $0 }, by: \.kind) {
                var p = PartsJudged()
                p.count = list.count
                let logs = list.map(\.ratio).filter(\.isFinite).sorted()
                if !logs.isEmpty {
                    let mean = logs.reduce(0, +) / Double(logs.count)
                    p.peakRatio = exp(logs[logs.count / 2])
                    p.peakLogSD = (logs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(logs.count))
                        .squareRoot()
                }
                for j in list {
                    p.surrogate.add(j.run, j.surrogate)
                    p.oracle.add(j.run, j.oracle)
                }
                p.surrogate.finish()
                p.oracle.finish()
                parts[kind] = p
                print(
                    String(
                        format:
                            "%@s: %d, surrogate's peak %.2f (%.2f) of the run's; where either calls it damaged, surrogate %d, %.2f / %.2f, oracle %d, %.2f / %.2f",
                        kind.capitalized as NSString, p.count, p.peakRatio, p.peakLogSD, p.surrogate.damaged,
                        p.surrogate.damagedExact, p.surrogate.damagedWithinOne, p.oracle.damaged,
                        p.oracle.damagedExact, p.oracle.damagedWithinOne))
                for (title, a) in [("surrogate", p.surrogate), ("oracle", p.oracle)] {
                    print(
                        "  \(kind.capitalized), \(title) (rows the run, columns \(title); \(names.joined(separator: ", "))):"
                    )
                    for row in a.confusion { print("    " + row.map { String(format: "%7d", $0) }.joined()) }
                }
            }
        }

        // `--by-angle`: the groups and bands again on all lines, the diagonal ones and balanced by
        // the line's angle to the cells (emmettl/bombcad-work#107).
        var byAngle: ByAngle?
        if args.contains("--by-angle") {
            let angleOf = kept.map { m -> CellAngle in
                let centre = FacadeLoadSurrogate.outerFace(reference.strips[m].component).centre
                return CellAngle(dx: Double(centre.x - charge.x), dy: Double(centre.y - charge.y))
            }
            func peaks(_ members: [Int]) -> CellAngle.Figure {
                let kept = members.filter { all[$0].run.peak > 0 && all[$0].surrogate.peak > 0 }
                return CellAngle.median(
                    kept.map { log(all[$0].surrogate.peak / all[$0].run.peak) }, kept.map { angleOf[$0] })
            }
            // Each side's glass both ways and its angle (its first strip's, as `--sides-out`), in
            // the sides' order.
            func sides(_ members: [Int]) -> (
                run: [GlazingBreakage], surrogate: [GlazingBreakage], angle: [CellAngle]
            ) {
                let grouped = Dictionary(grouping: members, by: { sideOf[$0] }).sorted {
                    $0.key.lexicographicallyPrecedes($1.key)
                }
                return (
                    grouped.map { $0.value.reduce(GlazingBreakage()) { $0 + all[$1].run.glass } },
                    grouped.map { $0.value.reduce(GlazingBreakage()) { $0 + all[$1].surrogate.glass } },
                    grouped.map { angleOf[$0.value[0]] }
                )
            }
            func agreement(_ s: (run: [GlazingBreakage], surrogate: [GlazingBreakage], angle: [CellAngle]))
                -> (CellAngle.Figure, CellAngle.Figure)
            {
                let pairs = zip(s.run, s.surrogate).map { (glassState($0), glassState($1)) }
                return (
                    CellAngle.mean(pairs.map { $0.0 == $0.1 ? 1 : 0 }, s.angle),
                    CellAngle.mean(pairs.map { abs($0.0 - $0.1) <= 1 ? 1 : 0 }, s.angle)
                )
            }
            var split = ByAngle()
            for (g, members) in zip(groups, groupMembers) {
                let (exact, withinOne) = agreement(sides(members))
                split.groups.append(
                    ByAngle.Group(
                        name: g.name, peakRatio: peaks(members), glassExact: exact, glassWithinOne: withinOne)
                )
            }
            for (b, members) in zip(bands, bandMembers) {
                let s = sides(members)
                let blown = { (g: GlazingBreakage) in g.fraction >= DistrictGlass.blownOutFraction ? 1.0 : 0 }
                split.bands.append(
                    ByAngle.Band(
                        from: b.from, to: b.to, peakRatio: peaks(members),
                        runSidesAny: CellAngle.mean(s.run.map(\.anyBroken), s.angle),
                        surrogateSidesAny: CellAngle.mean(s.surrogate.map(\.anyBroken), s.angle),
                        runSidesBlown: CellAngle.mean(s.run.map(blown), s.angle),
                        surrogateSidesBlown: CellAngle.mean(s.surrogate.map(blown), s.angle),
                        glassExact: agreement(s).0))
            }
            print(
                "By the line's angle to the cells (emmettl/bombcad-work#107), each as all / diagonal (30–45°) / balanced:"
            )
            print(
                "  group: peak ratio (median, by strip); glass exact; within one; sides axis / between / diagonal"
            )
            for g in split.groups {
                print(
                    "  \(g.name): peak \(CellAngle.show(g.peakRatio)); glass \(CellAngle.show(g.glassExact)); "
                        + "\(CellAngle.show(g.glassWithinOne)); \(g.glassExact.counts.map(String.init).joined(separator: " / "))"
                )
            }
            print(
                "  band: peak ratio; some broken, run | surrogate; blown out, run | surrogate; glass exact; sides axis / between / diagonal"
            )
            for b in split.bands {
                print(
                    String(
                        format: "  %4.0f–%4.0f m  ", b.from, b.to)
                        + "\(CellAngle.show(b.peakRatio));  \(CellAngle.show(b.runSidesAny)) | "
                        + "\(CellAngle.show(b.surrogateSidesAny));  \(CellAngle.show(b.runSidesBlown)) | "
                        + "\(CellAngle.show(b.surrogateSidesBlown));  \(CellAngle.show(b.glassExact));  "
                        + b.runSidesAny.counts.map(String.init).joined(separator: " / "))
            }
            byAngle = split
        }

        let result = Judged(
            massKg: mass, strips: kept.count, inside: Double(share), groups: groups,
            components: estimate.loads.count, loadsS: estimate.seconds, damageS: damageS,
            runWallS: value(args, "run-wall").flatMap(Double.init), bands: bands,
            parts: parts.isEmpty ? nil : parts, byAngle: byAngle)
        if let out = value(args, "out") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(result).write(to: URL(filePath: out))
        }
    }

    /// `body` for each of `count` on every core.
    package static func concurrentlyEach(_ count: Int, _ body: (Int) -> Void) {
        withoutActuallyEscaping(body) { body in
            nonisolated(unsafe) let shared = body
            DispatchQueue.concurrentPerform(iterations: count) { shared($0) }
        }
    }
}
