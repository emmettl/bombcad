import Foundation
import Metal
import simd

/// Blind test 3 (docs/blind-tests.md): K. A. Reynolds's high-strength slabs HSCV1–6 (UMKC MS
/// thesis, 2015) in the blast load simulator, the contest slab's rig (`SlabBenchmark`), built from
/// `Samples/Reynolds2015/inputs` alone. Every choice the inputs leave open is the predictor's,
/// declared in `Samples/Reynolds2015/predictions/assumptions.md` before any run.
///
/// The slab is meshed and held as the contest slab is (`SlabBenchmark.run`, the band's derived
/// mesh): cubic elements, 8 through the 4 in thickness, the pressure applied over the whole of
/// the loaded face, a pin and a roller on lines of nodes of the unloaded face, gravity ignored as
/// the slab stood upright. Only the concrete, the bars and the load are this test's.
public enum ReynoldsSlabTest {
    static let inch: Float = 0.0254
    static let psi: Float = 6894.76

    /// One slab of the series.
    public struct Slab: Sendable, Codable {
        public var name: String
        /// Bars along the span, centre to centre (in).
        public var barSpacingInches: Float
        /// Table 1's averages: peak (Pa) and impulse (Pa s).
        public var tablePeak: Float
        public var tableImpulse: Float
        /// The digitised average reflected pressure (s, Pa), from `loads.csv`.
        public var trace: [SIMD2<Float>]
        public var traceName: String
        /// The measured peak and residual (m), where the inputs give them (the open RSCR
        /// comparison; never for the blind HSCV slabs).
        public var measuredPeak: Float?
        public var measuredResidual: Float?
    }

    public struct Inputs: Sendable {
        public var slabs: [Slab]
        /// Cylinder strengths by age in days (Pa) and densities (kg/m³).
        public var cylinders: [(age: Int, strength: Float, density: Float)]
        /// The bars' yield after tensile testing (Pa).
        public var barYield: Float
    }

    public struct InputError: Error, LocalizedError {
        public var message: String
        public var errorDescription: String? { message }
    }

    /// Reads `slabs.json` and the `loads.csv` beside it.
    public static func inputs(from url: URL) throws -> Inputs {
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let concrete = root["concrete"] as? [String: Any],
            let cylinders = concrete["cylinders"] as? [[String: Any]],
            let loads = root["loads"] as? [String: Any],
            let table = loads["table1_average"] as? [String: Any],
            let slabs = root["slabs"] as? [String: Any], let names = slabs["names"] as? [String]
        else { throw InputError(message: "slabs.json lacks its concrete, loads or slabs") }
        let traces = try traces(from: url.deletingLastPathComponent().appending(path: "loads.csv"))
        func number(_ value: Any?) throws -> Float {
            guard let number = value as? NSNumber else {
                throw InputError(message: "not a number: \(value ?? "nil")")
            }
            return number.floatValue
        }
        let parsed = try names.map { name -> Slab in
            guard let row = table[name] as? [String: Any] else {
                throw InputError(message: "no Table 1 row for \(name)")
            }
            guard
                let (traceName, trace) = traces.first(where: {
                    $0.0.hasPrefix(name) || $0.0.contains(" and \(name) ")
                })
            else { throw InputError(message: "no digitised trace for \(name)") }
            let index = Int(name.dropFirst(4)) ?? 0
            return Slab(
                name: name, barSpacingInches: index <= 3 ? 4 : 8,
                tablePeak: try number(row["peak_kPa"]) * 1000,
                tableImpulse: try number(row["impulse_kPa_ms"]),
                trace: trace, traceName: traceName)
        }
        let yieldText = (root["reinforcement"] as? [String: Any])?["yield"] as? String ?? ""
        guard yieldText.contains("572.3") else {
            throw InputError(message: "the bars' yield is not 572.3 MPa")
        }
        return Inputs(
            slabs: parsed,
            cylinders: try cylinders.map {
                (
                    age: Int(try number($0["age_days"])), strength: try number($0["fc_MPa"]) * 1e6,
                    density: try number($0["density_kg_m3"])
                )
            },
            barYield: 572.3e6)
    }

    /// The traces of `loads.csv` in file order: name, then (s, Pa).
    static func traces(from url: URL) throws -> [(String, [SIMD2<Float>])] {
        let text = try String(contentsOf: url, encoding: .utf8)
        var traces: [(String, [SIMD2<Float>])] = []
        for line in text.split(whereSeparator: \.isNewline).dropFirst() {
            // "name",time_ms,pressure_psi,pressure_kPa
            guard let close = line.lastIndex(of: "\"") else { continue }
            let name = String(line[line.index(after: line.startIndex)..<close])
            let fields = line[line.index(after: close)...].split(separator: ",").compactMap { Float($0) }
            guard fields.count == 3 else { throw InputError(message: "bad loads.csv line: \(line)") }
            let point = SIMD2(fields[0] * 1e-3, fields[2] * 1000)
            if traces.last?.0 == name {
                traces[traces.count - 1].1.append(point)
            } else {
                traces.append((name, [point]))
            }
        }
        return traces
    }

    /// The open comparison after blind test 3's reveal: Reynolds's normal-strength 8 in slabs
    /// RSCR4–6, from `Samples/Reynolds2015/rscr/inputs.json`. The thesis gives each one's average
    /// peak and impulse but no history, so each takes a shape scaled to its impulse: with
    /// `contestShape` the contest slab's record (`SlabBenchmark.load`, as the record scaled it for
    /// the lower shot), otherwise the HSCV 8 in slab's load (its trace and tail, see `LoadShape.tail`)
    /// whose impulse is nearest. Run with `LoadShape.given`.
    public static func rscrInputs(from url: URL, hscv: Inputs, contestShape: Bool = false) throws -> Inputs {
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let loads = (root["loads"] as? [String: Any])?["table15"] as? [String: Any],
            let measured = root["measured"] as? [String: Any]
        else { throw InputError(message: "rscr/inputs.json lacks its loads or measurements") }
        func number(_ value: Any?) throws -> Float {
            guard let number = value as? NSNumber else {
                throw InputError(message: "not a number: \(value ?? "nil")")
            }
            return number.floatValue
        }
        let donors = hscv.slabs.filter { $0.barSpacingInches > 6 }
        let slabs = try ["RSCR4", "RSCR5", "RSCR6"].map { name -> Slab in
            guard let row = loads[name] as? [String: Any], let result = measured[name] as? [String: Any]
            else {
                throw InputError(message: "no Table 15 row for \(name)")
            }
            let impulse = try number(row["impulse_kPa_ms"])
            let shape: PressureLoad
            let shapeName: String
            if contestShape {
                shape = SlabBenchmark.load
                shapeName = "the contest slab's record (load 1a)"
            } else {
                guard
                    let donor = donors.min(by: {
                        abs($0.tableImpulse - impulse) < abs($1.tableImpulse - impulse)
                    })
                else { throw InputError(message: "no HSCV 8 in slab to take a shape from") }
                shape = load(donor, settings: Settings())
                shapeName = "\(donor.name)'s load (trace and tail)"
            }
            let scale = impulse / shape.impulse
            return Slab(
                name: name, barSpacingInches: 8, tablePeak: try number(row["peak_kPa"]) * 1000,
                tableImpulse: impulse, trace: shape.history.map { SIMD2($0.x, $0.y * scale) },
                traceName: String(format: "%@ × %.3f", shapeName, scale),
                measuredPeak: try number(result["peak_mm"]) / 1000,
                measuredResidual: try number(result["residual_mm"]) / 1000)
        }
        return Inputs(slabs: slabs, cylinders: [], barYield: hscv.barYield)
    }

    /// How the load is taken from the inputs.
    public enum LoadShape: String, Sendable, Codable, CaseIterable {
        /// The digitised trace as read, then falling linearly from its last point to zero so that
        /// the whole carries Table 1's average impulse (the primary).
        case tail
        /// The digitised trace, then to zero at 60 ms as Tables 6 and 7 end, the whole scaled to
        /// Table 1's impulse, as the contest's record was scaled to its stated impulse.
        case scaled
        /// The digitised trace as read, then to zero at 60 ms.
        case raw
        /// The slab's `trace` as it stands (the RSCR slabs' shapes, already scaled).
        case given
    }

    public struct Settings: Sendable, Codable {
        public var elementsThroughDepth = 8
        public var widthInches: Float = 33.75
        /// Between the supports' lines, centre to centre.
        public var spanInches: Float = 52
        /// The main bars' centres from the unloaded face (in): 1/2 in clear cover, under the cross
        /// bars, 0.5 + 0.375 + 0.1875.
        public var barDepthInches: Float = 1.0625
        /// Bars across the width, as Figs 3 and 4 draw them, for 4 in and 8 in spacing.
        public var barsAtFour: Float = 9
        public var barsAtEight: Float = 5
        /// Bars' area per width from the nominal spacing instead (71 mm² per 4 in or 8 in).
        public var nominalSpacing = false
        public var compressiveStrength: Float = 108.6e6
        public var density: Float = 2454
        public var ultimateStress: Float = 724e6
        public var ultimateStrain: Float = 0.07
        public var ruptureStrain: Float = 0.091
        public var load = LoadShape.tail
        public var loadFactor: Float = 1
        /// Bearings of this width (m) free to lift, in place of lines of nodes; nil for lines.
        public var bearingWidth: Float?
        public var duration: Double = 0.3
        /// The last stretch of the run over which the slab's rest is judged (s).
        public var restWindow: Float = 0.05
        /// A crack opening (largest reached) that counts an element broken across, as test 2's.
        public var brokenOpening: Float = 0.001
        /// Values of `ensembleInputs` where this run is an ensemble sample.
        public var sample: [String: Double] = [:]
        /// The contest slab's material (`SlabBenchmark.material`: 5,400 psi and its bars' measured
        /// Grade 60 curve) in place of the HSCV concrete and steel; the RSCR comparison's.
        public var contestMaterial = false
        public init() {}
    }

    /// The load applied to `slab`, pressure (Pa) against time (s) from the load's arrival.
    public static func load(_ slab: Slab, settings: Settings) -> PressureLoad {
        var history = slab.trace
        let last = history.last ?? .zero
        var load = PressureLoad(axis: 2, positiveSide: true, history: history)
        switch settings.load {
        case .tail:
            let missing = slab.tableImpulse - load.impulse
            if missing > 0, last.y > 0 {
                history.append(SIMD2(last.x + 2 * missing / last.y, 0))
            } else {
                history.append(SIMD2(max(last.x + 0.001, 0.06), 0))
            }
            load.history = history
        case .given:
            load.history = history
        case .scaled, .raw:
            history.append(SIMD2(max(last.x + 0.001, 0.06), 0))
            load.history = history
            if settings.load == .scaled {
                let scale = slab.tableImpulse / load.impulse
                load.history = history.map { SIMD2($0.x, $0.y * scale) }
            }
        }
        load.history = load.history.map { SIMD2($0.x, $0.y * settings.loadFactor) }
        return load
    }

    public static func steel(inputs: Inputs, settings: Settings) -> SteelProperties {
        SteelProperties(
            yieldStress: inputs.barYield, ultimateStress: settings.ultimateStress,
            ultimateStrain: settings.ultimateStrain, ruptureStrain: settings.ruptureStrain)
    }

    public static func material(inputs: Inputs, settings: Settings) -> StructureMaterial {
        if settings.contestMaterial {
            return ValidationEnsemble.perturbed(SlabBenchmark.material(rate: .strainRate), settings.sample)
        }
        var material = StructureMaterial.concrete(
            name: "Reynolds HSCV", compressiveStrength: settings.compressiveStrength,
            density: settings.density,
            steel: steel(inputs: inputs, settings: settings))
        material.rateDependent = true
        return ValidationEnsemble.perturbed(material, settings.sample)
    }

    /// The bars' area along the span per metre of width (m²/m).
    public static func barArea(_ slab: Slab, settings: Settings) -> Float {
        let bar: Float = 71e-6
        if settings.nominalSpacing { return bar / (slab.barSpacingInches * inch) }
        let count = slab.barSpacingInches < 6 ? settings.barsAtFour : settings.barsAtEight
        return count * bar / (settings.widthInches * inch)
    }

    public static func model(_ slab: Slab, inputs: Inputs, settings: Settings) -> StructureModel {
        let h = 4 * inch / Float(settings.elementsThroughDepth)
        let base = (1 / h).rounded() * h
        let box = Box(
            min: SIMD3(0, 0, base), max: SIMD3(64 * inch, settings.widthInches * inch, base + 4 * inch))
        var model = StructureModel(
            solids: [box], material: material(inputs: inputs, settings: settings), elementSize: h,
            fixedBase: false)
        let depth = Float(settings.sample["barDepth"] ?? Double(settings.barDepthInches)) * inch
        let area = barArea(slab, settings: settings) * Float(settings.sample["barArea"] ?? 1)
        // Cross bars No. 3, the first 8 in from each end then 12 in apart: 71 mm² per 12 in.
        model.addMat(
            to: box, thicknessAxis: 2, areaPerMetre: area, transverseAreaPerMetre: 71e-6 / (12 * inch),
            longitudinalAxis: 0, depth: depth, faces: (low: true, high: false))
        return model
    }

    /// What the run leaves of the slab.
    public struct Damage: Sendable, Codable {
        /// Whether intact concrete (active and cracked less than `brokenOpening`) still joins the
        /// two supports face to face.
        public var concreteSpans: Bool
        public var barElementsRuptured: Int
        public var removed: Int
        public var bare: Int
        /// Areas (m²) of the loaded face crushed past a strain of 0.0035, and of the loaded and
        /// unloaded faces removed or left as bare bars (spalled, scabbed).
        public var blastFaceCrushed: Float
        public var blastFaceGone: Float
        public var backFaceGone: Float
        /// Where along the span (mm from mid-span, + towards the roller) the loaded face is
        /// crushed, its extent.
        public var crushedFrom: Float?
        public var crushedTo: Float?
        /// The unloaded face's cracks across the span: for each column of elements along the
        /// span, mid-span at 0 (mm), the mean crack opening across the width (mm); and the
        /// columns whose mean opening is a local maximum above 0.1 mm.
        public var backFaceProfile: [SIMD2<Float>]
        public var mainCracks: [SIMD2<Float>]
        /// Each face's largest crack opening by element (mm), rows along y, x rising along each
        /// row; -1 removed, -2 bare.
        public var backCracks: [[Float]]
        public var blastCracks: [[Float]]
        /// As the solver draws it: `|` a crack across x, `-` across y, `x` gone, `.` uncracked.
        public var backPlan: [String]
        public var blastPlan: [String]
    }

    public struct Result: Sendable, Codable {
        public var slab: String
        public var settings: Settings
        public var elementSize: Float
        public var elementCount: Int
        public var appliedPeak: Float
        public var appliedImpulse: Float
        public var loadEnds: Float
        /// The unloaded face's centre, away from the blast positive (m), against time from the
        /// load's arrival (s), every 0.1 ms.
        public var history: [SIMD2<Float>]
        public var peak: Float
        public var peakTime: Float
        /// Mean over the run's last `restWindow`, and the range over it.
        public var residual: Float
        public var restRange: Float
        public var fails: Bool
        public var damage: Damage
        public var wallSeconds: Double
    }

    public static func run(
        device: MTLDevice, slab: Slab, inputs: Inputs, settings: Settings,
        progress: ((String) -> Void)? = nil
    ) throws -> Result {
        let model = model(slab, inputs: inputs, settings: settings)
        let solver = try StructureSolver(device: device, model: model)
        solver.gravity = 0
        solver.groundContact = false
        let load = load(slab, settings: settings)
        solver.appliedLoad = load

        // As `SlabBenchmark.run`: a pin and a roller on lines of nodes of the unloaded face, the
        // span apart about mid-length, or bearings free to lift.
        let h = model.elementSize
        let span = settings.spanInches * inch
        let first = Int(((64 * inch - span) / 2 / h).rounded())
        let second = Int(((64 * inch + span) / 2 / h).rounded())
        let bearing = settings.sample["bearing"].map { $0 > 0.5 ? Float(inch) : nil } ?? settings.bearingWidth
        solver.mutateNodes { nodes in
            func node(_ i: Int, _ j: Int, _ body: (inout StructureNode) -> Void) {
                if let index = solver.storedNode(i, j, 0) { body(&nodes[index]) }
            }
            for j in 0...solver.ey {
                if let width = bearing {
                    let reach = Int((width / 2 / h + 1e-3).rounded(.down))
                    for offset in -reach...reach {
                        for i in [first + offset, second + offset] { node(i, j) { $0.restsOnSupport = true } }
                    }
                    node(first, j) { $0.restrain(x: true) }
                } else {
                    node(first, j) { $0.restrain(x: true, z: true) }
                    node(second, j) { $0.restrain(z: true) }
                }
            }
        }

        let start = ContinuousClock.now
        var history: [SIMD2<Float>] = []
        let stepsPerSample = max(1, Int(0.0001 / solver.criticalTimeStep))
        var nextReport = 0.01
        while solver.time < settings.duration - 1e-9 {
            solver.advance(steps: stepsPerSample)
            history.append(SIMD2(Float(solver.time), -solver.displacement(solver.ex / 2, solver.ey / 2, 0).z))
            if solver.time >= nextReport {
                nextReport += 0.01
                progress?(
                    String(format: "%.0f ms: %.2f mm", solver.time * 1000, (history.last?.y ?? 0) * 1000))
            }
        }
        let elapsed = start.duration(to: .now)
        let peak = history.max { $0.y < $1.y } ?? .zero
        let end = Float(solver.time)
        let tail = history.filter { $0.x >= end - settings.restWindow }.map(\.y)
        let damage = damage(solver, first: first, second: second, settings: settings)
        return Result(
            slab: slab.name, settings: settings, elementSize: h, elementCount: solver.elementCount,
            appliedPeak: load.history.map(\.y).max() ?? 0, appliedImpulse: load.impulse,
            loadEnds: load.history.last?.x ?? 0,
            history: history, peak: peak.y, peakTime: peak.x,
            residual: tail.reduce(0, +) / Float(max(tail.count, 1)),
            restRange: (tail.max() ?? 0) - (tail.min() ?? 0),
            fails: !damage.concreteSpans || damage.barElementsRuptured > 0, damage: damage,
            wallSeconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18)
    }

    /// Reads the slab's state at the end of the run (see `Damage`).
    static func damage(_ solver: StructureSolver, first: Int, second: Int, settings: Settings) -> Damage {
        let h = solver.model.elementSize
        let (ex, ey, ez) = (solver.ex, solver.ey, solver.ez)
        func flat(_ i: Int, _ j: Int, _ k: Int) -> Int { i + ex * (j + ey * k) }
        var flags = [ElementFlag](repeating: .empty, count: ex * ey * ez)
        var opening = [Float](repeating: 0, count: ex * ey * ez)
        for k in 0..<ez {
            for j in 0..<ey {
                for i in 0..<ex {
                    flags[flat(i, j, k)] = solver.flag(i, j, k)
                    opening[flat(i, j, k)] = solver.crackOpening(i, j, k) * h
                }
            }
        }
        func intact(_ i: Int, _ j: Int, _ k: Int) -> Bool {
            flags[flat(i, j, k)] == .active && opening[flat(i, j, k)] < settings.brokenOpening
        }
        // Flood from the elements beside the pin's line through intact concrete to the roller's.
        var seen = Set<Int>()
        var stack: [(Int, Int, Int)] = []
        for j in 0..<ey {
            for k in 0..<ez where intact(first, j, k) {
                stack.append((first, j, k))
                seen.insert(flat(first, j, k))
            }
        }
        while let (i, j, k) = stack.popLast() {
            for (di, dj, dk) in [(1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1)] {
                let (a, b, c) = (i + di, j + dj, k + dk)
                guard a >= 0, a < ex, b >= 0, b < ey, c >= 0, c < ez, intact(a, b, c) else { continue }
                if seen.insert(flat(a, b, c)).inserted { stack.append((a, b, c)) }
            }
        }
        let concreteSpans = (0..<ey).contains { j in
            (0..<ez).contains { seen.contains(flat(second - 1, j, $0)) }
        }
        var ruptured = 0
        for k in 0..<ez {
            for j in 0..<ey {
                for i in 0..<ex where flags[flat(i, j, k)] != .empty && solver.steelRatio(i, j, k) != .zero {
                    let plastic = solver.barPlasticStrain(i, j, k)
                    if (0..<2).contains(where: { abs(plastic[$0]) >= 1e8 }) { ruptured += 1 }
                }
            }
        }
        let used = (0..<ey).filter { j in flags[flat(ex / 2, j, 0)] != .empty }
        let middle = Float(ex) / 2
        func x(_ i: Int) -> Float { (Float(i) + 0.5 - middle) * h * 1000 }
        var crushed: [Int] = []
        var crushedCount = 0
        for i in 0..<ex {
            var any = false
            for j in used where flags[flat(i, j, ez - 1)] == .active {
                if solver.plasticStrain(i, j, ez - 1) >= 0.0035 {
                    crushedCount += 1
                    any = true
                }
            }
            if any { crushed.append(i) }
        }
        func gone(_ k: Int) -> Int {
            var count = 0
            for j in used {
                for i in 0..<ex where flags[flat(i, j, k)] == .eroded || flags[flat(i, j, k)] == .bare {
                    count += 1
                }
            }
            return count
        }
        let profile = (0..<ex).map { i -> SIMD2<Float> in
            let values = used.map { j -> Float in
                let f = flags[flat(i, j, 0)]
                return f == .eroded || f == .bare ? 0 : opening[flat(i, j, 0)] * 1000
            }
            return SIMD2(x(i), values.reduce(0, +) / Float(max(values.count, 1)))
        }
        var main: [SIMD2<Float>] = []
        for i in profile.indices where profile[i].y > 0.1 {
            let left = i > 0 ? profile[i - 1].y : 0
            let right = i + 1 < profile.count ? profile[i + 1].y : 0
            if profile[i].y >= left && profile[i].y > right { main.append(profile[i]) }
        }
        func face(_ k: Int) -> [[Float]] {
            used.map { j in
                (0..<ex).map { i in
                    let n = flat(i, j, k)
                    return flags[n] == .eroded ? -1 : flags[n] == .bare ? -2 : opening[n] * 1000
                }
            }
        }
        return Damage(
            concreteSpans: concreteSpans, barElementsRuptured: ruptured,
            removed: flags.filter { $0 == .eroded }.count, bare: flags.filter { $0 == .bare }.count,
            blastFaceCrushed: Float(crushedCount) * h * h, blastFaceGone: Float(gone(ez - 1)) * h * h,
            backFaceGone: Float(gone(0)) * h * h,
            crushedFrom: crushed.first.map(x), crushedTo: crushed.last.map(x),
            backFaceProfile: profile, mainCracks: main, backCracks: face(0), blastCracks: face(ez - 1),
            backPlan: solver.crackPlan(layer: 0, threshold: 1e-4 / h),
            blastPlan: solver.crackPlan(layer: ez - 1, threshold: 1e-4 / h))
    }

    /// The inputs taken as uncertain for the predictor's estimate of quantity 1's uncertainty
    /// (see assumptions.md): values themselves (fc, bar depth, bearing) or factors on the
    /// primary's.
    public static let ensembleInputs: [EnsembleInput] = [
        EnsembleInput(
            key: "fc", name: "concrete compressive strength (Pa)",
            distribution: .uniform(low: 92.9e6, high: 115e6),
            source: "the slabs' age is not stated: from the 28-day cylinders to 6% above the 56-day"),
        ValidationEnsemble.tensile,
        ValidationEnsemble.fracture,
        EnsembleInput(
            key: "fy", name: "bar yield, as a factor", distribution: .normal(mean: 1, deviation: 0.03),
            source: "after tensile testing; 3%, as the ensembles take coupons"),
        EnsembleInput(
            key: "fu", name: "bar ultimate, as a factor on 724 MPa",
            distribution: .uniform(low: 0.9, high: 1.15),
            source: "not given: from 1.14 to 1.45 times the yield, assumed"),
        EnsembleInput(
            key: "load", name: "the load, as a factor", distribution: .normal(mean: 1, deviation: 0.03),
            source: "digitised to about 0.5 psi; the figures' impulse curves 1–3% from the traces"),
        EnsembleInput(
            key: "bearing", name: "supports: lines of nodes (≤ 0.5) or 1 in bearings free to lift",
            distribution: .uniform(low: 0, high: 1), source: "as the contest slab's ensemble"),
        EnsembleInput(
            key: "barDepth", name: "main bars' centres from the unloaded face (in)",
            distribution: .uniform(low: 0.6875, high: 1.0625),
            source: "which bars lie nearer the face is not stated"),
        EnsembleInput(
            key: "barArea", name: "main bars' area, as a factor on the drawn count",
            distribution: .uniform(low: 0.84, high: 1),
            source: "the drawn count (9, 5) against the nominal spacing (8.4, 4.2 bars in 33.75 in)"),
    ]

    /// `count` Latin-hypercube samples of `ensembleInputs` seeded with `seed`.
    public static func ensembleSamples(count: Int, seed: UInt64) -> [[String: Double]] {
        latinHypercube(count: count, dimensions: ensembleInputs.count, seed: seed).map { point in
            Dictionary(
                uniqueKeysWithValues: zip(ensembleInputs, point).map {
                    ($0.key, $0.distribution.value(at: $1))
                })
        }
    }

    /// `settings` with an ensemble sample's values: fc in pascals, the rest as `ensembleInputs`
    /// say.
    public static func settings(_ settings: Settings, values: [String: Double]) -> Settings {
        var s = settings
        s.sample = values
        if let load = values["load"] { s.loadFactor = Float(load) }
        return s
    }
}
