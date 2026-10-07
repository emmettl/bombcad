import Foundation

/// A connection of finite stiffness and strength between a body's base and the ground, in place
/// of the ideal clamp that `StructureModel.fixedBase` otherwise applies.
///
/// Each node on the ground plane is tied to the ground by springs acting over its share of the
/// base area (a quarter of each element face it touches). Across the joint the spring carries
/// compression without limit (a stiff bearing) and tension up to `tensileStrength`; tension then
/// holds until the joint has opened by `tensionPlateau` and falls linearly to nothing at
/// `tensionOpening`, unloading towards the origin. Along the joint the spring sticks until the
/// shear reaches the Mohr–Coulomb limit `cohesion + friction × compression`, then slides. The
/// cohesion falls with the tension as the joint opens, and sliding wears both away linearly over
/// `cohesionSlip`, so a joint opened in tension has lost its cohesion and one sheared through has
/// lost its tension. Once neither is left the node only rests on the ground: it bears on it,
/// slides on it with Coulomb friction and lifts off. The bearing is damped as the solver's
/// contacts are.
///
/// The law has no rate dependence, no dilatancy and no rotational stiffness of its own (a solid
/// body's base rocks through the opening of its nodes on one side). It applies to solid elements;
/// shells keep a clamped base.
public struct Anchorage: Sendable, Hashable, Codable {
    /// Normal stiffness per unit area in Pa/m; nil takes the body material's E / h, as stiff as
    /// one more element of the body, which leaves its time step unchanged.
    public var normalStiffness: Float?
    /// Shear stiffness per unit area in Pa/m; nil takes G / h.
    public var shearStiffness: Float?
    /// Tension the joint carries before it starts to open, in Pa. Zero for a body resting on the
    /// ground.
    public var tensileStrength: Float
    /// Opening (m) up to which the full tensile strength holds, as yielding bars hold it.
    public var tensionPlateau: Float
    /// Opening (m) at which the joint carries no more tension.
    public var tensionOpening: Float
    /// Shear strength at zero normal stress, in Pa.
    public var cohesion: Float
    /// Sliding (m) over which the cohesion is lost.
    public var cohesionSlip: Float
    /// Coefficient of friction, on the joint and on the ground once it has separated.
    public var friction: Float

    public init(
        normalStiffness: Float? = nil, shearStiffness: Float? = nil, tensileStrength: Float,
        tensionPlateau: Float = 0, tensionOpening: Float, cohesion: Float, cohesionSlip: Float,
        friction: Float
    ) {
        self.normalStiffness = normalStiffness
        self.shearStiffness = shearStiffness
        self.tensileStrength = tensileStrength
        self.tensionPlateau = tensionPlateau
        self.tensionOpening = tensionOpening
        self.cohesion = cohesion
        self.cohesionSlip = cohesionSlip
        self.friction = friction
    }

    /// A body standing on the ground without any connection: no tension, no cohesion, and
    /// Coulomb friction. 0.6 is a typical coefficient for concrete on concrete or on compacted
    /// ground.
    public static func resting(friction: Float = 0.6) -> Self {
        Self(tensileStrength: 0, tensionOpening: 0, cohesion: 0, cohesionSlip: 0, friction: friction)
    }

    /// An unreinforced construction joint, as of a wall cast on its footing: 1 MPa of tension lost
    /// over 40 J/m² of fracture energy (about half of the concrete's own), and the cohesion and
    /// friction of a rough joint in Eurocode 2, EN 1992-1-1 §6.2.5 (c = 0.45 of a C30 concrete's
    /// mean tensile strength of 2.9 MPa, μ = 0.7), lost over 1 mm of sliding.
    public static let constructionJoint = Self(
        tensileStrength: 1e6, tensionOpening: 2 * 40 / 1e6, cohesion: 1.3e6, cohesionSlip: 1e-3,
        friction: 0.7)

    /// A construction joint crossed by starter bars: the joint's own strength until it cracks,
    /// then the bars. They hold `ratio × yieldStrength` of tension until the joint has opened by
    /// `ductileOpening` (yield over a debonded length, about the bars' uniform elongation times
    /// twenty diameters each side), and lose it over as much again; across the joint they add
    /// clamping, `ratio × yieldStrength × μ` (EN 1992-1-1 §6.2.5, bars at right angles).
    ///
    /// - Parameters:
    ///   - ratio: Area of bars per unit area of joint.
    ///   - yieldStrength: The bars' yield strength in Pa.
    ///   - ductileOpening: Opening held at full strength, in metres.
    public static func dowelled(ratio: Float, yieldStrength: Float = 500e6, ductileOpening: Float = 0.02)
        -> Self
    {
        var joint = constructionJoint
        let bars = ratio * yieldStrength
        joint.tensileStrength = max(joint.tensileStrength, bars)
        joint.tensionPlateau = ductileOpening
        joint.tensionOpening = 2 * ductileOpening
        joint.cohesion += bars * joint.friction
        joint.cohesionSlip = ductileOpening
        return joint
    }

    /// The fraction of the tensile strength left once the joint has opened by `peak` metres:
    /// all of it to the end of the plateau, then falling linearly to nothing.
    func envelope(peak: Float, normalStiffness kn: Float) -> Float {
        let plateau = max(tensionPlateau, tensileStrength / kn)
        let end = max(tensionOpening, plateau)
        if peak <= plateau { return 1 }
        return peak >= end ? 0 : (end - peak) / (end - plateau)
    }

    /// The fraction of the joint's strength, in tension and cohesion, left after it has opened by
    /// `peak` and sliding has worn `wear` of it; 1 for a body resting on the ground, which has
    /// none to lose.
    func remaining(peak: Float, wear: Float, normalStiffness kn: Float) -> Float {
        guard tensileStrength > 0 || cohesion > 0 else { return 1 }
        return (1 - wear) * (tensileStrength > 0 ? envelope(peak: peak, normalStiffness: kn) : 1)
    }

    /// The stiffnesses per unit area for a body of `material` meshed with elements of size `h`.
    func stiffness(material: StructureMaterial, elementSize h: Float) -> (normal: Float, shear: Float) {
        (normalStiffness ?? material.youngsModulus / h, shearStiffness ?? material.shearModulus / h)
    }
}

/// The ways a body's base can stand on the ground, for choosing one by name.
public enum BaseConnection: String, CaseIterable, Sendable {
    /// Clamped: the base never gives (`fixedBase` with no anchorage).
    case clamped
    /// Cast on starter bars: two 565 mm²/m mats' worth across a 250 mm wall, a ratio of 0.45%.
    case dowelled
    /// Cast on a construction joint without bars.
    case joint
    /// Standing on the ground without any connection.
    case resting

    /// The starter bars' ratio of `dowelled`.
    public static let dowelRatio: Float = 2 * 565e-6 / 0.25

    public var anchorage: Anchorage? {
        switch self {
        case .clamped: nil
        case .dowelled: .dowelled(ratio: Self.dowelRatio)
        case .joint: .constructionJoint
        case .resting: .resting()
        }
    }

    public var title: String {
        switch self {
        case .clamped: "Clamped"
        case .dowelled: "Starter bars"
        case .joint: "Construction joint"
        case .resting: "Resting on the ground"
        }
    }

    /// The connection `anchorage` is, or the nearest: any other with a plateau counts as starter
    /// bars, any other with strength as a joint, and any without as resting.
    public init(_ anchorage: Anchorage?) {
        guard let anchorage else {
            self = .clamped
            return
        }
        if anchorage.tensileStrength <= 0 && anchorage.cohesion <= 0 {
            self = .resting
        } else {
            self = anchorage.tensionPlateau > 0 ? .dowelled : .joint
        }
    }
}
