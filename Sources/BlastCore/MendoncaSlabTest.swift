import Foundation
import Metal
import simd

/// Blind test 2 (docs/blind-tests.md): Mendonça et al.'s reinforced concrete slabs, 1.0 m square
/// and 80 mm thick with one mat of bars near the bottom face, resting on timber trestles along two
/// opposite sides 0.4 m above clay, under about 2.7 kg TNT-equivalent of unconfined PBX hung 1.3,
/// 1.6 or 2.0 m above their centres. Built from `Samples/Mendonca2020/inputs/slabs.json` alone;
/// every choice the inputs leave open is set out, with its reason, in
/// `Samples/Mendonca2020/predictions/assumptions.md`.
///
/// Coordinates: x along the span, between the trestles; y along the supported edges; z up from the
/// ground. The slab spans x and y from 1.0 to 2.0 m, in a domain 3.0 m square.
public enum MendoncaSlabTest {
    /// The steel of the three layouts (reinforcement.layouts).
    public enum Layout: String, Sendable, Codable {
        /// 5 mm bars at 15 cm both ways, and two 10 mm bars near the middle one way.
        case a = "A"
        /// 5 mm bars at 10 cm both ways.
        case b = "B"
        /// 5 mm bars at 15 cm both ways.
        case c = "C"

        /// Bars of the 5 mm mesh across a metre: "7 bars each way" at 15 cm, "about 10" at 10 cm.
        public var meshBarsPerMetre: Float { self == .b ? 10 : 7 }
    }

    /// One slab as the inputs give it, in SI units.
    public struct Slab: Sendable, Codable {
        public var name: String
        public var layout: Layout
        public var compressiveStrength: Float
        public var charge: Float
        /// Above the slab's upper surface (charge.standoff_note).
        public var standoff: Float
        /// From the slab's mass where the inputs give it (slabs 2 and 5), else the mean of those two.
        public var density: Float
    }

    public struct Inputs: Sendable {
        public var slabs: [Slab]
        public var plan: Float
        public var thickness: Float
        /// Of the slab's bottom face above the ground (supports.height_above_ground_m).
        public var height: Float
        /// Each trestle "0.80 m long" (supports.trestles).
        public var trestleLength: Float = 0.8
        /// "2.5 cm from the bottom face to the bars' level" (reinforcement.position).
        public var barDepth: Float = 0.025
        /// "5.0 mm bars"; "two 10 mm bars side by side near the middle"; "10 mm at 10 cm".
        public var meshBar: Float = 0.005
        public var heavyBar: Float = 0.010
        public var heavyBars = 2
        public var heavySpacing: Float = 0.10
        /// "350, given by the 2021 paper as an estimate" (reinforcement.steel.yield_MPa).
        public var yieldStress: Float = 350e6
    }

    public struct InputError: Error, LocalizedError {
        public var message: String
        public var errorDescription: String? { message }
    }

    /// Reads `slabs.json`: the numbers it holds as numbers are read from it; those it gives only
    /// in words are the defaults of `Inputs`, each quoted where it is declared.
    public static func inputs(from url: URL) throws -> Inputs {
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InputError(message: "\(url.path) is not a JSON object.")
        }
        func object(_ value: Any?, _ name: String) throws -> [String: Any] {
            guard let value = value as? [String: Any] else {
                throw InputError(message: "No \(name) in the inputs.")
            }
            return value
        }
        func number(_ value: Any?, _ name: String) throws -> Float {
            guard let value = value as? NSNumber else {
                throw InputError(message: "No number \(name) in the inputs.")
            }
            return value.floatValue
        }
        let slab = try object(root["slab"], "slab")
        guard let plan = slab["plan_m"] as? [NSNumber], plan.count == 2, plan[0] == plan[1] else {
            throw InputError(message: "The inputs' slab is not square.")
        }
        let thickness = try number(slab["thickness_m"], "slab.thickness_m")
        let concrete = try object(root["concrete"], "concrete")
        let strengths = try object(concrete["nominal_and_tested_fck_MPa"], "nominal_and_tested_fck_MPa")
        let supports = try object(root["supports"], "supports")
        let charge = try object(root["charge"], "charge")
        let masses = try object(charge["tnt_equivalent_kg_by_slab"], "tnt_equivalent_kg_by_slab")
        let standoffs = try object(charge["standoff_h_m_by_slab"], "standoff_h_m_by_slab")
        let specimens = try object(root["specimens"], "specimens")
        // "180 for slab 2 and 175 for slab 5"; not given for the others.
        let volume = plan[0].floatValue * plan[1].floatValue * thickness
        let weighed: [String: Float] = ["2": 180 / volume, "5": 175 / volume]
        let meanDensity = weighed.values.reduce(0, +) / Float(weighed.count)
        let names = specimens.keys.filter { Int($0) != nil }.sorted { Int($0)! < Int($1)! }
        let slabs = try names.map { name -> Slab in
            let specimen = try object(specimens[name], name)
            guard let grade = (specimen["concrete"] as? String)?.split(separator: " ").first.map(String.init),
                let layoutName = specimen["layout"] as? String, let layout = Layout(rawValue: layoutName)
            else { throw InputError(message: "Specimen \(name) has no concrete or layout.") }
            return Slab(
                name: name, layout: layout,
                compressiveStrength: try number(strengths[grade], "fck for \(grade)") * 1e6,
                charge: try number(masses[name], "charge for \(name)"),
                standoff: try number(standoffs[name], "stand-off for \(name)"),
                density: weighed[name] ?? meanDensity)
        }
        return Inputs(
            slabs: slabs, plan: plan[0].floatValue, thickness: thickness,
            height: try number(supports["height_above_ground_m"], "height_above_ground_m"))
    }

    /// What the inputs leave to the user of the tool (see assumptions.md), and the factors the
    /// predictor's own ensemble varies (all 1 in the primary prediction).
    public struct Settings: Sendable, Codable {
        public var elementsThroughDepth = 8
        /// The air's cells, and refinement near the shock and the mapped start (both model options,
        /// off by default).
        public var cellSize: Float = 0.0125
        public var refinement = 1
        public var mappedCharge = false
        /// Keep the air awake to the end of the run (a secondary run; by default it is frozen once
        /// quiet or after five crossings of the domain, and the structure then moves on in it).
        public var airAwake = false
        public var duration: Double = 0.2
        /// The timber the slab bears on along each supported edge, flush with the slab's edge, and
        /// the depth of the trestles' top rail as an obstacle in the air.
        public var bearingWidth: Float = 0.1
        public var railDepth: Float = 0.1
        /// The trestles' top rails as elastic timber bonded under the slab, resting on their
        /// supports in its place (a secondary run), rather than rigid supports under the slab's own
        /// face: softwood loaded across its grain, C24's mean modulus perpendicular to the grain
        /// (EN 338) and its mean density.
        public var timberBearings = false
        public var timberModulus: Float = 370e6
        public var timberDensity: Float = 420
        /// Slab A's two 10 mm bars along the span (x); false, across it.
        public var heavyBarsAlongSpan = true
        /// The charge's centre this far above the stand-off the inputs give (0: the stand-off is to
        /// its centre; 0.1: to the bottom of the 20 cm cylinder).
        public var chargeLift: Float = 0
        /// The pressure gauges' distance in from each edge at the corners.
        public var gaugeInset: Float = 0.05
        /// Studies after the reveal: the air beyond the slab's edges, and the domain's height (the
        /// blind runs' 1 m and 3.2 m); and a rigid block filling the space under the slab between
        /// its bearings, up to `underBlockGap` below it, nil for none.
        public var margin: Float = 1
        public var domainHeight: Float = 3.2
        public var underBlockGap: Float?
        /// Studies after the reveal: the bearings as soft ground under the slab instead of rigid
        /// lines, a Winkler bed of this subgrade modulus (Pa/m) over the bearings' area, yielding
        /// at `softSupportCapacity` (Pa), for trestles on clay; nil for the rigid bearings.
        public var softSupportModulus: Float?
        public var softSupportCapacity: Float = 600e3
        /// The crack opening (largest reached) that counts an element broken across.
        public var brokenOpening: Float = 0.001
        public var sampleInterval: Double = 1e-4
        public var pressureInterval: Double = 1e-5
        public var pressureRecord: Double = 0.03
        // The ensemble's factors.
        public var fcFactor: Float = 1
        public var ftFactor: Float = 1
        public var gfFactor: Float = 1
        public var fyFactor: Float = 1
        public var chargeFactor: Float = 1

        public init() {}
    }

    /// The bars: the stated estimate of the yield, with the hardening, ultimate and rupture strains
    /// of the model's typical 500 MPa bar (`SteelProperties.grade500`) scaled to it.
    public static func steel(inputs: Inputs, settings: Settings) -> SteelProperties {
        let preset = SteelProperties.grade500
        let fy = inputs.yieldStress * settings.fyFactor
        return SteelProperties(
            yieldStress: fy, ultimateStress: fy * preset.ultimateStress / preset.yieldStress,
            ultimateStrain: preset.ultimateStrain, ruptureStrain: preset.ruptureStrain)
    }

    /// The concrete at its tested strength, its other properties from the model's correlations,
    /// strengthening with strain rate as the app's reinforced concrete and every calibrated slab do.
    public static func material(_ slab: Slab, inputs: Inputs, settings: Settings) -> StructureMaterial {
        var material = StructureMaterial.concrete(
            name: "Mendonça slab \(slab.name)",
            compressiveStrength: slab.compressiveStrength * settings.fcFactor,
            density: slab.density, steel: steel(inputs: inputs, settings: settings))
        material.tensileStrength *= settings.ftFactor
        material.fractureEnergy *= settings.gfFactor
        material.crushingEnergy *= settings.gfFactor
        material.rateDependent = true
        return material
    }

    public static func slabBox(inputs: Inputs, settings: Settings = Settings()) -> Box {
        let m = settings.margin
        return Box(
            min: SIMD3(m, m, inputs.height),
            max: SIMD3(m + inputs.plan, m + inputs.plan, inputs.height + inputs.thickness))
    }

    /// The blind runs' domain, 3.0 × 3.0 × 3.2 m.
    public static let domain = SIMD3<Float>(3.0, 3.0, 3.2)

    public static func domain(inputs: Inputs, settings: Settings) -> SIMD3<Float> {
        let side = 2 * settings.margin + inputs.plan
        return SIMD3(side, side, settings.domainHeight)
    }

    /// The pressure gauges on the slab's top face, in the air against it: the four corners (the
    /// dataset's 1, 3, 4 and 6), the centre, and the four mid-sides (2, 5, 7 and 8) for interest;
    /// and one under the centre of the bottom face. Laid out as the inputs' sketch, its rows along
    /// the supported edges: 6 7 4 at the far support (x high), 2 and 8 at mid-span, 3 5 1 at the
    /// near support (x low), y rising from left to right.
    public static func gauges(inputs: Inputs, settings: Settings) -> [Gauge] {
        let s = slabBox(inputs: inputs, settings: settings)
        let d = settings.gaugeInset
        let lift: Float = 0.005
        let top = s.max.z + lift
        let xs: [Float] = [s.min.x + d, (s.min.x + s.max.x) / 2, s.max.x - d]
        let ys: [Float] = [s.min.y + d, (s.min.y + s.max.y) / 2, s.max.y - d]
        return [
            Gauge("1 (corner)", at: SIMD3(xs[0], ys[2], top)),
            Gauge("3 (corner)", at: SIMD3(xs[0], ys[0], top)),
            Gauge("4 (corner)", at: SIMD3(xs[2], ys[2], top)),
            Gauge("6 (corner)", at: SIMD3(xs[2], ys[0], top)),
            Gauge("centre", at: SIMD3(xs[1], ys[1], top)),
            Gauge("2 (mid-side)", at: SIMD3(xs[1], ys[0], top)),
            Gauge("5 (mid-side)", at: SIMD3(xs[0], ys[1], top)),
            Gauge("7 (mid-side)", at: SIMD3(xs[2], ys[1], top)),
            Gauge("8 (mid-side)", at: SIMD3(xs[1], ys[2], top)),
            Gauge("under the centre", at: SIMD3(xs[1], ys[1], s.min.z - lift)),
        ]
    }

    /// The slab meshed with solid elements, its mat smeared through a band one element deep at
    /// the bars' level; the trestles' top rails under the bearings as rigid blocks in the air; the
    /// charge as TNT at its stand-off above the centre.
    public static func scenario(_ slab: Slab, inputs: Inputs, settings: Settings) -> Scenario {
        let s = slabBox(inputs: inputs, settings: settings)
        let h = inputs.thickness / Float(settings.elementsThroughDepth)
        var model = StructureModel(
            solids: [s], material: material(slab, inputs: inputs, settings: settings), elementSize: h,
            fixedBase: false)
        let bar = Float.pi * inputs.meshBar * inputs.meshBar / 4
        var band = s
        band.min.z = s.min.z + inputs.barDepth - h / 2
        band.max.z = s.min.z + inputs.barDepth + h / 2
        let mesh = slab.layout.meshBarsPerMetre * bar / h
        model.reinforcement = [ReinforcementLayer(region: band, ratio: SIMD3(mesh, mesh, 0))]
        if slab.layout == .a {
            // Two bars 10 cm apart about the middle, each over its 10 cm.
            let heavy = Float.pi * inputs.heavyBar * inputs.heavyBar / 4
            let width = Float(inputs.heavyBars) * inputs.heavySpacing
            var strip = band
            let across = settings.heavyBarsAlongSpan ? 1 : 0
            let middle = (s.min[across] + s.max[across]) / 2
            strip.min[across] = middle - width / 2
            strip.max[across] = middle + width / 2
            var ratio = SIMD3<Float>.zero
            ratio[1 - across] = heavy / (inputs.heavySpacing * h)
            model.reinforcement.append(ReinforcementLayer(region: strip, ratio: ratio))
        }
        let c = SIMD2((s.min.x + s.max.x) / 2, (s.min.y + s.max.y) / 2)
        let half = inputs.trestleLength / 2
        let rails = [
            Box(
                min: SIMD3(s.min.x, c.y - half, s.min.z - settings.railDepth),
                max: SIMD3(s.min.x + settings.bearingWidth, c.y + half, s.min.z)),
            Box(
                min: SIMD3(s.max.x - settings.bearingWidth, c.y - half, s.min.z - settings.railDepth),
                max: SIMD3(s.max.x, c.y + half, s.min.z)),
        ]
        if let modulus = settings.softSupportModulus {
            // The slab's underside over each bearing, tied to soft ground that does not pull.
            for rail in rails {
                model.supports.append(
                    Box(
                        min: SIMD3(rail.min.x, rail.min.y, s.min.z - h / 2),
                        max: SIMD3(rail.max.x, rail.max.y, s.min.z + h / 2)))
                model.supportAnchorages.append(
                    .soil(
                        subgradeModulus: modulus, bearingCapacity: settings.softSupportCapacity, friction: 0.5
                    ))
            }
        }
        if settings.timberBearings {
            model.solids += rails
            for index in 1...rails.count {
                model.setMaterial(
                    .elastic(
                        density: settings.timberDensity, youngsModulus: settings.timberModulus,
                        poissonRatio: 0.3),
                    of: index)
            }
        }
        let position = SIMD3(c.x, c.y, s.max.z + slab.standoff + settings.chargeLift)
        let underBlock =
            settings.underBlockGap.map { gap in
                [
                    Box(
                        min: SIMD3(s.min.x + settings.bearingWidth, s.min.y, 0),
                        max: SIMD3(s.max.x - settings.bearingWidth, s.max.y, s.min.z - gap))
                ]
            } ?? []
        return Scenario(
            name: "Mendonça slab \(slab.name)", domainSize: domain(inputs: inputs, settings: settings),
            boxes: (settings.timberBearings || settings.softSupportModulus != nil ? [] : rails) + underBlock,
            charge: Charge(mass: slab.charge * settings.chargeFactor, position: position),
            gauges: gauges(inputs: inputs, settings: settings), structure: model)
    }

    /// One gauge's record, as its peak overpressure and its impulse.
    public struct GaugeResult: Sendable, Codable {
        public var name: String
        public var position: SIMD3<Float>
        public var peak: Float
        public var arrival: Float?
        /// The impulse of the first positive phase, from arrival until the overpressure first falls
        /// back below zero, and of all the positive overpressure in the run.
        public var impulse: Float
        public var impulseAllPositive: Float
    }

    /// What the run leaves of the slab.
    public struct Damage: Sendable, Codable {
        /// Whether intact concrete (neither removed, left as bare bars, nor cracked open by
        /// `brokenOpening`) still joins the two bearings face to face; whether the mat's unruptured
        /// bars do.
        public var concreteSpans: Bool
        public var barsSpan: Bool
        public var collapses: Bool
        /// Pieces of concrete (active or bare elements joined face to face) of at least 10
        /// elements, and the largest's share of the slab.
        public var pieces: Int
        public var largestShare: Float
        public var removed: Int
        public var bare: Int
        public var barElementsRuptured: Int
        /// Areas (m²) of the top face removed or bare (spalled or crushed out), crushed past a strain
        /// of 0.0035, and of the bottom face removed or bare (scabbed).
        public var topGone: Float
        public var topCrushed: Float
        public var bottomGone: Float
        /// The crack field: each face's largest crack opening by element (mm), rows along y, x
        /// rising along each row; -1 removed, -2 bare.
        public var bottomCracks: [[Float]]
        public var topCracks: [[Float]]
        /// As the solver draws it: `|` a crack across x, `-` across y, `x` gone, `.` uncracked.
        public var bottomPlan: [String]
        public var topPlan: [String]
    }

    public struct Result: Sendable, Codable {
        public var slab: Slab
        public var settings: Settings
        public var elementSize: Float
        public var elementCount: Int
        public var cellCount: Int
        /// Of the bottom face's centre (the lowest node there still held by an element), down
        /// positive (m), from the start.
        public var peakDisplacement: Float
        public var peakTime: Float
        public var endDisplacement: Float
        /// The mean over the last 10 ms.
        public var endDisplacementMean: Float
        public var largestRebound: Float
        public var history: [SIMD2<Float>]
        /// Every sample: time, the slab's mass-weighted mean vertical displacement (up positive),
        /// and the vertical displacement of the middle node of each bearing's middle line on the
        /// slab's bottom face, near and far (m). Description, to read the slab's flight by.
        public var bodyHistory: [SIMD4<Float>] = []
        public var gauges: [GaugeResult]
        /// Each gauge's overpressure (Pa) on a grid of `pressureInterval` to `pressureRecord`.
        public var pressureHistory: [[Float]]
        public var damage: Damage
        public var blownUp: Bool
        public var airSleptAt: Double?
        public var wallSeconds: Double
    }

    /// Runs `slab`. For studies after the reveal, `adjust` changes the scene and `configure` the air
    /// solver before it is loaded; both leave it as the blind prediction had it by default.
    public static func run(
        device: MTLDevice, slab: Slab, inputs: Inputs, settings: Settings = Settings(),
        adjust: (inout Scenario) -> Void = { _ in }, configure: (BlastSolver) -> Void = { _ in },
        progress: ((String) -> Void)? = nil
    ) throws -> Result {
        var scenario = scenario(slab, inputs: inputs, settings: settings)
        adjust(&scenario)
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: settings.cellSize)
        solver.configuration.refinement = settings.refinement
        solver.configuration.mappedCharge = settings.mappedCharge
        configure(solver)
        if settings.airAwake {
            solver.configuration.airSleepThreshold = 0
            solver.configuration.airSleepCrossings = 0
        }
        try solver.load(scenario)
        guard let structure = solver.structure else { throw BlastError.allocationFailed("structure") }
        let s = slabBox(inputs: inputs, settings: settings)
        let h = structure.model.elementSize
        func index(_ value: Float, _ axis: Int) -> Int {
            Int(((value - structure.origin[axis]) / h).rounded())
        }
        let bottom = index(s.min.z, 2)
        let top = index(s.max.z, 2)
        let ci = index((s.min.x + s.max.x) / 2, 0)
        let cj = index((s.min.y + s.max.y) / 2, 1)
        let low = index(s.min.y + (inputs.plan - inputs.trestleLength) / 2, 1)
        let high = index(s.max.y - (inputs.plan - inputs.trestleLength) / 2, 1)
        let bearing = Int((settings.bearingWidth / h).rounded())
        let near = index(s.min.x, 0)
        let far = index(s.max.x, 0)
        // Resting on the trestles' timber, free to lift off; held along the span at the near
        // bearing's middle line, and across at the middle of each. With timber bearings, their
        // undersides rest so.
        let seat = settings.timberBearings ? index(s.min.z - settings.railDepth, 2) : bottom
        if settings.softSupportModulus == nil {
            structure.mutateNodes { nodes in
                for j in low...high {
                    for i in Array(near...(near + bearing)) + Array((far - bearing)...far) {
                        guard let n = structure.storedNode(i, j, seat) else { continue }
                        nodes[n].restsOnSupport = true
                        if i == near + bearing / 2 { nodes[n].restrain(x: true) }
                        if j == cj && (i == near + bearing / 2 || i == far - bearing / 2) {
                            nodes[n].restrain(y: true)
                        }
                    }
                }
            }
        }
        func attached(_ i: Int, _ j: Int, _ k: Int) -> Bool {
            for a in (i - 1)...i {
                for b in (j - 1)...j {
                    for c in (k - 1)...k where c >= bottom && c < top {
                        let flag = structure.flag(a, b, c)
                        if flag == .active || flag == .bare { return true }
                    }
                }
            }
            return false
        }
        func centre() -> Float {
            let k = (bottom...top).first { attached(ci, cj, $0) } ?? top
            return -structure.displacement(ci, cj, k).z
        }

        // The gauges sat on the slab and moved with it: each reads the first air cell beyond the
        // slab's face at its point as it is now, and is moved there whenever that changes (a cell
        // the face has moved into is solid, and holds a stale state).
        let dx = solver.grid.cellSize
        let points = scenario.gauges.map(\.position)
        var cells = points.map { solver.nearestFluidCell(to: $0) }
        func followSlab() {
            var moved = cells
            for (n, point) in points.enumerated() {
                let above = point.z > s.max.z
                let (i, j) = (index(point.x, 0), index(point.y, 1))
                guard structure.storedNode(i, j, above ? top : bottom) != nil,
                    attached(i, j, above ? top : bottom)
                else { continue }
                let face = structure.position(i, j, above ? top : bottom).z
                var k = Int((face / dx).rounded(.down))
                let c = cells[n]
                while k >= 0, k < solver.grid.nz, solver.isSolid(c.i, c.j, k) { k += above ? 1 : -1 }
                moved[n].k = min(max(k, 0), solver.grid.nz - 1)
            }
            guard moved.map(\.k) != cells.map(\.k) else { return }
            let histories = solver.gaugeHistories
            cells = moved
            solver.setGauges(
                cells: cells,
                points: zip(points, cells).map { SIMD3($0.0.x, $0.0.y, (Float($0.1.k) + 0.5) * dx) })
            for (n, samples) in histories.enumerated() { solver.prependGaugeHistory(n, samples) }
        }

        func meanLift() -> Float {
            var weighted: Double = 0
            var total: Double = 0
            structure.mutateNodes { nodes in
                for node in nodes {
                    weighted += Double(node.mass) * Double(node.uz)
                    total += Double(node.mass)
                }
            }
            return Float(weighted / max(total, 1e-12))
        }
        var bodyHistory: [SIMD4<Float>] = [.zero]

        let start = ContinuousClock.now
        var history: [SIMD2<Float>] = [SIMD2(0, 0)]
        var nextSample = settings.sampleInterval
        var nextReport = 0.01
        var blownUp = false
        var slept: Double?
        while solver.time < settings.duration {
            let result = solver.advance(steps: 4, timeLimit: settings.duration)
            if !result.isStable {
                blownUp = true
                break
            }
            if result.steps == 0 && !solver.airIsAsleep { break }
            if slept == nil && solver.airIsAsleep { slept = solver.time }
            if !solver.airIsAsleep { followSlab() }
            if solver.time >= nextSample - 1e-9 {
                let u = centre()
                if !u.isFinite {
                    blownUp = true
                    break
                }
                history.append(SIMD2(Float(solver.time), u))
                bodyHistory.append(
                    SIMD4(
                        Float(solver.time), meanLift(),
                        structure.displacement(near + bearing / 2, cj, bottom).z,
                        structure.displacement(far - bearing / 2, cj, bottom).z))
                while nextSample <= solver.time + 1e-9 { nextSample += settings.sampleInterval }
            }
            if let progress, solver.time >= nextReport {
                nextReport += 0.01
                progress(
                    String(
                        format: "%4.0f ms: centre %6.2f mm, %d elements failed%@", solver.time * 1000,
                        (history.last?.y ?? 0) * 1000, structure.summary().erodedElements,
                        solver.airIsAsleep ? ", air asleep" : ""))
            }
        }
        let elapsed = ContinuousClock.now - start

        let peak = history.max { $0.y < $1.y } ?? .zero
        let afterPeak = history.filter { $0.x > peak.x }.map(\.y)
        let end = history.last ?? .zero
        let tail = history.filter { $0.x >= end.x - 0.01 }
        let ambient = scenario.atmosphere.pressure
        let gaugeResults = zip(scenario.gauges, solver.gaugeHistories).map { gauge, samples -> GaugeResult in
            let over = samples.map { (time: $0.time, p: $0.pressure - ambient) }
            let arrival = over.first { $0.p > 2e3 }?.time
            var first: Float = 0
            var all: Float = 0
            var inFirst = arrival != nil
            for (a, b) in zip(over, over.dropFirst()) {
                let mean = Float(0.5 * (Double(a.p) + Double(b.p)))
                let dt = Float(b.time - a.time)
                all += dt * max(mean, 0)
                if let arrival, a.time >= arrival, inFirst {
                    if b.p < 0 { inFirst = false } else { first += dt * mean }
                }
            }
            return GaugeResult(
                name: gauge.name, position: gauge.position, peak: over.map(\.p).max() ?? 0,
                arrival: arrival.map(Float.init), impulse: first, impulseAllPositive: all)
        }
        let grid = stride(from: 0.0, through: settings.pressureRecord, by: settings.pressureInterval)
        let pressureHistory = solver.gaugeHistories.map { samples -> [Float] in
            var n = 0
            return grid.map { t in
                guard let first = samples.first, t >= first.time else { return 0 }
                while n + 1 < samples.count && samples[n + 1].time <= t { n += 1 }
                guard n + 1 < samples.count else { return samples[n].pressure - ambient }
                let a = samples[n]
                let b = samples[n + 1]
                let f = Float((t - a.time) / max(b.time - a.time, 1e-12))
                return a.pressure + (b.pressure - a.pressure) * f - ambient
            }
        }
        return Result(
            slab: slab, settings: settings, elementSize: h, elementCount: structure.elementCount,
            cellCount: solver.grid.cellCount, peakDisplacement: peak.y, peakTime: peak.x,
            endDisplacement: end.y,
            endDisplacementMean: tail.map(\.y).reduce(0, +) / Float(max(tail.count, 1)),
            largestRebound: peak.y - (afterPeak.min() ?? peak.y), history: history, bodyHistory: bodyHistory,
            gauges: gaugeResults,
            pressureHistory: pressureHistory,
            damage: damage(structure, slab: s, inputs: inputs, settings: settings), blownUp: blownUp,
            airSleptAt: slept,
            wallSeconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18)
    }

    /// Reads the slab's state at the end of the run (see `Damage`).
    static func damage(_ structure: StructureSolver, slab s: Box, inputs: Inputs, settings: Settings)
        -> Damage
    {
        let h = structure.model.elementSize
        let ex = structure.ex
        let ey = structure.ey
        func index(_ value: Float, _ axis: Int) -> Int {
            Int(((value - structure.origin[axis]) / h).rounded())
        }
        let bottom = index(s.min.z, 2)
        let top = index(s.max.z, 2)
        let bearing = Int((settings.bearingWidth / h).rounded())
        let near = index(s.min.x, 0)
        let far = index(s.max.x, 0)
        let barLayer = index(s.min.z + inputs.barDepth - h / 2, 2)
        let layers = top - bottom
        func flat(_ i: Int, _ j: Int, _ k: Int) -> Int { i + ex * (j + ey * (k - bottom)) }
        let count = ex * ey * layers
        var flags = [ElementFlag](repeating: .empty, count: count)
        var opening = [Float](repeating: 0, count: count)
        for k in bottom..<top {
            for j in 0..<ey {
                for i in 0..<ex {
                    let f = structure.flag(i, j, k)
                    flags[flat(i, j, k)] = f
                    opening[flat(i, j, k)] = structure.crackOpening(i, j, k) * h
                }
            }
        }
        func intact(_ n: Int) -> Bool { flags[n] == .active && opening[n] < settings.brokenOpening }
        func flood(from seeds: [(Int, Int, Int)], through: (Int, Int, Int) -> Bool) -> Set<Int> {
            var seen = Set<Int>()
            var stack = seeds.filter { through($0.0, $0.1, $0.2) }
            for seed in stack { seen.insert(flat(seed.0, seed.1, seed.2)) }
            while let (i, j, k) = stack.popLast() {
                for (di, dj, dk) in [(1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1)] {
                    let (a, b, c) = (i + di, j + dj, k + dk)
                    guard a >= 0, a < ex, b >= 0, b < ey, c >= bottom, c < top, through(a, b, c) else {
                        continue
                    }
                    if seen.insert(flat(a, b, c)).inserted { stack.append((a, b, c)) }
                }
            }
            return seen
        }
        let nearColumns = near..<(near + bearing)
        let farColumns = (far - bearing)..<far
        var seeds: [(Int, Int, Int)] = []
        for i in nearColumns { for j in 0..<ey { for k in bottom..<top { seeds.append((i, j, k)) } } }
        let reached = flood(from: seeds) { intact(flat($0, $1, $2)) }
        let concreteSpans = farColumns.contains { i in
            (0..<ey).contains { j in (bottom..<top).contains { k in reached.contains(flat(i, j, k)) } }
        }
        func barsIntact(_ i: Int, _ j: Int, _ k: Int) -> Bool {
            guard k == barLayer else { return false }
            let f = flags[flat(i, j, k)]
            guard f == .active || f == .bare else { return false }
            let ratio = structure.steelRatio(i, j, k)
            let plastic = structure.barPlasticStrain(i, j, k)
            return (0..<2).contains { ratio[$0] > 0 && abs(plastic[$0]) < 1e8 }
        }
        let barReach = flood(
            from: nearColumns.flatMap { i in (0..<ey).map { (i, $0, barLayer) } }, through: barsIntact)
        let barsSpan = farColumns.contains { i in
            (0..<ey).contains { barReach.contains(flat(i, $0, barLayer)) }
        }
        var ruptured = 0
        for j in 0..<ey {
            for i in 0..<ex where flags[flat(i, j, barLayer)] != .empty {
                let plastic = structure.barPlasticStrain(i, j, barLayer)
                if (0..<2).contains(where: { abs(plastic[$0]) >= 1e8 }) { ruptured += 1 }
            }
        }
        // Pieces: active or bare elements joined face to face.
        var assigned = Set<Int>()
        var sizes: [Int] = []
        for k in bottom..<top {
            for j in 0..<ey {
                for i in 0..<ex {
                    let n = flat(i, j, k)
                    guard flags[n] == .active || flags[n] == .bare, !assigned.contains(n) else { continue }
                    let piece = flood(from: [(i, j, k)]) { a, b, c in
                        let f = flags[flat(a, b, c)]
                        return f == .active || f == .bare
                    }
                    assigned.formUnion(piece)
                    sizes.append(piece.count)
                }
            }
        }
        let total = flags.filter { $0 != .empty }.count
        let cellArea = h * h
        func face(_ k: Int) -> [[Float]] {
            (0..<ey).map { j in
                (0..<ex).map { i in
                    let n = flat(i, j, k)
                    return flags[n] == .eroded ? -1 : flags[n] == .bare ? -2 : opening[n] * 1000
                }
            }
        }
        var topCrushed = 0
        for j in 0..<ey {
            for i in 0..<ex where flags[flat(i, j, top - 1)] == .active {
                if structure.plasticStrain(i, j, top - 1) >= 0.0035 { topCrushed += 1 }
            }
        }
        let gone = { (k: Int) in
            (0..<count).filter { $0 / (ex * ey) == k - bottom }.filter {
                flags[$0] == .eroded || flags[$0] == .bare
            }.count
        }
        return Damage(
            concreteSpans: concreteSpans, barsSpan: barsSpan, collapses: !concreteSpans,
            pieces: sizes.filter { $0 >= 10 }.count,
            largestShare: Float(sizes.max() ?? 0) / Float(max(total, 1)),
            removed: flags.filter { $0 == .eroded }.count, bare: flags.filter { $0 == .bare }.count,
            barElementsRuptured: ruptured, topGone: Float(gone(top - 1)) * cellArea,
            topCrushed: Float(topCrushed) * cellArea, bottomGone: Float(gone(bottom)) * cellArea,
            bottomCracks: face(bottom), topCracks: face(top - 1),
            bottomPlan: structure.crackPlan(layer: bottom, threshold: 1e-4 / h),
            topPlan: structure.crackPlan(layer: top - 1, threshold: 1e-4 / h))
    }

    /// The inputs taken as uncertain for the predictor's own ensemble, as factors on the values
    /// the primary prediction takes, or the values themselves (see assumptions.md).
    public static let ensembleInputs: [EnsembleInput] = [
        EnsembleInput(
            key: "fc", name: "concrete compressive strength, as a factor",
            distribution: .normal(mean: 1, deviation: 0.05),
            source: "cylinders tested by an outside laboratory; 5% within a batch, assumed"),
        EnsembleInput(
            key: "ft", name: "tensile strength, as a factor on 0.3 fc^(2/3)",
            distribution: .logNormal(median: 1, variation: 0.15),
            source: "not measured; the Eurocode's correlation, 15% about it, assumed"),
        ValidationEnsemble.fracture,
        EnsembleInput(
            key: "fy", name: "bar yield, as a factor on 350 MPa",
            distribution: .uniform(low: 0.85, high: 1.6),
            source: "an estimate; CA-50 (500 MPa) or CA-60 (600 MPa) possible; 300 to 560 MPa, assumed"),
        EnsembleInput(
            key: "charge", name: "TNT equivalence, as a factor",
            distribution: .normal(mean: 1, deviation: 0.1),
            source: "the authors', its method unstated; 10%, assumed"),
        EnsembleInput(
            key: "lift", name: "the charge's centre above the stated stand-off (m)",
            distribution: .uniform(low: 0, high: 0.1),
            source: "the stand-off to the cylinder's centre or to its bottom face"),
        EnsembleInput(
            key: "bearing", name: "bearing width (m)", distribution: .uniform(low: 0.05, high: 0.15),
            source: "not given; 50 to 150 mm, assumed"),
    ]

    /// The primary prediction's values of `ensembleInputs`.
    public static let primaryValues: [String: Double] = [
        "fc": 1, "ft": 1, "gf": 1, "fy": 1, "charge": 1, "lift": 0, "bearing": 0.1,
    ]

    /// `count` Latin-hypercube samples of `ensembleInputs` seeded with `seed`, after the primary
    /// prediction's values (index 0).
    public static func ensembleSamples(count: Int, seed: UInt64) -> [[String: Double]] {
        let points = latinHypercube(count: count, dimensions: ensembleInputs.count, seed: seed)
        return [primaryValues]
            + points.map { point in
                Dictionary(
                    uniqueKeysWithValues: zip(ensembleInputs, point).map {
                        ($0.key, $0.distribution.value(at: $1))
                    })
            }
    }

    /// `settings` with an ensemble sample's values.
    public static func settings(_ settings: Settings, values: [String: Double]) -> Settings {
        var s = settings
        s.fcFactor = Float(values["fc"] ?? 1)
        s.ftFactor = Float(values["ft"] ?? 1)
        s.gfFactor = Float(values["gf"] ?? 1)
        s.fyFactor = Float(values["fy"] ?? 1)
        s.chargeFactor = Float(values["charge"] ?? 1)
        s.chargeLift = Float(values["lift"] ?? 0)
        s.bearingWidth = Float(values["bearing"] ?? Double(settings.bearingWidth))
        return s
    }
}
