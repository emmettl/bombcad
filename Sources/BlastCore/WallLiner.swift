import Foundation

/// A spray-on elastomeric liner (polyurea) on the inside face of an unreinforced masonry wall,
/// lapped onto its supports: once the masonry cracks and rocks, the liner holds it and carries the
/// load as a membrane until it tears. The retrofit the US Air Force Research Laboratory developed
/// (Knox et al., 2000; Davidson et al., 2004); here judged against the open shock-tube tests at the
/// University of Ottawa (Ciornei, MASc, 2012; Ezekiel, PhD, 2025).
///
/// **The membrane** (Ciornei, thesis, §4.2.3.2, eqs. 4.23–4.32): the wall's middle deflects by Δ,
/// the liner over its span h takes the arc of a parabola, length L, and its stretch L − h is taken
/// up over a tenth of the span (where it has come away from the masonry at the cracks, as he
/// assumed): ε = (L − h) / (0.1 h). At its stress σ(ε), a liner t thick pulls on the supports at
/// θ = atan(4Δ/h), resisting p = 2 σ t sin θ / h. It tears at its strain at break, and the wall
/// is lost.
public struct WallLiner: Codable, Hashable, Sendable {
    /// m.
    public var thickness: Double
    /// Young's modulus, yield stress and strength (Pa), and strain at break.
    public var modulus: Double
    public var yieldStress: Double
    public var strength: Double
    public var breakStrain: Double

    /// The share of the span the liner's stretch is taken up over (Ciornei's assumption).
    public static let strainedShare = 0.1

    public init(
        thickness: Double, modulus: Double, yieldStress: Double, strength: Double, breakStrain: Double
    ) {
        self.thickness = thickness
        self.modulus = modulus
        self.yieldStress = yieldStress
        self.strength = strength
        self.breakStrain = breakStrain
    }

    /// Line-X polyurea `mm` thick, as Ciornei's: E 386 MPa, 14 MPa, 82% at break (the maker's,
    /// his Table 2.3), elastic until it reaches its strength.
    public static func polyurea(mm: Double) -> WallLiner {
        WallLiner(thickness: mm * 1e-3, modulus: 386e6, yieldStress: 14e6, strength: 14e6, breakStrain: 0.82)
    }

    /// The stress at strain `e`, Pa: elastic to the yield stress, then hardening linearly to the
    /// strength at break.
    public func stress(_ e: Double) -> Double {
        let yieldStrain = yieldStress / modulus
        if e <= yieldStrain { return modulus * max(e, 0) }
        guard breakStrain > yieldStrain else { return yieldStress }
        return yieldStress + (strength - yieldStress)
            * min((e - yieldStrain) / (breakStrain - yieldStrain), 1)
    }

    /// The liner's strain when the middle of a span `h` deflects by `x`.
    public func strain(deflection x: Double, span h: Double) -> Double {
        let d = abs(x)
        guard d > 0 else { return 0 }
        // A parabola's arc over its span h with sag d.
        let k = 4 * d / h
        let length = h / 2 * (1 + k * k).squareRoot() + h / (2 * k) * asinh(k)
        return (length - h) / (Self.strainedShare * h)
    }

    /// Its resistance at deflection `x` over span `h`, Pa.
    public func resistance(deflection x: Double, span h: Double) -> Double {
        let theta = atan(4 * abs(x) / h)
        return 2 * stress(strain(deflection: x, span: h)) * thickness * sin(theta) / h
    }

    /// The deflection at which it tears over span `h`, m.
    public func tearDeflection(span h: Double) -> Double {
        var low = 0.0
        var high = h
        for _ in 0..<60 {
            let mid = (low + high) / 2
            if strain(deflection: mid, span: h) < breakStrain { low = mid } else { high = mid }
        }
        return low
    }

    public func validate() throws {
        guard
            [thickness, modulus, yieldStress, strength, breakStrain].allSatisfy({ $0.isFinite && $0 > 0 }),
            strength >= yieldStress
        else {
            throw ImportedMesh.ImportError.invalid(
                "A wall liner's thickness and properties must be positive.")
        }
    }
}

extension SDOFSystem {
    /// The system with `liner` on it over `span`: its backbone the masonry's and the liner's
    /// membrane together, to where the liner tears, when the wall is lost. The liner's mass is
    /// added.
    public func lined(_ liner: WallLiner, span: Double, density: Double = 1100) -> SDOFSystem {
        var system = self
        let tear = liner.tearDeflection(span: span)
        let start = backbone[0].x
        var points: [SIMD2<Double>] = [
            SIMD2(start, envelope(start) + liner.resistance(deflection: start, span: span))
        ]
        let count = 80
        for n in 1...count {
            let x = start + (tear - start) * Double(n) / Double(count)
            points.append(SIMD2(x, envelope(x) + liner.resistance(deflection: x, span: span)))
        }
        points.append(SIMD2(tear * (1 + 1e-6), 0))
        system.backbone = points
        system.massPerArea += density * liner.thickness
        return system
    }
}
