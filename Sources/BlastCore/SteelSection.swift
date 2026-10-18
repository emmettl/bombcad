import Foundation

/// A rolled steel section by its properties, and the rectangle a beam element can stand for it
/// with. A beam element's section is a rectangle, so an I-section is drawn as one 0.6 of its depth
/// wide, of steel scaled to the section's major-axis bending stiffness, plastic bending strength
/// and mass (as `IFCStructure` does for flanged sections it reads from geometry). Its axial
/// stiffness is then about twice the section's, and its minor-axis stiffness near the section's
/// for a column section (a universal column), well above it for a beam's.
public struct SteelSection: Sendable, Hashable {
    public var name: String
    /// Depth and flange width, metres.
    public var depth: Float
    public var width: Float
    /// Area (m²), major-axis second moment of area (m⁴) and plastic modulus (m³).
    public var area: Float
    public var secondMoment: Float
    public var plasticModulus: Float
    /// A cold-formed section's wall thickness (m), what screws into it hold in; nil for a rolled
    /// section.
    public var thickness: Float?

    public init(
        name: String, depth: Float, width: Float, area: Float, secondMoment: Float, plasticModulus: Float,
        thickness: Float? = nil
    ) {
        self.name = name
        self.depth = depth
        self.width = width
        self.area = area
        self.secondMoment = secondMoment
        self.plasticModulus = plasticModulus
        self.thickness = thickness
    }

    // UK sections, from the SCI's tables of section properties (P363, the "Blue Book").

    /// 457 × 191 × 67 UB, a primary floor beam over 7.5 m.
    public static let ub457x191x67 = Self(
        name: "457×191×67 UB", depth: 0.4534, width: 0.1899, area: 85.5e-4, secondMoment: 29_380e-8,
        plasticModulus: 1471e-6)
    /// 356 × 171 × 45 UB, a secondary floor beam over 7.5 m.
    public static let ub356x171x45 = Self(
        name: "356×171×45 UB", depth: 0.3514, width: 0.1711, area: 57.3e-4, secondMoment: 12_070e-8,
        plasticModulus: 775e-6)
    /// 305 × 305 × 118 UC, a column of a ten- to twelve-storey frame.
    public static let uc305x305x118 = Self(
        name: "305×305×118 UC", depth: 0.3145, width: 0.3074, area: 150e-4, secondMoment: 27_670e-8,
        plasticModulus: 1958e-6)

    /// The width of the rectangle that stands for the section: 0.6 of its depth.
    public var rectangleWidth: Float { 0.6 * depth }

    /// `steel` scaled so that a rectangle `width` (by default `rectangleWidth`) by `depth` of it
    /// bends as stiffly and as strongly about its major axis as the section, and weighs as much:
    /// its modulus by the second moments' ratio, its yield and hardening by the plastic moduli's.
    /// Its wave speed, which sets the time step, is the same whatever the width; a narrower one
    /// keeps its faces off the mesh's lines.
    public func equivalent(of steel: StructureMaterial = .structuralSteel, width: Float? = nil)
        -> StructureMaterial
    {
        let width = width ?? rectangleWidth
        // The grade's rate law from the steel's own yield, before it is scaled.
        var material = steel.resolvingRateLaw()
        material.name = "\(steel.name), \(name)"
        material.youngsModulus *= secondMoment / (width * depth * depth * depth / 12)
        material.density *= area / (width * depth)
        material.yieldStress *= plasticModulus / (width * depth * depth / 4)
        // Hardening is a stress per strain, scaled as the yield is: the rectangle's fibres strain as
        // the section's do at the same curvature, so the stresses carry the section's moments.
        material.hardeningModulus *= plasticModulus / (width * depth * depth / 4)
        return material
    }
}
