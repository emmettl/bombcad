import Foundation
import Metal
import simd

/// Blind test 1 (docs/blind-tests.md): T. D. Hrynyk's reinforced concrete slabs (PhD thesis,
/// University of Toronto, 2013), 1.8 m square and 130 mm thick, held at their corners and struck
/// at the centre again and again by a 300 mm square steel weight at 8 m/s, the mass rising from
/// 150 kg. Built from `Samples/Hrynyk2013/inputs/slabs.json` alone; every choice the inputs leave
/// open is set out, with its reason, in `Samples/Hrynyk2013/predictions/assumptions.md`.
///
/// Coordinates: the slab's edges along x and y, z up. Its corners, which pointed north, east,
/// south and west in the test frame, are taken as south (0, 0), east (1.8, 0), north (1.8, 1.8)
/// and west (0, 1.8), so that the north-east edge runs along y and the south-east edge along x.
public enum HrynykSlabTest {
    /// One slab as the inputs give it, in SI units.
    public struct Slab: Sendable {
        public var name: String
        public var barName: String
        public var barArea: Float
        public var spacing: Float
        /// Centre to centre of the outer layers (one each face) and of the inner layers.
        public var outerCentres: Float
        public var innerCentres: Float
        public var compressiveStrength: Float
        /// The thesis's tensile strength derived from the prisms' flexural strength (ft*).
        public var tensileStrength: Float
        /// Secant modulus of the cylinders (ASTM C469).
        public var youngsModulus: Float
        public var barModulus: Float
        public var yieldStress: Float
        public var yieldStrain: Float
        public var hardeningStrain: Float
        public var ultimateStress: Float
        public var ultimateStrain: Float
    }

    /// What the inputs say of the test as a whole.
    public struct Inputs: Sendable {
        public var slabs: [Slab]
        public var plan: Float
        public var thickness: Float
        /// The concrete's density from its mix (cement, sand, water and stone per m³).
        public var density: Float
        public var aggregateSize: Float
        public var impactSpeed: Float
        public var masses: [Float]
        /// The supports' centres from both edges: "145 mm in from both edges" (supports.positions).
        public var supportInset: Float = 0.145
        /// The striking face, "300 x 300 mm, flat, steel" (impactor.striking_face).
        public var faceSide: Float = 0.3
    }

    public struct InputError: Error, LocalizedError {
        public var message: String
        public var errorDescription: String? { message }
    }

    /// Reads `slabs.json`: millimetres, megapascals and kilograms there.
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
        guard let plan = slab["plan"] as? [NSNumber], plan.count == 2, plan[0] == plan[1] else {
            throw InputError(message: "The inputs' slab is not square.")
        }
        let thickness = try number(slab["thickness"], "slab.thickness") / 1000
        let reinforcement = try object(root["reinforcement"], "reinforcement")
        let outer = try object(reinforcement["centre_to_centre_of_outer_layers"], "outer layers")
        let inner = try object(reinforcement["centre_to_centre_of_inner_layers"], "inner layers")
        let bars = try object(reinforcement["bars"], "bars")
        let concrete = try object(root["concrete_common"], "concrete_common")
        let mix = try object(concrete["mix_per_m3"], "mix_per_m3")
        let density = try ["cement_GU_kg", "sand_kg", "water_kg", "limestone_13mm_kg"].reduce(Float(0)) {
            try $0 + number(mix[$1], $1)
        }
        let impactor = try object(root["impactor"], "impactor")
        let loading = try object(root["loading_protocol"], "loading_protocol")
        guard let masses = loading["masses_kg_by_impact"] as? [NSNumber] else {
            throw InputError(message: "No masses_kg_by_impact in the inputs.")
        }
        let specimens = try object(root["specimens"], "specimens")
        let slabs = try specimens.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map {
            name -> Slab in
            let specimen = try object(specimens[name], name)
            guard let barName = specimen["bars"] as? String else {
                throw InputError(message: "No bars for \(name).")
            }
            let bar = try object(bars[barName], barName)
            return Slab(
                name: name, barName: barName,
                barArea: try number(bar["area_mm2"], "area_mm2") * 1e-6,
                spacing: try number(specimen["spacing"], "spacing") / 1000,
                outerCentres: try number(outer["\(barName) bars"], "outer \(barName)") / 1000,
                innerCentres: try number(inner["\(barName) bars"], "inner \(barName)") / 1000,
                compressiveStrength: try number(specimen["fc_test_age"], "fc_test_age") * 1e6,
                tensileStrength: try number(specimen["ft_star"], "ft_star") * 1e6,
                youngsModulus: try number(specimen["Ec_secant"], "Ec_secant") * 1e6,
                barModulus: try number(bar["E"], "E") * 1e6,
                yieldStress: try number(bar["fy"], "fy") * 1e6,
                yieldStrain: try number(bar["yield_strain"], "yield_strain"),
                hardeningStrain: try number(bar["strain_at_hardening"], "strain_at_hardening"),
                ultimateStress: try number(bar["fu"], "fu") * 1e6,
                ultimateStrain: try number(bar["strain_at_fu"], "strain_at_fu"))
        }
        return Inputs(
            slabs: slabs, plan: plan[0].floatValue / 1000, thickness: thickness, density: density,
            // "crushed limestone, 13 mm nominal maximum"
            aggregateSize: 0.013,
            impactSpeed: try number(impactor["impact_speed"], "impact_speed"),
            masses: masses.map(\.floatValue))
    }

    /// What the inputs leave to the user of the tool (see assumptions.md).
    public struct Settings: Sendable, Codable {
        /// Solid elements through the slab's thickness; the plan is divided into an even number of
        /// elements as near that size as it goes.
        public var elementsThroughDepth = 16
        /// The bearing plates under and over each corner: plan side and thickness (20 mm stated
        /// for the plate beneath; the side not given).
        public var bearingSide: Float = 0.1
        public var bearingThickness: Float = 0.02
        /// The seat of the spherical pin beneath and of the ball above: the patch of the plates'
        /// outer faces held, nil a single node each, on one vertical line, so that the corner
        /// turns freely (a patch above and one below clamp it between them).
        public var seatSide: Float = 0
        /// The weight's flat steel face, as steel elements on the slab carrying the rest of the
        /// weight's mass on their top nodes.
        public var faceThickness: Float = 0.016
        /// The bars' rupture strain as a multiple of their strain at the ultimate (not given).
        public var ruptureFactor: Float = 1.3
        /// Each impact is run this long, then the slab is brought to rest under mass-proportional
        /// damping for `settleTime` before the next.
        public var duration: Double = 0.2
        public var settleTime: Double = 0.08
        public var settleDamping: Float = 400
        /// How often the histories are sampled.
        public var sampleInterval: Double = 25e-6

        public init() {}
    }

    /// The concrete of `slab` as measured at the time of its tests, strengthening with strain rate
    /// as every calibrated impact bench's does; its bars on their measured curve: the yield
    /// plateau to the strain at hardening, then rising to the ultimate as Mander's power curve
    /// with an exponent of 2, holding to rupture.
    public static func material(
        _ slab: Slab, inputs: Inputs, settings: Settings = Settings()
    ) -> StructureMaterial {
        let ultimatePlastic = slab.ultimateStrain - slab.ultimateStress / slab.barModulus
        let hardeningPlastic = slab.hardeningStrain - slab.yieldStrain
        let rupture = settings.ruptureFactor * slab.ultimateStrain - slab.ultimateStress / slab.barModulus
        var steel = SteelProperties(
            yieldStress: slab.yieldStress, ultimateStress: slab.ultimateStress,
            ultimateStrain: ultimatePlastic,
            ruptureStrain: rupture)
        steel.youngsModulus = slab.barModulus
        let hardening = [0.25, 0.5, 0.75].map { share -> SIMD2<Float> in
            let strain = hardeningPlastic + Float(share) * (ultimatePlastic - hardeningPlastic)
            let left = (ultimatePlastic - strain) / (ultimatePlastic - hardeningPlastic)
            return SIMD2(strain, slab.ultimateStress - (slab.ultimateStress - slab.yieldStress) * left * left)
        }
        steel.measuredCurve =
            [SIMD2(0, slab.yieldStress), SIMD2(hardeningPlastic, slab.yieldStress)] + hardening + [
                SIMD2(ultimatePlastic, slab.ultimateStress), SIMD2(rupture, slab.ultimateStress),
            ]
        var material = StructureMaterial.concrete(
            name: "Hrynyk \(slab.name)", compressiveStrength: slab.compressiveStrength,
            density: inputs.density,
            steel: steel)
        material.youngsModulus = slab.youngsModulus
        material.tensileStrength = slab.tensileStrength
        material.aggregateSize = inputs.aggregateSize
        material.rateDependent = true
        return material
    }

    /// Where things sit in the lattice: node indices along x, y (plan) and z (height).
    public struct Layout: Sendable {
        public var h: Float
        public var planElements: Int
        public var thicknessElements: Int
        /// Node rows: the bearing plates' undersides at 0, the slab's bottom and top faces, and the
        /// tops of the face and the upper bearing plates.
        public var slabBottom: Int
        public var slabTop: Int
        public var faceTop: Int
        public var bearingTop: Int
        /// The slab's centre node, the face's half-width and the supports' centre nodes along each
        /// axis (near and far).
        public var centre: Int
        public var faceHalf: Int
        public var supports: [Int]
        public var bearingHalf: Int
        public var seatHalf: Int
    }

    public static func layout(inputs: Inputs, settings: Settings) -> Layout {
        // An even number across the plan, so that the centre falls on a node.
        let planElements =
            2 * Int((inputs.plan / (inputs.thickness / Float(settings.elementsThroughDepth)) / 2).rounded())
        let h = inputs.plan / Float(planElements)
        let thicknessElements = Int((inputs.thickness / h).rounded())
        let bearingRows = max(Int((settings.bearingThickness / h).rounded()), 1)
        let faceRows = max(Int((settings.faceThickness / h).rounded()), 1)
        let support = Int((inputs.supportInset / h).rounded())
        return Layout(
            h: h, planElements: planElements, thicknessElements: thicknessElements, slabBottom: bearingRows,
            slabTop: bearingRows + thicknessElements, faceTop: bearingRows + thicknessElements + faceRows,
            bearingTop: 2 * bearingRows + thicknessElements, centre: planElements / 2,
            // An even number of elements across the face, centred on the slab's centre node; of the two
            // nearest 300 mm, the smaller.
            faceHalf: Int((inputs.faceSide / 2 / h).rounded(.down)),
            supports: [support, planElements - support],
            bearingHalf: max(Int((settings.bearingSide / 2 / h).rounded()), 1),
            seatHalf: max(Int((settings.seatSide / 2 / h).rounded()), 0))
    }

    /// The slab meshed with solid elements, its four layers of bars each smeared through a band
    /// one element deep at its own height, with steel bearing plates under and over each corner
    /// and the weight's face on top at the centre.
    public static func model(
        _ slab: Slab, inputs: Inputs, settings: Settings = Settings(), material: StructureMaterial? = nil
    ) -> (StructureModel, Layout) {
        let l = layout(inputs: inputs, settings: settings)
        let h = l.h
        let base = (1 / h).rounded() * h
        func z(_ row: Int) -> Float { base + Float(row - l.slabBottom) * h }
        func x(_ node: Int) -> Float { Float(node) * h }
        let slabBox = Box(
            min: SIMD3(0, 0, z(l.slabBottom)), max: SIMD3(inputs.plan, inputs.plan, z(l.slabTop)))
        let face = Box(
            min: SIMD3(x(l.centre - l.faceHalf), x(l.centre - l.faceHalf), z(l.slabTop)),
            max: SIMD3(x(l.centre + l.faceHalf), x(l.centre + l.faceHalf), z(l.faceTop)))
        var solids = [slabBox, face]
        for i in l.supports {
            for j in l.supports {
                let low = SIMD2(x(i - l.bearingHalf), x(j - l.bearingHalf))
                let high = SIMD2(x(i + l.bearingHalf), x(j + l.bearingHalf))
                solids.append(Box(min: SIMD3(low, z(0)), max: SIMD3(high, z(l.slabBottom))))
                solids.append(Box(min: SIMD3(low, z(l.slabTop)), max: SIMD3(high, z(l.bearingTop))))
            }
        }
        var model = StructureModel(
            solids: solids, material: material ?? self.material(slab, inputs: inputs, settings: settings),
            elementSize: h, fixedBase: false)
        // The weight's face, a concrete-filled steel section, stiff, and the bearing plates, each
        // held at one node: elastic steel.
        for index in 1..<solids.count {
            model.setMaterial(.elastic(density: 7850, youngsModulus: 210e9, poissonRatio: 0.3), of: index)
        }
        // Symmetric through the depth; the bars along x outside those along y in both mats.
        let middle = (z(l.slabBottom) + z(l.slabTop)) / 2
        let layers: [(height: Float, axis: Int)] = [
            (middle - slab.outerCentres / 2, 0), (middle - slab.innerCentres / 2, 1),
            (middle + slab.innerCentres / 2, 1), (middle + slab.outerCentres / 2, 0),
        ]
        model.reinforcement = layers.map { layer in
            var band = slabBox
            band.min.z = layer.height - h / 2
            band.max.z = layer.height + h / 2
            var ratio = SIMD3<Float>.zero
            ratio[layer.axis] = slab.barArea / (slab.spacing * h)
            return ReinforcementLayer(region: band, ratio: ratio)
        }
        // A blow: impulsive loading (which, for solid elements, leaves every default as it is).
        model.detectedLoading = .impulsive
        return (model, l)
    }

    /// The inputs taken as uncertain for the predictor's own ensemble, as factors on the values
    /// the primary prediction takes (sample 0, the middle of each).
    public static let ensembleInputs: [EnsembleInput] =
        [
            EnsembleInput(
                key: "fc", name: "concrete compressive strength, as a factor",
                distribution: .normal(mean: 1, deviation: 0.05),
                source: "five match-cured cylinders at the time of the tests; 5% within a batch, assumed"),
            EnsembleInput(
                key: "ft", name: "tensile strength, as a factor on ft*",
                distribution: .logNormal(median: 1, variation: 0.1),
                source: "ft* derived from the prisms' flexural strength; 10% for the derivation, assumed"),
            ValidationEnsemble.fracture,
        ] + ValidationEnsemble.steel(measured: true) + [
            EnsembleInput(
                key: "speed", name: "impact speed, as a factor",
                distribution: .normal(mean: 1, deviation: 0.02),
                source: "nominal 8.0 m/s; the high-speed video found little deviation; 2%, assumed"),
            EnsembleInput(
                key: "bearing", name: "bearing plates' side, as a factor on 100 mm",
                distribution: .uniform(low: 0.75, high: 1.5), source: "not given; 75 to 150 mm, assumed"),
            EnsembleInput(
                key: "rupture", name: "bars' rupture strain, as a factor on 1.3 times the strain at ultimate",
                distribution: .uniform(low: 1.1 / 1.3, high: 1.6 / 1.3),
                source: "not given; 1.1 to 1.6 times the strain at ultimate, assumed"),
        ]

    /// `count` Latin-hypercube samples of `ensembleInputs` seeded with `seed`, after the middle
    /// (index 0), as values for `run(values:)` with the strength made absolute for `slab`.
    public static func ensembleSamples(_ slab: Slab, count: Int, seed: UInt64) -> [[String: Double]] {
        let middle = Dictionary(uniqueKeysWithValues: ensembleInputs.map { ($0.key, $0.distribution.median) })
        let points = latinHypercube(count: count, dimensions: ensembleInputs.count, seed: seed)
        let samples =
            [middle]
            + points.map { point in
                Dictionary(
                    uniqueKeysWithValues: zip(ensembleInputs, point).map {
                        ($0.key, $0.distribution.value(at: $1))
                    })
            }
        return samples.map { values in
            var values = values
            values["fc"] = (values["fc"] ?? 1) * Double(slab.compressiveStrength)
            return values
        }
    }

    /// One impact's outcome. Displacements down and from the impact's start, in metres; forces in
    /// newtons; times in seconds from first contact.
    public struct Impact: Sendable, Codable {
        public var number: Int
        public var mass: Float
        public var peakDisplacement: Float
        public var peakTime: Float
        /// After the slab is brought to rest; and, as the beam benches take it, the mean over the
        /// last 30 ms of the impact's run.
        public var residualDisplacement: Float
        public var residualTail: Float
        /// The sum of the four bearings' upward reactions beneath (the load cells), less its
        /// value at the impact's start (the slab's own weight), at its peak; also its peak
        /// averaged over 0.5 ms, and when the peak came.
        public var peakReaction: Float
        public var peakReactionAveraged: Float
        public var reactionTime: Float
        /// The weight's mass times its deceleration, filtered as the tests' (tenth-order
        /// Butterworth at 1.2 kHz, forward and backward), at its peak and when; and unfiltered.
        public var peakImpactForce: Float
        public var impactForceTime: Float
        public var peakImpactForceRaw: Float
        /// When the weight left the face (nil if it stayed on to the end of the run).
        public var weightLeft: Float?
        /// Whether the face, its bond to the slab gone, was set back on the slab's top at the
        /// centre before this impact.
        public var faceReseated = false
        /// The face's step down into the top face at the face's edge, left by this impact and in
        /// total.
        public var penetration: Float
        public var totalPenetration: Float
        /// Punching (see assumptions.md): the bottom face's elements gone within 450 mm of the
        /// centre (m²), the element layers through the thickness a crack of 1 mm or more (or an
        /// element gone) reaches within 450 mm, and whether both criteria are met.
        public var bottomAreaGone: Float
        public var layersCrossed: Int
        public var thicknessLayers: Int
        public var punched: Bool
        public var elementsRemoved: Int
        public var elementsBare: Int
        public var blownUp: Bool
        /// Histories: (time, midpoint displacement) to `duration` every 0.1 ms; (time, total
        /// reaction beneath, reaction above, impact force filtered, unfiltered) to 50 ms at each
        /// sample.
        public var displacementHistory: [SIMD2<Float>]
        public var forceHistory: [[Float]]
        public var wallSeconds: Double
    }

    public struct Result: Sendable, Codable {
        public var slab: String
        public var settings: Settings
        public var elementSize: Float
        public var elementCount: Int
        public var timeStep: Float
        public var impacts: [Impact]
        /// The slab's settled sag under its own weight before the first impact.
        public var selfWeightSag: Float
    }

    /// A tenth-order Butterworth low-pass filter at `cutoff` Hz, applied forward and then backward
    /// to `signal` sampled at `rate` Hz, as five second-order sections from the bilinear transform
    /// with the cutoff pre-warped. The signal is taken as nil before and after (the weight is
    /// off the slab), which the caller pads.
    public static func butterworthForwardBackward(_ signal: [Double], rate: Double, cutoff: Double)
        -> [Double]
    {
        let order = 10
        let k = tan(Double.pi * cutoff / rate)
        let sections = (1...(order / 2)).map { n -> [Double] in
            let q = 2 * sin(Double.pi * Double(2 * n - 1) / Double(2 * order))
            let norm = 1 / (1 + q * k + k * k)
            let b0 = k * k * norm
            return [b0, 2 * b0, b0, 2 * (k * k - 1) * norm, (1 - q * k + k * k) * norm]
        }
        func pass(_ x: [Double]) -> [Double] {
            var y = x
            for s in sections {
                var (x1, x2, y1, y2) = (0.0, 0.0, 0.0, 0.0)
                for i in y.indices {
                    let x0 = y[i]
                    let y0 = s[0] * x0 + s[1] * x1 + s[2] * x2 - s[3] * y1 - s[4] * y2
                    (x2, x1, y2, y1) = (x1, x0, y1, y0)
                    y[i] = y0
                }
            }
            return y
        }
        return Array(pass(Array(pass(signal).reversed())).reversed())
    }

    /// Strikes `slab` once for each of `masses` at the centre, on one model carried from impact to
    /// impact. `values` perturbs the inputs for an ensemble (keys as `ValidationEnsemble`'s, and
    /// "speed", "bearing" and "rupture" as factors). `progress` hears of each impact as it ends.
    public static func run(
        device: MTLDevice, slab: Slab, inputs: Inputs, settings: Settings = Settings(),
        masses: [Float]? = nil,
        values: [String: Double] = [:], progress: (Impact) -> Void = { _ in },
        adjust: (inout StructureModel) -> Void = { _ in },
        prepare: (StructureSolver, Layout) -> Void = { _, _ in },
        inspect: (StructureSolver, Layout, Int, Double) -> Void = { _, _, _, _ in }
    ) throws -> Result {
        var settings = settings
        if let factor = values["bearing"] { settings.bearingSide *= Float(factor) }
        if let factor = values["rupture"] { settings.ruptureFactor *= Float(factor) }
        let material = ValidationEnsemble.perturbed(
            self.material(slab, inputs: inputs, settings: settings), values)
        let speed = inputs.impactSpeed * Float(values["speed"] ?? 1)
        var (model, l) = self.model(slab, inputs: inputs, settings: settings, material: material)
        adjust(&model)
        let solver = try StructureSolver(device: device, model: model)
        solver.groundContact = false
        prepare(solver, l)
        let h = l.h
        let g = solver.gravity
        let face = (l.centre - l.faceHalf)...(l.centre + l.faceHalf)
        // The bearing plates' seats: beneath, resting on the pin (pushing up only) and held
        // sideways as each corner's pin or roller holds it; above, held down by the ball.
        let near = l.supports[0]
        let far = l.supports[1]
        let corners: [(i: Int, j: Int, x: Bool, y: Bool)] = [
            (near, near, false, true),  // south: free along the south-east edge (x)
            (far, near, true, true),  // east: pinned
            (far, far, true, false),  // north: free along the north-east edge (y)
            (near, far, false, false),  // west: free
        ]
        var seatsBelow: [(Int, Int)] = []
        var seatsAbove: [(Int, Int)] = []
        solver.mutateNodes { nodes in
            for corner in corners {
                for i in (corner.i - l.seatHalf)...(corner.i + l.seatHalf) {
                    for j in (corner.j - l.seatHalf)...(corner.j + l.seatHalf) {
                        if let n = solver.storedNode(i, j, 0) {
                            nodes[n].restsOnSupport = true
                            nodes[n].restrain(x: corner.x, y: corner.y)
                            seatsBelow.append((i, j))
                        }
                        if let n = solver.storedNode(i, j, l.bearingTop) {
                            nodes[n].isHeldDown = true
                            seatsAbove.append((i, j))
                        }
                    }
                }
            }
        }
        var faceNodes: [Int] = []
        var weightNodes: [Int] = []
        for i in face {
            for j in face {
                for k in l.slabTop...l.faceTop {
                    if let n = solver.storedNode(i, j, k) {
                        faceNodes.append(n)
                        if k == l.faceTop { weightNodes.append(n) }
                    }
                }
            }
        }
        let faceMass = Float((2 * l.faceHalf) * (2 * l.faceHalf) * (l.faceTop - l.slabTop)) * h * h * h * 7850

        func reactions() -> (below: Float, above: Float) {
            var below: Float = 0
            var above: Float = 0
            for (i, j) in seatsBelow where solver.displacement(i, j, 0).z == 0 {
                below -= solver.nodalForce(i, j, 0).z
            }
            for (i, j) in seatsAbove where solver.displacement(i, j, l.bearingTop).z == 0 {
                above -= solver.nodalForce(i, j, l.bearingTop).z
            }
            return (below, above)
        }
        // The midpoint of the bottom face: the lowest node at the centre still held by an element.
        func attached(_ i: Int, _ j: Int, _ k: Int) -> Bool {
            for a in (i - 1)...i {
                for b in (j - 1)...j {
                    for c in (k - 1)...k where c >= l.slabBottom && c < l.slabTop {
                        let flag = solver.flag(a, b, c)
                        if flag == .active || flag == .bare { return true }
                    }
                }
            }
            return false
        }
        func midpoint() -> Float {
            let k = (l.slabBottom...l.slabTop).first { attached(l.centre, l.centre, $0) } ?? l.slabTop
            return -solver.displacement(l.centre, l.centre, k).z
        }
        func settle() {
            solver.damping = settings.settleDamping
            let stop = solver.time + settings.settleTime
            while solver.time < stop { solver.advance(steps: 100) }
            solver.damping = 0
            solver.mutateNodes { nodes in
                for n in nodes.indices { nodes[n].velocity = .zero }
            }
        }
        // The slab's top at column (i, j): the highest node there still held by a concrete element.
        func surface(_ i: Int, _ j: Int) -> Float? {
            guard
                let k = stride(from: l.slabTop, through: l.slabBottom, by: -1).first(where: {
                    attached(i, j, $0)
                })
            else { return nil }
            return solver.referencePosition(i, j, k).z + solver.displacement(i, j, k).z
        }
        // The step down at the face's edge: the slab's top along the face's perimeter against its
        // top two elements out (while the face is bonded on, its perimeter nodes).
        func faceStep() -> Float {
            var inside: [Float] = []
            var outside: [Float] = []
            let a = l.faceHalf
            for i in (l.centre - a - 2)...(l.centre + a + 2) {
                for j in (l.centre - a - 2)...(l.centre + a + 2) {
                    let ring = max(abs(i - l.centre), abs(j - l.centre))
                    if ring == a, let z = surface(i, j) { inside.append(z) }
                    if ring == a + 2, let z = surface(i, j) { outside.append(z) }
                }
            }
            guard !inside.isEmpty, !outside.isEmpty else { return 0 }
            return outside.reduce(0, +) / Float(outside.count) - inside.reduce(0, +) / Float(inside.count)
        }
        // Where the concrete the face was bonded to has all gone, the face is a loose piece, which
        // contact (on once any element has failed) lets strike the slab: it is set back, undeformed
        // and at rest, on the highest point of the slab's top under it at the centre, one element
        // above it, where contact begins.
        func reseatFace() -> Bool {
            let bonded = face.contains { i in face.contains { j in attached(i, j, l.slabTop) } }
            if bonded { return false }
            let heights = face.flatMap { i in face.compactMap { j in surface(i, j) } }
            guard let top = heights.max() else { return false }
            let lift = top + h - solver.referencePosition(l.centre, l.centre, l.slabTop).z
            solver.mutateNodes { nodes in
                for n in faceNodes {
                    nodes[n].displacement = SIMD3(0, 0, lift)
                    nodes[n].velocity = .zero
                }
            }
            return true
        }
        func damage() -> (area: Float, layers: Int, removed: Int, bare: Int) {
            let reach = Int((0.45 / h).rounded())
            var area: Float = 0
            var layers = 0
            var removed = 0
            var bare = 0
            for i in 0..<solver.ex {
                for j in 0..<solver.ey {
                    for k in l.slabBottom..<l.slabTop {
                        let flag = solver.flag(i, j, k)
                        if flag == .eroded { removed += 1 }
                        if flag == .bare { bare += 1 }
                    }
                }
            }
            for k in l.slabBottom..<l.slabTop {
                var crossed = false
                for i in (l.centre - reach)..<(l.centre + reach) {
                    for j in (l.centre - reach)..<(l.centre + reach) {
                        let flag = solver.flag(i, j, k)
                        let gone = flag == .eroded || flag == .bare
                        if k == l.slabBottom && gone { area += h * h }
                        if gone || solver.crackOpening(i, j, k) >= 0.001 { crossed = true }
                    }
                }
                if crossed { layers += 1 }
            }
            return (area, layers, removed, bare)
        }

        settle()
        let selfWeightSag = midpoint()
        let stepsPerSample = max(
            1, Int((settings.sampleInterval / Double(solver.criticalTimeStep)).rounded()))
        let sample = Double(stepsPerSample) * Double(solver.criticalTimeStep)
        var impacts: [Impact] = []
        for (number, mass) in (masses ?? Array(inputs.masses.prefix(4))).enumerated() {
            let wallStart = ContinuousClock.now
            let reseated = reseatFace()
            let start = midpoint()
            let startStep = faceStep()
            let startReaction = reactions().below
            // The weight: its face's nodes all start down at the impact speed, the rest of its mass
            // shared among the face's top nodes.
            let added = max(mass - faceMass, 0) / Float(weightNodes.count)
            solver.mutateNodes { nodes in
                for n in faceNodes { nodes[n].velocity = SIMD3(0, 0, -speed) }
                for n in weightNodes { nodes[n].mass += added }
            }
            var attachedWeight = true
            var weightLeft: Float?
            let t0 = solver.time
            var displacement: [SIMD2<Float>] = []
            var below: [Float] = []
            var above: [Float] = []
            var speeds: [Double] = [Double(speed)]
            while solver.time - t0 < settings.duration - 1e-9 {
                solver.advance(steps: stepsPerSample)
                let t = Float(solver.time - t0)
                inspect(solver, l, number + 1, solver.time - t0)
                displacement.append(SIMD2(t, midpoint() - start))
                let r = reactions()
                below.append(r.below - startReaction)
                above.append(r.above)
                if attachedWeight {
                    var rising = false
                    solver.mutateNodes { nodes in
                        let momentum = weightNodes.reduce(Float(0)) {
                            $0 + nodes[$1].mass * nodes[$1].velocity.z
                        }
                        let total = weightNodes.reduce(Float(0)) { $0 + nodes[$1].mass }
                        let v = momentum / total
                        speeds.append(Double(-v))
                        if v > 0 {
                            for n in weightNodes { nodes[n].mass -= added }
                            rising = true
                        }
                    }
                    if rising {
                        attachedWeight = false
                        weightLeft = t
                    }
                }
            }
            if attachedWeight {
                solver.mutateNodes { nodes in
                    for n in weightNodes { nodes[n].mass -= added }
                }
            }
            let records = displacement.count
            let tail = displacement.filter { Double($0.x) >= settings.duration - 0.03 }
            let residualTail = tail.map(\.y).reduce(0, +) / Float(max(tail.count, 1))
            // The impact force: the weight's mass times its deceleration (contact force over the
            // weight: its deceleration less gravity's pull), nil once it has left.
            var force = [Double](repeating: 0, count: records)
            for i in 1..<speeds.count where i - 1 < records {
                force[i - 1] = Double(mass) * ((speeds[i - 1] - speeds[i]) / sample + Double(g))
            }
            let pad = Int((0.02 / sample).rounded())
            let padded = [Double](repeating: 0, count: pad) + force + [Double](repeating: 0, count: pad)
            let filtered = Array(
                butterworthForwardBackward(padded, rate: 1 / sample, cutoff: 1200)[pad..<(pad + records)])
            settle()
            let residual = midpoint() - start
            let step = faceStep()
            let d = damage()
            let peakIndex = displacement.indices.max { displacement[$0].y < displacement[$1].y } ?? 0
            let reactionIndex = below.indices.max { below[$0] < below[$1] } ?? 0
            let forceIndex = filtered.indices.max { filtered[$0] < filtered[$1] } ?? 0
            let window = max(1, Int((0.0005 / sample).rounded()))
            var averaged: Float = 0
            if below.count >= window {
                var sum = below[0..<window].reduce(0, +)
                averaged = sum / Float(window)
                for end in window..<below.count {
                    sum += below[end] - below[end - window]
                    averaged = max(averaged, sum / Float(window))
                }
            }
            let tenth = max(1, Int((0.0001 / sample).rounded()))
            let early = min(records, Int((0.05 / sample).rounded()))
            let elapsed = ContinuousClock.now - wallStart
            let impact = Impact(
                number: number + 1, mass: mass, peakDisplacement: displacement[peakIndex].y,
                peakTime: displacement[peakIndex].x, residualDisplacement: residual,
                residualTail: residualTail,
                peakReaction: below[reactionIndex], peakReactionAveraged: averaged,
                reactionTime: Float(Double(reactionIndex + 1) * sample),
                peakImpactForce: Float(filtered[forceIndex]),
                impactForceTime: Float((Double(forceIndex) + 0.5) * sample),
                peakImpactForceRaw: Float(force.max() ?? 0), weightLeft: weightLeft, faceReseated: reseated,
                penetration: step - startStep, totalPenetration: step,
                bottomAreaGone: d.area, layersCrossed: d.layers, thicknessLayers: l.thicknessElements,
                punched: d.area >= 0.09 && d.layers == l.thicknessElements, elementsRemoved: d.removed,
                elementsBare: d.bare, blownUp: solver.summary().hasBlownUp,
                displacementHistory: stride(from: tenth - 1, to: records, by: tenth).map { displacement[$0] },
                forceHistory: (0..<early).map {
                    [
                        Float(Double($0 + 1) * sample), below[$0], above[$0], Float(filtered[$0]),
                        Float(force[$0]),
                    ]
                },
                wallSeconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds)
                    * 1e-18)
            impacts.append(impact)
            progress(impact)
            if impact.blownUp { break }
        }
        return Result(
            slab: slab.name, settings: settings, elementSize: h, elementCount: solver.elementCount,
            timeStep: solver.criticalTimeStep, impacts: impacts, selfWeightSag: selfWeightSag)
    }
}
