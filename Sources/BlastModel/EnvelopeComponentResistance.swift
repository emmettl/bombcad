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
    ///
    /// `axialLoad` (N per metre, the masonry above) holds a wall `height` tall: cracked across
    /// its height it rocks as two halves against it, which resist 8 P (t − x) / h² at a deflection
    /// x (the thrust's lever arm from face to face shrinking to nothing at the thickness, as SBEDS
    /// treats an unreinforced wall held by its axial load; PDC-TR 06-01, 2008). The panel takes
    /// the larger of the two resistances.
    public static func unreinforcedMasonry(
        thickness: Double, material: StructureMaterial, a: Double, b: Double, edges: Edges = .fixed,
        axialLoad: Double = 0, height: Double = 0
    ) -> SDOFSystem {
        let poisson = Double(material.poissonRatio)
        let rigidity = Double(material.youngsModulus) * pow(thickness, 3) / 12 / (1 - poisson * poisson)
        let k = stiffness(rigidity: rigidity, a: a, b: b, edges: edges)
        let cracking = Double(material.tensileStrength) * thickness * thickness / 6
        let rocking = height > 0 ? 8 * axialLoad * thickness / (height * height) : 0
        let resistance = max(pressureAtMoment(cracking, a: a, b: b, edges: edges), rocking)
        let factors = loadMassFactors(edges)
        return SDOFSystem(
            massPerArea: Double(material.density) * thickness, loadMassElastic: factors.elastic,
            loadMassPlastic: factors.plastic,
            backbone: [SIMD2(resistance / k, resistance), SIMD2(thickness, 0)], span: a)
    }

    /// Points along the arch's resistance that `arching` lays its backbone on.
    static let archingPoints = 16

    /// `system`, an unreinforced masonry wall `thickness` thick, held against horizontal thrust at
    /// both ends of `span` (returns: cross walls, party walls, the building's corners), with the
    /// resistance of arching between them where that is larger. Three hinges, at the ends and the
    /// middle, each pressing a thrust block of 0.85 f_m half the thickness deep, resist
    /// q(x) = 1.7 f_m (t − x)² / L² at a deflection x of the middle between rigid abutments,
    /// falling to nothing at the thickness (after McDowell, McKee and Sevin, "Arching action theory
    /// of masonry walls", Journal of the Structural Division 82, 1956). The thrust grows only as
    /// the blocks shorten, so the arch takes hold as the wall deflects: from the wall's cracking
    /// (its own backbone's first point) the resistance rises straight to the curve at
    /// x_p = (0.85 f_m / E) L² / (2 t), where struts half the thickness deep have shortened by the
    /// masonry's strain at that stress (no further than half the thickness), and follows it down.
    /// The thrust needs the abutments not to give; a terrace's neighbours, pushed the same way,
    /// balance it at each party wall. `material`'s strength and modulus, without a dynamic
    /// increase.
    public static func arching(
        _ system: SDOFSystem, thickness t: Double, material: StructureMaterial, span: Double
    ) -> SDOFSystem {
        guard span > 0, t > 0, let first = system.backbone.first, let last = system.backbone.last,
            last.y == 0, last.x > first.x, first.x < t
        else { return system }
        let strength = Double(material.compressiveStrength)
        let q0 = 1.7 * strength * t * t / (span * span)
        guard q0 > first.y else { return system }
        func curve(_ x: Double) -> Double { x >= t ? 0 : q0 * (1 - x / t) * (1 - x / t) }
        let peakAt = max(
            min(0.85 * strength / Double(material.youngsModulus) * span * span / (2 * t), t / 2),
            first.x)
        // The arch: rising from the wall's cracking to the curve at its peak, then down it.
        func arch(_ x: Double) -> Double {
            guard x < peakAt else { return curve(x) }
            return first.y + (curve(peakAt) - first.y) * (x - first.x) / (peakAt - first.x)
        }
        // The wall's own resistance at x: its backbone, linear between its points.
        func own(_ x: Double) -> Double {
            if x <= first.x { return first.y * x / first.x }
            for (p, q) in zip(system.backbone, system.backbone.dropFirst()) where x <= q.x {
                return p.y + (q.y - p.y) * (x - p.x) / (q.x - p.x)
            }
            return last.y
        }
        let end = max(t, last.x)
        let rising = peakAt > first.x ? 4 : 0
        var points: [Double] = (0..<rising).map {
            first.x + (peakAt - first.x) * Double($0 + 1) / Double(rising)
        }
        let falling = Self.archingPoints - rising
        points += (1..<falling).map { peakAt + (end - peakAt) * Double($0) / Double(falling) }
        var result = system
        result.backbone = [first] + points.map { SIMD2($0, max(own($0), arch($0))) } + [SIMD2(end, 0)]
        return result
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

    // MARK: Cantilevers

    /// UFC 3-340-02 Table 3-12 (after Biggs 1964, Table 5.1) for a cantilever under a uniform
    /// load: K_LM 0.65 elastic, 0.66 plastic. The plastic factor is a rigid rotation about the
    /// base (K_L 1/2, K_M 1/3), so it serves a rocking wall too.
    public static let cantileverLoadMass = (elastic: 0.65, plastic: 0.66)

    /// A reinforced concrete wall fixed at its base and free at its top, `height` high, with
    /// `steelArea` m² of vertical bars per metre at `depth` from the compression face (UFC §4):
    /// the base's moment capacity on dynamic strengths (Table 4-1), the ultimate unit resistance
    /// of a cantilever under a uniform load r_u = 2 M_N / L² (UFC Table 3-1), the elastic stiffness
    /// 8 E I / L⁴ (Table 3-8) on the mean of the gross and cracked sections (§4-14);
    /// elastic–perfectly plastic. The deflection is the top's; the system's `span` is twice the
    /// height, so that its support rotation atan(x / (span / 2)) is the cantilever's atan(x / L)
    /// (UFC Table 3-5).
    ///
    /// `topMass` (kg per metre of wall) is a mass carried at the top, a cap or canopy: moving
    /// with the top, it adds M / (K_M L) to the mass per area, K_M the plastic mass factor (1/3).
    public static func reinforcedConcreteCantilever(
        thickness: Double, depth: Double, steelArea: Double, material: StructureMaterial, height: Double,
        topMass: Double = 0
    ) -> SDOFSystem {
        let fc = Double(material.compressiveStrength)
        let fy = Double(material.steel?.yieldStress ?? 500e6)
        let concrete = Double(material.youngsModulus)
        let steel = Double(material.steel?.youngsModulus ?? 200e9)
        let force = steelArea * fy * reinforcementFlexureIncrease
        let block = force / (0.85 * fc * concreteFlexureIncrease)
        let capacity = force * (depth - block / 2)
        let resistance = 2 * capacity / (height * height)
        let n = steel / concrete
        let rho = steelArea / depth
        let k = (2 * n * rho + n * n * rho * rho).squareRoot() - n * rho
        let cracked = pow(k * depth, 3) / 3 + n * steelArea * pow(depth - k * depth, 2)
        let gross = pow(thickness, 3) / 12
        let stiffness = 8 * concrete * (gross + cracked) / 2 / pow(height, 4)
        return .elasticPlastic(
            massPerArea: Double(material.density) * thickness + 3 * topMass / height, stiffness: stiffness,
            ultimate: resistance,
            loadMassElastic: cantileverLoadMass.elastic, loadMassPlastic: cantileverLoadMass.plastic,
            span: 2 * height)
    }

    /// An unreinforced masonry wall standing free, `height` high: elastic on its gross section
    /// (8 E I / L⁴) until the base cracks, at the moment (f_t + σ) t² / 6, σ = ρ g L its weight's
    /// stress at the base and f_t its bond (none if `bondedBase` is false, a wall stood on the
    /// ground); then it rocks about the leeward edge of its base as a rigid block, which its
    /// weight resists by ρ g t (t − x) / L per area at a top deflection x, falling to nothing as x
    /// reaches the thickness and its weight passes over the edge (statics of a rigid block, as
    /// SBEDS treats a cracked unreinforced wall held only by its axial load; PDC-TR 06-01, 2008).
    /// The deflection is the top's; `span` is twice the height, as for the concrete cantilever.
    public static func unreinforcedMasonryCantilever(
        thickness: Double, material: StructureMaterial, height: Double, bondedBase: Bool = true,
        gravity: Double = 9.81
    ) -> SDOFSystem {
        let rho = Double(material.density)
        let stiffness = 8 * Double(material.youngsModulus) * pow(thickness, 3) / 12 / pow(height, 4)
        let weight = rho * gravity * thickness  // per area of the wall's face, Pa
        func rocking(_ x: Double) -> Double { max(weight * (thickness - x) / height, 0) }
        let bond = bondedBase ? Double(material.tensileStrength) : 0
        let cracking = 2 * (bond + rho * gravity * height) * thickness * thickness / 6 / (height * height)
        var backbone: [SIMD2<Double>]
        if cracking > rocking(cracking / stiffness) {
            // Bonded: elastic to cracking, then down to the rocking line.
            let x = cracking / stiffness
            backbone = [SIMD2(x, cracking), SIMD2(x * (1 + 1e-6), rocking(x)), SIMD2(thickness, 0)]
        } else {
            // Unbonded (or weakly bonded): elastic until it meets the rocking line, then down it.
            let x = weight * thickness / (height * stiffness + weight)
            backbone = [SIMD2(x, rocking(x)), SIMD2(thickness, 0)]
        }
        return SDOFSystem(
            massPerArea: rho * thickness, loadMassElastic: cantileverLoadMass.elastic,
            loadMassPlastic: cantileverLoadMass.plastic, backbone: backbone, span: 2 * height)
    }

    // MARK: One-way panels

    /// UFC 3-340-02 Table 3-12 (Biggs 1964, Table 5.1) for a one-way member under a uniform load:
    /// simply supported 0.78 elastic, 0.66 plastic; both ends fixed 0.77 elastic, 0.66 plastic.
    public static func oneWayLoadMass(_ edges: Edges) -> (elastic: Double, plastic: Double) {
        edges == .fixed ? (0.77, 0.66) : (0.78, 0.66)
    }

    /// A reinforced concrete or masonry strip spanning `span` between two opposite supports, the
    /// other two edges free, `steelArea` m² of bars per metre at `depth` from the compression face
    /// (the same either way for a central mat): the moment capacity on dynamic strengths, r_u =
    /// 8 M_N / L² simply supported or 8 (M_N + M_P) / L² fixed (UFC Table 3-1), the stiffness
    /// 384 E I / (5 L⁴) or 384 E I / L⁴ (Table 3-8) on the mean of the gross and cracked sections;
    /// elastic–perfectly plastic. Its span is the system's, so atan(x / (L/2)) is its rotation.
    public static func reinforcedOneWay(
        thickness: Double, depth: Double, steelArea: Double, material: StructureMaterial, span: Double,
        edges: Edges = .simplySupported
    ) -> SDOFSystem {
        let fc = Double(material.compressiveStrength)
        let fy = Double(material.steel?.yieldStress ?? 500e6)
        let modulus = Double(material.youngsModulus)
        let steel = Double(material.steel?.youngsModulus ?? 200e9)
        let force = steelArea * fy * reinforcementFlexureIncrease
        let block = force / (0.85 * fc * concreteFlexureIncrease)
        let capacity = force * (depth - block / 2)
        let resistance = 8 * capacity * (edges == .fixed ? 2 : 1) / (span * span)
        let n = steel / modulus
        let rho = steelArea / depth
        let k = (2 * n * rho + n * n * rho * rho).squareRoot() - n * rho
        let cracked = pow(k * depth, 3) / 3 + n * steelArea * pow(depth - k * depth, 2)
        let gross = pow(thickness, 3) / 12
        let stiffness = 384 * modulus * (gross + cracked) / 2 / ((edges == .fixed ? 1 : 5) * pow(span, 4))
        let factors = oneWayLoadMass(edges)
        return .elasticPlastic(
            massPerArea: Double(material.density) * thickness, stiffness: stiffness, ultimate: resistance,
            loadMassElastic: factors.elastic, loadMassPlastic: factors.plastic, span: span)
    }

    /// An unreinforced masonry strip spanning `span` between two opposite supports, without
    /// arching: elastic on its gross section until the largest moment reaches f_t t² / 6 (at the
    /// middle simply supported, w L² / 8; at the supports fixed, w L² / 12), then a mechanism whose
    /// resistance falls to nothing when the middle deflects by the thickness. Spanning up between
    /// its foot and top under `axialLoad` (N/m), the larger of that and the rocking resistance
    /// 8 P t / L² (as `unreinforcedMasonry`).
    public static func unreinforcedMasonryOneWay(
        thickness: Double, material: StructureMaterial, span: Double, edges: Edges = .simplySupported,
        axialLoad: Double = 0
    ) -> SDOFSystem {
        let modulus = Double(material.youngsModulus)
        let stiffness = 384 * modulus * pow(thickness, 3) / 12 / ((edges == .fixed ? 1 : 5) * pow(span, 4))
        let cracking = Double(material.tensileStrength) * thickness * thickness / 6
        let resistance = max(cracking * (edges == .fixed ? 12 : 8), 8 * axialLoad * thickness) / (span * span)
        let factors = oneWayLoadMass(edges)
        return SDOFSystem(
            massPerArea: Double(material.density) * thickness, loadMassElastic: factors.elastic,
            loadMassPlastic: factors.plastic,
            backbone: [SIMD2(resistance / stiffness, resistance), SIMD2(thickness, 0)], span: span)
    }
}
