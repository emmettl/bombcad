import Foundation
import Metal
import simd

/// A case or input an ensemble does not know.
public struct EnsembleError: Error, LocalizedError {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// One input of a validation case taken as uncertain: what it is, how it is spread, and where
/// that spread comes from.
public struct EnsembleInput: Sendable {
    public var key: String
    public var name: String
    public var distribution: EnsembleDistribution
    public var source: String
}

/// One output compared with a measurement, and the tests' own scatter where repeats give one.
public struct EnsembleOutput: Sendable {
    public var key: String
    public var name: String
    public var unit: String
    public var measured: Double?
    /// The repeats' coefficient of variation, estimated from their range; nil without repeats.
    public var measuredVariation: Double?
}

/// A validation case as an ensemble runs it.
public struct EnsembleCase: Sendable {
    public var id: String
    public var title: String
    public var inputs: [EnsembleInput]
    public var outputs: [EnsembleOutput]
    /// Roughly how long one run takes on an M4 Max (measured lightly loaded), for sharing the
    /// work out.
    public var estimatedSeconds: Double
}

/// One run of an ensemble: the case, its place in the ensemble (0 has every input at its middle
/// value), each input's value, and the kernels' rounding where one is chosen.
public struct EnsembleSample: Codable, Sendable, Equatable {
    public var caseID: String
    public var index: Int
    public var values: [String: Double]
    /// nil builds the kernels as the run's environment says, the default unless set.
    public var rounding: KernelRounding?

    public init(caseID: String, index: Int, values: [String: Double], rounding: KernelRounding? = nil) {
        self.caseID = caseID
        self.index = index
        self.values = values
        self.rounding = rounding
    }
}

/// What a run came to: each output, and its time.
public struct EnsembleOutcome: Codable, Sendable, Equatable {
    public var outputs: [String: Double]
    public var seconds: Double
    public var device: String

    public init(outputs: [String: Double], seconds: Double, device: String) {
        self.outputs = outputs
        self.seconds = seconds
        self.device = device
    }
}

/// The validation cases rerun with their uncertain inputs sampled, to give the model's own spread
/// against each measurement. Most tests are one shot a specimen, so this is the only spread there
/// is to set beside them. The inputs and their distributions are stated with each case; the
/// cases themselves are those of docs/validation.md, on its documented meshes and grids, and no
/// default changes.
public enum ValidationEnsemble {
    // MARK: - Distributions shared by the cases

    /// A concrete's strength stated as a class or a single value: fib Model Code 2010 takes the
    /// mean 8 MPa above the characteristic strength, a standard deviation of about 4.9 MPa.
    static func statedStrength(_ value: Double) -> EnsembleInput {
        EnsembleInput(
            key: "fc", name: "concrete compressive strength",
            distribution: .normal(mean: value, deviation: 4.9e6),
            source: "fib Model Code 2010: fcm − fck = 8 MPa, a standard deviation of 4.9 MPa")
    }

    /// A concrete's strength measured on cylinders of its own cast: a 5% coefficient of
    /// variation within a batch (an assumption, typical of a cast's cylinders).
    static func measuredStrength(_ value: Double) -> EnsembleInput {
        EnsembleInput(
            key: "fc", name: "concrete compressive strength",
            distribution: .normal(mean: value, deviation: 0.05 * value),
            source: "measured on the cast's cylinders; 5% within a batch, assumed")
    }

    static let tensile = EnsembleInput(
        key: "ft", name: "tensile strength, as a factor on its correlation with fc",
        distribution: .logNormal(median: 1, variation: 0.18),
        source: "fib Model Code 2010: fctk,0.05 = 0.7 fctm and fctk,0.95 = 1.3 fctm, about 18%")

    static let fracture = EnsembleInput(
        key: "gf", name: "fracture energy, as a factor on its correlation with fc",
        distribution: .logNormal(median: 1, variation: 0.3),
        source: "fib Model Code 2010 gives GF = 73 fcm^0.18 as a mean; 30% scatter, assumed")

    /// Bar steel: `measured` from the specimens' own coupons, 3%; nominal or assumed, the JCSS
    /// Probabilistic Model Code's 6% (30 MPa on 500).
    static func steel(measured: Bool) -> [EnsembleInput] {
        let variation = measured ? 0.03 : 0.06
        let source =
            measured ? "the specimens' own coupons; 3%, assumed" : "JCSS Probabilistic Model Code, about 6%"
        return [
            EnsembleInput(
                key: "fy", name: "bar yield, as a factor",
                distribution: .normal(mean: 1, deviation: variation),
                source: source),
            EnsembleInput(
                key: "fu", name: "bar ultimate, as a factor",
                distribution: .normal(mean: 1, deviation: variation),
                source: source + "; never below the yield"),
        ]
    }

    static func chargeMass(_ variation: Double, source: String) -> EnsembleInput {
        EnsembleInput(
            key: "mass", name: "charge mass, as a factor (with its TNT equivalence)",
            distribution: .normal(mean: 1, deviation: variation), source: source)
    }

    static func standoff(_ metres: Double, deviation: Double) -> EnsembleInput {
        EnsembleInput(
            key: "standoff", name: "standoff (m)", distribution: .normal(mean: metres, deviation: deviation),
            source: "placing a charge by hand, assumed")
    }

    // MARK: - The cases

    static let saatciTest = ImpactBenchmark.tests.first { $0.name == "SS2b-1" }!
    static let wuTest = TwoFaceSlabTests.wuTests.first { $0.name == "S8" }!
    static let chiquitoTest = CloseInSlabTest.tests.first { $0.name == "S1-S3" }!
    static func petersonTests(_ prefix: String) -> [ImpactBenchmark.PetersonTest] {
        ImpactBenchmark.petersonTests.filter { $0.name.hasPrefix(prefix) }
    }
    /// The Kingery–Bulmash wall: 100 kg at a scaled distance of 2 m/kg^(1/3), on 0.25 m cells.
    static let wallDistance = 2.0
    static let wallCell: Float = 0.25

    /// The repeats' coefficient of variation from their range: the range over d₂ (1.128 for two,
    /// 1.693 for three) over the mean.
    static func scatter(_ values: [Double]) -> Double? {
        guard values.count > 1, let low = values.min(), let high = values.max() else { return nil }
        let d2 = values.count == 2 ? 1.128 : 1.693
        let mean = values.reduce(0, +) / Double(values.count)
        return (high - low) / d2 / mean
    }

    static func peterson(_ prefix: String, title: String) -> EnsembleCase {
        let tests = petersonTests(prefix)
        func measured(_ value: (ImpactBenchmark.PetersonTest) -> Float?) -> (Double?, Double?) {
            let values = tests.compactMap(value).map { Double($0) / 1000 }
            return (values.isEmpty ? nil : values.reduce(0, +) / Double(values.count), scatter(values))
        }
        let impact = measured(\.impact)
        let near = measured(\.nearReaction)
        let far = measured(\.farReaction)
        return EnsembleCase(
            id: "peterson-\(prefix.lowercased())", title: title,
            inputs: [
                statedStrength(36e6), tensile, fracture,
            ] + steel(measured: true) + [
                EnsembleInput(
                    key: "pad", name: "the fibreboard's stiffness, as a factor",
                    distribution: .logNormal(median: 1, variation: 0.5),
                    source: "fitted to the impact forces; the board's own stiffness unknown, 50% assumed"),
                EnsembleInput(
                    key: "speed", name: "impact speed, as a factor",
                    distribution: .normal(mean: 1, deviation: 0.02),
                    source: "a drop of 2.4 m through a guiding tube; 2% for its friction, assumed"),
            ],
            outputs: [
                EnsembleOutput(
                    key: "impact", name: "impact force", unit: "kN", measured: impact.0,
                    measuredVariation: impact.1),
                EnsembleOutput(
                    key: "near", name: "near reaction", unit: "kN", measured: near.0,
                    measuredVariation: near.1),
                EnsembleOutput(
                    key: "far", name: "far reaction", unit: "kN", measured: far.0, measuredVariation: far.1),
            ], estimatedSeconds: 12)
    }

    public static let cases: [EnsembleCase] = [
        EnsembleCase(
            id: "contest-slab",
            title: "Contest slab (2013 blast blind simulation contest), 8 elements through",
            inputs: [
                statedStrength(5400 * 6894.76), tensile, fracture,
            ] + steel(measured: true) + [
                EnsembleInput(
                    key: "load", name: "pressure record, as a factor",
                    distribution: .normal(mean: 1, deviation: 0.03),
                    source: "two readings of the record differ by 4% in impulse"),
                EnsembleInput(
                    key: "supports", name: "supports: lines of nodes (≤ 0.5) or 1 in bearings free to lift",
                    distribution: .uniform(low: 0, high: 1),
                    source: "the rig is not described; either, equally likely"),
            ],
            outputs: [
                EnsembleOutput(
                    key: "peak", name: "peak deflection", unit: "mm", measured: 109,
                    // The repeat (the contest's slab 4) peaked at 113 mm: range 4 mm on a mean of 111,
                    // over d2 = 1.128 for two.
                    measuredVariation: 0.032)
            ], estimatedSeconds: 27),
        EnsembleCase(
            id: "janney", title: "Janney's beam bent to failure, 12 elements through",
            inputs: [statedStrength(36.2e6), tensile, fracture] + steel(measured: false),
            outputs: [
                EnsembleOutput(
                    key: "moment", name: "peak moment", unit: "kN m", measured: 41.5, measuredVariation: nil),
                EnsembleOutput(
                    key: "failure", name: "deflection at failure", unit: "mm", measured: 42,
                    measuredVariation: nil),
            ], estimatedSeconds: 58),
        EnsembleCase(
            id: "oa1",
            title: "OA1, a beam without stirrups failing in shear, 24 elements through, a 92 mm slice",
            inputs: [measuredStrength(22.6e6), tensile, fracture] + steel(measured: false),
            outputs: [
                EnsembleOutput(
                    key: "peak", name: "peak load", unit: "kN", measured: 332, measuredVariation: nil),
                EnsembleOutput(
                    key: "deflection", name: "deflection at the peak", unit: "mm", measured: 9.2,
                    measuredVariation: nil),
            ], estimatedSeconds: 14),
        EnsembleCase(
            id: "saatci", title: "Saatci's SS2b-1, struck by 600 kg at 8 m/s, 16 elements through",
            inputs: [
                measuredStrength(Double(saatciTest.concreteStrength)),
                EnsembleInput(
                    key: "ftAbsolute", name: "tensile strength (Pa)",
                    distribution: .uniform(low: 3.1e6, high: 3.4e6),
                    source: "measured after the tests: 3.1 to 3.4 MPa"),
                fracture,
            ] + steel(measured: true) + [
                EnsembleInput(
                    key: "speed", name: "impact speed, as a factor",
                    distribution: .normal(mean: 1, deviation: 0.01),
                    source: "a drop of 3.26 m; 1%, assumed")
            ],
            outputs: [
                EnsembleOutput(
                    key: "peak", name: "peak deflection", unit: "mm", measured: 37.9, measuredVariation: nil),
                EnsembleOutput(
                    key: "residual", name: "residual deflection", unit: "mm", measured: 18.5,
                    measuredVariation: nil),
                EnsembleOutput(
                    key: "reaction", name: "largest support reaction", unit: "kN", measured: 592,
                    measuredVariation: nil),
            ], estimatedSeconds: 35),
        peterson("D-1d-NoS", title: "Peterson's D-1d-NoS, struck at one depth from a support, no stirrups"),
        peterson("D-2d-S90", title: "Peterson's D-2d-S90, struck at two depths, stirrups at 90 mm"),
        EnsembleCase(
            id: "wu-s8", title: "Wu et al.'s S8, 1.6 kg at 0.5 m over a 2 m slab, coupled",
            inputs: [
                EnsembleInput(
                    key: "fc", name: "concrete compressive strength",
                    distribution: .normal(mean: 0.8 * 47e6, deviation: 0.8 * 0.9e6),
                    source: "six cubes: 47.0 MPa, 1.9%; taken as 0.8 of the cubes'"),
                EnsembleInput(
                    key: "cylinder", name: "cylinder over cube strength, as a factor on 0.8",
                    distribution: .uniform(low: 0.94, high: 1.06), source: "0.75 to 0.85, assumed"),
                tensile, fracture,
            ] + steel(measured: false) + [
                chargeMass(0.02, source: "TNT, weighed; 2%, assumed"),
                standoff(0.5, deviation: 0.005),
            ],
            outputs: [
                EnsembleOutput(
                    key: "peak", name: "peak deflection, 300 mm from the centre", unit: "mm",
                    measured: Double(wuTest.peak ?? 0) * 1000, measuredVariation: nil),
                EnsembleOutput(
                    key: "residual", name: "residual deflection there", unit: "mm",
                    measured: Double(wuTest.residual ?? 0) * 1000, measuredVariation: nil),
            ], estimatedSeconds: 79),
        EnsembleCase(
            id: "chiquito-s1", title: "Chiquito et al.'s S1–S3, 2 kg at 1 m over a slab, coupled",
            inputs: [
                statedStrength(33e6), tensile, fracture,
            ] + steel(measured: false) + [
                chargeMass(0.08, source: "PG2 and dynamite stated as TNT; their equivalence ±15%, as 8%"),
                standoff(1.0, deviation: 0.02),
            ],
            outputs: [
                // The text's values; the scatter from the three shots' peaks in its Figure 9.
                EnsembleOutput(
                    key: "near", name: "peak at G1, 1 m", unit: "MPa", measured: 2.5,
                    measuredVariation: scatter([3.3, 3.45, 3.6])),
                EnsembleOutput(
                    key: "far", name: "peak at G3, 2 m", unit: "MPa", measured: 0.5,
                    measuredVariation: scatter([0.47, 0.525, 0.58])),
            ], estimatedSeconds: 33),
        EnsembleCase(
            id: "kb-wall",
            title: "100 kg on a rigid wall at 2 m/kg^(1/3), 0.25 m cells, against Kingery–Bulmash",
            inputs: [
                chargeMass(0.02, source: "a cast charge, weighed; 2%, assumed"),
                standoff(wallDistance * pow(100, 1.0 / 3), deviation: 0.05),
            ],
            outputs: [
                EnsembleOutput(
                    key: "pressure", name: "reflected peak overpressure", unit: "kPa",
                    measured: KingeryBulmash.point(at: wallDistance).map { $0.reflectedPressure / 1000 },
                    measuredVariation: nil),
                EnsembleOutput(
                    key: "impulse", name: "reflected impulse", unit: "Pa s",
                    measured: KingeryBulmash.point(at: wallDistance).map { $0.reflectedImpulse(mass: 100) },
                    measuredVariation: nil),
            ], estimatedSeconds: 5),
        EnsembleCase(
            id: "kb-curve",
            title:
                "The Kingery–Bulmash curves themselves for the wall case's inputs: what its inputs' spread alone does",
            inputs: [
                chargeMass(0.02, source: "a cast charge, weighed; 2%, assumed"),
                standoff(wallDistance * pow(100, 1.0 / 3), deviation: 0.05),
            ],
            outputs: [
                EnsembleOutput(
                    key: "pressure", name: "reflected peak overpressure", unit: "kPa",
                    measured: KingeryBulmash.point(at: wallDistance).map { $0.reflectedPressure / 1000 },
                    measuredVariation: nil),
                EnsembleOutput(
                    key: "impulse", name: "reflected impulse", unit: "Pa s",
                    measured: KingeryBulmash.point(at: wallDistance).map { $0.reflectedImpulse(mass: 100) },
                    measuredVariation: nil),
            ], estimatedSeconds: 0.001),
    ]

    public static func estimatedSeconds(case id: String) -> Double {
        cases.first { $0.id == id }?.estimatedSeconds ?? 60
    }

    /// Each case and its inputs, for `--list`.
    public static var listing: [String] {
        cases.flatMap { item in
            ["\(item.id): \(item.title)"]
                + item.inputs.map { "  \($0.name): \($0.distribution.description) (\($0.source))" }
        }
    }

    /// `count` samples of `case`'s inputs by a Latin hypercube seeded with `seed`, after the run
    /// with every input at its middle value, which comes first.
    public static func samples(case id: String, count: Int, seed: UInt64) throws -> [EnsembleSample] {
        guard let item = cases.first(where: { $0.id == id }) else {
            throw EnsembleError("No validation case \(id).")
        }
        let middle = Dictionary(
            uniqueKeysWithValues: item.inputs.map { ($0.key, $0.distribution.value(at: 0.5)) })
        let points = latinHypercube(count: count, dimensions: item.inputs.count, seed: seed)
        return [EnsembleSample(caseID: id, index: 0, values: middle)]
            + points.enumerated().map { number, point in
                EnsembleSample(
                    caseID: id, index: number + 1,
                    values: Dictionary(
                        uniqueKeysWithValues: zip(item.inputs, point).map {
                            ($0.key, $0.distribution.value(at: $1))
                        }))
            }
    }

    /// `case`'s run with every input at its middle value, once with each of the kernels'
    /// roundings, the default first: the spread a different rounding gives, which is where results
    /// after failure are one draw among several.
    public static func roundingSamples(case id: String) throws -> [EnsembleSample] {
        let middle = try samples(case: id, count: 0, seed: 0)[0]
        return KernelRounding.allCases.enumerated().map { number, rounding in
            EnsembleSample(caseID: id, index: number, values: middle.values, rounding: rounding)
        }
    }

    // MARK: - Running one

    /// Runs `sample` on this Mac's GPU.
    public static func run(_ sample: EnsembleSample) throws -> EnsembleOutcome {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw BlastError.allocationFailed("No Metal device")
        }
        let start = ContinuousClock.now
        // An output that did not happen (a beam that never failed) is left out.
        let outputs = try KernelRounding.$current.withValue(sample.rounding) {
            try outputs(sample, device: device).filter(\.value.isFinite)
        }
        let took = start.duration(to: .now)
        return EnsembleOutcome(
            outputs: outputs,
            seconds: Double(took.components.seconds) + Double(took.components.attoseconds) * 1e-18,
            device: device.name)
    }

    /// `material` with its concrete and bars as `values` say: fc in pascals (the stiffness,
    /// tensile strength, fracture and crushing energies following it by their correlations, so
    /// that a case's own values move with it), the tensile strength and fracture energy then
    /// scaled, and the bars' yield and ultimate scaled, a measured curve with them.
    static func perturbed(_ material: StructureMaterial, _ values: [String: Double]) -> StructureMaterial {
        var material = material
        if let fc = values["fc"].map({ Float($0) }), fc > 0 {
            let ratio = fc / material.compressiveStrength
            material.youngsModulus *= ratio.squareRoot()
            material.tensileStrength *= pow(ratio, 2.0 / 3.0)
            material.fractureEnergy *= pow(ratio, 0.18)
            material.crushingEnergy *= pow(ratio, 0.18)
            material.compressiveStrength = fc
        }
        if let ft = values["ftAbsolute"].map({ Float($0) }) { material.tensileStrength = ft }
        if let factor = values["ft"].map({ Float($0) }) { material.tensileStrength *= factor }
        if let factor = values["gf"].map({ Float($0) }) {
            material.fractureEnergy *= factor
            material.crushingEnergy *= factor
        }
        if var steel = material.steel {
            let fy = Float(values["fy"] ?? 1)
            let fu = max(Float(values["fu"] ?? 1), fy * steel.yieldStress / steel.ultimateStress)
            // Along a measured curve, the yield's factor at yield, the ultimate's from the
            // ultimate strain on, and between them in proportion.
            if let curve = steel.measuredCurve {
                steel.measuredCurve = curve.map { point in
                    let share = min(max(point.x / max(steel.ultimateStrain, 1e-6), 0), 1)
                    return SIMD2(point.x, point.y * (fy + (fu - fy) * share))
                }
            }
            steel.yieldStress *= fy
            steel.ultimateStress *= fu
            material.steel = steel
        }
        return material
    }

    static func outputs(_ sample: EnsembleSample, device: MTLDevice) throws -> [String: Double] {
        let values = sample.values
        func value(_ key: String, _ fallback: Double = 1) -> Double { values[key] ?? fallback }
        switch sample.caseID {
        case "contest-slab":
            let supports: SlabBenchmark.Supports =
                value("supports", 0) <= 0.5 ? .lines : .bearings(width: 0.0254, holdDown: false)
            let result = try SlabBenchmark.run(
                device: device, loadScale: Float(value("load")), supports: supports,
                adjust: { $0 = perturbed($0, values) })
            return ["peak": Double(result.peak) * 1000]
        case "janney":
            let result = try BeamBenchmark.run(device: device, adjust: { $0 = perturbed($0, values) })
            return [
                "moment": Double(result.peakMoment) / 1000,
                "failure": result.failureDeflection.map { Double($0) * 1000 } ?? .nan,
            ]
        case "oa1":
            let result = try ShearBeamBenchmark.run(
                device: device, elementsThroughDepth: 24, slice: 0.092, adjust: { $0 = perturbed($0, values) }
            )
            return ["peak": Double(result.peak) / 1000, "deflection": Double(result.peakDeflection) * 1000]
        case "saatci":
            var specimen = ImpactBenchmark.specimen(saatciTest)
            specimen.material = perturbed(specimen.material, values)
            let result = try ImpactBenchmark.run(
                device: device, specimen: specimen, weight: saatciTest.weight,
                speed: ImpactBenchmark.impactSpeed * Float(value("speed")))
            return [
                "peak": Double(result.peak) * 1000, "residual": Double(result.residual) * 1000,
                "reaction": Double(result.peakReaction) / 1000,
            ]
        case let id where id.hasPrefix("peterson-"):
            let prefix = String(id.dropFirst("peterson-".count))
            guard
                let test = ImpactBenchmark.petersonTests.first(where: {
                    $0.name.lowercased().hasPrefix(prefix)
                })
            else { throw EnsembleError("No Peterson test \(prefix).") }
            var specimen = ImpactBenchmark.specimen(test)
            specimen.material = perturbed(specimen.material, values)
            specimen.pad = specimen.pad.map { $0 * Float(value("pad")) }
            let result = try ImpactBenchmark.run(
                device: device, specimen: specimen, weight: ImpactBenchmark.petersonWeight,
                speed: ImpactBenchmark.petersonSpeed * Float(value("speed")), duration: 0.03)
            return [
                "impact": Double(result.peakImpactForce) / 1000,
                "near": Double(result.supportReactions.x) / 1000,
                "far": Double(result.supportReactions.y) / 1000,
            ]
        case "wu-s8":
            var test = wuTest
            test.charge *= Float(value("mass"))
            test.standoff = Float(value("standoff", Double(wuTest.standoff ?? 0.5)))
            var concrete = values
            concrete["fc"] = value("fc", 0.8 * 47e6) * value("cylinder")
            let result = try TwoFaceSlabTests.run(
                device: device, test: test,
                adjust: { scenario in
                    if let material = scenario.structure?.material {
                        scenario.structure?.material = perturbed(material, concrete)
                    }
                })
            return ["peak": Double(result.peaks[0]) * 1000, "residual": Double(result.residuals[0]) * 1000]
        case "chiquito-s1":
            var test = chiquitoTest
            test.charge *= Float(value("mass"))
            test.standoff = Float(value("standoff", Double(chiquitoTest.standoff)))
            let result = try CloseInSlabTest.run(
                device: device, test: test,
                adjust: { scenario in
                    if let material = scenario.structure?.material {
                        scenario.structure?.material = perturbed(material, values)
                    }
                })
            func peak(_ prefix: String) -> Double {
                Double(result.gaugePeaks.first { $0.name.hasPrefix(prefix) }?.pressure ?? .nan) / 1e6
            }
            return ["near": peak("G1"), "far": peak("G3")]
        case "kb-curve":
            let mass = 100 * value("mass")
            guard let point = KingeryBulmash.point(at: value("standoff") / cbrt(mass)) else {
                throw EnsembleError("Outside the Kingery–Bulmash curves.")
            }
            return [
                "pressure": point.reflectedPressure / 1000, "impulse": point.reflectedImpulse(mass: mass),
            ]
        case "kb-wall":
            return try wall(
                mass: 100 * Float(value("mass")), standoff: Float(value("standoff")), device: device)
        default:
            throw EnsembleError("No validation case \(sample.caseID).")
        }
    }

    /// A hemispherical surface burst of `mass` kg on rigid ground, `standoff` metres from a rigid
    /// wall, as `blastbench validate` runs its reflected cases: the reflected peak overpressure
    /// (kPa) and impulse (Pa s) at the wall's foot.
    static func wall(mass: Float, standoff: Float, device: MTLDevice) throws -> [String: Double] {
        var wall = ScenarioPreset.openGround.scenario
        wall.charge.mass = mass
        wall.reflectiveFaces = [.zMin, .xMax]
        wall.charge.position = SIMD3(64 - standoff, 32, 0)
        wall.gauges = [Gauge("Wall", at: SIMD3(63.99, 32, 0.05))]
        // The air every run ships with (`SolverConfiguration.recommended`).
        let solver = try BlastSolver(
            // Pinned to the balloon until rerun on the mapped start (validation.md, "Still on the balloon start").
            device: device, scenario: wall, cellSize: wallCell, configuration: .recommended.balloonStart)
        solver.advance(until: 0.1)
        let cell = solver.nearestFluidCell(to: wall.gauges[0].position)
        return [
            "pressure": Double(
                (solver.gaugeHistories[0].map(\.pressure).max() ?? 0) - wall.atmosphere.pressure)
                / 1000,
            "impulse": Double(solver.impulse(cell.i, cell.j, cell.k)),
        ]
    }
}
