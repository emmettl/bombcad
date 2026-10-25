import Foundation

/// A CPU reference for an eight-node hexahedron that, once cracked, stops leaning on hourglass
/// control (emmettl/bombcad-work#20, stage 1). Plain Swift on the standard library alone, in double
/// precision and small strain, so that it can become a candidate for ContinuumKit's
/// `SolidMechanics` later. Nothing on the GPU uses it.
///
/// Four formulations share one geometry:
/// - `onePointHourglass`: today's element in `Structure.metal`, one point at the centre and
///   Flanagan–Belytschko stiffness hourglass control of E h / 48 per unit modal amplitude, capped
///   for concrete at the element's bending capacity times h² / 8, as the shader caps it;
/// - `fullIntegration`: plain trilinear strain at 2 × 2 × 2 Gauss points, which locks in bending
///   (parasitic shear), kept as the control Edgerton's Hex8 study rejected;
/// - `assumedStrain`: 2 × 2 × 2 points with an assumed strain after T. Belytschko and
///   L. P. Bindeman, "Assumed strain stabilization of the eight node hexahedral element",
///   *Computer Methods in Applied Mechanics and Engineering* 105, 1993: the constant strain of the
///   mean gradient plus each hourglass mode's strain, mapped by the centre Jacobian, with the shear
///   terms that vary along a displacement's own direction (the parasitic shear of bending) left
///   out. No hourglass control: every mode has energy of its own;
/// - `switching`: `onePointHourglass` until any of the eight points would leave the elastic range
///   (crack, or be squeezed past a tenth of the strain at peak), then `assumedStrain` for good,
///   each point starting from the centre's history and carrying its own crack state. Its bars are
///   strained at their own height throughout (two points along them, two across a mat).
///
/// The field is written from the paper's construction as recalled, not copied: the mean gradient
/// (Flanagan and Belytschko, 1981), the γ vectors orthogonal to linear fields, the centre
/// Jacobian for the modes' gradients and a corotational frame from its columns. Belytschko and
/// Bindeman's Poisson correction for bending ("quintessential bending", ASQBI) is not included,
/// so an element one deep bending with ν > 0 is stiff by about 1 / (1 − ν²).
public enum CrackedHex {
    /// Natural coordinates of the eight Gauss points, ±1/√3, ordered as the corners.
    public static let gauss = 1 / 3.0.squareRoot()

    /// Corner `a`'s natural coordinates: bit 0 is ξ, bit 1 η, bit 2 ζ.
    public static func corner(_ a: Int) -> SIMD3<Double> {
        SIMD3(a & 1 == 0 ? -1 : 1, a & 2 == 0 ? -1 : 1, a & 4 == 0 ? -1 : 1)
    }

    public static func gaussPoint(_ g: Int) -> SIMD3<Double> { corner(g) * gauss }

    /// What of an element's bars the one-point element's hourglass cap counts: all their yield
    /// spread through the element (today's), none of it, or what their membrane stress at the
    /// centre leaves, M_p (1 − (s / f_y)²) (emmettl/bombcad-work#36).
    public enum HourglassSteel: Sendable, Equatable {
        case smeared, none, remaining
    }

    public enum Formulation: Sendable, Equatable {
        case onePointHourglass(coefficient: Double)
        case fullIntegration
        case assumedStrain
        case switching(coefficient: Double)

        /// Today's element, with the shader's hourglass coefficient of 1.
        public static let today = Formulation.onePointHourglass(coefficient: 1)
        public static let cracked = Formulation.switching(coefficient: 1)
    }
}

// MARK: - Small matrices

/// A 3 × 3 matrix, row-major.
struct CrackedHexMatrix: Equatable {
    var e: [Double]

    static let zero = CrackedHexMatrix(e: Array(repeating: 0, count: 9))
    static let identity = CrackedHexMatrix(e: [1, 0, 0, 0, 1, 0, 0, 0, 1])

    init(e: [Double]) { self.e = e }

    /// The matrix whose columns are `c0`, `c1`, `c2`.
    init(columns c0: SIMD3<Double>, _ c1: SIMD3<Double>, _ c2: SIMD3<Double>) {
        e = [c0.x, c1.x, c2.x, c0.y, c1.y, c2.y, c0.z, c1.z, c2.z]
    }

    subscript(_ i: Int, _ j: Int) -> Double {
        get { e[3 * i + j] }
        set { e[3 * i + j] = newValue }
    }

    func column(_ j: Int) -> SIMD3<Double> { SIMD3(e[j], e[3 + j], e[6 + j]) }

    var transpose: CrackedHexMatrix {
        CrackedHexMatrix(e: [e[0], e[3], e[6], e[1], e[4], e[7], e[2], e[5], e[8]])
    }

    var determinant: Double {
        let c0 = column(0)
        let c1 = column(1)
        let c2 = column(2)
        return CrackedHex.dot(c0, CrackedHex.cross(c1, c2))
    }

    /// det(J) J⁻ᵀ, whose columns are c1 × c2, c2 × c0 and c0 × c1.
    var cofactor: CrackedHexMatrix {
        let c0 = column(0)
        let c1 = column(1)
        let c2 = column(2)
        return CrackedHexMatrix(
            columns: CrackedHex.cross(c1, c2), CrackedHex.cross(c2, c0), CrackedHex.cross(c0, c1))
    }

    var inverse: CrackedHexMatrix {
        let d = determinant
        var m = cofactor.transpose
        for k in 0..<9 { m.e[k] /= d }
        return m
    }

    static func * (a: CrackedHexMatrix, b: CrackedHexMatrix) -> CrackedHexMatrix {
        var m = CrackedHexMatrix.zero
        for i in 0..<3 {
            for j in 0..<3 {
                m[i, j] = a[i, 0] * b[0, j] + a[i, 1] * b[1, j] + a[i, 2] * b[2, j]
            }
        }
        return m
    }

    static func * (a: CrackedHexMatrix, v: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(
            a[0, 0] * v.x + a[0, 1] * v.y + a[0, 2] * v.z, a[1, 0] * v.x + a[1, 1] * v.y + a[1, 2] * v.z,
            a[2, 0] * v.x + a[2, 1] * v.y + a[2, 2] * v.z)
    }

    static func + (a: CrackedHexMatrix, b: CrackedHexMatrix) -> CrackedHexMatrix {
        CrackedHexMatrix(e: zip(a.e, b.e).map { $0 + $1 })
    }
}

extension CrackedHex {
    static func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { a.x * b.x + a.y * b.y + a.z * b.z }

    static func cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
    }

    static func length(_ a: SIMD3<Double>) -> Double { dot(a, a).squareRoot() }
}

// MARK: - Geometry

extension CrackedHex {
    /// One element's rest shape and the strain operators every formulation needs, in Voigt order
    /// xx, yy, zz, xy, yz, zx with engineering shear. Displacements are ordered corner by corner,
    /// x, y, z within each (24 in all).
    public struct Geometry: Sendable {
        public let rest: [SIMD3<Double>]
        public let volume: Double
        /// Cube root of the volume: the h of the hourglass stiffness and its cap.
        public let size: Double
        /// The mean shape-function gradients (Flanagan–Belytschko's uniform gradient).
        let gradients: [SIMD3<Double>]
        /// γ_αa: the four hourglass shape vectors, orthogonal to every linear field, with the
        /// 1/8 of the trilinear interpolation (the shader's are eight times these).
        let gamma: [[Double]]
        /// The corotational frame (columns along the centre Jacobian's, orthonormalised) and the
        /// centre Jacobian's inverse in that frame.
        let frame: CrackedHexMatrix
        let localInverse: CrackedHexMatrix

        /// The strain operator at the centre, and at the eight Gauss points with and without the
        /// shear filter.
        public let centre: [[Double]]
        public let assumed: [[[Double]]]
        public let full: [[[Double]]]

        public init(rest: [SIMD3<Double>]) {
            precondition(rest.count == 8, "eight corners")
            self.rest = rest
            var volume = 0.0
            var integrated = Array(repeating: SIMD3<Double>.zero, count: 8)
            for g in 0..<8 {
                let p = CrackedHex.gaussPoint(g)
                let jacobian = Geometry.jacobian(rest, at: p)
                volume += jacobian.determinant
                let cofactor = jacobian.cofactor
                for a in 0..<8 {
                    integrated[a] = integrated[a] + cofactor * Geometry.naturalGradient(a, at: p)
                }
            }
            precondition(volume > 0, "an element turned inside out")
            self.volume = volume
            size = Foundation.cbrt(volume)
            let gradients = integrated.map { $0 / volume }
            self.gradients = gradients
            var gamma: [[Double]] = []
            for mode in 0..<4 {
                var shape = SIMD3<Double>.zero
                for a in 0..<8 { shape += Geometry.hourglassSign(mode, a) * rest[a] }
                gamma.append(
                    (0..<8).map { a in
                        (Geometry.hourglassSign(mode, a) - CrackedHex.dot(shape, gradients[a])) / 8
                    })
            }
            self.gamma = gamma
            let centreJacobian = Geometry.jacobian(rest, at: .zero)
            let e0 = centreJacobian.column(0) / CrackedHex.length(centreJacobian.column(0))
            var e1 = centreJacobian.column(1) - CrackedHex.dot(centreJacobian.column(1), e0) * e0
            e1 /= CrackedHex.length(e1)
            let e2 = CrackedHex.cross(e0, e1)
            let frame = CrackedHexMatrix(columns: e0, e1, e2)
            self.frame = frame
            let localInverse = (frame.transpose * centreJacobian).inverse
            self.localInverse = localInverse
            func operatorAt(_ p: SIMD3<Double>, filtered: Bool) -> [[Double]] {
                Geometry.strainOperator(
                    at: p, filtered: filtered, gradients: gradients, gamma: gamma, frame: frame,
                    localInverse: localInverse)
            }
            centre = operatorAt(.zero, filtered: true)
            assumed = (0..<8).map { operatorAt(CrackedHex.gaussPoint($0), filtered: true) }
            full = (0..<8).map { operatorAt(CrackedHex.gaussPoint($0), filtered: false) }
        }

        /// The assumed-strain operator at any natural point (for bars at their own depth).
        public func assumedOperator(at p: SIMD3<Double>) -> [[Double]] {
            Geometry.strainOperator(
                at: p, filtered: true, gradients: gradients, gamma: gamma, frame: frame,
                localInverse: localInverse)
        }

        /// The strain operator is linear: built column by column from unit displacements.
        static func strainOperator(
            at p: SIMD3<Double>, filtered: Bool, gradients: [SIMD3<Double>], gamma: [[Double]],
            frame: CrackedHexMatrix, localInverse: CrackedHexMatrix
        ) -> [[Double]] {
            var b = Array(repeating: Array(repeating: 0.0, count: 24), count: 6)
            for column in 0..<24 {
                var u = Array(repeating: SIMD3<Double>.zero, count: 8)
                u[column / 3][column % 3] = 1
                let strain = Geometry.strain(
                    u, at: p, filtered: filtered, gradients: gradients, gamma: gamma, frame: frame,
                    localInverse: localInverse)
                for v in 0..<6 { b[v][column] = strain[v] }
            }
            return b
        }

        /// The rest frame's unit vector along local axis `axis`.
        public func axis(_ axis: Int) -> SIMD3<Double> { frame.column(axis) }

        /// The element's length along local axis `axis`, through its centre.
        public func length(along axis: Int) -> Double {
            let jacobian = Geometry.jacobian(rest, at: .zero)
            return 2 * CrackedHex.length(jacobian.column(axis))
        }

        /// The hourglass amplitudes q_α = Σ_a γ_αa u_a.
        func hourglassAmplitudes(_ u: [Double]) -> [SIMD3<Double>] {
            (0..<4).map { mode in
                var q = SIMD3<Double>.zero
                for a in 0..<8 { q += gamma[mode][a] * SIMD3(u[3 * a], u[3 * a + 1], u[3 * a + 2]) }
                return q
            }
        }

        // ∂N_a/∂ξ at natural point p.
        static func naturalGradient(_ a: Int, at p: SIMD3<Double>) -> SIMD3<Double> {
            let s = CrackedHex.corner(a)
            let f = 1 + s * p
            return SIMD3(s.x * f.y * f.z, s.y * f.x * f.z, s.z * f.x * f.y) / 8
        }

        // J_ik = ∂X_i/∂ξ_k.
        static func jacobian(_ rest: [SIMD3<Double>], at p: SIMD3<Double>) -> CrackedHexMatrix {
            var columns = [SIMD3<Double>](repeating: .zero, count: 3)
            for a in 0..<8 {
                let g = naturalGradient(a, at: p)
                for k in 0..<3 { columns[k] += rest[a] * g[k] }
            }
            return CrackedHexMatrix(columns: columns[0], columns[1], columns[2])
        }

        /// h_αa: ηζ, ξζ, ξη and ξηζ at corner a.
        static func hourglassSign(_ mode: Int, _ a: Int) -> Double {
            let s = CrackedHex.corner(a)
            switch mode {
            case 0: return s.y * s.z
            case 1: return s.x * s.z
            case 2: return s.x * s.y
            default: return s.x * s.y * s.z
            }
        }

        /// The variables (bit 0 ξ, bit 1 η, bit 2 ζ) of ∂H_α/∂ξ_m, or nil where it is zero; each
        /// mode H_α (ηζ, ξζ, ξη, ξηζ) is a product of distinct variables.
        static func derivativeVariables(_ mode: Int, _ m: Int) -> Int? {
            let variables = [0b110, 0b101, 0b011, 0b111][mode]
            return variables & (1 << m) == 0 ? nil : variables & ~(1 << m)
        }

        static func monomial(_ variables: Int, at p: SIMD3<Double>) -> Double {
            var value = 1.0
            for k in 0..<3 where variables & (1 << k) != 0 { value *= p[k] }
            return value
        }

        /// The small strain at natural point p: the mean gradient's, plus each hourglass mode's
        /// gradient in the corotational frame. Filtered, the shear term ∂u_i/∂x_k (i ≠ k) keeps
        /// only the parts of the mode's derivative that do not vary along ξ_i: those that do are
        /// the parasitic shear of a fibre along i bending.
        static func strain(
            _ u: [SIMD3<Double>], at p: SIMD3<Double>, filtered: Bool, gradients: [SIMD3<Double>],
            gamma: [[Double]], frame: CrackedHexMatrix, localInverse: CrackedHexMatrix
        ) -> [Double] {
            var g = CrackedHexMatrix.zero
            for a in 0..<8 {
                for i in 0..<3 {
                    for j in 0..<3 { g[i, j] += u[a][i] * gradients[a][j] }
                }
            }
            var local = CrackedHexMatrix.zero
            for mode in 0..<4 {
                var q = SIMD3<Double>.zero
                for a in 0..<8 { q += gamma[mode][a] * u[a] }
                let ql = frame.transpose * q
                for i in 0..<3 {
                    for k in 0..<3 {
                        var d = 0.0
                        for m in 0..<3 {
                            guard let variables = derivativeVariables(mode, m) else { continue }
                            if filtered && i != k && variables & (1 << i) != 0 { continue }
                            d += localInverse[m, k] * monomial(variables, at: p)
                        }
                        local[i, k] += ql[i] * d
                    }
                }
            }
            g = g + frame * local * frame.transpose
            return [g[0, 0], g[1, 1], g[2, 2], g[0, 1] + g[1, 0], g[1, 2] + g[2, 1], g[2, 0] + g[0, 2]]
        }
    }
}

// MARK: - Materials

extension CrackedHex {
    /// Concrete for the reference: each lattice axis's normal stress follows its own normal strain
    /// (Poisson's ratio 0), with a crack across that axis once it passes the cracking strain.
    /// Tension softens linearly to zero at 2 G_f / (f_t h), h the crack band; compression is
    /// Hognestad's parabola to f_c at 2 f_c / E, then a straight fall of 15% by `crushingStrain`,
    /// floored at a fifth. Both unload along the secant to the origin. Shear is G γ, times
    /// `shearRetention` once either axis of the pair has cracked. This is not BombCAD's concrete
    /// model, which stage 2 would evaluate per point; it is the same law in the element and in
    /// the section analysis, so that they differ only in the element.
    public struct Concrete: Sendable, Equatable {
        public var youngsModulus: Double
        public var compressiveStrength: Double
        public var tensileStrength: Double
        public var fractureEnergy: Double
        public var bandWidth: Double
        public var crushingStrain: Double = 0.0038
        public var shearRetention: Double = 0.1

        public init(
            youngsModulus: Double, compressiveStrength: Double, tensileStrength: Double,
            fractureEnergy: Double, bandWidth: Double
        ) {
            self.youngsModulus = youngsModulus
            self.compressiveStrength = compressiveStrength
            self.tensileStrength = tensileStrength
            self.fractureEnergy = fractureEnergy
            self.bandWidth = bandWidth
        }

        public var strainAtPeak: Double { 2 * compressiveStrength / youngsModulus }
        public var crackingStrain: Double { tensileStrength / youngsModulus }
        /// Where tension has softened to nothing; never steeper than a snap-back.
        public var ultimateTensileStrain: Double {
            max(2 * fractureEnergy / (tensileStrength * bandWidth), 1.01 * crackingStrain)
        }
        /// The point leaves the elastic range past this compressive strain (the parabola's secant
        /// has fallen 5% there).
        public var compressiveElasticLimit: Double { 0.1 * strainAtPeak }

        /// Tension envelope and its slope at strain e ≥ 0.
        public func tension(_ e: Double) -> (stress: Double, slope: Double) {
            let cracking = crackingStrain
            if e <= cracking { return (youngsModulus * e, youngsModulus) }
            let ultimate = ultimateTensileStrain
            if e >= ultimate { return (0, 0) }
            let slope = -tensileStrength / (ultimate - cracking)
            return (tensileStrength + slope * (e - cracking), slope)
        }

        /// Compression envelope (magnitudes) and its slope at shortening e ≥ 0.
        public func compression(_ e: Double) -> (stress: Double, slope: Double) {
            let peak = strainAtPeak
            let fc = compressiveStrength
            if e <= peak {
                let r = e / peak
                return (fc * (2 * r - r * r), fc * (2 - 2 * r) / peak)
            }
            let slope = -0.15 * fc / (crushingStrain - peak)
            let stress = fc + slope * (e - peak)
            return stress > 0.2 * fc ? (stress, slope) : (0.2 * fc, 0)
        }

        /// Normal stress and tangent for strain e, from the largest tension and shortening so far,
        /// which it updates.
        public func normal(_ e: Double, tension most: inout Double, compression deepest: inout Double)
            -> (stress: Double, tangent: Double)
        {
            if e >= 0 {
                if e >= most {
                    most = e
                    let (s, slope) = tension(e)
                    return (s, slope)
                }
                if most <= crackingStrain { return (youngsModulus * e, youngsModulus) }
                let secant = tension(most).stress / most
                return (secant * e, secant)
            }
            let m = -e
            if m >= deepest {
                deepest = m
                let (s, slope) = compression(m)
                return (-s, slope)
            }
            if deepest <= 0 { return (youngsModulus * e, youngsModulus) }
            let secant = compression(deepest).stress / deepest
            return (secant * e, secant)
        }
    }

    /// Bars: elastic–plastic with linear kinematic hardening, its tangent `hardening` × E past yield.
    public struct Steel: Sendable, Equatable {
        public var youngsModulus: Double = 200e9
        public var yieldStress: Double
        public var hardening: Double = 0.01

        public init(yieldStress: Double, hardening: Double = 0.01) {
            self.yieldStress = yieldStress
            self.hardening = hardening
        }

        public struct State: Sendable, Equatable {
            public var plastic = 0.0
            public var back = 0.0
            public init() {}
        }

        public func stress(_ e: Double, state: inout State) -> (stress: Double, tangent: Double) {
            let h = hardening * youngsModulus / (1 - hardening)
            let trial = youngsModulus * (e - state.plastic)
            let relative = trial - state.back
            let excess = abs(relative) - yieldStress
            if excess <= 0 { return (trial, youngsModulus) }
            let sign: Double = relative > 0 ? 1 : -1
            let slip = excess / (youngsModulus + h)
            state.plastic += sign * slip
            state.back += sign * h * slip
            return (trial - sign * youngsModulus * slip, youngsModulus * h / (youngsModulus + h))
        }
    }

    public enum Law: Sendable, Equatable {
        case elastic(youngsModulus: Double, poissonRatio: Double)
        case concrete(Concrete)

        public var youngsModulus: Double {
            switch self {
            case .elastic(let e, _): return e
            case .concrete(let c): return c.youngsModulus
            }
        }
    }

    /// A point's history: per lattice axis, its largest tension and shortening so far.
    public struct PointHistory: Sendable, Equatable {
        public var tension = SIMD3<Double>.zero
        public var compression = SIMD3<Double>.zero
        public init() {}

        public func cracked(_ concrete: Concrete) -> Bool {
            tension.max() > concrete.crackingStrain
        }
    }

    /// Stress (Voigt) and a diagonal or full tangent (row-major 6 × 6) at one point.
    static func evaluate(_ law: Law, strain: [Double], state: inout PointHistory) -> (
        stress: [Double], tangent: [Double]
    ) {
        var tangent = Array(repeating: 0.0, count: 36)
        switch law {
        case .elastic(let e, let nu):
            let lambda = e * nu / ((1 + nu) * (1 - 2 * nu))
            let mu = e / (2 * (1 + nu))
            for i in 0..<3 {
                for j in 0..<3 { tangent[6 * i + j] = lambda + (i == j ? 2 * mu : 0) }
                tangent[6 * (i + 3) + i + 3] = mu
            }
            var stress = Array(repeating: 0.0, count: 6)
            for i in 0..<6 {
                for j in 0..<6 { stress[i] += tangent[6 * i + j] * strain[j] }
            }
            return (stress, tangent)
        case .concrete(let c):
            var stress = Array(repeating: 0.0, count: 6)
            for i in 0..<3 {
                let (s, t) = c.normal(
                    strain[i], tension: &state.tension[i], compression: &state.compression[i])
                stress[i] = s
                tangent[7 * i] = t
            }
            let g = c.youngsModulus / 2
            for (v, pair) in [(3, (0, 1)), (4, (1, 2)), (5, (2, 0))] {
                let open =
                    state.tension[pair.0] > c.crackingStrain || state.tension[pair.1] > c.crackingStrain
                let modulus = open ? g * c.shearRetention : g
                stress[v] = modulus * strain[v]
                tangent[7 * v] = modulus
            }
            return (stress, tangent)
        }
    }

    /// Whether a strain would take a point out of the elastic range.
    static func leavesElasticRange(_ law: Law, strain: [Double]) -> Bool {
        guard case .concrete(let c) = law else { return false }
        for i in 0..<3 where strain[i] > c.crackingStrain || -strain[i] > c.compressiveElasticLimit {
            return true
        }
        return false
    }
}
