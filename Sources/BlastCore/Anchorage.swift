import Foundation
import simd

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
/// With a `bearingCapacity`, the ground under the base yields once pressed harder than that, and
/// the base settles into it for good; unloaded, it springs back from where it settled. Over soil
/// (`soil(...)`) the connection is a Winkler bed: a subgrade modulus for its stiffness, a bearing
/// capacity, friction and no tension.
///
/// With a `footing`, the connection ties the base to a rigid footing of finite plan, with its own
/// mass, instead of the ground: the joint moves and turns with the footing, which stands on soil
/// that bears over its plan alone (`Footing`).
///
/// The law has no rate dependence, no dilatancy and no rotational stiffness of its own: a solid
/// body's base rocks through the opening of its nodes on one side, and a shell's or a column's
/// through points of its faces that turn with its node (`ShellMesh.jointPoints`).
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
    /// Pressure in Pa the ground bears before it yields and the base settles; nil bears any.
    public var bearingCapacity: Float?
    /// A rigid footing between the base and the soil; nil ties the base to the ground itself.
    public var footing: Footing?
    /// Which side of the body the joint is on, for a support region's connection; nil (or
    /// `below`) for a horizontal joint under it.
    public var side: JointSide?
    /// The joint's normal at any angle, across it from the support into the body, for a support
    /// region's connection; it takes the place of `side`. Need not be of unit length.
    public var jointNormal: SIMD3<Float>?

    public init(
        normalStiffness: Float? = nil, shearStiffness: Float? = nil, tensileStrength: Float,
        tensionPlateau: Float = 0, tensionOpening: Float, cohesion: Float, cohesionSlip: Float,
        friction: Float, bearingCapacity: Float? = nil, footing: Footing? = nil, side: JointSide? = nil,
        jointNormal: SIMD3<Float>? = nil
    ) {
        self.bearingCapacity = bearingCapacity
        self.footing = footing
        self.side = side
        self.jointNormal = jointNormal
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

    /// A footing on soil, as a Winkler bed: the ground's stiffness, its subgrade modulus in Pa/m
    /// (a reaction of that many pascals per metre of settlement), the same along the base; its
    /// ultimate bearing pressure in Pa; friction; and no tension. The defaults are for a medium
    /// dense sand under a footing about a metre wide: 50 MN/m³, 600 kPa and 0.5, within the
    /// ranges foundation texts give for such a sand (J. E. Bowles, *Foundation Analysis and
    /// Design*, for one), written from memory and not measured for any site.
    public static func soil(
        subgradeModulus: Float = 50e6, bearingCapacity: Float = 600e3, friction: Float = 0.5
    )
        -> Self
    {
        Self(
            normalStiffness: subgradeModulus, shearStiffness: subgradeModulus, tensileStrength: 0,
            tensionOpening: 0, cohesion: 0, cohesionSlip: 0, friction: friction,
            bearingCapacity: bearingCapacity)
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

    /// The unit vector across the joint from the support into the body, the way it opens: the
    /// `jointNormal`, else the `side`'s.
    public var across: SIMD3<Float> {
        if let jointNormal, simd_length(jointNormal) > 0 { return simd_normalize(jointNormal) }
        return (side ?? .below).normal
    }

    /// Whether the joint is under the body, horizontal: the ground's and a footing's only way.
    public var isUnder: Bool { simd_distance(across, SIMD3(0, 0, 1)) < 1e-5 }

    /// The normal of a joint whose support lies `tilt` radians from straight below the body (0
    /// under it, π/2 beside it, π over it), towards `azimuth` radians round from x in plan.
    public static func normal(tilt: Float, azimuth: Float) -> SIMD3<Float> {
        SIMD3(-sin(tilt) * cos(azimuth), -sin(tilt) * sin(azimuth), cos(tilt))
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

/// Which side of a body a connection's joint is on, the support beyond it: under the body (a
/// horizontal joint it bears on), over it (one it hangs from), or against one of its faces
/// across x or y (a vertical joint, as of a wall cast against another). The joint acts across
/// the lattice faces of solid elements that face that way; shells and columns are tied only
/// under them.
public enum JointSide: String, CaseIterable, Sendable, Hashable, Codable {
    case below, above, negativeX, positiveX, negativeY, positiveY

    /// The lattice axis across the joint.
    var axis: Int {
        switch self {
        case .below, .above: 2
        case .negativeX, .positiveX: 0
        case .negativeY, .positiveY: 1
        }
    }

    /// Which way along `axis` the joint lies from the body: -1 or 1.
    var direction: Int { self == .below || self == .negativeX || self == .negativeY ? -1 : 1 }

    /// The unit vector across the joint from the support into the body, the way it opens.
    public var normal: SIMD3<Float> {
        var value = SIMD3<Float>.zero
        value[axis] = Float(-direction)
        return value
    }

    public var title: String {
        switch self {
        case .below: "Under the body"
        case .above: "Over the body"
        case .negativeX: "Against its −x face"
        case .positiveX: "Against its +x face"
        case .negativeY: "Against its −y face"
        case .positiveY: "Against its +y face"
        }
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
    /// On a footing over soil that can settle and yield (`Anchorage.soil()`).
    case soil
    /// Cast on starter bars onto a rigid footing, 0.4 m thick and reaching 0.5 m beyond the base
    /// on each side, on a half-space of medium dense sand with its mass and radiation damping
    /// (`Footing`).
    case footing

    /// The starter bars' ratio of `dowelled`.
    public static let dowelRatio: Float = 2 * 565e-6 / 0.25

    public var anchorage: Anchorage? {
        switch self {
        case .clamped: nil
        case .dowelled: .dowelled(ratio: Self.dowelRatio)
        case .joint: .constructionJoint
        case .resting: .resting()
        case .soil: .soil()
        case .footing:
            {
                var joint = Anchorage.dowelled(ratio: Self.dowelRatio)
                joint.footing = Footing()
                return joint
            }()
        }
    }

    public var title: String {
        switch self {
        case .clamped: "Clamped"
        case .dowelled: "Starter bars"
        case .joint: "Construction joint"
        case .resting: "Resting on the ground"
        case .soil: "On soil"
        case .footing: "On a footing over soil"
        }
    }

    /// The connection `anchorage` is, or the nearest: any with a footing counts as one, any with
    /// a bearing capacity as soil, any other with a plateau as starter bars, any other with
    /// strength as a joint, and any without as resting.
    public init(_ anchorage: Anchorage?) {
        guard let anchorage else {
            self = .clamped
            return
        }
        if anchorage.footing != nil {
            self = .footing
        } else if anchorage.bearingCapacity != nil {
            self = .soil
        } else if anchorage.tensileStrength <= 0 && anchorage.cohesion <= 0 {
            self = .resting
        } else {
            self = anchorage.tensionPlateau > 0 ? .dowelled : .joint
        }
    }
}

// The same law layout consumed by both Metal node kernels (`AnchorLaw`).
struct AnchorageParameters {
    var stiffnessAndTension: SIMD4<Float>
    var failureAndFriction: SIMD4<Float>
    /// The ground's bearing capacity (zero: without limit), then the joint's normal when it is
    /// not under the body (zero otherwise).
    var bearing: SIMD4<Float>

    init(_ law: Anchorage, material: StructureMaterial, elementSize: Float) {
        let stiffness = law.stiffness(material: material, elementSize: elementSize)
        stiffnessAndTension = SIMD4(
            stiffness.normal, stiffness.shear, law.tensileStrength, law.tensionPlateau)
        failureAndFriction = SIMD4(law.tensionOpening, law.cohesion, law.cohesionSlip, law.friction)
        // A joint that is not under the body carries its normal; zero is up.
        let normal = law.isUnder ? SIMD3<Float>.zero : law.across
        bearing = SIMD4(law.bearingCapacity ?? 0, normal.x, normal.y, normal.z)
    }
}

extension Anchorage {
    /// Reject invalid laws before they reach a GPU, including laws loaded from a document.
    public func validate() throws {
        let values = [
            tensileStrength, tensionPlateau, tensionOpening, cohesion, cohesionSlip, friction,
            bearingCapacity ?? 0,
        ]
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 }),
            tensionOpening >= tensionPlateau,
            normalStiffness.map({ $0.isFinite && $0 > 0 }) ?? true,
            shearStiffness.map({ $0.isFinite && $0 > 0 }) ?? true
        else {
            throw ImportedMesh.ImportError.invalid(
                "Connection values must be finite and nonnegative, stiffness must be positive, and final opening cannot precede the strength plateau."
            )
        }
        try footing?.validate()
        guard
            jointNormal.map({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && simd_length($0) > 1e-6 })
                ?? true
        else {
            throw ImportedMesh.ImportError.invalid("A joint's normal must be finite and not zero.")
        }
        guard footing == nil || isUnder else {
            throw ImportedMesh.ImportError.invalid("A footing can only stand under the body.")
        }
    }
}

extension StructureModel {
    /// Nil entries retain ideal clamping. Finite region connections are horizontal bearings.
    public func anchorage(ofSupport index: Int) -> Anchorage? {
        supportAnchorages.indices.contains(index) ? supportAnchorages[index] : nil
    }

    public mutating func setAnchorage(_ law: Anchorage?, ofSupport index: Int) {
        guard supports.indices.contains(index) else { return }
        while supportAnchorages.count <= index { supportAnchorages.append(nil) }
        supportAnchorages[index] = law
    }

    public mutating func removeSupport(at index: Int) {
        guard supports.indices.contains(index) else { return }
        supports.remove(at: index)
        if supportAnchorages.indices.contains(index) { supportAnchorages.remove(at: index) }
    }

    func containsSupport(_ index: Int, at point: SIMD3<Float>) -> Bool {
        let slack = 1e-3 * elementSize
        let box = supports[index]
        return (0..<3).allSatisfy { point[$0] >= box.min[$0] - slack && point[$0] <= box.max[$0] + slack }
    }

    func isClampedBySupport(at point: SIMD3<Float>) -> Bool {
        supports.indices.contains { anchorage(ofSupport: $0) == nil && containsSupport($0, at: point) }
    }

    /// Which connection holds the point: 0 the ground's, 1 + n support region n's; nil clamped
    /// or free. As `connection(at:)`.
    func connectionSlot(at point: SIMD3<Float>) -> Int? {
        guard !isClampedBySupport(at: point) else { return nil }
        if let index = finiteSupportIndex(at: point) { return 1 + index }
        return fixedBase && abs(point.z) < 1e-4 && baseAnchorage != nil ? 0 : nil
    }

    /// An ideal clamp takes precedence, followed by the last finite support, then the ground.
    func connection(at point: SIMD3<Float>) -> Anchorage? {
        guard !isClampedBySupport(at: point) else { return nil }
        if let index = finiteSupportIndex(at: point) { return anchorage(ofSupport: index) }
        return fixedBase && abs(point.z) < 1e-4 ? baseAnchorage : nil
    }

    /// The connection in `slot`: 0 the ground's, 1 + n support region n's.
    func connection(inSlot slot: Int) -> Anchorage? {
        slot == 0 ? (fixedBase ? baseAnchorage : nil) : anchorage(ofSupport: slot - 1)
    }

    /// The normals of every connection's joint.
    var connectionNormals: [SIMD3<Float>] {
        ((fixedBase ? [baseAnchorage] : []) + supportAnchorages).compactMap { $0?.across }
    }

    func finiteSupportIndex(at point: SIMD3<Float>) -> Int? {
        guard !isClampedBySupport(at: point) else { return nil }
        return supports.indices.reversed().first {
            anchorage(ofSupport: $0) != nil && containsSupport($0, at: point)
        }
    }

    func validateAnchorages() throws {
        guard supportAnchorages.count <= supports.count else {
            throw ImportedMesh.ImportError.invalid("A connection references a missing support region.")
        }
        try baseAnchorage?.validate()
        guard baseAnchorage?.isUnder ?? true else {
            throw ImportedMesh.ImportError.invalid("The ground's connection can only be under the body.")
        }
        for law in supportAnchorages.compactMap({ $0 }) { try law.validate() }
    }

    /// Whether any support region's connection faces another way than down.
    var hasTurnedJoints: Bool { supportAnchorages.contains { $0.map { !$0.isUnder } ?? false } }

    var connectionStiffness: (normal: Float, shear: Float)? {
        let laws = (fixedBase ? [baseAnchorage].compactMap { $0 } : []) + supportAnchorages.compactMap { $0 }
        guard !laws.isEmpty else { return nil }
        return laws.reduce((normal: Float(0), shear: Float(0))) { result, law in
            let value = law.stiffness(material: material, elementSize: elementSize)
            return (max(result.normal, value.normal), max(result.shear, value.shear))
        }
    }
}
