import Foundation
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

    /// The memberwise initialiser, written out so that BlastCore can use it.
    package init(
        key: String,
        name: String,
        distribution: EnsembleDistribution,
        source: String
    ) {
        self.key = key
        self.name = name
        self.distribution = distribution
        self.source = source
    }
}

/// One output compared with a measurement, and the tests' own scatter where repeats give one.
public struct EnsembleOutput: Sendable {
    public var key: String
    public var name: String
    public var unit: String
    public var measured: Double?
    /// The repeats' coefficient of variation, estimated from their range; nil without repeats.
    public var measuredVariation: Double?

    /// The memberwise initialiser, written out so that BlastCore can use it.
    package init(
        key: String,
        name: String,
        unit: String,
        measured: Double? = nil,
        measuredVariation: Double? = nil
    ) {
        self.key = key
        self.name = name
        self.unit = unit
        self.measured = measured
        self.measuredVariation = measuredVariation
    }
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

    /// The memberwise initialiser, written out so that BlastCore can use it.
    package init(
        id: String,
        title: String,
        inputs: [EnsembleInput],
        outputs: [EnsembleOutput],
        estimatedSeconds: Double
    ) {
        self.id = id
        self.title = title
        self.inputs = inputs
        self.outputs = outputs
        self.estimatedSeconds = estimatedSeconds
    }
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
    package static func statedStrength(_ value: Double) -> EnsembleInput {
        EnsembleInput(
            key: "fc", name: "concrete compressive strength",
            distribution: .normal(mean: value, deviation: 4.9e6),
            source: "fib Model Code 2010: fcm − fck = 8 MPa, a standard deviation of 4.9 MPa")
    }

    /// A concrete's strength measured on cylinders of its own cast: a 5% coefficient of
    /// variation within a batch (an assumption, typical of a cast's cylinders).
    package static func measuredStrength(_ value: Double) -> EnsembleInput {
        EnsembleInput(
            key: "fc", name: "concrete compressive strength",
            distribution: .normal(mean: value, deviation: 0.05 * value),
            source: "measured on the cast's cylinders; 5% within a batch, assumed")
    }

    package static let tensile = EnsembleInput(
        key: "ft", name: "tensile strength, as a factor on its correlation with fc",
        distribution: .logNormal(median: 1, variation: 0.18),
        source: "fib Model Code 2010: fctk,0.05 = 0.7 fctm and fctk,0.95 = 1.3 fctm, about 18%")

    package static let fracture = EnsembleInput(
        key: "gf", name: "fracture energy, as a factor on its correlation with fc",
        distribution: .logNormal(median: 1, variation: 0.3),
        source: "fib Model Code 2010 gives GF = 73 fcm^0.18 as a mean; 30% scatter, assumed")

    /// Bar steel: `measured` from the specimens' own coupons, 3%; nominal or assumed, the JCSS
    /// Probabilistic Model Code's 6% (30 MPa on 500).
    package static func steel(measured: Bool) -> [EnsembleInput] {
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

    package static func chargeMass(_ variation: Double, source: String) -> EnsembleInput {
        EnsembleInput(
            key: "mass", name: "charge mass, as a factor (with its TNT equivalence)",
            distribution: .normal(mean: 1, deviation: variation), source: source)
    }

    package static func standoff(_ metres: Double, deviation: Double) -> EnsembleInput {
        EnsembleInput(
            key: "standoff", name: "standoff (m)", distribution: .normal(mean: metres, deviation: deviation),
            source: "placing a charge by hand, assumed")
    }

    // MARK: - The cases

    package static let saatciTest = ImpactBenchmark.tests.first { $0.name == "SS2b-1" }!
    package static let wuTest = TwoFaceSlabTests.wuTests.first { $0.name == "S8" }!
    package static let chiquitoTest = CloseInSlabTest.tests.first { $0.name == "S1-S3" }!
    package static func petersonTests(_ prefix: String) -> [ImpactBenchmark.PetersonTest] {
        ImpactBenchmark.petersonTests.filter { $0.name.hasPrefix(prefix) }
    }
    /// The Kingery–Bulmash wall: 100 kg at a scaled distance of 2 m/kg^(1/3), on 0.25 m cells.
    package static let wallDistance = 2.0
    package static let wallCell: Float = 0.25

    /// The repeats' coefficient of variation from their range: the range over d₂ (1.128 for two,
    /// 1.693 for three) over the mean.
    package static func scatter(_ values: [Double]) -> Double? {
        guard values.count > 1, let low = values.min(), let high = values.max() else { return nil }
        let d2 = values.count == 2 ? 1.128 : 1.693
        let mean = values.reduce(0, +) / Double(values.count)
        return (high - low) / d2 / mean
    }

    // MARK: - Running one

    /// `material` with its concrete and bars as `values` say: fc in pascals (the stiffness,
    /// tensile strength, fracture and crushing energies following it by their correlations, so
    /// that a case's own values move with it), the tensile strength and fracture energy then
    /// scaled, and the bars' yield and ultimate scaled, a measured curve with them.
    package static func perturbed(_ material: StructureMaterial, _ values: [String: Double])
        -> StructureMaterial
    {
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
}
