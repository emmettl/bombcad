import Foundation
import simd

/// NIST's steel moment-frame assemblies under a column's removal (F. Sadek, J. A. Main, H. S. Lew,
/// S. D. Robert, V. P. Chiarito and S. El-Tawil, *An experimental and computational study of steel
/// moment connections under a column removal scenario*, NIST TN 1669, 2010, open): two spans of 6.10
/// m between three columns, the middle one a stub pushed down until the connections at it fractured.
/// - WUF-B: W21×73 beams welded to W18×119 columns; failed at 495 mm, 890 kN, a chord rotation of
///   0.081 rad, the beams pulling 667 kN.
/// - RBS: W24×94 beams with reduced sections to W24×131 columns; failed at 851 mm, 1,780 kN,
///   0.14 rad, the beams pulling 2,447 kN.
/// And a gravity frame's simple connection, from J. M. Weigand and J. W. Berman, *Steel gravity
/// connections subjected to large rotations and axial loads* (Connections VIII, 2016, open, NIST):
/// - SPS: W18×35 beams on single-plate shear connections (three 19 mm bolts, 9.5 mm plate) to
///   W14×90 columns, two simulated spans of 9.1 m. The test loaded one connection as such a system
///   would, its beams taken as rigid; the eight three-bolt connections on that span failed at a
///   median drop of 892 mm (772–972), at a median turn of 0.0905 rad, pull of 431 kN and shear at
///   the column face of 40 kN, so the stub's load about 2 (T sin θ + V cos θ) = 157 kN. The
///   steels' yields were not read; A992's nominal 345 and 450 MPa are taken.
/// Here the members are the shell solver's beams, rectangles scaled to each section's major-axis
/// stiffness, plastic moment and mass (`SteelSection.equivalent`), at the measured yields (Table
/// 3–1) without a strain-rate law, the test being slow. The end columns are taken one storey high
/// (4.19 m, the buildings' 13 ft 9 in), the beams at mid-height, fixed at the foot and held sideways
/// at the top as the test's braces held them (the figure giving their height was not read); out of
/// plane everything is held, as the beams were braced at mid-span. The stub is pushed down at
/// `speed`; the joints are rigid, or hinged by `connection`.
public enum ColumnRemovalTest {
    public enum Specimen: String, Sendable, CaseIterable {
        case weldedFlange = "WUF-B"
        case reducedBeamSection = "RBS"
        case singlePlateShear = "SPS"

        /// The connection the specimen was built with.
        public var connection: SteelConnection {
            switch self {
            case .weldedFlange: .weldedFlange
            case .reducedBeamSection: .reducedBeamSection
            case .singlePlateShear: .singlePlateShear
            }
        }

        /// Each span between columns, m.
        package var span: Float { self == .singlePlateShear ? 9.1 : 6.10 }
    }

    public struct Result: Sendable {
        /// Largest load (N) and the stub's drop then (m); the drop at which the load fell to half
        /// its largest after it, if it did (the assembly failed).
        public var peakLoad: Float
        public var dropAtPeak: Float
        public var failedAt: Float?
        public var hingesReleased: Int
        public var curve: [SIMD2<Float>]

        /// The memberwise initialiser, written out so that BlastCore can use it.
        package init(
            peakLoad: Float,
            dropAtPeak: Float,
            failedAt: Float? = nil,
            hingesReleased: Int,
            curve: [SIMD2<Float>]
        ) {
            self.peakLoad = peakLoad
            self.dropAtPeak = dropAtPeak
            self.failedAt = failedAt
            self.hingesReleased = hingesReleased
            self.curve = curve
        }
    }

    /// The beams' and columns' sections (AISC's tables), their steels' measured yield and ultimate
    /// (Pa), and what the test measured: failure drop (m) and load (N).
    package static func specimen(_ s: Specimen) -> (
        beam: SteelSection, column: SteelSection, beamSteel: SIMD2<Float>, columnSteel: SIMD2<Float>,
        measured: (drop: Float, load: Float)
    ) {
        let inch: Float = 0.0254
        func section(_ name: String, d: Float, bf: Float, area: Float, ix: Float, zx: Float) -> SteelSection {
            SteelSection(
                name: name, depth: d * inch, width: bf * inch, area: area * inch * inch,
                secondMoment: ix * pow(inch, 4), plasticModulus: zx * pow(inch, 3))
        }
        switch s {
        case .weldedFlange:
            return (
                section("W21×73", d: 21.2, bf: 8.30, area: 21.6, ix: 1600, zx: 172),
                section("W18×119", d: 19.0, bf: 11.3, area: 35.1, ix: 2190, zx: 262),
                SIMD2(359e6, 496e6), SIMD2(352e6, 456e6), (0.495, 890e3)
            )
        case .reducedBeamSection:
            return (
                section("W24×94", d: 24.3, bf: 9.07, area: 27.7, ix: 2700, zx: 254),
                section("W24×131", d: 24.5, bf: 12.9, area: 38.5, ix: 4020, zx: 370),
                SIMD2(455e6, 554e6), SIMD2(378e6, 494e6), (0.851, 1780e3)
            )
        case .singlePlateShear:
            return (
                section("W18×35", d: 17.7, bf: 6.00, area: 10.3, ix: 510, zx: 66.5),
                section("W14×90", d: 14.0, bf: 14.5, area: 26.5, ix: 999, zx: 157),
                SIMD2(345e6, 450e6), SIMD2(345e6, 450e6), (0.892, 157e3)
            )
        }
    }

    public static func measured(_ s: Specimen) -> (drop: Float, load: Float) { specimen(s).measured }
}
