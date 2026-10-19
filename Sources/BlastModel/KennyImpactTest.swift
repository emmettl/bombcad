import Foundation
import simd

/// Kenny's drop-hammer tests on slender strips (D. Kenny, *Dynamic pulse buckling of slender beams
/// with geometric imperfections subjected to an axial impact*, PhD thesis, Dalhousie, 2001,
/// hdl:10222/55746; a scan, read from its pages): a 10 kg hammer dropped at about 6.2 m/s onto
/// strips 50.8 mm wide standing upright, clamped at the foot over 75 mm, held at the head by a
/// lubricated slide bearing that stops it moving or turning sideways but lets it shorten. The
/// strips buckled plastically, their largest buckle near the clamped foot; Table 6-4 gives each
/// series' mean final deflection of that buckle and how far up it lay, Table 6-6 the materials as
/// bilinear laws. Strips that buckled at the head, where the bearing had lifted out of its collar,
/// were set aside by Kenny; so are his series AIIe and AIIf here, the slenderest.
///
/// Here each strip is a line of the shell solver's beams, its weaker side the strip's thickness.
/// A strip 3.175 mm thick and 50.8 mm wide meshes as a plate, so it is drawn 6 mm wide, of a
/// material stiffer, denser and stronger by 50.8 / 6: its axial stiffness and mass, its bending
/// about its weak axis, its plastic moment and both its wave speeds are the strip's. The hammer
/// drives the head at its own speed, slowed by the strip's push, until the strip stops pushing and
/// they part. Bowed by Eurocode 3's rule for the length (curve c, a solid section's) or, with
/// `measuredBow`, to Kenny's mean measured initial imperfection β = A₀ / L.
public enum KennyImpactTest {
    public struct Series: Sendable {
        public var name: String
        public var steel: Bool
        /// Thickness (m) and unsupported length (m).
        public var thickness: Float
        public var length: Float
        public var speed: Float
        /// Mean initial imperfection over the length.
        public var beta: Float
        /// Measured: mean final deflection of the peak buckle and its height above the clamp (m).
        public var deflection: Float
        public var position: Float

        /// The memberwise initialiser, written out so that BlastCore can use it.
        package init(
            name: String,
            steel: Bool,
            thickness: Float,
            length: Float,
            speed: Float,
            beta: Float,
            deflection: Float,
            position: Float
        ) {
            self.name = name
            self.steel = steel
            self.thickness = thickness
            self.length = length
            self.speed = speed
            self.beta = beta
            self.deflection = deflection
            self.position = position
        }
    }

    /// Table 6-1 to 6-4: steel CR1018 (SI) and aluminium 6061-T6 (AI, 3.175 mm; AII, 4.7625 mm).
    public static let series: [Series] = {
        let t1: Float = 0.003175
        let t2: Float = 0.0047625
        func s(
            _ n: String, _ steel: Bool, _ t: Float, _ l: Float, _ v: Float, _ b: Float, _ w: Float, _ x: Float
        )
            -> Series
        {
            Series(
                name: n, steel: steel, thickness: t, length: l / 1000, speed: v, beta: b,
                deflection: w / 1000,
                position: x / 1000)
        }
        return [
            s("SIa", true, t1, 137, 6.22, 0.0027, 10.8, 54.2),
            s("SIb", true, t1, 183, 6.22, 0.0017, 12.7, 52.5),
            s("SIc", true, t1, 275, 6.24, 0.0020, 8.0, 63.7),
            s("SId", true, t1, 367, 6.14, 0.0021, 7.3, 130.0),
            s("SIe", true, t1, 458, 6.31, 0.0023, 5.4, 92.6),
            s("SIf", true, t1, 550, 6.18, 0.0025, 5.0, 125.6),
            s("AIa", false, t1, 137, 6.20, 0.0029, 14.1, 51.3),
            s("AIb", false, t1, 183, 6.20, 0.0023, 19.4, 57.8),
            s("AIc", false, t1, 275, 6.24, 0.0020, 21.3, 60.0),
            s("AId", false, t1, 367, 6.14, 0.0019, 18.3, 59.5),
            s("AIe", false, t1, 458, 6.19, 0.0021, 22.0, 68.8),
            s("AIf", false, t1, 550, 6.22, 0.0024, 20.8, 71.9),
            s("AIIa", false, t2, 206, 6.28, 0.0019, 17.6, 75.0),
            s("AIIb", false, t2, 275, 6.21, 0.0019, 18.0, 80.4),
            s("AIIc", false, t2, 412, 6.21, 0.0019, 17.6, 84.0),
            s("AIId", false, t2, 550, 6.23, 0.0020, 17.0, 97.5),
        ]
    }()

    public struct Result: Sendable {
        /// The largest final sideways deflection (m) and its height above the clamp (m).
        public var deflection: Float
        public var position: Float
        /// When the hammer stopped, and when it first left the strip (s).
        public var stopped: Float
        public var parted: Float

        /// The memberwise initialiser, written out so that BlastCore can use it.
        package init(
            deflection: Float,
            position: Float,
            stopped: Float,
            parted: Float
        ) {
            self.deflection = deflection
            self.position = position
            self.stopped = stopped
            self.parted = parted
        }
    }
}
