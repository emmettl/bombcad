import Foundation

/// The SDOF systems of envelope components (walls, roofs and panes as rectangular panels loaded
/// uniformly across their thin axis), from their material and size, as UFC 3-340-02 (2008) and
/// SBEDS build them: an elastic stiffness from plate theory, an ultimate resistance from the
/// yield-line or cracking moment, and Biggs's load–mass factors for two-way panels.
///
/// The span `a` is the shorter in-plane size and `b` the longer. Every quantity is per unit area
/// of the panel: masses in kg/m², resistances and pressures in Pa, deflections at the middle in m.
public enum EnvelopePanel {
    /// How a panel's edges are held. Panels of a monolithic building, continuous with their
    /// neighbours, are taken as fixed; a pane in a frame as simply supported.
    public enum Edges: String, Codable, Sendable { case fixed, simplySupported }

    /// UFC 3-340-02 Table 4-1's dynamic increase factors for flexure, far design range: concrete
    /// in compression 1.19, reinforcement 1.17.
    public static let concreteFlexureIncrease = 1.19
    public static let reinforcementFlexureIncrease = 1.17

    /// Timoshenko & Woinowsky-Krieger (1959) for a uniformly loaded rectangular plate, ν 0.3:
    /// the deflection at the middle α q a⁴ / D and the largest bending moment β q a² (at the
    /// middle when simply supported, at the middle of a long edge when clamped), against b / a.
    static let ratios: [Double] = [1.0, 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9, 2.0, 1e9]
    static let deflection: [Edges: [Double]] = [
        .simplySupported: [
            0.00406, 0.00485, 0.00564, 0.00638, 0.00705, 0.00772, 0.00830, 0.00883, 0.00931, 0.00974,
            0.01013, 0.01302,
        ],
        .fixed: [
            0.00126, 0.00150, 0.00172, 0.00191, 0.00207, 0.00220, 0.00230, 0.00238, 0.00245, 0.00249,
            0.00254, 0.00260,
        ],
    ]
    static let moment: [Edges: [Double]] = [
        .simplySupported: [
            0.0479, 0.0554, 0.0627, 0.0694, 0.0755, 0.0812, 0.0862, 0.0908, 0.0948, 0.0985, 0.1017, 0.125,
        ],
        .fixed: [
            0.0513, 0.0581, 0.0639, 0.0687, 0.0726, 0.0757, 0.0780, 0.0799, 0.0812, 0.0822, 0.0829, 0.0833,
        ],
    ]

    /// A coefficient interpolated in b / a, held at the last tabulated ratio below infinity.
    static func coefficient(_ table: [Double], aspect: Double) -> Double {
        let ratio = max(aspect, 1)
        for index in 1..<ratios.count where ratio <= ratios[index] {
            if ratios[index] > 100 { return table[index] }
            let t = (ratio - ratios[index - 1]) / (ratios[index] - ratios[index - 1])
            return table[index - 1] + t * (table[index] - table[index - 1])
        }
        return table.last!
    }

    /// Elastic stiffness of a plate of flexural rigidity `rigidity` (N m): pressure per deflection
    /// at its middle.
    public static func stiffness(rigidity: Double, a: Double, b: Double, edges: Edges) -> Double {
        rigidity / (coefficient(deflection[edges]!, aspect: b / a) * pow(a, 4))
    }

    /// The pressure at which the largest elastic bending moment reaches `capacity` (N m/m).
    public static func pressureAtMoment(_ capacity: Double, a: Double, b: Double, edges: Edges) -> Double {
        capacity / (coefficient(moment[edges]!, aspect: b / a) * a * a)
    }

    /// Yield-line resistance of an isotropically reinforced rectangular panel (Johansen): with
    /// positive and negative moment capacities `positive` and `negative` (N m/m, negative 0 for
    /// simply supported edges), q = 24 (m⁺ + m⁻) / a² / (√(3 + (a/b)²) − a/b)².
    public static func yieldLineResistance(positive: Double, negative: Double, a: Double, b: Double) -> Double
    {
        let r = a / b
        let shape = (3 + r * r).squareRoot() - r
        return 24 * (positive + negative) / (a * a) / (shape * shape)
    }

    /// Biggs (1964) Table 5.5's load–mass factors for two-way panels under a uniform load,
    /// rounded over aspect ratios 1 to 2: (elastic, plastic).
    public static func loadMassFactors(_ edges: Edges) -> (elastic: Double, plastic: Double) {
        edges == .fixed ? (0.64, 0.67) : (0.68, 0.66)
    }

    /// A reinforced concrete panel `thickness` thick with `steelArea` m² of bars per metre each
    /// way at `depth` from the compression face (the same each way and for either sign of
    /// moment when the mat is central). The elastic stiffness takes UFC's average of the gross
    /// and cracked moments of inertia (§4-14), the resistance the yield line on dynamic
    /// strengths; elastic–perfectly plastic.
    public static func reinforcedConcrete(
        thickness: Double, depth: Double, steelArea: Double, material: StructureMaterial, a: Double,
        b: Double,
        edges: Edges = .fixed
    ) -> SDOFSystem {
        let fc = Double(material.compressiveStrength)
        let fy = Double(material.steel?.yieldStress ?? 500e6)
        let concrete = Double(material.youngsModulus)
        let steel = Double(material.steel?.youngsModulus ?? 200e9)
        let fdc = fc * concreteFlexureIncrease
        let fds = fy * reinforcementFlexureIncrease
        // Moment capacity per metre: the bars' force over the lever arm to the stress block.
        let force = steelArea * fds
        let block = force / (0.85 * fdc)
        let capacity = force * (depth - block / 2)
        let resistance = yieldLineResistance(
            positive: capacity, negative: edges == .fixed ? capacity : 0, a: a, b: b)
        // Cracked section (UFC eq 4-12's transformed section) and gross, averaged.
        let n = steel / concrete
        let rho = steelArea / depth
        let k = (2 * n * rho + n * n * rho * rho).squareRoot() - n * rho
        let cracked = pow(k * depth, 3) / 3 + n * steelArea * pow(depth - k * depth, 2)
        let gross = pow(thickness, 3) / 12
        let poisson = Double(material.poissonRatio)
        let rigidity = concrete * (gross + cracked) / 2 / (1 - poisson * poisson)
        let factors = loadMassFactors(edges)
        return .elasticPlastic(
            massPerArea: Double(material.density) * thickness,
            stiffness: stiffness(rigidity: rigidity, a: a, b: b, edges: edges), ultimate: resistance,
            loadMassElastic: factors.elastic, loadMassPlastic: factors.plastic, span: a)
    }

    /// An unreinforced masonry panel without arching: elastic on the gross section until its
    /// tensile strength cracks it (the pressure at which the largest moment reaches the cracking
    /// moment f_t t² / 6), then a rocking mechanism whose resistance falls to nothing when the
    /// deflection reaches the thickness.
    public static func unreinforcedMasonry(
        thickness: Double, material: StructureMaterial, a: Double, b: Double, edges: Edges = .fixed
    ) -> SDOFSystem {
        let poisson = Double(material.poissonRatio)
        let rigidity = Double(material.youngsModulus) * pow(thickness, 3) / 12 / (1 - poisson * poisson)
        let k = stiffness(rigidity: rigidity, a: a, b: b, edges: edges)
        let cracking = Double(material.tensileStrength) * thickness * thickness / 6
        let resistance = pressureAtMoment(cracking, a: a, b: b, edges: edges)
        let factors = loadMassFactors(edges)
        return SDOFSystem(
            massPerArea: Double(material.density) * thickness, loadMassElastic: factors.elastic,
            loadMassPlastic: factors.plastic,
            backbone: [SIMD2(resistance / k, resistance), SIMD2(thickness, 0)], span: a)
    }

    /// A glass pane, elastic on small-deflection plate theory until the largest bending stress
    /// reaches its breaking strength, when it loses all resistance (`SDOFResponse.lostResistanceAt`
    /// is when it breaks). Membrane stiffening, which lowers the stress once the deflection
    /// passes the thickness, is left out, so it breaks early.
    public static func glass(
        thickness: Double, material: StructureMaterial, a: Double, b: Double, edges: Edges = .fixed
    ) -> SDOFSystem {
        let poisson = Double(material.poissonRatio)
        let rigidity = Double(material.youngsModulus) * pow(thickness, 3) / 12 / (1 - poisson * poisson)
        let k = stiffness(rigidity: rigidity, a: a, b: b, edges: edges)
        let breaking = Double(material.tensileStrength) * thickness * thickness / 6
        let resistance = pressureAtMoment(breaking, a: a, b: b, edges: edges)
        let factors = loadMassFactors(edges)
        let breakAt = resistance / k
        return SDOFSystem(
            massPerArea: Double(material.density) * thickness, loadMassElastic: factors.elastic,
            loadMassPlastic: factors.elastic,
            backbone: [SIMD2(breakAt, resistance), SIMD2(breakAt * (1 + 1e-6), 0)], reboundFactor: 1, span: a)
    }
}
