import Foundation
import Metal
import simd

public enum MaterialModel: UInt32, Sendable, Codable {
    /// Elastic-plastic with a single yield stress and a plastic-strain failure limit.
    case vonMises = 0
    /// Concrete that cracks in tension and crushes in compression, with optional reinforcement.
    case concrete = 1
}

/// Reinforcing steel: elastic, then hardening linearly from yield to ultimate, then a plateau
/// until it ruptures.
public struct SteelProperties: Sendable, Hashable, Codable {
    /// Pa
    public var youngsModulus: Float = 200e9
    public var yieldStress: Float
    public var ultimateStress: Float
    /// Plastic strain at which the ultimate stress is reached.
    public var ultimateStrain: Float
    /// Plastic strain at which the bar breaks.
    public var ruptureStrain: Float
    /// A measured hardening curve as (plastic strain, stress) points, used in place of the
    /// straight line from yield to ultimate. At most eight points; the bar breaks at the last.
    public var measuredCurve: [SIMD2<Float>]?

    public init(yieldStress: Float, ultimateStress: Float, ultimateStrain: Float, ruptureStrain: Float) {
        self.yieldStress = yieldStress
        self.ultimateStress = ultimateStress
        self.ultimateStrain = ultimateStrain
        self.ruptureStrain = ruptureStrain
    }

    /// The hardening curve as (plastic strain, stress) points.
    public var curve: [SIMD2<Float>] {
        if let measuredCurve { return Array(measuredCurve.prefix(8)) }
        return [
            SIMD2(0, yieldStress), SIMD2(ultimateStrain, max(ultimateStress, yieldStress)),
            SIMD2(max(ruptureStrain, ultimateStrain * 1.001), max(ultimateStress, yieldStress)),
        ]
    }

    /// Typical ribbed bar with a 500 MPa characteristic yield.
    public static let grade500 = SteelProperties(
        yieldStress: 500e6, ultimateStress: 575e6, ultimateStrain: 0.075, ruptureStrain: 0.12)
}

/// Material of a deformable structure.
///
/// The concrete model works on total strain, with cracks smeared over the three lattice planes.
/// Across each plane the normal stress follows a uniaxial curve (exponential softening in
/// tension, a parabola then linear softening in compression), with the softening scaled so that
/// the energy to open a crack or crush a band does not depend on the mesh. Shear across a
/// cracked plane is carried by aggregate interlock, which weakens as the crack widens.
/// Reinforcement is smeared into the elements it passes through.
public struct StructureMaterial: Sendable, Hashable, Codable {
    public var name: String
    public var model: MaterialModel
    /// kg/m³
    public var density: Float
    /// Pa
    public var youngsModulus: Float
    public var poissonRatio: Float

    // Von Mises model.
    /// Uniaxial yield stress in Pa.
    public var yieldStress: Float = 1e30
    /// Slope of the stress against plastic strain after yield, in Pa.
    public var hardeningModulus: Float = 0
    /// Equivalent plastic strain at which an element is removed.
    public var failureStrain: Float = 1e30

    // Concrete model.
    /// Uniaxial compressive strength in Pa.
    public var compressiveStrength: Float = 0
    /// Uniaxial tensile strength in Pa.
    public var tensileStrength: Float = 0
    /// Energy to open a unit area of crack, in J/m².
    public var fractureEnergy: Float = 0
    /// Energy to crush a unit area of band, in J/m².
    public var crushingEnergy: Float = 0
    /// Crack width, in metres, at which an element with no intact steel across the crack is
    /// removed. Well before this the crack carries no tension; removal only matters for letting
    /// pieces separate, so it is deliberately late: a cracked element still resists compression.
    public var erosionOpening: Float = 0.005
    /// Properties of the reinforcement, or nil to ignore any reinforcement in the model.
    public var steel: SteelProperties?
    /// Typical distance between cracks in a reinforced member, in metres. Plain concrete forms
    /// one crack, whose energy is spread over one element; bars force a crack every so often,
    /// so in reinforced concrete the energy is spread over this distance instead (when it is
    /// larger than an element), which keeps the response independent of the mesh.
    public var crackSpacing: Float = 0.1
    /// Shortest length, in metres, over which crushing is taken to spread. Zero spreads it over
    /// one element.
    public var crushBand: Float = 0
    /// Gain in compressive strength per unit of lateral confining stress (Richart's 4.1).
    public var confinementCoefficient: Float = 4.1
    /// Largest aggregate size in metres, which governs how well a crack still carries shear.
    public var aggregateSize: Float = 0.016
    /// Fraction of a crack's inelastic opening that remains when the tension across it is
    /// released, because fragments and misfit stop the faces closing completely.
    public var crackResidual: Float = 0.1
    /// Fixed multipliers on strength, such as the design dynamic increase factors of
    /// UFC 3-340-02. They apply on top of `rateDependent`, so normally use one or the other.
    public var concreteRateFactor: Float = 1
    public var steelRateFactor: Float = 1
    /// Raise strength with the local strain rate: CEB-FIP 1990 for concrete in compression,
    /// Malvar and Ross (1998) in tension, Malvar and Crawford (1998) for reinforcement.
    public var rateDependent = false

    /// A von Mises material.
    public init(
        name: String, density: Float, youngsModulus: Float, poissonRatio: Float, yieldStress: Float,
        hardeningModulus: Float = 0, failureStrain: Float
    ) {
        self.name = name
        self.model = .vonMises
        self.density = density
        self.youngsModulus = youngsModulus
        self.poissonRatio = poissonRatio
        self.yieldStress = yieldStress
        self.hardeningModulus = hardeningModulus
        self.failureStrain = failureStrain
    }

    /// A material that never yields or fails.
    public static func elastic(density: Float, youngsModulus: Float, poissonRatio: Float) -> Self {
        Self(
            name: "Elastic", density: density, youngsModulus: youngsModulus, poissonRatio: poissonRatio,
            yieldStress: 1e30, failureStrain: 1e30)
    }

    /// Concrete of the given compressive strength (Pa), with its other properties taken from
    /// standard correlations: E = 4700 sqrt(fc) MPa (ACI 318), ft = 0.3 fc^(2/3) MPa (Eurocode 2)
    /// and Gf = 73 fc^0.18 N/m (fib Model Code 2010), with a crushing energy of 250 Gf.
    public static func concrete(
        name: String, compressiveStrength: Float, density: Float = 2400, steel: SteelProperties? = nil
    ) -> Self {
        let megapascals = compressiveStrength / 1e6
        var material = Self(
            name: name, density: density, youngsModulus: 4700e6 * megapascals.squareRoot(), poissonRatio: 0.2,
            yieldStress: 1e30, failureStrain: 1e30)
        material.model = .concrete
        material.compressiveStrength = compressiveStrength
        material.tensileStrength = 0.3e6 * pow(megapascals, 2.0 / 3.0)
        material.fractureEnergy = 73 * pow(megapascals, 0.18)
        material.crushingEnergy = 250 * material.fractureEnergy
        material.steel = steel
        return material
    }

    /// 30 MPa concrete with 500 MPa reinforcement wherever the model specifies it, both
    /// strengthening with strain rate.
    public static let reinforcedConcrete: Self = {
        var material = concrete(name: "Reinforced concrete", compressiveStrength: 30e6, steel: .grade500)
        material.rateDependent = true
        return material
    }()

    /// The same concrete with its reinforcement left out.
    public static let plainConcrete: Self = {
        var material = concrete(name: "Plain concrete", compressiveStrength: 30e6)
        material.rateDependent = true
        return material
    }()

    /// Unreinforced blockwork, treated as a weak, brittle concrete.
    public static let masonry: Self = {
        var material = concrete(name: "Masonry", compressiveStrength: 8e6, density: 1900)
        material.youngsModulus = 6e9
        material.tensileStrength = 0.3e6
        material.fractureEnergy = 20
        material.crushingEnergy = 5000
        material.erosionOpening = 0.003
        return material
    }()

    public static let presets: [Self] = [.reinforcedConcrete, .plainConcrete, .masonry]

    public var shearModulus: Float { youngsModulus / (2 * (1 + poissonRatio)) }

    public var lameLambda: Float {
        youngsModulus * poissonRatio / ((1 + poissonRatio) * (1 - 2 * poissonRatio))
    }

    /// Speed of compression waves in the bulk material, which sets the explicit time step.
    public var dilatationalWaveSpeed: Float {
        ((lameLambda + 2 * shearModulus) / density).squareRoot()
    }
}

/// Reinforcement smeared uniformly through a region. `ratio` is steel area per unit area of
/// concrete for bars running along x, y and z.
public struct ReinforcementLayer: Sendable, Hashable, Codable {
    public var region: Box
    public var ratio: SIMD3<Float>

    public init(region: Box, ratio: SIMD3<Float>) {
        self.region = region
        self.ratio = ratio
    }
}

/// A pressure history applied to one outer face of a structure, for running it without the air.
public struct PressureLoad: Sendable, Hashable {
    /// Axis (0, 1, 2 for x, y, z) normal to the loaded faces.
    public var axis: Int
    /// Load the faces whose outward normal points along the positive axis.
    public var positiveSide: Bool
    /// Time (s) and pressure (Pa) pairs, interpolated linearly; pressure pushes into the face.
    public var history: [SIMD2<Float>]

    public init(axis: Int, positiveSide: Bool, history: [SIMD2<Float>]) {
        self.axis = axis
        self.positiveSide = positiveSide
        self.history = history
    }

    /// Impulse per unit area of the whole history, in Pa s.
    public var impulse: Float {
        zip(history, history.dropFirst()).reduce(0) { $0 + 0.5 * ($1.0.y + $1.1.y) * ($1.1.x - $1.0.x) }
    }
}

/// A deformable body: the union of `solids` minus `openings`, meshed with cubic elements.
public struct StructureModel: Sendable, Hashable, Codable {
    public var solids: [Box]
    public var openings: [Box]
    public var material: StructureMaterial
    /// Edge length of an element in metres.
    public var elementSize: Float
    /// Clamp the nodes that sit on the ground plane.
    public var fixedBase: Bool
    public var reinforcement: [ReinforcementLayer] = []

    public init(
        solids: [Box], openings: [Box] = [], material: StructureMaterial = .reinforcedConcrete,
        elementSize: Float, fixedBase: Bool = true
    ) {
        self.solids = solids
        self.openings = openings
        self.material = material
        self.elementSize = elementSize
        self.fixedBase = fixedBase
    }

    public func occupies(_ point: SIMD3<Float>) -> Bool {
        solids.contains { $0.contains(point) } && !openings.contains { $0.contains(point) }
    }

    public var bounds: Box {
        var low = SIMD3<Float>(repeating: .infinity)
        var high = SIMD3<Float>(repeating: -.infinity)
        for box in solids {
            low = simd_min(low, box.min)
            high = simd_max(high, box.max)
        }
        return Box(min: low, max: high)
    }

    /// Adds a mat of bars, running both ways, near one or both faces of a slab or wall.
    ///
    /// - Parameters:
    ///   - slab: The slab or wall to reinforce.
    ///   - thicknessAxis: The axis (0, 1, 2) through the slab's thickness.
    ///   - areaPerMetre: Bar area per metre width in each direction, in m²/m. Pass different
    ///     values for the two in-plane axes with `transverseAreaPerMetre`.
    ///   - depth: Distance from the face to the centre of the bars.
    ///   - faces: Which faces get a mat: the low side, the high side, or both.
    public mutating func addMat(
        to slab: Box, thicknessAxis: Int, areaPerMetre: Float, transverseAreaPerMetre: Float? = nil,
        longitudinalAxis: Int? = nil, depth: Float, faces: (low: Bool, high: Bool) = (true, true)
    ) {
        // Each mat is smeared through a band one element thick, centred on the bars.
        let h = elementSize
        var ratio = SIMD3<Float>(repeating: areaPerMetre / h)
        if let transverseAreaPerMetre, let longitudinalAxis {
            ratio = SIMD3(repeating: transverseAreaPerMetre / h)
            ratio[longitudinalAxis] = areaPerMetre / h
        }
        ratio[thicknessAxis] = 0
        func band(centre: Float) -> ReinforcementLayer {
            var region = slab
            region.min[thicknessAxis] = centre - h / 2
            region.max[thicknessAxis] = centre + h / 2
            return ReinforcementLayer(region: region, ratio: ratio)
        }
        if faces.low { reinforcement.append(band(centre: slab.min[thicknessAxis] + depth)) }
        if faces.high { reinforcement.append(band(centre: slab.max[thicknessAxis] - depth)) }
    }

    /// Replaces the reinforcement with a standard arrangement worked out from the shape of each
    /// solid: a slab or wall (one dimension much smaller than the others) gets a mat of bars in
    /// both faces; anything stockier is treated as a column, with 2% steel along its length and
    /// ties across it.
    ///
    /// - Parameters:
    ///   - areaPerMetre: Bar area per metre width of each mat, each way, in m²/m.
    ///   - depth: Distance from a face to the centre of its mat.
    public mutating func autoReinforce(areaPerMetre: Float = 565e-6, depth: Float = 0.04) {
        reinforcement = []
        for solid in solids {
            let size = solid.size
            let thin = (0..<3).min { size[$0] < size[$1] } ?? 0
            let others = (0..<3).filter { $0 != thin }
            let isSlab = size[thin] <= 0.6 && others.allSatisfy { size[$0] >= 3 * size[thin] }
            if isSlab {
                addMat(
                    to: solid, thicknessAxis: thin, areaPerMetre: areaPerMetre,
                    depth: Swift.min(depth, size[thin] / 2))
            } else {
                let long = (0..<3).max { size[$0] < size[$1] } ?? 2
                var ratio = SIMD3<Float>(repeating: 0.004)
                ratio[long] = 0.02
                reinforcement.append(ReinforcementLayer(region: solid, ratio: ratio))
            }
        }
    }
}

/// Node of the structural mesh as stored on the GPU. Layout matches `StructureNode` in
/// `Structure.metal`.
public struct StructureNode: Sendable {
    /// Displacement from the node's lattice position, in metres.
    public var ux: Float = 0
    public var uy: Float = 0
    public var uz: Float = 0
    public var mass: Float = 0
    public var vx: Float = 0
    public var vy: Float = 0
    public var vz: Float = 0
    /// Bits 0-2 hold the node still along x, y, z; bit 3 keeps its velocity as set; bit 4
    /// lets it rise but not fall below where it started.
    public var flags: UInt32 = 0

    public init() {}

    public var displacement: SIMD3<Float> {
        get { SIMD3(ux, uy, uz) }
        set { (ux, uy, uz) = (newValue.x, newValue.y, newValue.z) }
    }

    public var velocity: SIMD3<Float> {
        get { SIMD3(vx, vy, vz) }
        set { (vx, vy, vz) = (newValue.x, newValue.y, newValue.z) }
    }

    /// Held still in every direction.
    public var isFixed: Bool {
        get { flags & 7 == 7 }
        set { flags = newValue ? flags | 7 : flags & ~7 }
    }

    /// Holds the node still along the chosen axes only.
    public mutating func restrain(x: Bool = false, y: Bool = false, z: Bool = false) {
        flags |= (x ? 1 : 0) | (y ? 2 : 0) | (z ? 4 : 0)
    }

    /// Rests on a support that pushes up but does not hold down: the node cannot move below
    /// its starting height, and lifts off freely.
    public var restsOnSupport: Bool {
        get { flags & 16 != 0 }
        set { flags = newValue ? flags | 16 : flags & ~16 }
    }

    /// Moves at its current velocity regardless of the forces on it.
    public var isPrescribed: Bool {
        get { flags & 8 != 0 }
        set { flags = newValue ? flags | 8 : flags & ~8 }
    }
}

public enum ElementFlag: UInt8, Sendable {
    case empty = 0
    case active = 1
    case eroded = 2
}

public struct StructureSummary: Sendable, Hashable {
    /// Elements still carrying load.
    public var activeElements = 0
    /// Elements removed after reaching the failure strain.
    public var erodedElements = 0
    /// Largest displacement, in metres, of a node still attached to an active element.
    public var maxDisplacement: Float = 0
    /// Largest equivalent plastic strain (von Mises) or compressive strain (concrete) in an
    /// active element.
    public var maxPlasticStrain: Float = 0
    /// Largest damage index in an active element: 0 is sound, 1 is at the point of failure.
    public var maxDamage: Float = 0
    /// True when the solution has become numerically unstable (some displacement is not a number).
    public var hasBlownUp = false

    public init() {}

    public var erodedFraction: Double {
        let total = activeElements + erodedElements
        return total == 0 ? 0 : Double(erodedElements) / Double(total)
    }
}

/// Layout matches `StructureUniforms` in `Structure.metal`.
struct StructureUniforms {
    var ex: UInt32
    var ey: UInt32
    var ez: UInt32
    var substep: UInt32 = 0
    var h: Float
    var originX: Float
    var originY: Float
    var originZ: Float
    var density: Float
    var lambda: Float
    var mu: Float
    var yieldStress: Float
    var hardening: Float
    var failureStrain: Float
    var hourglassStiffness: Float
    var bulkLinear: Float
    var bulkQuadratic: Float
    var soundSpeed: Float
    var criticalStep: Float
    var fixedStep: Float = 0
    var gravity: Float
    var damping: Float
    var ambientPressure: Float = 101_325
    var fluidGamma: Float = 1.4
    var fluidCell: Float = 1
    var fluidNx: UInt32 = 1
    var fluidNy: UInt32 = 1
    var fluidNz: UInt32 = 1
    var coupled: UInt32 = 0
    var minVolumeRatio: Float
    var groundFriction: Float
    var contactMode: UInt32 = 0
    var stamp: UInt32 = 0
    var gridNx: UInt32 = 1
    var gridNy: UInt32 = 1
    var gridNz: UInt32 = 1
    var gridOriginX: Float = 0
    var gridOriginY: Float = 0
    var gridOriginZ: Float = 0
    var contactStiffness: Float = 0
    var contactDamping: Float = 0
    var contactFriction: Float = 0
    var materialModel: UInt32 = 0
    var youngsModulus: Float = 0
    var compressiveStrength: Float = 0
    var tensileStrength: Float = 0
    var crackOnset: Float = 1
    var crackSoftening: Float = 1
    var crushPeak: Float = 1
    var crushEnd: Float = 2
    var erosionStrain: Float = 1
    var crushErosion: Float = 1
    var confinement: Float = 0
    var steelModulus: Float = 0
    var steelPoints: UInt32 = 1
    var steelStrain: (Float, Float, Float, Float, Float, Float, Float, Float) = (0, 0, 0, 0, 0, 0, 0, 0)
    var steelStress: (Float, Float, Float, Float, Float, Float, Float, Float) = (0, 0, 0, 0, 0, 0, 0, 0)
    var rateFilter: Float = 0
    var concreteRateCompression: Float = 0
    var concreteRateTension: Float = 0
    var steelRateYield: Float = 0
    var steelRateUltimate: Float = 0
    var crackBand: Float = 1
    var interlockStrength: Float = 0
    var interlockWidthScale: Float = 0
    var shearRetention: Float = 0.25
    var crackResidual: Float = 0
    var steelHardeningRatio: Float = 0.01
    var loadTime: Float = 0
    var loadCount: UInt32 = 0
    var loadFace: UInt32 = 0
}

/// Layout matches `CouplingUniforms` in `Structure.metal`.
struct CouplingUniforms {
    var regionX: UInt32
    var regionY: UInt32
    var regionZ: UInt32
    var regionNx: UInt32
    var regionNy: UInt32
    var regionNz: UInt32
    var fluidNx: UInt32
    var fluidNy: UInt32
    var fluidNz: UInt32
    var threshold: UInt32
    var ex: UInt32
    var ey: UInt32
    var fluidCell: Float
    var h: Float
    var originX: Float
    var originY: Float
    var originZ: Float
    var gamma: Float
    var ambientDensity: Float
    var ambientPressure: Float
}

/// When nodes of the structure repel each other.
public enum ContactMode: UInt32, Sendable {
    /// Parts of the structure pass through each other.
    case off = 0
    /// Contact switches on once any element has failed; an intact structure does not need it.
    case afterFailure = 1
    case always = 2
}

/// Loads and compiles the compute kernels shared by the fluid and structural solvers.
enum ShaderLibrary {
    static func make(device: MTLDevice) throws -> MTLLibrary {
        let source = try ["Solver", "Structure"].map { name in
            guard
                let url = Bundle.module.url(
                    forResource: name, withExtension: "metal", subdirectory: "Shaders")
            else {
                throw BlastError.missingShader("\(name).metal")
            }
            return try String(contentsOf: url, encoding: .utf8)
        }.joined(separator: "\n")
        return try device.makeLibrary(source: source, options: nil)
    }
}
