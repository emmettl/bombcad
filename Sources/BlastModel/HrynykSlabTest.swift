import Foundation
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

        /// The memberwise initialiser, written out so that BlastCore can use it.
        package init(
            name: String,
            barName: String,
            barArea: Float,
            spacing: Float,
            outerCentres: Float,
            innerCentres: Float,
            compressiveStrength: Float,
            tensileStrength: Float,
            youngsModulus: Float,
            barModulus: Float,
            yieldStress: Float,
            yieldStrain: Float,
            hardeningStrain: Float,
            ultimateStress: Float,
            ultimateStrain: Float
        ) {
            self.name = name
            self.barName = barName
            self.barArea = barArea
            self.spacing = spacing
            self.outerCentres = outerCentres
            self.innerCentres = innerCentres
            self.compressiveStrength = compressiveStrength
            self.tensileStrength = tensileStrength
            self.youngsModulus = youngsModulus
            self.barModulus = barModulus
            self.yieldStress = yieldStress
            self.yieldStrain = yieldStrain
            self.hardeningStrain = hardeningStrain
            self.ultimateStress = ultimateStress
            self.ultimateStrain = ultimateStrain
        }
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

        /// The memberwise initialiser, written out so that BlastCore can use it.
        package init(
            number: Int,
            mass: Float,
            peakDisplacement: Float,
            peakTime: Float,
            residualDisplacement: Float,
            residualTail: Float,
            peakReaction: Float,
            peakReactionAveraged: Float,
            reactionTime: Float,
            peakImpactForce: Float,
            impactForceTime: Float,
            peakImpactForceRaw: Float,
            weightLeft: Float? = nil,
            faceReseated: Bool = false,
            penetration: Float,
            totalPenetration: Float,
            bottomAreaGone: Float,
            layersCrossed: Int,
            thicknessLayers: Int,
            punched: Bool,
            elementsRemoved: Int,
            elementsBare: Int,
            blownUp: Bool,
            displacementHistory: [SIMD2<Float>],
            forceHistory: [[Float]],
            wallSeconds: Double
        ) {
            self.number = number
            self.mass = mass
            self.peakDisplacement = peakDisplacement
            self.peakTime = peakTime
            self.residualDisplacement = residualDisplacement
            self.residualTail = residualTail
            self.peakReaction = peakReaction
            self.peakReactionAveraged = peakReactionAveraged
            self.reactionTime = reactionTime
            self.peakImpactForce = peakImpactForce
            self.impactForceTime = impactForceTime
            self.peakImpactForceRaw = peakImpactForceRaw
            self.weightLeft = weightLeft
            self.faceReseated = faceReseated
            self.penetration = penetration
            self.totalPenetration = totalPenetration
            self.bottomAreaGone = bottomAreaGone
            self.layersCrossed = layersCrossed
            self.thicknessLayers = thicknessLayers
            self.punched = punched
            self.elementsRemoved = elementsRemoved
            self.elementsBare = elementsBare
            self.blownUp = blownUp
            self.displacementHistory = displacementHistory
            self.forceHistory = forceHistory
            self.wallSeconds = wallSeconds
        }
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

        /// The memberwise initialiser, written out so that BlastCore can use it.
        package init(
            slab: String,
            settings: Settings,
            elementSize: Float,
            elementCount: Int,
            timeStep: Float,
            impacts: [Impact],
            selfWeightSag: Float
        ) {
            self.slab = slab
            self.settings = settings
            self.elementSize = elementSize
            self.elementCount = elementCount
            self.timeStep = timeStep
            self.impacts = impacts
            self.selfWeightSag = selfWeightSag
        }
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
}
