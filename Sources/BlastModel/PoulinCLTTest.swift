import Foundation
import simd

/// Cross-laminated timber panels in the University of Ottawa's shock tube: M. M. Poulin, MASc
/// thesis, University of Ottawa, 2019 (open), and Poulin, Viau, Lacroix and Doudak, J. Struct.
/// Eng. 144(2), 2018.
///
/// Eighteen Nordic panels, grade E1 of ANSI/APA PRG 320 (35 mm lamellae, 1950f-1.7E machine
/// stress-rated spruce-pine-fir along the panel), 3-ply (105 mm) and 5-ply (175 mm), 445 mm wide,
/// simply supported over 2,235 mm. A hinged steel load-transfer device collected the shock tube's
/// pressure over an equivalent 3.55 m^2 and pressed it onto the panel as two line loads at the
/// third points, as in the static four-point bending tests; with the device, the moving mass was
/// 342.1 kg (3-ply) and 384.5 kg (5-ply). The thesis tabulates every shot's reflected pressure and
/// impulse, the peak mid-span deflection and the failure mode (its Table 4.3), and the static
/// tests' resistance and stiffness (Table 4.1).
///
/// The model: the panel as layered timber shells, one lamella crossed in two (or two in three),
/// on lines held still through the thickness at the supports; the device's force, P(t) x 3.55
/// m^2, shared between strips one element wide under the load lines; and its mass, what the
/// moving mass leaves after the panel's clear span, split between the load lines' nodes. Each
/// shot's pressure is a triangle of its measured peak and impulse (the thesis plots, but does
/// not tabulate, the histories; the positive phase was 5 to 70 ms).
public enum PoulinCLTTest {
    public struct Shot: Sendable {
        public var name: String
        public var plies: Int
        /// Reflected peak (Pa) and impulse (Pa s).
        public var pressure: Float
        public var impulse: Float
        /// Measured peak mid-span deflection (m) and failure mode.
        public var deflection: Float
        public var mode: String
    }

    /// Poulin's Table 4.3.
    public static let shots: [Shot] = [
        Shot(name: "CLT3-4.1", plies: 3, pressure: 11.6e3, impulse: 90, deflection: 0.0161, mode: "elastic"),
        Shot(
            name: "CLT3-4.2", plies: 3, pressure: 38.7e3, impulse: 379, deflection: 0.1052,
            mode: "rolling shear"),
        Shot(name: "CLT3-5.1", plies: 3, pressure: 48.2e3, impulse: 442, deflection: 0.0886, mode: "flexure"),
        Shot(name: "CLT3-6.1", plies: 3, pressure: 52.6e3, impulse: 614, deflection: 0.1437, mode: "flexure"),
        Shot(name: "CLT3-7.1", plies: 3, pressure: 6.5e3, impulse: 79, deflection: 0.0118, mode: "elastic"),
        Shot(
            name: "CLT3-7.2", plies: 3, pressure: 52.8e3, impulse: 440, deflection: 0.1192,
            mode: "rolling shear"),
        Shot(name: "CLT3-8.1", plies: 3, pressure: 5.8e3, impulse: 59, deflection: 0.0101, mode: "elastic"),
        Shot(
            name: "CLT3-8.2", plies: 3, pressure: 49.0e3, impulse: 468, deflection: 0.0895,
            mode: "rolling shear, then flexure"),
        Shot(name: "CLT3-9.1", plies: 3, pressure: 12.2e3, impulse: 131, deflection: 0.0187, mode: "elastic"),
        Shot(
            name: "CLT3-9.2", plies: 3, pressure: 30.9e3, impulse: 322, deflection: 0.0584,
            mode: "rolling shear"),
        Shot(name: "CLT3-10.1", plies: 3, pressure: 9.1e3, impulse: 93, deflection: 0.0123, mode: "elastic"),
        Shot(
            name: "CLT3-10.2", plies: 3, pressure: 34.0e3, impulse: 374, deflection: 0.0994, mode: "flexure"),
        Shot(name: "CLT3-11.1", plies: 3, pressure: 9.2e3, impulse: 107, deflection: 0.0117, mode: "elastic"),
        Shot(
            name: "CLT3-11.2", plies: 3, pressure: 32.9e3, impulse: 345, deflection: 0.0725, mode: "flexure"),
        Shot(name: "CLT5-4.1", plies: 5, pressure: 53.7e3, impulse: 610, deflection: 0.0807, mode: "flexure"),
        Shot(
            name: "CLT5-5.1", plies: 5, pressure: 58.6e3, impulse: 691, deflection: 0.0582,
            mode: "rolling shear"),
        Shot(name: "CLT5-6.1", plies: 5, pressure: 7.2e3, impulse: 82, deflection: 0.0065, mode: "elastic"),
        Shot(name: "CLT5-6.2", plies: 5, pressure: 55.8e3, impulse: 602, deflection: 0.0779, mode: "flexure"),
        Shot(name: "CLT5-7.1", plies: 5, pressure: 7.3e3, impulse: 82, deflection: 0.0064, mode: "elastic"),
        Shot(name: "CLT5-7.2", plies: 5, pressure: 51.2e3, impulse: 481, deflection: 0.0370, mode: "flexure"),
    ]

    /// Poulin's Table 4.1: the static tests' peak total load (N), the mid-span deflection there
    /// (m) and the stiffness (N/m), for 3 and 5 plies.
    public static func staticMeasured(plies: Int) -> (load: Float, deflection: Float, stiffness: Float) {
        plies == 3 ? (68.4e3, 0.0347, 2.1e6) : (128.6e3, 0.0236, 5.9e6)
    }

    /// The outer lamella's stress at the static tests' peak (Table 4.1), by layered beam theory
    /// with E1's moduli (11.7 GPa along, 390 MPa across): M z E / EI, with M = (R/2) (L/3) / b.
    public static func staticRupture(plies: Int) -> Float {
        let e: Float = 11.7e9
        let t: Float = 0.035
        let depth = t * Float(plies)
        var stiffness: Float = 0
        for l in 0..<plies {
            let centre = (Float(l) + 0.5) * t - depth / 2
            let modulus = l % 2 == 0 ? e : e / 30
            stiffness += modulus * (t * t * t / 12 + t * centre * centre)
        }
        let moment = staticMeasured(plies: plies).load / 2 * (span / 3) / width
        return moment * (depth / 2) * e / stiffness
    }

    public static let span: Float = 2.235
    public static let width: Float = 0.445
    public static let loadedArea: Float = 3.55
    public static func movingMass(plies: Int) -> Float { plies == 3 ? 342.1 : 384.5 }

    /// Grade E1's lamellae (PRG 320-2019, Tables A1 and A3: E 11,700 MPa along the panel and the
    /// Canadian specified compressive strength along it, 19.3 MPa), the fibres breaking at the
    /// static tests' outer-lamella stress (`staticRupture`), the
    /// other moduli by its Annex X3 (E90 = E/30, G = E/16, G_R = G/10), raised to their means with
    /// the JCSS model's coefficients of variation as `TimberProperties.strengthClass` does; across
    /// the grain, in shear along it and in rolling shear, C24's (PRG 320's specified rolling
    /// strength, 0.50 MPa, is a design value; raised to a mean by the same rule it is 0.77 MPa,
    /// below every mean the literature gives, 1.0 to 1.9). `rate` is the strengths' dynamic
    /// increase factor.
    public static func material(plies: Int, rate: Float, rollingScale: Float = 1) -> StructureMaterial {
        let e: Float = 11.7e9
        var properties = TimberProperties(
            alongGrain: e, acrossGrain: e / 30, shearModulus: e / 16,
            rollingShearModulus: rollingScale * e / 160,
            lamellae: TimberProperties.crossLaminated(plies))
        let c24 = TimberProperties.strengthClass(.c24)
        // Calibrated on the static tests: the outer lamella's stress at their peak.
        properties.tensionAlong = staticRupture(plies: plies)
        properties.compressionAlong = 19.3e6 * TimberProperties.lognormalMean(cov: 0.2)
        properties.rollingStrength = c24.rollingStrength
        properties.tensionAcross = c24.tensionAcross
        properties.compressionAcross = c24.compressionAcross
        properties.shearStrength = c24.shearStrength
        properties.strengthFactor = rate
        return .timber(name: "E1 CLT \(plies)-ply", density: 450, properties: properties)
    }

    public struct Result: Sendable {
        /// Peak mid-span deflection (m), and when (s).
        public var deflection: Float
        public var time: Float
        /// The largest damage each mode reached anywhere: fibre, splitting and rolling shear.
        public var fibre: Float
        public var splitting: Float
        public var rolling: Float
        public var removed: Int
        /// The first mode to break through a layer (damage 1), and when (s; for a static push,
        /// the load in N); nil if none did.
        public var firstMode: String?
        public var firstAt: Float = 0
        /// For a static push: the total load (N) against mid-span deflection (m).
        public var curve: [SIMD2<Float>] = []

        /// The memberwise initialiser, written out so that BlastCore can use it.
        package init(
            deflection: Float,
            time: Float,
            fibre: Float,
            splitting: Float,
            rolling: Float,
            removed: Int,
            firstMode: String? = nil,
            firstAt: Float = 0,
            curve: [SIMD2<Float>] = []
        ) {
            self.deflection = deflection
            self.time = time
            self.fibre = fibre
            self.splitting = splitting
            self.rolling = rolling
            self.removed = removed
            self.firstMode = firstMode
            self.firstAt = firstAt
            self.curve = curve
        }
    }
}
