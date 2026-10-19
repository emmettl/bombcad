import Foundation
import simd

/// Nassr's steel beams and columns in the open (A. A. Nassr, PhD thesis, McMaster University, 2012,
/// open; also Nassr, Razaqpur, Tait, Campidelli and Foo, *J. Struct. Eng.* 2012 and *IJIE* 2013):
/// wide-flange members 2,413 mm long, pinned at the top and on a roller at the foot, in a frame
/// walled in so that the blast reflects off them evenly, 50–250 kg of ANFO at 7–10.3 m. Beams carried
/// no axial load; columns 25% of their capacity, by strands anchored at the ends' middles. Here each
/// member is the shell solver's line of beams, the section a rectangle of the steel scaled to its
/// bending stiffness, plastic moment and mass about the axis bent (`SteelSection.equivalent`),
/// loaded by the shot's mean reflected pressure (Table 2.5, the gauges that recorded) as a triangle
/// of that peak and impulse over the width it faces, the column's axial load by a head mass under
/// gravity raised before the blast.
public enum NassrSteelTest {
    public enum Axis: String, Sendable {
        case strong = "x-x"
        case weak = "y-y"
    }

    public struct Shot: Sendable {
        public var number: Int
        public var section: String
        public var axis: Axis
        /// Mean reflected peak (Pa) and impulse (Pa s) of the gauges that recorded.
        public var pressure: Float
        public var impulse: Float
        /// The width loaded (m): the flange, the depth for the weak axis, or shot 5's curtain.
        public var width: Float
        /// Mass moving with the member besides its own (kg): shot 5's curtain, three times the beam's.
        public var addedMass: Float
        /// Column's axial load (N).
        public var axialLoad: Float
        /// Measured largest mid-span deflections (m), beam and column, and the column's permanent one.
        public var beam: Float?
        public var column: Float?
        public var columnPermanent: Float?
    }

    /// Tables 2.1, 2.5, 2.6, 4.1 and 4.2.
    public static let shots: [Shot] = [
        Shot(
            number: 1, section: "W150X24", axis: .strong, pressure: 307e3, impulse: 715, width: 0.102,
            addedMass: 0, axialLoad: 270e3, beam: 0.0069, column: 0.0053, columnPermanent: 0),
        Shot(
            number: 2, section: "W150X24", axis: .weak, pressure: 623e3, impulse: 1279, width: 0.160,
            addedMass: 0, axialLoad: 270e3, beam: 0.0408, column: 0.0561, columnPermanent: 0.0298),
        Shot(
            number: 3, section: "W150X24", axis: .strong, pressure: 1560e3, impulse: 2128, width: 0.102,
            addedMass: 0, axialLoad: 270e3, beam: 0.0332, column: 0.0309, columnPermanent: 0),
        Shot(
            number: 4, section: "W150X24", axis: .strong, pressure: 4283e3, impulse: 3174, width: 0.102,
            addedMass: 0, axialLoad: 270e3, beam: nil, column: 0.107, columnPermanent: 0.0602),
        Shot(
            number: 5, section: "W200X71", axis: .strong, pressure: 2098e3, impulse: 3144, width: 1.18,
            addedMass: 3 * 71 * span, axialLoad: 640e3, beam: 0.0628, column: 0.071, columnPermanent: 0.0328),
    ]

    public static let span: Float = 2.413

    /// The sections from their nominal dimensions (CISC), flanges and web as rectangles (no
    /// fillets: 1–4% below the tables), and their mill yield (393 and 362 MPa).
    public static func section(_ name: String, axis: Axis) -> (SteelSection, yield: Float, kgPerM: Float) {
        let (d, b, t, w): (Float, Float, Float, Float) =
            name == "W150X24" ? (0.160, 0.102, 0.0103, 0.0066) : (0.216, 0.206, 0.0174, 0.0102)
        let web = d - 2 * t
        let area = 2 * b * t + web * w
        let strong = SteelSection(
            name: name, depth: d, width: b, area: area,
            secondMoment: (b * d * d * d - (b - w) * web * web * web) / 12,
            plasticModulus: b * t * (d - t) + w * web * web / 4)
        let weak = SteelSection(
            name: name + " weak axis", depth: b, width: d, area: area,
            secondMoment: 2 * t * b * b * b / 12 + web * w * w * w / 12,
            plasticModulus: 2 * t * b * b / 4 + web * w * w / 4)
        return (axis == .strong ? strong : weak, name == "W150X24" ? 393e6 : 362e6, 7850 * area)
    }

    public struct Result: Sendable {
        public var shot: Int
        public var column: Bool
        /// Largest mid-span deflection (m) and the deflection left at the end (m).
        public var peak: Float
        public var final: Float
        public var measured: Float?

        /// The memberwise initialiser, written out so that BlastCore can use it.
        package init(
            shot: Int,
            column: Bool,
            peak: Float,
            final: Float,
            measured: Float? = nil
        ) {
            self.shot = shot
            self.column = column
            self.peak = peak
            self.final = final
            self.measured = measured
        }
    }
}
