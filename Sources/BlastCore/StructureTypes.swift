import ContactSearchMetal
import Foundation
import Metal
import simd

public enum MaterialModel: UInt32, Sendable, Codable {
    /// Elastic-plastic with a single yield stress and a plastic-strain failure limit.
    case vonMises = 0
    /// Concrete that cracks in tension and crushes in compression, with optional reinforcement.
    case concrete = 1
    /// Timber: orthotropic, stiff along its grain and soft across it, in layers that may cross
    /// (cross-laminated timber). Shells and beams only (see `TimberProperties`).
    case timber = 2
}

/// Strength classes of timber: solid softwood (EN 338:2016) and homogeneous glulam
/// (EN 14080:2013).
public enum TimberGrade: String, Sendable, Hashable, Codable, CaseIterable {
    case c16 = "C16"
    case c24 = "C24"
    case c30 = "C30"
    case gl24h = "GL24h"
    case gl28h = "GL28h"

    /// Mean density (kg/m^3).
    public var density: Float {
        switch self {
        case .c16: 370
        case .c24: 420
        case .c30: 460
        case .gl24h: 420
        case .gl28h: 460
        }
    }
}

/// Timber's elastic properties along and across its grain, and how its layers are laid.
///
/// In a shell, each layer is orthotropic plane stress, as ContinuumKit's `OrthotropicPlaneStress`
/// (copied into the shell kernel in single precision), with its grain along `grainAxis` turned by
/// `grainRotation` about the shell's normal, or across it where its lamella is crossed. Through
/// the thickness, shear along the grain takes `shearModulus` and shear across it, rolling the
/// fibres, takes `rollingShearModulus`. A beam's grain runs along it.
public struct TimberProperties: Sendable, Hashable, Codable {
    /// Moduli along and across the grain, and in-plane shear (Pa).
    public var alongGrain: Float
    public var acrossGrain: Float
    public var shearModulus: Float
    /// Shear across the grain through the thickness: rolling shear (Pa).
    public var rollingShearModulus: Float
    /// Poisson's ratio, strain across the grain over strain along it under stress along it.
    public var poissonRatio: Float = 0.35
    /// The global axis (0 x, 1 y, 2 z) the grain of uncrossed lamellae runs along, as far as it
    /// lies in a shell's plane; where it does not (a shell normal to it), along the shell's first
    /// axis.
    public var grainAxis: Int = 0
    /// A further turn of the grain about each shell's normal, in radians.
    public var grainRotation: Float = 0
    /// Strengths (Pa): tension and compression along and across the grain, shear along it and
    /// rolling shear. Left at 1e30, timber never breaks.
    public var tensionAlong: Float = 1e30
    public var compressionAlong: Float = 1e30
    public var tensionAcross: Float = 1e30
    public var compressionAcross: Float = 1e30
    public var shearStrength: Float = 1e30
    public var rollingStrength: Float = 1e30
    /// Fracture energies (J/m^2): breaking the fibres in tension, splitting (opening across the
    /// grain), sliding along it and rolling shear. The fibres' is 0 by default: they break at
    /// once, as the University of Ottawa's glulam beams and CLT panels did, at finger joints and
    /// defects, and as Lacroix recommends for glulam (a brittle resistance curve). Clear wood's
    /// 60 kJ/m^2 (Sandhaas and van de Kuilen) softened members over several times their breaking
    /// strain, and they carried 12-25% more than measured. (ContinuumKit's `TimberFailure`
    /// rejects a zero energy; a band too long for its energy breaks at once there too.)
    public var fibreEnergy: Float = 0
    public var splittingEnergy: Float = 500
    public var shearEnergy: Float = 1200
    public var rollingEnergy: Float = 600
    /// The strengths' dynamic increase factor at blast rates (stiffness takes none).
    public var strengthFactor: Float = 1
    /// The lamellae from the bottom face up (the shell's negative normal side): their shares of
    /// the thickness and whether each crosses the grain. Empty for one layer along the grain
    /// (solid timber and glulam).
    public var lamellae: [Lamella] = []

    public struct Lamella: Sendable, Hashable, Codable {
        public var share: Float
        public var crossed: Bool
        public init(share: Float, crossed: Bool) {
            self.share = share
            self.crossed = crossed
        }
    }

    public init(
        alongGrain: Float, acrossGrain: Float, shearModulus: Float, rollingShearModulus: Float,
        poissonRatio: Float = 0.35, grainAxis: Int = 0, grainRotation: Float = 0, lamellae: [Lamella] = []
    ) {
        self.alongGrain = alongGrain
        self.acrossGrain = acrossGrain
        self.shearModulus = shearModulus
        self.rollingShearModulus = rollingShearModulus
        self.poissonRatio = poissonRatio
        self.grainAxis = grainAxis
        self.grainRotation = grainRotation
        self.lamellae = lamellae
    }

    /// `count` lamellae of equal thickness, crossing in turn, the outer ones along the grain.
    public static func crossLaminated(_ count: Int) -> [Lamella] {
        (0..<count).map { Lamella(share: 1 / Float(count), crossed: $0 % 2 == 1) }
    }

    /// A strength class at its mean values: EN 338:2016 for solid softwood (C16, C24, C30) and
    /// EN 14080:2013 for homogeneous glulam (GL24h, GL28h).
    /// - **Moduli:** the classes' means, rolling shear a tenth of shear (ANSI/APA PRG 320-2019
    ///   Annex X3; the Studiengemeinschaft Holzleimbau's Glulam-Bulletin, 2019).
    /// - **Strengths:** the classes' characteristic values, raised to their means with the JCSS
    ///   Probabilistic Model Code's distributions (Part 3.5, 2006): bending lognormal with a CoV of
    ///   0.25 (0.15 for glulam), which the fibres break at, compression along 0.8 times it, shear
    ///   and rolling shear the same, tension across Weibull at 2.5 times density's 0.1, and
    ///   compression across normal at 0.1. Rolling shear's characteristic value is 1.0 MPa (the
    ///   Glulam-Bulletin, under the German national annex).
    /// - **Fracture energies:** spruce's (Sandhaas and van de Kuilen, HERON 58, 2013) across the
    ///   grain and in shear; along it the fibres break at once (`fibreEnergy`).
    /// - **Dynamic increase factor:** 1.4 on solid timber's strengths (CSA S850-12, as Poulin's
    ///   thesis quotes it; Jacques et al. 2014 found 1.41 on studs' rupture modulus) and 1.14 on
    ///   glulam's (Lacroix's thesis, 2017, for beams without finger joints in their outer
    ///   laminations). Cross-laminated timber takes 1.28 (`crossLaminatedPanel(_:of:)`).
    public static func strengthClass(_ grade: TimberGrade) -> TimberProperties {
        let glulam = grade == .gl24h || grade == .gl28h
        // Characteristic strengths (MPa): bending, compression along, tension and compression
        // across, shear; and mean moduli (MPa): E0, E90, G.
        let (fm, fc0, ft90, fc90, fv, e0, e90, g): (Float, Float, Float, Float, Float, Float, Float, Float) =
            switch grade {
            case .c16: (16, 17, 0.4, 2.2, 3.2, 8000, 270, 500)
            case .c24: (24, 21, 0.4, 2.5, 4.0, 11000, 370, 690)
            case .c30: (30, 24, 0.4, 2.7, 4.0, 12000, 400, 750)
            case .gl24h: (24, 24, 0.5, 2.5, 3.5, 11500, 300, 650)
            case .gl28h: (28, 28, 0.5, 2.5, 3.5, 12600, 300, 650)
            }
        let bending: Float = glulam ? 0.15 : 0.25
        var properties = TimberProperties(
            alongGrain: e0 * 1e6, acrossGrain: e90 * 1e6, shearModulus: g * 1e6, rollingShearModulus: g * 1e5)
        // The fibres break at the bending strength: members under a blast bend, and in bending
        // timber breaks at its rupture modulus, about 1.6 times its strength in pure tension
        // (JCSS: E[R_t,0] = 0.6 E[R_m]), so a member in pure tension is that much too strong.
        properties.tensionAlong = fm * 1e6 * Self.lognormalMean(cov: bending)
        properties.compressionAlong = fc0 * 1e6 * Self.lognormalMean(cov: 0.8 * bending)
        properties.tensionAcross = ft90 * 1e6 * Self.weibullMean(cov: 0.25)
        properties.compressionAcross = fc90 * 1e6 / (1 - 1.645 * 0.1)
        properties.shearStrength = fv * 1e6 * Self.lognormalMean(cov: bending)
        properties.rollingStrength = 1.0e6 * Self.lognormalMean(cov: bending)
        properties.strengthFactor = glulam ? 1.14 : 1.4
        return properties
    }

    /// Cross-laminated timber of `count` lamellae of `grade`, crossing in turn: the strength
    /// class's properties, with the dynamic increase factor Poulin et al. found on CLT panels'
    /// resistance in the University of Ottawa's shock tube, 1.28 (J. Struct. Eng. 144(2), 2018).
    public static func crossLaminatedPanel(_ count: Int, of grade: TimberGrade = .c24) -> TimberProperties {
        var properties = strengthClass(grade)
        properties.lamellae = crossLaminated(count)
        properties.strengthFactor = 1.28
        return properties
    }

    /// A lognormal property's mean over its 5% fractile.
    static func lognormalMean(cov: Float) -> Float {
        let sigma = (log(1 + cov * cov)).squareRoot()
        return exp(1.645 * sigma + 0.5 * sigma * sigma)
    }

    /// A two-parameter Weibull property's mean over its 5% fractile.
    static func weibullMean(cov: Float) -> Float {
        // The shape whose CoV is `cov`, by bisection on Gamma(1 + 2/k) / Gamma(1 + 1/k)^2 - 1.
        var low: Float = 0.5
        var high: Float = 50
        for _ in 0..<60 {
            let k = (low + high) / 2
            let ratio = tgammaf(1 + 2 / k) / pow(tgammaf(1 + 1 / k), 2) - 1
            if ratio.squareRoot() > cov { low = k } else { high = k }
        }
        let k = (low + high) / 2
        return tgammaf(1 + 1 / k) / pow(-log(Float(0.95)), 1 / k)
    }

    /// The lamellae's tops through the thickness, from -1 (bottom face) to 1 (top face).
    var lamellaTops: [Float] {
        let total = lamellae.reduce(0) { $0 + $1.share }
        var top: Float = -1
        return lamellae.map { lamella in
            top += 2 * lamella.share / total
            return top
        }
    }
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

    /// Typical ribbed bar with a 500 MPa characteristic yield. Its rupture strain is a typical
    /// bar's plastic elongation at fracture over the 100 mm window rupture is judged over (its
    /// uniform elongation plus its neck's extension over the window): 15%, since 16 October 2026
    /// (12% before, about a characteristic bar's). See concrete-model.md#reinforcement.
    public static let grade500 = SteelProperties(
        yieldStress: 500e6, ultimateStress: 575e6, ultimateStrain: 0.075, ruptureStrain: 0.15)
}

/// The units masonry is laid in and the mortar joints between them, laid in running bond: each
/// course is offset by half a unit from the one below. Where the solid elements are small enough
/// to show the joints (no more than half a course high and a quarter of a unit long), the
/// elements a joint passes through carry across it only the mortar's bond, and slide along it
/// by Coulomb friction; everywhere else in the wall the units' own strength applies. On coarser
/// elements, and in shells, the wall keeps its material's strength throughout.
public struct MasonryUnits: Sendable, Hashable, Codable {
    /// Length of a unit along the wall with one head joint, in metres.
    public var length: Float
    /// Height of a course: a unit with one bed joint, in metres.
    public var courseHeight: Float
    /// Tensile strength of a unit, in Pa, and the energy to crack a unit area of it, in J/m².
    public var tensileStrength: Float
    public var fractureEnergy: Float
    /// Tensile strength of the bond of mortar to unit, in Pa, and the energy to open a unit
    /// area of joint, in J/m².
    public var bondStrength: Float
    public var bondFractureEnergy: Float
    /// Shear a joint carries with nothing pressing on it, in Pa; it is lost as the joint opens
    /// or slides, over `shearFractureEnergy` (J/m²) of sliding.
    public var cohesion: Float
    /// Coefficient of friction along a joint.
    public var friction: Float
    public var shearFractureEnergy: Float

    public init(
        length: Float, courseHeight: Float, tensileStrength: Float, fractureEnergy: Float,
        bondStrength: Float,
        bondFractureEnergy: Float, cohesion: Float, friction: Float, shearFractureEnergy: Float
    ) {
        self.length = length
        self.courseHeight = courseHeight
        self.tensileStrength = tensileStrength
        self.fractureEnergy = fractureEnergy
        self.bondStrength = bondStrength
        self.bondFractureEnergy = bondFractureEnergy
        self.cohesion = cohesion
        self.friction = friction
        self.shearFractureEnergy = shearFractureEnergy
    }

    /// Solid clay bricks, 215 by 65 mm on face with 10 mm joints. The joints are those of
    /// Lourenço and Rots (1997) for van der Pluijm's and Raijmakers and Vermeltfoort's brickwork:
    /// 0.25 MPa and 18 J/m² in tension, a cohesion of 1.4 times that, friction 0.75 and 125 J/m²
    /// in shear; a brick cracks at 2 MPa with 80 J/m².
    public static let brick = MasonryUnits(
        length: 0.225, courseHeight: 0.075, tensileStrength: 2e6, fractureEnergy: 80, bondStrength: 0.25e6,
        bondFractureEnergy: 18, cohesion: 0.35e6, friction: 0.75, shearFractureEnergy: 125)

    /// Hollow dense concrete blocks, 440 by 215 mm on face with 10 mm joints, per gross area: a
    /// block of 7.3 MPa about 55% solid is of 13 MPa concrete, which by the correlations used
    /// for concrete cracks at 1.7 MPa with 115 J/m², so the block at 0.9 MPa with 60 J/m²; the
    /// joints have the blockwork's 0.2 MPa and 10 J/m² in tension, and the brickwork's ratios
    /// in shear.
    public static let concreteBlock = MasonryUnits(
        length: 0.45, courseHeight: 0.225, tensileStrength: 0.9e6, fractureEnergy: 60, bondStrength: 0.2e6,
        bondFractureEnergy: 10, cohesion: 0.28e6, friction: 0.75, shearFractureEnergy: 100)

    /// Whether elements of size `h` are small enough to show the joints: at least two to a
    /// course, and two to the half unit by which courses overlap.
    public func isResolved(byElementsOf h: Float) -> Bool {
        courseHeight >= 1.999 * h && length >= 3.999 * h
    }
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
    /// Judge a bar's rupture by its plastic strain averaged over a debonded length (the crack
    /// spacing) rather than in the one element a crack runs through.
    public var bondSpreading = true
    /// Gain in compressive strength per unit of lateral confining stress (Richart's 4.1).
    public var confinementCoefficient: Float = 4.1
    /// Largest aggregate size in metres, which governs how well a crack still carries shear.
    public var aggregateSize: Float = 0.016
    /// Fraction of a crack's inelastic opening that remains when the tension across it is
    /// released, because fragments and misfit stop the faces closing completely.
    public var crackResidual: Float = 0.1
    /// Multiplier on the bars' dowel action across cracks (1, Rasmussen's strength for a bar
    /// well embedded in concrete), for studying how much it matters.
    public var dowelFactor: Float = 1
    /// Multiplier on aggregate interlock's shear capacity across cracks (1, the modified
    /// compression field theory's), for studying how much it matters.
    public var interlockFactor: Float = 1
    /// With `rateDependent`, the fracture energy grows as the tensile strength's rate factor to
    /// this power: 1 scales the whole tension-softening curve with the strength, 0 keeps the
    /// static fracture energy.
    public var fractureRateExponent: Float = 0.5
    /// A crack that has slid (see `StructureModel.crackSlip`) keeps at least this times its slip
    /// open: its faces ride up on the aggregate and cannot close (dilatancy).
    public var crackDilatancy: Float = 0.5
    /// Fixed multipliers on strength, such as the design dynamic increase factors of
    /// UFC 3-340-02. They apply on top of `rateDependent`, so normally use one or the other.
    public var concreteRateFactor: Float = 1
    public var steelRateFactor: Float = 1
    /// Raise strength with the local strain rate: CEB-FIP 1990 for concrete in compression, the
    /// fib Model Code 2010 in tension, and for reinforcement the CEB's law (Bulletin 187, 1988),
    /// which the Model Code 2010 re-adopted.
    public var rateDependent = false
    /// With `rateDependent`, raise the bars' strength too; off, they keep their static curve.
    public var steelRateDependent = true
    /// Masonry: the units it is laid in and the joints between them (see `MasonryUnits`). The
    /// strengths above are then the wall's as a whole, used where the elements are too coarse
    /// to show the joints.
    public var units: MasonryUnits?
    /// Drawn as see-through glass rather than an opaque solid.
    public var isTransparent = false
    /// Timber's orthotropy and layers, for `MaterialModel.timber`.
    public var timber: TimberProperties?
    /// A beam's flange that buckles locally (a thin-walled section's, as a profiled sheet's rib):
    /// its fibres on that side lose their compressive stress past an onset strain. Nil for none.
    public var localBuckling: LocalBuckling?

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

    /// Timber of a strength class at its mean density, its grain along `grainAxis`; with
    /// `lamellae` above one, cross-laminated.
    public static func timber(_ grade: TimberGrade, grainAxis: Int = 0, lamellae: Int = 1) -> Self {
        var properties =
            lamellae > 1
            ? TimberProperties.crossLaminatedPanel(lamellae, of: grade)
            : TimberProperties.strengthClass(grade)
        properties.grainAxis = grainAxis
        let glulam = grade == .gl24h || grade == .gl28h
        let name =
            lamellae > 1
            ? "CLT, \(lamellae) lamellae of \(grade.rawValue)"
            : glulam ? "Glulam \(grade.rawValue)" : "Softwood \(grade.rawValue)"
        return .timber(name: name, density: grade.density, properties: properties)
    }

    /// Timber with the given properties: breaking as its strengths say, never if they are left
    /// at 1e30.
    public static func timber(name: String, density: Float, properties: TimberProperties) -> Self {
        var material = Self(
            name: name, density: density, youngsModulus: properties.alongGrain,
            poissonRatio: properties.poissonRatio, yieldStress: 1e30, failureStrain: 1e30)
        material.model = .timber
        material.timber = properties
        return material
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

    /// Unreinforced solid masonry (brick), treated as a weak, brittle concrete.
    public static let masonry: Self = {
        var material = concrete(name: "Masonry", compressiveStrength: 8e6, density: 1900)
        material.youngsModulus = 6e9
        material.tensileStrength = 0.3e6
        material.fractureEnergy = 20
        material.crushingEnergy = 5000
        material.erosionOpening = 0.003
        material.units = .brick
        return material
    }()

    /// Hollow dense concrete blockwork ("breeze block"), treated as masonry is: a weak, brittle
    /// concrete, its properties for the wall as a whole, per gross area. Blocks of 7.3 MPa about
    /// 55% solid, in general-purpose mortar: by Eurocode 6 (EN 1996-1-1), f_k = 0.45 f_b^0.7
    /// f_m^0.3, about 3 MPa, and E = 1000 f_k; a tensile strength of 0.2 MPa, set by the bond to
    /// the mortar, and 10 N/m of fracture energy.
    public static let concreteBlock: Self = {
        var material = concrete(name: "Concrete block", compressiveStrength: 3e6, density: 1400)
        material.youngsModulus = 3e9
        material.tensileStrength = 0.2e6
        material.fractureEnergy = 10
        material.crushingEnergy = 2500
        material.erosionOpening = 0.003
        material.units = .concreteBlock
        return material
    }()

    /// Structural steel, S355: yields at 355 MPa and hardens slowly, failing at 20% strain.
    public static let structuralSteel = Self(
        name: "Structural steel", density: 7850, youngsModulus: 210e9, poissonRatio: 0.3, yieldStress: 355e6,
        hardeningModulus: 1e9, failureStrain: 0.2)

    /// Annealed float glass, as a brittle material: elastic until it cracks at 45 MPa, then
    /// gone after a fraction of a millimetre (its fracture energy, about 8 J/m², is that of
    /// toughness 0.75 MPa m^(1/2)). Meant for panes meshed as shells.
    public static let annealedGlass: Self = {
        var material = concrete(name: "Annealed glass", compressiveStrength: 1000e6, density: 2500)
        material.youngsModulus = 70e9
        material.poissonRatio = 0.22
        material.tensileStrength = 45e6
        material.fractureEnergy = 8
        material.crushingEnergy = 2000
        material.erosionOpening = 0.0005
        material.aggregateSize = 0
        material.isTransparent = true
        return material
    }()

    /// Thermally toughened glass (EN 12150-1): annealed glass whose surfaces are held in
    /// compression, so that it cracks only at its characteristic bending strength of 120 MPa.
    /// Broken, it dices; here it fails as annealed glass does, at the higher stress.
    public static let toughenedGlass: Self = {
        var material = annealedGlass
        material.name = "Toughened glass"
        material.tensileStrength = 120e6
        return material
    }()

    /// Softwood of strength class C24 (EN 338), its grain along x: joists, rafters and studs.
    public static let softwood: Self = .timber(.c24)
    /// Homogeneous glulam GL24h (EN 14080), its grain along x: beams and columns.
    public static let glulam: Self = .timber(.gl24h)
    /// Cross-laminated timber of five C24 lamellae, the outer ones along x: walls and floors.
    public static let crossLaminatedTimber: Self = .timber(.c24, lamellae: 5)

    public static let presets: [Self] = [
        .reinforcedConcrete, .plainConcrete, .masonry, .concreteBlock, .structuralSteel, .annealedGlass,
        .toughenedGlass, .softwood, .glulam, .crossLaminatedTimber,
    ]

    public var shearModulus: Float { youngsModulus / (2 * (1 + poissonRatio)) }

    public var lameLambda: Float {
        youngsModulus * poissonRatio / ((1 + poissonRatio) * (1 - 2 * poissonRatio))
    }

    /// Speed of compression waves in the bulk material, which sets the explicit time step.
    public var dilatationalWaveSpeed: Float {
        ((lameLambda + 2 * shearModulus) / density).squareRoot()
    }

    /// Speed of in-plane compression waves in a thin plate, which is in plane stress.
    public var plateWaveSpeed: Float {
        (youngsModulus / (density * (1 - poissonRatio * poissonRatio))).squareRoot()
    }
}

/// How a structure is meshed.
public enum ElementKind: String, Sendable, Hashable, Codable, CaseIterable {
    /// Cubic solid elements on a lattice, several through the thickness of a wall.
    case solid
    /// Four-node shell elements on the midsurfaces of walls and slabs, with layers through the
    /// thickness. Every solid must then be plate-like.
    case shell
}

/// Reinforcement smeared uniformly through a region. `ratio` is steel area per unit area of
/// concrete for bars running along x, y and z.
/// How one solid of a structure is reinforced.
public enum Reinforcement: Sendable, Hashable, Codable {
    /// Worked out from the solid's shape: a mat of bars in each face of a wall or slab (565 mm²
    /// per metre each way, centred 40 mm in), or 2% steel along a column with 0.4% ties.
    case automatic
    /// Plain concrete.
    case none
    /// A mat of bars, the same each way, centred `depth` in from one or both faces of a wall or
    /// slab. With one face, it is the face on the low side of the thin axis.
    case mats(areaPerMetre: Float, depth: Float, bothFaces: Bool)
    /// Steel along the solid's longest dimension and ties across it, as fractions of the area.
    case column(longitudinal: Float, ties: Float)
}

public struct ReinforcementLayer: Sendable, Hashable, Codable {
    public var region: Box
    public var ratio: SIMD3<Float>

    public init(region: Box, ratio: SIMD3<Float>) {
        self.region = region
        self.ratio = ratio
    }
}

/// A layer of straight bars at 45 degrees to two lattice axes, such as the diagonal bars across
/// a chamfered corner. In the plane of those two axes the bars run from `start` along
/// `direction` (which has equal and opposite or equal components along the two axes and none
/// along the third) for `length`; the layer repeats along the third axis over `span`, with
/// `areaPerMetre` of bar per metre along it. It is smeared across a band sqrt(2) elements wide,
/// over the diagonal rows of elements there in proportion to how near each lies to the bars,
/// so that its steel is kept.
/// An element holds one set of inclined bars; where layers of different directions overlap,
/// the larger wins.
public struct InclinedBars: Sendable, Hashable, Codable {
    public var start: SIMD3<Float>
    public var direction: SIMD3<Float>
    public var length: Float
    public var span: ClosedRange<Float>
    public var areaPerMetre: Float

    public init(
        start: SIMD3<Float>, direction: SIMD3<Float>, length: Float, span: ClosedRange<Float>,
        areaPerMetre: Float
    ) {
        self.start = start
        self.direction = direction
        self.length = length
        self.span = span
        self.areaPerMetre = areaPerMetre
    }

    /// The two lattice axes the bars lie between, the third, and the code the element kernel
    /// knows them by (see `ElementSteel` in Structure.metal).
    var axes: (third: Int, code: UInt16)? {
        let magnitude = simd_abs(direction)
        guard let third = (0..<3).first(where: { magnitude[$0] < 1e-6 }) else { return nil }
        let plane = (third + 1) % 3  // the planes are (x, y), (y, z), (z, x): their first axis
        let other = (plane + 1) % 3
        guard abs(magnitude[plane] - magnitude[other]) < 1e-4 * max(magnitude[plane], 1e-6) else {
            return nil
        }
        let backwards = (direction[plane] > 0) != (direction[other] > 0)
        return (third, UInt16(1 + 2 * plane + (backwards ? 1 : 0)))
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
    /// For shells, each element's share of the pressure, in the mesh's order (a line load
    /// spread over the elements under it); nil for all of it everywhere.
    public var elementShares: [Float]?
    /// For shells and beams, each node's share of the table as a force (N per Pa of the table),
    /// pushing against the loaded faces' outward normal, in the mesh's node order: a load the
    /// beams take; nil for none.
    public var nodeShares: [Float]?

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
    /// With `fixedBase`, ties the base to the ground by a connection that can deform, open,
    /// slide and fail (see `Anchorage`) instead of clamping it. Nil clamps it. Support regions
    /// have independent connection laws.
    public var baseAnchorage: Anchorage?
    public var reinforcement: [ReinforcementLayer] = []
    /// Bars at 45 degrees to the lattice (see `InclinedBars`).
    public var inclinedBars: [InclinedBars] = []
    /// How each solid is reinforced, by index into `solids`; solids beyond the end of this list
    /// are reinforced automatically. Applied by `autoReinforce()`.
    public var solidReinforcement: [Reinforcement] = []
    /// The material of each solid, by index into `solids`, where it is not `material`. Where
    /// solids overlap, the later one's material wins.
    public var solidMaterial: [StructureMaterial?] = []
    /// Source ownership travels with editable regions, including after detachment. A nil
    /// entry is a locally added region; the part ID is scoped to its imported instance.
    public struct SourcePart: Sendable, Hashable, Codable {
        public var modelID: UUID
        public var partID: Int
        public init(modelID: UUID, partID: Int) {
            self.modelID = modelID
            self.partID = partID
        }
    }
    public var solidSourceParts: [SourcePart?] = []
    /// Solid elements on a lattice, or shells on the midsurfaces of walls and slabs. With
    /// shells, `elementSize` is their size in the plane of the wall or slab.
    public var elementKind: ElementKind = .solid
    /// How each solid is meshed, by index into `solids`, where it differs from `elementKind`.
    /// A body with both kinds is meshed as two, tied together where shells meet solid elements;
    /// `elementSize` is then the solid elements' size and `shellElementSize` the shells'.
    public var solidElementKind: [ElementKind?] = []
    /// Profiled metal sheets, by index into `solids`: a solid with one is a sheet of that profile,
    /// its ribs along the axis given, meshed as shells (`ProfiledSheet`) of its own material's
    /// steel at the profile's yield. Encoded only when some solid has one.
    public var solidSheets: [SheetAssignment?] = []
    /// Connections along shell edges as springs to fixed ground (shells only).
    public var springSupports: [SpringSupport] = []
    /// Profiled sheets screwed to the beams they lie on, as `expandingSheets` leaves them.
    public var sheetFastenings: [SheetFastening] = []
    /// In a body of both kinds, the shells' size; `elementSize` if nil.
    public var shellElementSize: Float?
    /// Layers of concrete (or other material) through the thickness of each shell.
    public var shellLayers: Int = 8
    /// With shells, whether members that touch but share no node of the mesh (layers stacked
    /// face to face, a beam meeting a column off its centreline) are tied at their nearest
    /// nodes. Set for structures from IFC; nil (no) otherwise.
    public var tiesTouching: Bool?
    /// Regions in which the structure is held still: nodes inside any of them do not move
    /// (beyond the ground plane, which `fixedBase` holds). For walls built into rigid scenery.
    public var supports: [Box] = []
    /// Per-region horizontal bearing laws. Missing or nil entries clamp the region.
    public var supportAnchorages: [Anchorage?] = []
    /// Where two materials meet, the elements on the weaker one's side carry only this bond
    /// across the boundary: tensile strength (Pa) and fracture energy (J/m²), as of mortar on
    /// concrete, so that infill can come away from its frame. Nil bonds them as one body.
    public var interfaceBond: SIMD2<Float>?
    /// A typical bond of masonry to concrete: 0.2 MPa and 10 J/m².
    public static let masonryBond = SIMD2<Float>(0.2e6, 10)

    /// Whether masonry is meshed as units and mortar joints where its material gives them and
    /// the solid elements are small enough (see `MasonryUnits`).
    public var unitJoints = true
    /// Whether shells check each section's shear against the simplified modified compression
    /// field theory, as beams always do. Off by default: under a blast the slab test's shells
    /// carried shears near their supports that the method, which is static, says they cannot.
    public var shellSectionShear = false

    /// Whether concrete whose crack axes are fixed opens a second crack where the tension turns
    /// more than 30 degrees away from them, instead of carrying it across the first by shear.
    public var secondCracks = true
    /// Whether concrete that has crushed or opened past removal while its bars are intact stays
    /// as those bars alone (see `ElementFlag.bare`), so that a holed member hangs on its bars,
    /// instead of taking its smeared bars with it.
    public var bareBars = true
    /// Whether concrete broken into fragments is removed (left as its bars where they are intact):
    /// cracked open across at least two planes by 0.5 mm, and across one by 5% of the element's
    /// size, by analogy with the erosion of the continuous surface cap model (damage near one and
    /// principal strain past 5%) with which Martínez-Almajano et al. (2021) holed slabs under
    /// close-in charges. Off by default: see the concrete model's Removal.
    public var removesFragments = false
    /// Whether shear that a crack's interlock and dowels cannot hold slides it for good, as a
    /// masonry joint slides, instead of springing back when the load comes off.
    public var crackSlip = true
    /// Bars that slip in their concrete, by the Model Code's bond-slip law (see `BondSlip`); nil
    /// bonds them perfectly. Solid elements' bars along the lattice axes only.
    public var bondSlip: BondSlip?
    /// Bars given as their own trusses (`DiscreteBar`), embedded in the elements, in place of the
    /// smeared bars' stress along them: the elements' smeared bars then stand only for dowel
    /// action, bridging cracks and the hourglass cap. They slip by `bondSlip`, or are bonded
    /// perfectly without it (smeared bars never slip beside them). Solid elements only; none by
    /// default.
    public var discreteBars: [DiscreteBar] = []
    /// Whether the reinforcement layers' bars along the lattice axes are laid as discrete bars too
    /// (`barsFromLayers`), of `trussDiameter`, or failing that `bondSlip`'s, or 12 mm.
    public var barsAsTrusses = false
    public var trussDiameter: Float?
    /// With a length (m), cracks soften by their inelastic strain averaged over the elements
    /// within it either side across their band, along the lattice axis nearest their normal,
    /// their fracture energy spread over that band: nonlocal cracking, which keeps a crack from
    /// gathering into one element. Solid elements only; nil, cracks soften element by element.
    public var crackAveraging: Float?
    /// The time (s) over which the strain rate the rate laws see is averaged: 100 µs by default
    /// (`defaultStrainRateWindow`, since 12 October 2026). Nil averages over the last 50 of the
    /// structure's steps instead, as before, a window that shrinks with the element and the step
    /// (see validation.md, "Convergence on today's defaults"). Saved as 0 when nil, and left out
    /// at the default.
    public var strainRateWindow: Float? = StructureModel.defaultStrainRateWindow
    /// The default strain-rate window, 100 µs: between the 50-step windows of the meshes the
    /// defaults were chosen on (80 µs for the contest slab on 8 elements, 107 µs for Saatci's
    /// beams on 16, 53 and 131 µs for Janney's beam on 24 and 12).
    public static let defaultStrainRateWindow: Float = 1e-4
    /// Whether concrete that fails becomes particles that keep its mass (`RubbleParticle`), each
    /// taking its element's mass, momentum and energy from the element's nodes and pushing, in
    /// contact only, on the other particles and on what is left of the body: rubble that carries
    /// compression but no tension, and leaves the body's nodes. Off, a failed element's mass stays
    /// on its nodes. Solid elements only; off by default.
    public var rubbleParticles = false
    /// Whether an element with a free face cracks when that face reaches the tensile strength,
    /// its bending across its depth read from its hourglass modes, rather than when its centre
    /// does. Off, the bottom layer of a slab n elements deep cracks at about 1 + 1/n times the
    /// section's cracking moment, which decides a lightly reinforced slab's strength. Solid
    /// elements only; off by default.
    public var extremeFibreCracking = false
    /// Whether a bare element of structural concrete (its bars alone, `bareBars`) is removed once
    /// squeezed below a quarter of its volume, as softer materials' are. Flattened or turned inside
    /// out across its bars' plane, its bars' strains blow up and fling its nodes apart: in Hupfauf's
    /// SN144 one was thrown at 2,400 m/s (docs/structural-model.md). Off by default.
    public var erodesCrushedBare = false
    /// Whether a bare element of structural concrete crushed below a quarter of its volume keeps
    /// its bars but loses its hourglass control, whose mode shapes grow as one over the element's
    /// volume and fling its nodes (Hupfauf's SN144). Off by default; an alternative to
    /// `erodesCrushedBare`, which removes the element and its bars' tie.
    public var releasesCrushedBareHourglass = false
    /// Whether a crack's faces, riding up on their aggregate as it slides, press on whatever holds
    /// it from opening, and pressed, carry more shear: Walraven and Reinhardt's relations between
    /// a crack's opening, slip, shear and the stress across it (HERON 26(1A), 1981, eqs. 1a and
    /// 1b), which their push-off tests with restraint follow. Off, a crack carries the interlock
    /// of an unpressed crack whatever presses it. Solid elements only. The confined regime's
    /// defaults turn it on as well (`appliesPressedInterlock`).
    public var pressedInterlock = false
    /// The regime the user chose the defaults for (`StructuralRegime`); nil to take the one the
    /// scene detects.
    public var regimeOverride: StructuralRegime?
    /// The loading the user chose the defaults for; nil to take the scene's.
    public var loadingOverride: StructuralLoading?
    /// Whether the regime's defaults apply (see `appliesPressedInterlock` and
    /// `appliesBeamSectionShear`); off, every option is as set. On by default.
    public var regimeDefaults = true
    /// The regime and loading the scene the model runs in gives it (`detectingRegime(in:)`); not
    /// saved.
    public internal(set) var detectedRegime: StructuralRegime?
    public internal(set) var detectedLoading: StructuralLoading?
    /// Whether a cracked solid element's hourglass control (the bending its one integration point
    /// cannot feel) stiffens only as its most opened crack's secant share of the elastic, instead
    /// of as an uncracked element whatever its cracking, up to the cap.
    public var hourglassFollowsCracking = false
    /// Whether the bars' strength counts in the cap on a solid element's hourglass control, as if
    /// they were spread through its depth and so could bend it; off, only the concrete's
    /// remaining strength does.
    public var hourglassCapsSteel = true
    /// Options retired since the model was saved, which it set away from what is now the only
    /// behaviour, each with a note of what it did and what applies instead (see
    /// docs/concrete-strategy.md); not saved.
    public internal(set) var retiredOptions: [String] = []

    /// Most materials one structure can hold.
    public static let maxMaterials = 8

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

    /// Whether a solid fills `point`. An opening cuts the solids it crosses but not one it holds
    /// whole: a pane of glass set in a wall's opening stays.
    public func occupies(_ point: SIMD3<Float>) -> Bool {
        solids.contains { solid in
            solid.contains(point) && !openings.contains { $0.contains(point) && !$0.holds(solid) }
        }
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

    /// How solid `index` is reinforced.
    public func reinforcement(of index: Int) -> Reinforcement {
        solidReinforcement.indices.contains(index) ? solidReinforcement[index] : .automatic
    }

    /// Sets how solid `index` is reinforced. Call `autoReinforce()` afterwards to apply it.
    public mutating func setReinforcement(_ spec: Reinforcement, of index: Int) {
        guard solids.indices.contains(index) else { return }
        while solidReinforcement.count <= index { solidReinforcement.append(.automatic) }
        solidReinforcement[index] = spec
    }

    /// Removes solid `index` together with its reinforcement and material settings.
    public mutating func removeSolid(at index: Int) {
        guard solids.indices.contains(index) else { return }
        solids.remove(at: index)
        if solidReinforcement.indices.contains(index) { solidReinforcement.remove(at: index) }
        if solidMaterial.indices.contains(index) { solidMaterial.remove(at: index) }
        if solidElementKind.indices.contains(index) { solidElementKind.remove(at: index) }
        if solidSourceParts.indices.contains(index) { solidSourceParts.remove(at: index) }
        if solidSheets.indices.contains(index) { solidSheets.remove(at: index) }
    }

    /// How solid `index` is meshed: a profiled sheet always as shells.
    public func elementKind(of index: Int) -> ElementKind {
        // Profiled sheets and timber are meshed as shells and beams whatever the rest is.
        if sheet(of: index) != nil || material(of: index).model == .timber { return .shell }
        return (solidElementKind.indices.contains(index) ? solidElementKind[index] : nil) ?? elementKind
    }

    /// The profiled sheet solid `index` is, if it is one.
    public func sheet(of index: Int) -> SheetAssignment? {
        solidSheets.indices.contains(index) ? solidSheets[index] : nil
    }

    /// Makes solid `index` a profiled sheet, or (nil) a plain solid again.
    public mutating func setSheet(_ sheet: SheetAssignment?, of index: Int) {
        guard solids.indices.contains(index) else { return }
        while solidSheets.count <= index { solidSheets.append(nil) }
        solidSheets[index] = sheet
        while solidSheets.last.map({ $0 == nil }) == true { solidSheets.removeLast() }
    }

    /// The same body with each profiled sheet built as `ProfiledSheet` builds it: its solid the
    /// skin, as thick as the profile is deep, the ribs appended after the other solids. The
    /// body as the shell solver meshes it.
    public func expandingSheets() -> StructureModel {
        guard solidSheets.contains(where: { $0 != nil }) else { return self }
        var model = self
        model.solidSheets = []
        for index in solids.indices {
            guard let sheet = sheet(of: index) else { continue }
            let built = ProfiledSheet(
                profile: sheet.profile, region: solids[index], span: sheet.ribAxis,
                steel: material(of: index),
                crestSide: sheet.crestSide ?? 1
            )
            .build(in: &model, at: index)
            if let fastening = sheet.fastening {
                model.sheetFastenings.append(
                    SheetFastening(solids: built, fastening: fastening, crestSide: sheet.crestSide ?? 1))
            }
        }
        return model
    }

    /// Meshes solid `index` with `kind`.
    public mutating func setElementKind(_ kind: ElementKind, of index: Int) {
        guard solids.indices.contains(index) else { return }
        while solidElementKind.count <= index { solidElementKind.append(nil) }
        solidElementKind[index] = kind == elementKind ? nil : kind
    }

    /// The same body with the pieces that come within `distance` of `point` meshed as solid
    /// elements of `elementSize` and the rest as shells of `shellSize`: solid elements where the
    /// stress through a wall's thickness matters, near a charge.
    public func solidNear(_ point: SIMD3<Float>, within distance: Float, shellSize: Float) -> StructureModel {
        var model = self
        model.elementKind = .solid
        model.solidElementKind = []
        for (index, box) in solids.enumerated() {
            let nearest = simd_clamp(point, box.min, box.max)
            model.setElementKind(simd_distance(nearest, point) <= distance ? .solid : .shell, of: index)
        }
        if model.isMixed {
            model.shellElementSize = shellSize
        } else if let kind = solids.indices.first.map({ model.elementKind(of: $0) }), kind == .shell {
            // Nothing is near: all shells.
            model.elementKind = .shell
            model.solidElementKind = []
            model.elementSize = shellSize
        }
        return model
    }

    /// Whether some solids are meshed with solid elements and others with shells.
    public var isMixed: Bool {
        Set(solids.indices.map { elementKind(of: $0) }).count > 1
    }

    /// Whether every solid is meshed as shells and beams, as chosen or as its material needs.
    public var isAllShells: Bool {
        !solids.isEmpty && solids.indices.allSatisfy { elementKind(of: $0) == .shell }
    }

    /// The part of the body meshed with `kind`: its solids, with their materials and
    /// reinforcement, and everything else; nil if there are none.
    public func part(_ kind: ElementKind) -> StructureModel? {
        let chosen = solids.indices.filter { elementKind(of: $0) == kind }
        guard !chosen.isEmpty else { return nil }
        var part = self
        part.elementKind = kind
        part.solids = chosen.map { solids[$0] }
        part.solidMaterial = chosen.map { solidMaterial.indices.contains($0) ? solidMaterial[$0] : nil }
        part.solidReinforcement = chosen.map { reinforcement(of: $0) }
        part.solidSheets = chosen.map { sheet(of: $0) }
        part.solidElementKind = []
        if kind == .shell, let shellElementSize { part.elementSize = shellElementSize }
        return part
    }

    /// The material of solid `index`.
    public func material(of index: Int) -> StructureMaterial {
        (solidMaterial.indices.contains(index) ? solidMaterial[index] : nil) ?? material
    }

    /// Sets the material of solid `index`; nil returns it to the structure's own material.
    public mutating func setMaterial(_ newMaterial: StructureMaterial?, of index: Int) {
        guard solids.indices.contains(index) else { return }
        while solidMaterial.count <= index { solidMaterial.append(nil) }
        solidMaterial[index] = newMaterial == material ? nil : newMaterial
    }

    /// The distinct materials in the structure, `material` first.
    public var materials: [StructureMaterial] {
        var list = [material]
        for case let other? in solidMaterial where !list.contains(other) {
            list.append(other)
        }
        return list
    }

    /// Index into `materials` of the material at `point`: that of the last solid containing it.
    public func materialIndex(at point: SIMD3<Float>) -> Int {
        guard let index = solids.lastIndex(where: { $0.contains(point) }) else { return 0 }
        return materials.firstIndex(of: material(of: index)) ?? 0
    }

    /// The mortar joints that pass through the element whose low corner is `low`, as bits 0 to 2
    /// for joints across x, y and z. The element belongs to the last solid that contains its
    /// centre, a wall of `units` laid from that solid's base: bed joints every course, across
    /// z, and head joints every unit along the longer of the solid's horizontal sides, offset
    /// by half a unit in alternate courses.
    func jointPlanes(inElementAt low: SIMD3<Float>, units: MasonryUnits) -> UInt8 {
        let h = elementSize
        let centre = low + 0.5 * h
        guard let wall = solids.last(where: { $0.contains(centre) }) else { return 0 }
        let slack = 1e-3 * h
        /// Whether a plane of the family `start + n * spacing` lies in [from, from + h).
        func crosses(_ from: Float, start: Float, spacing: Float) -> Bool {
            let next = start + ((from - slack - start) / spacing).rounded(.up) * spacing
            return next < from + h - slack
        }
        var planes: UInt8 = 0
        if crosses(low.z, start: wall.min.z, spacing: units.courseHeight) { planes |= 4 }
        let along = wall.size.x >= wall.size.y ? 0 : 1
        let course = Int(((centre.z - wall.min.z) / units.courseHeight).rounded(.down))
        let start = wall.min[along] + (course % 2 == 0 ? 0 : 0.5 * units.length)
        // The wall's own ends are not joints.
        if crosses(low[along], start: start, spacing: units.length), low[along] - slack > wall.min[along] {
            planes |= UInt8(1 << along)
        }
        return planes
    }

    /// Replaces the reinforcement with the arrangement each solid asks for. Solids left as
    /// `.automatic` get a standard arrangement worked out from their shape: a slab or wall (one
    /// dimension much smaller than the others) gets a mat of bars in both faces; anything
    /// stockier is treated as a column, with 2% steel along its length and ties across it.
    ///
    /// - Parameters:
    ///   - areaPerMetre: Bar area per metre width of each automatic mat, each way, in m²/m.
    ///   - depth: Distance from a face to the centre of its automatic mat.
    public mutating func autoReinforce(areaPerMetre: Float = 565e-6, depth: Float = 0.04) {
        reinforcement = []
        for (index, solid) in solids.enumerated() {
            let size = solid.size
            let thin = (0..<3).min { size[$0] < size[$1] } ?? 0
            let long = (0..<3).max { size[$0] < size[$1] } ?? 2
            let others = (0..<3).filter { $0 != thin }
            let isSlab = size[thin] <= 0.6 && others.allSatisfy { size[$0] >= 3 * size[thin] }
            func column(_ longitudinal: Float, _ ties: Float) {
                var ratio = SIMD3<Float>(repeating: ties)
                ratio[long] = longitudinal
                reinforcement.append(ReinforcementLayer(region: solid, ratio: ratio))
            }
            switch reinforcement(of: index) {
            case .automatic:
                if isSlab {
                    addMat(
                        to: solid, thicknessAxis: thin, areaPerMetre: areaPerMetre,
                        depth: Swift.min(depth, size[thin] / 2))
                } else {
                    column(0.02, 0.004)
                }
            case .none:
                break
            case .mats(let area, let matDepth, let bothFaces):
                addMat(
                    to: solid, thicknessAxis: thin, areaPerMetre: area,
                    depth: Swift.min(matDepth, size[thin] / 2), faces: (true, bothFaces))
            case .column(let longitudinal, let ties):
                column(longitudinal, ties)
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
    /// lets it rise but not fall below where it started. Bit 5 is set by the solver when all
    /// eight elements around the node are intact, which leaves it out of contact. Bit 6 keeps
    /// its vertical velocity as set. Bit 7 lets it fall but not rise above where it started.
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

    /// Held down by a support above it: the node cannot rise above its starting height, and
    /// falls away freely.
    public var isHeldDown: Bool {
        get { flags & 128 != 0 }
        set { flags = newValue ? flags | 128 : flags & ~128 }
    }

    /// Moves at its current velocity regardless of the forces on it.
    public var isPrescribed: Bool {
        get { flags & 8 != 0 }
        set { flags = newValue ? flags | 8 : flags & ~8 }
    }

    /// Keeps its current vertical velocity regardless of the forces on it, and is free
    /// sideways: a node under a loading plate on rollers.
    public var isPushedVertically: Bool {
        get { flags & 64 != 0 }
        set { flags = newValue ? flags | 64 : flags & ~64 }
    }
}

public enum ElementFlag: UInt8, Sendable {
    case empty = 0
    case active = 1
    case eroded = 2
    /// Concrete gone, its bars still carrying: no concrete stress and no air load, but it holds
    /// its nodes together along its intact bars until they rupture.
    case bare = 4
}

public struct StructureSummary: Sendable, Hashable {
    /// Elements still carrying load.
    public var activeElements = 0
    /// Elements removed after reaching the failure strain.
    public var erodedElements = 0
    /// Largest displacement now, in metres, of a node still attached to an active element: the
    /// structure's deflection at this moment, not the largest it has reached.
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

    /// The summary of two parts of one body together.
    public func combined(with other: StructureSummary) -> StructureSummary {
        var both = self
        both.activeElements += other.activeElements
        both.erodedElements += other.erodedElements
        both.maxDisplacement = max(maxDisplacement, other.maxDisplacement)
        both.maxPlasticStrain = max(maxPlasticStrain, other.maxPlasticStrain)
        both.maxDamage = max(maxDamage, other.maxDamage)
        both.hasBlownUp = hasBlownUp || other.hasBlownUp
        return both
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
    var bulkLinear: Float
    var bulkQuadratic: Float
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
    var contactNx: UInt32 = 1
    var contactNy: UInt32 = 1
    var contactNz: UInt32 = 1
    var gridOriginX: Float = 0
    var gridOriginY: Float = 0
    var gridOriginZ: Float = 0
    var contactStiffness: Float = 0
    var contactDamping: Float = 0
    var contactFriction: Float = 0
    var rateFilter: Float = 0
    var loadTime: Float = 0
    var loadCount: UInt32 = 0
    var loadFace: UInt32 = 0
    var debrisLoading: UInt32 = 0
    var exchangeX: Int32 = 0
    var exchangeY: Int32 = 0
    var exchangeZ: Int32 = 0
    var exchangeNx: Int32 = 0
    var exchangeNy: Int32 = 0
    var exchangeNz: Int32 = 0
    var fluidAirModel: UInt32 = 0
    var interfaceLinks: UInt32 = 0
    var fluidRefine: UInt32 = 0
    var fluidBlocksX: UInt32 = 0
    var fluidBlocksY: UInt32 = 0
    var secondCracks: UInt32 = 0
    var barAxes: UInt32 = 7
    var bareBars: UInt32 = 0
    var crackSlip: UInt32 = 0
    var anchored: UInt32 = 0
    var anchorNormalStiffness: Float = 0
    var anchorShearStiffness: Float = 0
    var anchorTension: Float = 0
    var anchorPlateau: Float = 0
    var anchorOpening: Float = 0
    var anchorCohesion: Float = 0
    var anchorCohesionSlip: Float = 0
    var anchorFriction: Float = 0
    var bondSlip: UInt32 = 0
    var bondPeak: Float = 0
    var bondResidual: Float = 0
    var bondS1: Float = 0
    var bondS2: Float = 0
    var bondS3: Float = 0
    var bondAlpha: Float = 0
    var bondYieldRange: Float = 0
    var bondYieldExponent: Float = 0
    var couplingMapCount: UInt32 = 0
    var footings: UInt32 = 0
    var fluidDeepRatio: UInt32 = 0
    var fluidDeepBlocksX: UInt32 = 0
    var fluidDeepBlocksY: UInt32 = 0
    var fluidDeepPatchOffset: UInt32 = 0
    var fluidDeepCellOffset: UInt32 = 0
    var pressedInterlock: UInt32 = 0
    var gravityX: Float = 0
    var gravityY: Float = 0
    var gravityZ: Float = -1
    var pairs: UInt32 = 0
    var removesFragments: UInt32 = 0
    var discreteBond: UInt32 = 0
    var crackReach: UInt32 = 0
    var fragmentOpening: Float = 0.5e-3
    var fragmentStrain: Float = 0.05
    var groundCoulomb: Float = 0
    var groundStiffness: Float = 0
}

/// One material as the element kernel sees it. Layout matches `MaterialParameters` in
/// `Structure.metal`.
struct MaterialParameters {
    var density: Float = 0
    var lambda: Float = 0
    var mu: Float = 0
    var yieldStress: Float = 1e30
    var hardening: Float = 0
    var failureStrain: Float = 1e30
    var hourglassStiffness: Float = 0
    var soundSpeed: Float = 0
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
    var barReach: Float = 0
    /// Mortar joints: the bond's tensile strength over the unit's, the decay strain of its
    /// softening, the joint's cohesion and friction, and the opening (as a strain) that a unit
    /// of sliding strain counts for.
    var jointStrength: Float = 1
    var jointSoftening: Float = 1
    var jointCohesion: Float = 0
    var jointFriction: Float = 0
    var jointSlipDamage: Float = 0
    var crackSofteningAlone: Float = 1
    var dowelFactor: Float = 1
    var fractureRateExponent: Float = 1
    var crackDilatancy: Float = 0
    /// Timber (`TimberProperties`): the modulus across the grain, the shear moduli in the plane
    /// and rolling, the Poisson's ratio along to across, the grain's global axis and its turn
    /// about the normal, and up to eight lamellae, their tops through the thickness and a bit
    /// each for those crossed.
    var acrossGrain: Float = 0
    var grainShear: Float = 0
    var rollingShear: Float = 0
    var grainPoisson: Float = 0
    var grainAxis: UInt32 = 0
    var grainRotation: Float = 0
    var lamellaCount: UInt32 = 0
    var lamellaCrossed: UInt32 = 0
    var lamellaTop: (Float, Float, Float, Float, Float, Float, Float, Float) = (0, 0, 0, 0, 0, 0, 0, 0)
    /// Timber's strengths at blast rates (Pa) and fracture energies (J/m^2), as
    /// `TimberProperties` has them.
    var tensionAlong: Float = 1e30
    var compressionAlong: Float = 1e30
    var tensionAcross: Float = 1e30
    var compressionAcross: Float = 1e30
    var grainShearStrength: Float = 1e30
    var rollingStrength: Float = 1e30
    var fibreEnergy: Float = 0
    var splittingEnergy: Float = 0
    var shearEnergy: Float = 0
    var rollingEnergy: Float = 0
    // Local buckling (`LocalBuckling`): the axis + 1 (0 for none), the side, the onset, the
    // softening strain and the residual share.
    var bucklingAxis: UInt32 = 0
    var bucklingSide: Float = 0
    var bucklingOnset: Float = 1e30
    var bucklingSoftening: Float = 1
    var bucklingResidual: Float = 1
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
    var airModel: UInt32 = 0
    /// What each splatted point counts for in a cell's occupancy (see `threshold`).
    var splatWeight: UInt32 = 1
    /// The air's refinement: its ratio (0 when not refined), the size of its grid of blocks, the
    /// count that makes a fine cell solid, and the points along each edge an element is sampled
    /// at for the fine cells.
    var refineRatio: UInt32 = 0
    var blocksX: UInt32 = 0
    var blocksY: UInt32 = 0
    var fineThreshold: UInt32 = 1
    var fineSamples: UInt32 = 1
    var coarseSamples: UInt32 = 1
    var couplingMapCount: UInt32 = 0
    var couplingTileCapacity: UInt32 = 0
    var deepRatio: UInt32 = 0
    var deepBlocksX: UInt32 = 0
    var deepBlocksY: UInt32 = 0
    var deepThreshold: UInt32 = 1
    var deepPatchOffset: UInt32 = 0
    var deepCellOffset: UInt32 = 0
    /// 1 while the air sleeps: points in coupling pages not allocated are left out quietly.
    var quietCoverage: UInt32 = 0
    /// 0: elements counted as points; otherwise each sample as a box, by its overlap with each
    /// cell, in these units (see `SolverConfiguration.structureMaskOverlap`).
    var overlapUnits: UInt32 = 0
    /// 1: a cell turns solid an eighth above `threshold` and opens an eighth below it.
    var maskHysteresis: UInt32 = 0
    /// 1 when the cells marked in the solver's kept air (beside stationary envelopes' recorded
    /// faces) must stay air (see `remaskPrepare`).
    var keepsAir: UInt32 = 0
}

/// When nodes of the structure repel each other.
public enum ContactMode: UInt32, Sendable {
    /// Parts of the structure pass through each other.
    case off = 0
    /// Contact switches on once any element has failed; an intact structure does not need it.
    case afterFailure = 1
    case always = 2
}

/// How the kernels round their arithmetic. Results before failure agree between these to about
/// 1%; after failure, where one element's removal decides the next, they spread, and the spread
/// is the scatter any change to the arithmetic, the compiler or the GPU would give (see
/// "Results after failure move with the rounding" in docs/validation.md). A run chooses one with
/// `KernelRounding.$current.withValue(_:)`; otherwise the kernels are built as by default, or as
/// the environment's `BuildProbe` says.
public enum KernelRounding: String, Codable, Sendable, CaseIterable {
    /// Metal's fast math, as always.
    case standard = "default"
    /// Fast math without fused multiply-adds (`#pragma METAL fp contract(off)`).
    case unfused
    /// Relaxed math: fast math's reassociation and approximate functions, but honouring
    /// infinities and NaNs.
    case relaxed

    /// The rounding the kernels built in this task use; nil leaves them as the environment says.
    @TaskLocal public static var current: KernelRounding?

    var mathMode: MTLMathMode? { self == .relaxed ? .relaxed : nil }
    var contract: String? { self == .unfused ? "off" : nil }

    /// The environment variables that build the kernels this way (`BuildProbe`), for a process to
    /// set before it builds any; the default sets none, and those set otherwise are cleared.
    public var environment: [String: String] {
        switch self {
        case .standard: [:]
        case .unfused: ["BOMBCAD_KERNEL_CONTRACT": "off"]
        case .relaxed: ["BOMBCAD_KERNEL_MATH": "relaxed"]
        }
    }

    /// As the ensemble prints it.
    public var name: String {
        switch self {
        case .standard: "default"
        case .unfused: "no fused multiply-adds"
        case .relaxed: "relaxed math"
        }
    }
}

/// How the kernels are compiled, for measuring what fast math does to results: unchanged unless
/// set in the environment. `BOMBCAD_KERNEL_MATH` (fast, relaxed or safe) sets the math mode,
/// `BOMBCAD_KERNEL_CONTRACT` (off, on or fast) prepends Metal's contraction pragma, and
/// `BOMBCAD_STATE_PADDING` adds that many unused floats to the structure's element state, a change
/// to the source that alters no arithmetic, as an unrelated edit would: at its end, or with
/// `BOMBCAD_STATE_PADDING_AT=middle` after `compaction` (the last field read from Swift), which
/// moves the fields after it. `BOMBCAD_KERNEL_PERTURB`, a comma-separated list, makes other such
/// edits: `branch` a test in the element kernel that never passes, `kernel` an unused kernel calling
/// the element kernel's helpers. See "Fast math and the build" in docs/performance.md.
struct BuildProbe {
    var mathMode: MTLMathMode?
    var contract: String?
    var statePadding = 0
    var padInMiddle = false
    var perturbations: Set<String> = []

    static let current: BuildProbe = {
        let environment = ProcessInfo.processInfo.environment
        var probe = BuildProbe()
        switch environment["BOMBCAD_KERNEL_MATH"] {
        case "fast": probe.mathMode = .fast
        case "relaxed": probe.mathMode = .relaxed
        case "safe": probe.mathMode = .safe
        default: break
        }
        if let contract = environment["BOMBCAD_KERNEL_CONTRACT"], ["off", "on", "fast"].contains(contract) {
            probe.contract = contract
        }
        probe.statePadding = max(0, environment["BOMBCAD_STATE_PADDING"].flatMap(Int.init) ?? 0)
        probe.padInMiddle = environment["BOMBCAD_STATE_PADDING_AT"] == "middle"
        probe.perturbations = Set(
            (environment["BOMBCAD_KERNEL_PERTURB"] ?? "").split(separator: ",").map(String.init))
        return probe
    }()
}

/// Loads and compiles the compute kernels shared by the fluid and structural solvers.
enum ShaderLibrary {
    static func make(device: MTLDevice) throws -> MTLLibrary {
        let files = [
            "Solver", "Refine", "Structure", "Rubble", "Shell", "BodyContact", "Footing", "Extract",
            "Radiation",
            "Gravity",
            "Deflagration", "Mixing",
        ]
        var probe = BuildProbe.current
        if let rounding = KernelRounding.current {
            probe.mathMode = rounding.mathMode
            probe.contract = rounding.contract
        }
        var source = try files.map { name in
            guard
                let url = Bundle.module.url(
                    forResource: name, withExtension: "metal", subdirectory: "Shaders")
            else {
                throw BlastError.missingShader("\(name).metal")
            }
            return try String(contentsOf: url, encoding: .utf8)
        }.joined(separator: "\n")
        // Contact's table and search are ContinuumKit's (`ContactSearchMetal`), compiled ahead of
        // the kernels that use them.
        source = try MetalContactSearch.functionSource() + "\n" + source
        if probe.statePadding > 0 {
            // Unused floats in the element state: a change to the source that alters no
            // arithmetic, to see what results a rebuild moves.
            let padding = "    float unusedPadding[\(probe.statePadding)];\n"
            let size = "sizeof(ElementState) == \(StructureSolver.stateStride - 4 * probe.statePadding)"
            guard source.contains(size) else { throw BlastError.missingShader("ElementState's size check") }
            source = source.replacingOccurrences(
                of: size, with: "sizeof(ElementState) == \(StructureSolver.stateStride)")
            if probe.padInMiddle {
                let anchor =
                    "    float compaction;  // concrete: largest volumetric compression so far, mu = V0 / V - 1\n"
                guard let field = source.range(of: anchor) else {
                    throw BlastError.missingShader("ElementState's compaction, to pad after")
                }
                source.insert(contentsOf: padding, at: field.upperBound)
            } else {
                guard let start = source.range(of: "struct ElementState {"),
                    let end = source.range(of: "\n};", range: start.upperBound..<source.endIndex)
                else { throw BlastError.missingShader("ElementState's end, to pad") }
                source.insert(contentsOf: "\n" + padding.dropLast(), at: end.lowerBound)
            }
        }
        if probe.perturbations.contains("branch") {
            let load = "    ElementState state = states[compact];\n"
            guard source.contains(load) else {
                throw BlastError.missingShader("the element kernel's state load")
            }
            source = source.replacingOccurrences(
                of: load, with: load + "    if (state.plasticStrain < -1.0e30f) { state.display = 0.5f; }\n")
        }
        if probe.perturbations.contains("kernel") {
            source += """

                kernel void unusedProbe(device float *values [[buffer(0)]],
                                        constant MaterialParameters *materials [[buffer(1)]],
                                        uint id [[thread_position_in_grid]]) {
                    float3 eigen;
                    float3x3 vectors;
                    symmetricEigen(float3x3(values[id]), eigen, vectors);
                    values[id] = eigen.x + tensionEnvelope(values[id + 1], 1.0f, materials[0])
                        + compressionIncrease(values[id + 2], materials[0]);
                }

                """
        }
        if let contract = probe.contract { source = "#pragma METAL fp contract(\(contract))\n" + source }
        guard let mathMode = probe.mathMode else {
            return try device.makeLibrary(source: source, options: nil)
        }
        let options = MTLCompileOptions()
        options.mathMode = mathMode
        return try device.makeLibrary(source: source, options: options)
    }

    /// Index of the optional function constant that compiles a kernel for one gas model
    /// (`airModelConstant` in Solver.metal).
    static let airModelConstant = 2
    /// Index of the optional function constant that compiles gravity in the air into a kernel
    /// (`airGravityConstant` in Solver.metal); without it, the kernel leaves gravity's code out.
    static let airGravityConstant = 5

    /// Index of the optional function constant that compiles sub-grid mixing into a kernel
    /// (`airMixingConstant` in Solver.metal).
    static let airMixingConstant = 6

    /// Index of the optional function constant that compiles afterburning's extinction limit into
    /// a kernel (`burnLimitConstant` in Solver.metal).
    static let burnLimitConstant = 7

    /// Index of the optional function constant that compiles the terrain's cut cells into a kernel
    /// (`cutCellsConstant` in Solver.metal).
    static let cutCellsConstant = 13

    /// `constants` with the terrain's cut cells compiled in.
    static func withCutCells(_ constants: MTLFunctionConstantValues) -> MTLFunctionConstantValues {
        var on = true
        constants.setConstantValue(&on, type: .bool, index: cutCellsConstant)
        return constants
    }

    /// Index of the optional function constant that compiles congestion's porous cells into a
    /// kernel (`porousAirConstant` in Solver.metal).
    static let porousAirConstant = 14

    /// `constants` with congestion's porous cells compiled in.
    static func withPorousAir(_ constants: MTLFunctionConstantValues) -> MTLFunctionConstantValues {
        var on = true
        constants.setConstantValue(&on, type: .bool, index: porousAirConstant)
        return constants
    }

    /// `constants` with afterburning's extinction limit compiled in.
    static func withBurnLimit(_ constants: MTLFunctionConstantValues) -> MTLFunctionConstantValues {
        var on = true
        constants.setConstantValue(&on, type: .bool, index: burnLimitConstant)
        return constants
    }

    /// `constants` with sub-grid mixing compiled in.
    static func withMixing(_ constants: MTLFunctionConstantValues) -> MTLFunctionConstantValues {
        var on = true
        constants.setConstantValue(&on, type: .bool, index: airMixingConstant)
        return constants
    }

    /// `constants` with gravity in the air compiled in.
    static func withGravity(_ constants: MTLFunctionConstantValues) -> MTLFunctionConstantValues {
        var on = true
        constants.setConstantValue(&on, type: .bool, index: airGravityConstant)
        return constants
    }

    /// A compute pipeline for kernel `name`, specialised with `constants` (none by default).
    /// Every kernel is specialised: many read the optional gas-model constant through the gas
    /// functions, and Metal builds a pipeline from such a kernel only once it is specialised.
    static func pipeline(
        _ name: String, in library: MTLLibrary,
        constants: MTLFunctionConstantValues = MTLFunctionConstantValues()
    ) throws -> MTLComputePipelineState {
        guard let function = try? library.makeFunction(name: name, constantValues: constants) else {
            throw BlastError.missingFunction(name)
        }
        return try library.device.makeComputePipelineState(function: function)
    }
}

// MARK: - Decoding layouts saved by earlier versions

extension StructureMaterial {
    /// Decodes a material saved by any version: properties added since it was saved take
    /// their standard values.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        model = try container.decode(MaterialModel.self, forKey: .model)
        density = try container.decode(Float.self, forKey: .density)
        youngsModulus = try container.decode(Float.self, forKey: .youngsModulus)
        poissonRatio = try container.decode(Float.self, forKey: .poissonRatio)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try container.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        yieldStress = try value(.yieldStress, yieldStress)
        hardeningModulus = try value(.hardeningModulus, hardeningModulus)
        failureStrain = try value(.failureStrain, failureStrain)
        compressiveStrength = try value(.compressiveStrength, compressiveStrength)
        tensileStrength = try value(.tensileStrength, tensileStrength)
        fractureEnergy = try value(.fractureEnergy, fractureEnergy)
        crushingEnergy = try value(.crushingEnergy, crushingEnergy)
        erosionOpening = try value(.erosionOpening, erosionOpening)
        steel = try container.decodeIfPresent(SteelProperties.self, forKey: .steel)
        crackSpacing = try value(.crackSpacing, crackSpacing)
        aggregateSize = try value(.aggregateSize, aggregateSize)
        bondSpreading = try value(.bondSpreading, bondSpreading)
        confinementCoefficient = try value(.confinementCoefficient, confinementCoefficient)
        crackResidual = try value(.crackResidual, crackResidual)
        dowelFactor = try value(.dowelFactor, dowelFactor)
        interlockFactor = try value(.interlockFactor, interlockFactor)
        fractureRateExponent = try value(.fractureRateExponent, fractureRateExponent)
        crackDilatancy = try value(.crackDilatancy, crackDilatancy)
        concreteRateFactor = try value(.concreteRateFactor, concreteRateFactor)
        steelRateFactor = try value(.steelRateFactor, steelRateFactor)
        rateDependent = try value(.rateDependent, rateDependent)
        steelRateDependent = try value(.steelRateDependent, steelRateDependent)
        units = try container.decodeIfPresent(MasonryUnits.self, forKey: .units)
        // Glass saved before this property existed is still drawn as glass.
        isTransparent = try value(.isTransparent, name.localizedCaseInsensitiveContains("glass"))
        timber = try container.decodeIfPresent(TimberProperties.self, forKey: .timber)
    }
}

extension StructureModel {
    private enum CodingKeys: String, CodingKey {
        case solids, openings, material, elementSize, fixedBase, baseAnchorage
        case reinforcement, inclinedBars, solidReinforcement, solidMaterial, solidSourceParts
        case elementKind, shellLayers, supports, supportAnchorages, secondCracks
        case bareBars, removesFragments, crackSlip, bondSlip,
            solidElementKind, solidSheets, springSupports, sheetFastenings
        case shellElementSize, interfaceBond, unitJoints, shellSectionShear
        case pressedInterlock, regimeOverride, loadingOverride, regimeDefaults
        case hourglassFollowsCracking, hourglassCapsSteel, discreteBars, barsAsTrusses, trussDiameter
        case crackAveraging, rubbleParticles, strainRateWindow, tiesTouching, extremeFibreCracking,
            erodesCrushedBare, releasesCrushedBareHourglass
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(solids, forKey: .solids)
        try container.encode(openings, forKey: .openings)
        try container.encode(material, forKey: .material)
        try container.encode(elementSize, forKey: .elementSize)
        try container.encode(fixedBase, forKey: .fixedBase)
        try container.encodeIfPresent(baseAnchorage, forKey: .baseAnchorage)
        try container.encode(reinforcement, forKey: .reinforcement)
        try container.encode(inclinedBars, forKey: .inclinedBars)
        try container.encode(solidReinforcement, forKey: .solidReinforcement)
        try container.encode(solidMaterial, forKey: .solidMaterial)
        try container.encode(solidSourceParts, forKey: .solidSourceParts)
        try container.encode(elementKind, forKey: .elementKind)
        try container.encode(shellLayers, forKey: .shellLayers)
        try container.encode(supports, forKey: .supports)
        try container.encode(secondCracks, forKey: .secondCracks)
        try container.encode(bareBars, forKey: .bareBars)
        if removesFragments { try container.encode(removesFragments, forKey: .removesFragments) }
        try container.encode(crackSlip, forKey: .crackSlip)
        // Saved only where they differ from the standard, so files without them read as before.
        if pressedInterlock { try container.encode(pressedInterlock, forKey: .pressedInterlock) }
        try container.encodeIfPresent(regimeOverride, forKey: .regimeOverride)
        try container.encodeIfPresent(loadingOverride, forKey: .loadingOverride)
        if !regimeDefaults { try container.encode(regimeDefaults, forKey: .regimeDefaults) }
        if hourglassFollowsCracking {
            try container.encode(hourglassFollowsCracking, forKey: .hourglassFollowsCracking)
        }
        if !hourglassCapsSteel { try container.encode(hourglassCapsSteel, forKey: .hourglassCapsSteel) }
        if !discreteBars.isEmpty { try container.encode(discreteBars, forKey: .discreteBars) }
        if barsAsTrusses { try container.encode(barsAsTrusses, forKey: .barsAsTrusses) }
        try container.encodeIfPresent(trussDiameter, forKey: .trussDiameter)
        try container.encodeIfPresent(crackAveraging, forKey: .crackAveraging)
        if strainRateWindow != Self.defaultStrainRateWindow {
            try container.encode(strainRateWindow ?? 0, forKey: .strainRateWindow)
        }
        try container.encodeIfPresent(tiesTouching, forKey: .tiesTouching)
        if rubbleParticles { try container.encode(rubbleParticles, forKey: .rubbleParticles) }
        if extremeFibreCracking { try container.encode(extremeFibreCracking, forKey: .extremeFibreCracking) }
        if erodesCrushedBare { try container.encode(erodesCrushedBare, forKey: .erodesCrushedBare) }
        if releasesCrushedBareHourglass {
            try container.encode(releasesCrushedBareHourglass, forKey: .releasesCrushedBareHourglass)
        }
        try container.encodeIfPresent(bondSlip, forKey: .bondSlip)
        try container.encode(solidElementKind, forKey: .solidElementKind)
        if solidSheets.contains(where: { $0 != nil }) {
            try container.encode(solidSheets, forKey: .solidSheets)
        }
        if !springSupports.isEmpty { try container.encode(springSupports, forKey: .springSupports) }
        if !sheetFastenings.isEmpty { try container.encode(sheetFastenings, forKey: .sheetFastenings) }
        try container.encodeIfPresent(shellElementSize, forKey: .shellElementSize)
        try container.encodeIfPresent(interfaceBond, forKey: .interfaceBond)
        try container.encode(unitJoints, forKey: .unitJoints)
        try container.encode(shellSectionShear, forKey: .shellSectionShear)
        if !supportAnchorages.isEmpty { try container.encode(supportAnchorages, forKey: .supportAnchorages) }
    }

    /// Decodes a structure saved by any version: properties added since it was saved take
    /// their standard values.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        solids = try container.decode([Box].self, forKey: .solids)
        openings = try container.decode([Box].self, forKey: .openings)
        material = try container.decode(StructureMaterial.self, forKey: .material)
        elementSize = try container.decode(Float.self, forKey: .elementSize)
        fixedBase = try container.decode(Bool.self, forKey: .fixedBase)
        baseAnchorage = try container.decodeIfPresent(Anchorage.self, forKey: .baseAnchorage)
        reinforcement = try container.decodeIfPresent([ReinforcementLayer].self, forKey: .reinforcement) ?? []
        inclinedBars = try container.decodeIfPresent([InclinedBars].self, forKey: .inclinedBars) ?? []
        solidReinforcement =
            try container.decodeIfPresent([Reinforcement].self, forKey: .solidReinforcement) ?? []
        solidMaterial = try container.decodeIfPresent([StructureMaterial?].self, forKey: .solidMaterial) ?? []
        solidSourceParts =
            try container.decodeIfPresent([SourcePart?].self, forKey: .solidSourceParts) ?? []
        elementKind = try container.decodeIfPresent(ElementKind.self, forKey: .elementKind) ?? .solid
        shellLayers = try container.decodeIfPresent(Int.self, forKey: .shellLayers) ?? 8
        tiesTouching = try container.decodeIfPresent(Bool.self, forKey: .tiesTouching)
        supports = try container.decodeIfPresent([Box].self, forKey: .supports) ?? []
        supportAnchorages = try container.decodeIfPresent([Anchorage?].self, forKey: .supportAnchorages) ?? []
        secondCracks = try container.decodeIfPresent(Bool.self, forKey: .secondCracks) ?? true
        bareBars = try container.decodeIfPresent(Bool.self, forKey: .bareBars) ?? true
        removesFragments = try container.decodeIfPresent(Bool.self, forKey: .removesFragments) ?? false
        crackSlip = try container.decodeIfPresent(Bool.self, forKey: .crackSlip) ?? true
        pressedInterlock = try container.decodeIfPresent(Bool.self, forKey: .pressedInterlock) ?? false
        regimeOverride = try container.decodeIfPresent(StructuralRegime.self, forKey: .regimeOverride)
        loadingOverride = try container.decodeIfPresent(StructuralLoading.self, forKey: .loadingOverride)
        regimeDefaults = try container.decodeIfPresent(Bool.self, forKey: .regimeDefaults) ?? true
        hourglassFollowsCracking =
            try container.decodeIfPresent(Bool.self, forKey: .hourglassFollowsCracking) ?? false
        hourglassCapsSteel = try container.decodeIfPresent(Bool.self, forKey: .hourglassCapsSteel) ?? true
        discreteBars = try container.decodeIfPresent([DiscreteBar].self, forKey: .discreteBars) ?? []
        barsAsTrusses = try container.decodeIfPresent(Bool.self, forKey: .barsAsTrusses) ?? false
        trussDiameter = try container.decodeIfPresent(Float.self, forKey: .trussDiameter)
        crackAveraging = try container.decodeIfPresent(Float.self, forKey: .crackAveraging)
        // Absent: the default; 0: the 50-step average.
        strainRateWindow =
            try container.decodeIfPresent(Float.self, forKey: .strainRateWindow)
            .map { $0 > 0 ? $0 : nil } ?? Self.defaultStrainRateWindow
        rubbleParticles = try container.decodeIfPresent(Bool.self, forKey: .rubbleParticles) ?? false
        extremeFibreCracking =
            try container.decodeIfPresent(Bool.self, forKey: .extremeFibreCracking) ?? false
        erodesCrushedBare = try container.decodeIfPresent(Bool.self, forKey: .erodesCrushedBare) ?? false
        releasesCrushedBareHourglass =
            try container.decodeIfPresent(Bool.self, forKey: .releasesCrushedBareHourglass) ?? false
        bondSlip = try container.decodeIfPresent(BondSlip.self, forKey: .bondSlip)
        solidElementKind = try container.decodeIfPresent([ElementKind?].self, forKey: .solidElementKind) ?? []
        solidSheets = try container.decodeIfPresent([SheetAssignment?].self, forKey: .solidSheets) ?? []
        springSupports = try container.decodeIfPresent([SpringSupport].self, forKey: .springSupports) ?? []
        sheetFastenings = try container.decodeIfPresent([SheetFastening].self, forKey: .sheetFastenings) ?? []
        shellElementSize = try container.decodeIfPresent(Float.self, forKey: .shellElementSize)
        interfaceBond = try container.decodeIfPresent(SIMD2<Float>.self, forKey: .interfaceBond)
        unitJoints = try container.decodeIfPresent(Bool.self, forKey: .unitJoints) ?? true
        shellSectionShear = try container.decodeIfPresent(Bool.self, forKey: .shellSectionShear) ?? false
        retiredOptions = try Self.retiredOptions(in: decoder)
        try validateAnchorages()
    }
}

/// Options retired after the case matrix found no case they served (docs/concrete-strategy.md,
/// stage 0). A model saved with one set away from what is now the only behaviour reads with
/// that behaviour, and a note of what was dropped (`StructureModel.retiredOptions`).
private enum RetiredKey: String, CodingKey, CaseIterable {
    // The model's.
    case crackAxes, slipWidensCracks, crackShearStiffness, barRateAlongBars
    // A material's.
    case crushBand, crushLength, tensionRateLaw, steelRateLaw
    // Where the model keeps its materials.
    case material, solidMaterial
}

extension StructureModel {
    /// Notes for the retired options `decoder`'s model and its materials set away from what now
    /// applies.
    fileprivate static func retiredOptions(in decoder: any Decoder) throws -> [String] {
        let container = try decoder.container(keyedBy: RetiredKey.self)
        var notes: [String] = []
        if let axes = try container.decodeIfPresent(String.self, forKey: .crackAxes),
            axes != "turningUntilOpen"
        {
            notes.append(
                "Crack axes '\(axes)' were retired: cracks turn with the stress until they open, then stay fixed."
            )
        }
        if try container.decodeIfPresent(Bool.self, forKey: .slipWidensCracks) == false {
            notes.append(
                "Keeping a crack's slide out of its opening was retired: what a crack slides opens it too.")
        }
        if try container.decodeIfPresent(Bool.self, forKey: .crackShearStiffness) == true {
            notes.append(
                "A crack's shear stiffness falling with its width was retired: a cracked plane keeps a quarter "
                    + "of the concrete's.")
        }
        if try container.decodeIfPresent(Bool.self, forKey: .barRateAlongBars) == false {
            notes.append(
                "Bars taking the strain rate of the element they run through was retired: they take it along "
                    + "their debonded length.")
        }
        var materials: [KeyedDecodingContainer<RetiredKey>] = []
        if container.contains(.material) {
            materials.append(try container.nestedContainer(keyedBy: RetiredKey.self, forKey: .material))
        }
        if container.contains(.solidMaterial),
            var list = try? container.nestedUnkeyedContainer(forKey: .solidMaterial)
        {
            while !list.isAtEnd {
                if try list.decodeNil() { continue }
                materials.append(try list.nestedContainer(keyedBy: RetiredKey.self))
            }
        }
        var seen = Set<String>()
        for material in materials {
            var found: [String] = []
            if let band = try material.decodeIfPresent(Float.self, forKey: .crushBand), band > 0 {
                found.append("A shortest crushing band was retired: crushing spreads over one element.")
            }
            if let length = try material.decodeIfPresent(Float.self, forKey: .crushLength), length > 0 {
                found.append("Nonlocal crushing was retired: crushing is the element's own.")
            }
            if let law = try material.decodeIfPresent(String.self, forKey: .tensionRateLaw),
                law != "modelCode2010"
            {
                found.append(
                    "Malvar and Ross's tensile strain-rate law was retired: the fib Model Code 2010's applies."
                )
            }
            if let law = try material.decodeIfPresent(String.self, forKey: .steelRateLaw), law != "ceb" {
                found.append(
                    "Malvar and Crawford's strain-rate law for bars was retired: the CEB's, as the Model Code 2010 "
                        + "re-adopted it, applies.")
            }
            for note in found where seen.insert(note).inserted { notes.append(note) }
        }
        return notes
    }
}

extension Box {
    /// Whether `inner` lies within this box, to a millimetre: a pane set in an opening.
    func holds(_ inner: Box) -> Bool {
        (0..<3).allSatisfy { inner.min[$0] >= min[$0] - 1e-3 && inner.max[$0] <= max[$0] + 1e-3 }
    }
}

/// Local buckling of a thin-walled beam's compression flange, in a beam of von Mises steel that
/// stands for it (`ProfiledSheet`'s ribs): fibres on the flange's side of the section, past
/// `onsetStrain` in compression, carry a stress falling linearly from the yield to `residual` of
/// it over a further `softeningStrain`, the largest compression they have reached setting it.
/// The softening hinge of a class 4 section, on the fibres' strains.
public struct LocalBuckling: Codable, Hashable, Sendable {
    /// The global axis across the section along which the flange lies, and its side of the
    /// section's middle (+1, -1, or 0 for both sides).
    public var axis: Int
    public var side: Int
    public var onsetStrain: Float
    public var softeningStrain: Float
    public var residual: Float

    public init(axis: Int, side: Int, onsetStrain: Float, softeningStrain: Float, residual: Float) {
        self.axis = axis
        self.side = side
        self.onsetStrain = onsetStrain
        self.softeningStrain = softeningStrain
        self.residual = residual
    }
}

/// A connection along a shell's edge as springs to fixed ground at its nodes, each spring per
/// metre of edge shared among the nodes by their lengths along it: pulling along `along`, across
/// along `across`, and turning about the edge, which runs along `edge`, along which the nodes are
/// held still. Each is elastic, then
/// yields and hardens (or softens) linearly, unloading elastically (`SpringLaw`); the turning
/// one differs either way. Langdon's connections of her corrugated panels are such springs.
public struct SpringSupport: Codable, Hashable, Sendable {
    /// The nodes it holds: those of the shells inside.
    public var region: Box
    public var edge: Int
    public var along: Int
    public var pull: SpringLaw
    /// Across the edge towards +across, and (if given) towards -across: a sheet's screws pulled
    /// through one way, the sheet bearing on its support the other.
    public var across: SpringLaw
    public var acrossNegative: SpringLaw?
    /// Turning about +edge, and about -edge.
    public var turnPositive: SpringLaw
    public var turnNegative: SpringLaw
    /// Whether the edge comes away altogether once the across spring has given way to nothing: a
    /// sheet off its screws (nil for no).
    public var releases: Bool?

    public init(
        region: Box, edge: Int, along: Int, pull: SpringLaw, across: SpringLaw,
        acrossNegative: SpringLaw? = nil,
        turnPositive: SpringLaw, turnNegative: SpringLaw, releases: Bool? = nil
    ) {
        self.region = region
        self.edge = edge
        self.along = along
        self.pull = pull
        self.across = across
        self.acrossNegative = acrossNegative
        self.turnPositive = turnPositive
        self.turnNegative = turnNegative
        self.releases = releases
    }

    /// The axis across the edge, normal to `edge` and `along`.
    public var acrossAxis: Int { 3 - edge - along }
}

/// A spring's law per metre: elastic at `stiffness` (N/m per m, or N m/rad per m) to `yield` (N
/// per m, or N m per m), then at `hardening`, which is negative for one that softens, its
/// resistance never below zero; unloading elastically.
public struct SpringLaw: Codable, Hashable, Sendable {
    public var stiffness: Float
    public var yield: Float
    public var hardening: Float

    public init(stiffness: Float, yield: Float = .infinity, hardening: Float = 0) {
        self.stiffness = stiffness
        self.yield = yield
        self.hardening = hardening
    }
}
