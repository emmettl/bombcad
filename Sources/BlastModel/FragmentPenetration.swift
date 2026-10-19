import Foundation

/// What a steel fragment does to what it strikes, by the standard empirical methods: UFC
/// 3-340-02's for concrete (§4-60, the modified NDRC form) and its steel plates (§5-49),
/// Project THOR's for metal plates, and a measured threshold for glass. Outcomes are named as
/// Edgerton names them: the fragment stopped (embedded), stopped with the far face spalled, or
/// through (perforated), with its speed beyond.
public struct PenetrationResult: Codable, Sendable, Equatable {
    public enum Outcome: String, Codable, Sendable, CaseIterable, Comparable {
        case stopped, spalled, perforated

        public static func < (a: Self, b: Self) -> Bool {
            allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
        }
    }

    public var outcome: Outcome
    /// How far it would go into the same material were it thick, m (nil where the method does
    /// not give it).
    public var depthM: Float?
    /// The thickness that would stop it, and that would also keep the far face from spalling,
    /// m (nil where the method does not give it).
    public var perforationThicknessM: Float?
    public var spallThicknessM: Float?
    /// Its speed once through, m/s; zero unless perforated.
    public var residualSpeed: Float
    /// Which method: "UFC 3-340-02 4-60", "UFC 3-340-02 5-49", "THOR <target>", "glass".
    public var method: String
    /// Through, the hole it leaves, m²: the fragment's mean presented area, for want of a cited hole
    /// size (UFC 3-340-02 §4-60.1 describes craters wider than the fragment but gives no size), so
    /// a lower bound. Set where the fragment's area is known (`FragmentCloud`).
    public var holeAreaM2: Float? = nil
}

public enum FragmentPenetration {
    static let ounce: Float = 0.028_349_523
    static let inch: Float = 0.0254
    static let foot: Float = 0.3048
    static let grain: Float = 0.000_064_798_91
    static let psi: Float = 6_894.757

    /// The diameter of UFC 3-340-02's standard primary fragment of `ounces` (Figure 2-245), in:
    /// `d = 0.695 W^(1/3)`, as Equations 4-200 and 4-201 restate 4-198 and 4-199 by weight.
    public static func standardDiameter(ounces: Float) -> Float { 0.695 * cbrt(ounces) }

    /// UFC 3-340-02's relative penetrability, Table 4-16.
    public enum Metal: Float, Codable, Sendable {
        case armourPiercing = 1
        case mildSteel = 0.7
        case lead = 0.5
        case aluminium = 0.15
    }

    /// A fragment of `mass` kg striking concrete `thickness` m thick, of compressive strength
    /// `strength` Pa, at `speed` m/s, nose-on: UFC 3-340-02 §4-60, Equations 4-198 and 4-199
    /// (UFC's standard fragment of that weight, which it takes as the critical shape), 4-202
    /// for the strength, 4-203 for the metal, 4-204 and 4-207 for the thicknesses that prevent
    /// perforation and spalling, and 4-205 or 4-206 for the speed beyond.
    public static func concrete(
        mass: Float, speed: Float, thickness: Float, strength: Float, metal: Metal = .mildSteel
    ) -> PenetrationResult {
        let ounces = mass / ounce
        let v = max(speed, 0) / foot
        let d = standardDiameter(ounces: ounces)
        let tc = thickness / inch
        let shallow = 2.86e-3 * pow(d, 1.1) * pow(v, 0.9)
        let xf = shallow <= 2 * d ? shallow : 2.04e-6 * pow(d, 1.2) * pow(v, 1.8) + d
        let x = metal.rawValue * xf * (4_000 / max(strength / psi, 1)).squareRoot()
        let tpf = 1.13 * x * pow(d, 0.1) + 1.311 * d
        let tsp = 1.215 * x * pow(d, 0.1) + 2.12 * d
        var residual: Float = 0
        let outcome: PenetrationResult.Outcome
        if tc < tpf {
            let ratio = tc / tpf
            residual = speed * pow(xf < 2 * d ? 1 - ratio * ratio : 1 - ratio, 0.555)
            outcome = .perforated
        } else {
            outcome = tc < tsp ? .spalled : .stopped
        }
        return PenetrationResult(
            outcome: outcome, depthM: x * inch, perforationThicknessM: tpf * inch,
            spallThicknessM: tsp * inch,
            residualSpeed: residual, method: "UFC 3-340-02 4-60")
    }

    /// A mild steel fragment of `mass` kg striking a mild steel plate `thickness` m thick at
    /// `speed` m/s, nose-on: UFC 3-340-02 §5-49, Equation 5-65 (5-64 for armour-piercing) for
    /// the depth and the critical perforation speed, and 5-66 for the speed beyond.
    public static func steelPlate(
        mass: Float, speed: Float, thickness: Float, armourPiercing: Bool = false
    ) -> PenetrationResult {
        let ounces = mass / ounce
        let coefficient: Float = armourPiercing ? 0.30 : 0.21
        let t = thickness / inch
        let depth = coefficient * pow(ounces, 0.33) * pow(max(speed, 0) / foot / 1000, 1.22)
        let critical = pow(t / (coefficient * pow(ounces, 0.33)), 1 / 1.22) * 1000 * foot
        let d = standardDiameter(ounces: ounces)
        let through = speed > critical
        let residual =
            through ? speed * (1 - (critical / speed) * (critical / speed)).squareRoot() / (1 + t / d) : 0
        return PenetrationResult(
            outcome: through ? .perforated : .stopped, depthM: depth * inch, perforationThicknessM: nil,
            spallThicknessM: nil, residualSpeed: residual, method: "UFC 3-340-02 5-49")
    }

    /// Project THOR's empirical constants for compact steel fragments perforating metal plates
    /// (Technical Report 47, 1961, as Deniz, METU MSc thesis, 2010, Tables 3.2 and 3.3,
    /// reproduces them): `Vr = Vs − 10^c (hA)^α m^β (sec θ)^γ Vs^λ` and the speed just to
    /// perforate `V0 = 10^c1 (hA)^α1 m^β1 (sec θ)^γ1`, h in inches, A the fragment's mean
    /// impact area in square inches, m in grains, speeds in feet a second.
    public struct ThorTarget: Codable, Sendable, Equatable {
        public var name: String
        public var c: Float, alpha: Float, beta: Float, gamma: Float, lambda: Float
        public var c1: Float, alpha1: Float, beta1: Float, gamma1: Float

        public static let magnesium = ThorTarget(
            name: "Magnesium", c: 6.904, alpha: 1.092, beta: -1.170, gamma: 1.050, lambda: -0.087, c1: 6.349,
            alpha1: 1.004, beta1: -1.076, gamma1: 0.966)
        public static let aluminium2024 = ThorTarget(
            name: "Aluminum Alloy 2024T-3", c: 7.047, alpha: 1.029, beta: -1.072, gamma: 1.251,
            lambda: -0.139,
            c1: 6.185, alpha1: 0.903, beta1: -0.941, gamma1: 1.098)
        public static let titanium = ThorTarget(
            name: "Titanium Alloy", c: 6.292, alpha: 1.103, beta: -1.095, gamma: 1.369, lambda: 0.167,
            c1: 7.552,
            alpha1: 1.325, beta1: -1.314, gamma1: 1.643)
        public static let castIron = ThorTarget(
            name: "Cast Iron", c: 4.840, alpha: 1.042, beta: -1.051, gamma: 1.028, lambda: 0.523, c1: 10.153,
            alpha1: 2.186, beta1: -2.204, gamma1: 2.156)
        public static let faceHardenedSteel = ThorTarget(
            name: "Face-Hardened Steel", c: 4.356, alpha: 0.674, beta: -0.791, gamma: 0.989, lambda: 0.434,
            c1: 7.694, alpha1: 1.191, beta1: -1.397, gamma1: 1.747)
        public static let mildSteel = ThorTarget(
            name: "Mild Homogeneous Steel", c: 6.399, alpha: 0.889, beta: -0.945, gamma: 1.262, lambda: 0.019,
            c1: 6.523, alpha1: 0.906, beta1: -0.963, gamma1: 1.286)
        public static let hardSteel = ThorTarget(
            name: "Hard Homogeneous Steel", c: 6.475, alpha: 0.889, beta: -0.945, gamma: 1.262, lambda: 0.019,
            c1: 6.601, alpha1: 0.906, beta1: -0.963, gamma1: 1.286)
        public static let copper = ThorTarget(
            name: "Copper", c: 2.785, alpha: 0.678, beta: -0.730, gamma: 0.846, lambda: 0.802, c1: 14.065,
            alpha1: 3.476, beta1: -3.687, gamma1: 4.270)
        public static let lead = ThorTarget(
            name: "Lead", c: 1.999, alpha: 0.499, beta: -0.502, gamma: 0.655, lambda: 0.818, c1: 10.955,
            alpha1: 2.735, beta1: -2.753, gamma1: 3.590)
        public static let tuballoy = ThorTarget(
            name: "Tuballoy", c: 2.537, alpha: 0.583, beta: -0.603, gamma: 0.865, lambda: 0.828, c1: 14.773,
            alpha1: 3.393, beta1: -3.510, gamma1: 5.037)

        public static let all = [
            magnesium, aluminium2024, titanium, castIron, faceHardenedSteel, mildSteel, hardSteel, copper,
            lead,
            tuballoy,
        ]
    }

    /// A steel fragment of `mass` kg and mean impact area `area` m² striking a metal plate
    /// `thickness` m thick at `speed` m/s, `obliquity` radians from its normal, by THOR.
    public static func thor(
        _ target: ThorTarget, mass: Float, area: Float, speed: Float, thickness: Float, obliquity: Float = 0
    ) -> PenetrationResult {
        let ha = (thickness / inch) * (area / (inch * inch))
        let grains = mass / grain
        let secant = 1 / max(cos(min(abs(obliquity), 1.4)), 0.17)
        let v = max(speed, 0) / foot
        let limit =
            pow(10, target.c1) * pow(ha, target.alpha1) * pow(grains, target.beta1)
            * pow(secant, target.gamma1)
        guard v > limit else {
            return PenetrationResult(
                outcome: .stopped, depthM: nil, perforationThicknessM: nil, spallThicknessM: nil,
                residualSpeed: 0,
                method: "THOR \(target.name)")
        }
        let loss =
            pow(10, target.c) * pow(ha, target.alpha) * pow(grains, target.beta) * pow(secant, target.gamma)
            * pow(v, target.lambda)
        return PenetrationResult(
            outcome: .perforated, depthM: nil, perforationThicknessM: nil, spallThicknessM: nil,
            residualSpeed: max(v - loss, 0) * foot, method: "THOR \(target.name)")
    }

    /// The momentum, N s, past which a steel ball always broke 5 mm annealed glass in Kim et al.
    /// (Applied Sciences 15, 386, 2025): 2.1 g at 40 m/s and 4.15 g at 21 m/s, 0.084 and
    /// 0.087 N s; neither broke it at 34 and 14.5 m/s.
    public static let glassBreakingMomentum: Float = 0.085

    /// A steel fragment striking an annealed pane: broken and holed (perforated) when its
    /// momentum passes `glassBreakingMomentum`; it is not slowed (no method gives how much).
    public static func glass(mass: Float, speed: Float) -> PenetrationResult {
        let through = mass * speed >= glassBreakingMomentum
        return PenetrationResult(
            outcome: through ? .perforated : .stopped, depthM: nil, perforationThicknessM: nil,
            spallThicknessM: nil, residualSpeed: through ? speed : 0, method: "glass")
    }
}

/// What a block or a structure's solid is, to a fragment striking it: its material, how thick it
/// is (nil: the box's own depth across the face struck), and for concrete and masonry its
/// compressive strength. Envelope blocks also name their building and pane.
public struct FragmentTarget: Codable, Sendable, Equatable {
    public enum Material: String, Codable, Sendable { case concrete, masonry, steel, aluminium, glass }
    public var material: Material
    public var thickness: Float?
    /// Pa.
    public var strength: Float = 0
    /// The envelope building, and the pane among its panes, a block belongs to.
    public var owner: UUID? = nil
    public var pane: Int? = nil

    public init(
        material: Material, thickness: Float? = nil, strength: Float = 0, owner: UUID? = nil, pane: Int? = nil
    ) {
        self.material = material
        self.thickness = thickness
        self.strength = strength
        self.owner = owner
        self.pane = pane
    }

    /// A structure's material as a target; nil for one no method covers (timber, plastics).
    public init?(_ material: StructureMaterial) {
        if material.isTransparent {
            self.init(material: .glass)
        } else if material.model == .concrete {
            self.init(
                material: material.units == nil ? .concrete : .masonry, strength: material.compressiveStrength
            )
        } else if material.density > 7000, material.yieldStress > 150e6, material.yieldStress < 1e29 {
            self.init(material: .steel)
        } else if (2500...3000).contains(material.density), material.yieldStress > 50e6,
            material.yieldStress < 1e29
        {
            self.init(material: .aluminium)
        } else {
            return nil
        }
    }

    /// What a fragment of `mass` kg and mean presented area `area` m² does, striking it at
    /// `speed` m/s `obliquity` radians from the normal of a face `thickness` m deep. Concrete and
    /// masonry are judged nose-on, as UFC 3-340-02 designs (masonry as concrete of its strength,
    /// for want of a method of its own); metal plates by THOR; glass by its breaking momentum.
    public func assess(mass: Float, area: Float, speed: Float, thickness: Float, obliquity: Float)
        -> PenetrationResult
    {
        switch material {
        case .concrete, .masonry:
            FragmentPenetration.concrete(mass: mass, speed: speed, thickness: thickness, strength: strength)
        case .steel:
            FragmentPenetration.thor(
                .mildSteel, mass: mass, area: area, speed: speed, thickness: thickness, obliquity: obliquity)
        case .aluminium:
            FragmentPenetration.thor(
                .aluminium2024, mass: mass, area: area, speed: speed, thickness: thickness,
                obliquity: obliquity)
        case .glass:
            FragmentPenetration.glass(mass: mass, speed: speed)
        }
    }
}

/// Where and when a fragment goes through an envelope's wall, roof or pane, and the hole it leaves.
public struct EnvelopeHole: Codable, Sendable, Equatable {
    public var owner: UUID
    /// The pane, by its index among its envelope's panes; nil for a wall or roof.
    public var pane: Int?
    /// s from the start.
    public var time: Double
    public var position: SIMD3<Float>
    /// The hole's area, m², the real fragments the flown one stands for together.
    public var areaM2: Float
}

extension FragmentCloud {
    /// Every hole a cased charge's fragments make through envelopes up to `until`, in time order:
    /// the same fragments (`spec`'s seed) flown before the run in still air of `density` and
    /// `pressure`, so that the holes are known before the blast reaches any, whatever the
    /// fragments' consumer lags. Ahead of the blast the air is still; inside it the wind would
    /// carry them a little faster (fragments.md).
    public static func envelopeHoles(
        spec: FragmentSpec, scene: FragmentScene, density: Float, pressure: Float, until: Double
    ) -> [EnvelopeHole] {
        var cloud = FragmentCloud(spec: spec, scene: scene)
        cloud.land(in: Primitive(density: density, pressure: pressure), limit: until)
        return cloud.impacts.compactMap { impact -> EnvelopeHole? in
            guard impact.time <= until, let owner = impact.objectID, impact.surface.hasPrefix("block"),
                let penetration = impact.penetration, penetration.outcome == .perforated
            else { return nil }
            return EnvelopeHole(
                owner: owner, pane: impact.pane, time: impact.time, position: impact.position,
                areaM2: (penetration.holeAreaM2 ?? 0) * impact.count)
        }
        .sorted { ($0.time, $0.owner.uuidString) < ($1.time, $1.owner.uuidString) }
    }

    /// When a cased charge's fragments hole each envelope pane, by component id ("<owner>/pane/<j>.0"),
    /// s from the start, up to `until`: the same fragments (`spec`'s seed) flown before the run in
    /// still air of `density` and `pressure`, so that the times are known before the blast reaches
    /// any pane, whatever the fragments' consumer lags. Ahead of the blast the air is still; inside
    /// it the wind would carry them a little faster (fragments.md).
    public static func paneHoles(
        spec: FragmentSpec, scene: FragmentScene, density: Float, pressure: Float, until: Double
    ) -> [String: Double] {
        var holes: [String: Double] = [:]
        for hole in envelopeHoles(
            spec: spec, scene: scene, density: density, pressure: pressure, until: until)
        {
            guard let pane = hole.pane else { continue }
            let id = "\(hole.owner.uuidString)/pane/\(pane).0"
            holes[id] = min(holes[id] ?? .infinity, hole.time)
        }
        return holes
    }
}
