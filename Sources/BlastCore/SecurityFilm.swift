import Foundation

/// Security (anti-shatter) film on a monolithic pane: a polyester (PET) sheet, 0.1–0.4 mm thick,
/// bonded to the pane's inner face. Once the glass cracks the film holds its fragments and carries
/// the load as a membrane, as a laminate's interlayer does (`LaminatedGlass`), until it tears or
/// leaves its frame; how it is held there (`Anchorage`) decides which.
public struct SecurityFilm: Codable, Hashable, Sendable {
    /// How the film is held at the pane's edges.
    public enum Anchorage: String, Codable, Hashable, Sendable, CaseIterable {
        /// Daylight: the film stops 1–3 mm short of the frame's beads (CPNI EBP 09/13), held by
        /// nothing there.
        case daylight
        /// Wet glazed: a structural silicone bead joins the film to the frame over half an inch
        /// (the 3M and ARA tests' beads, 13 mm on film and frame).
        case wetGlazed
        /// Mechanically attached: a batten or a gasketed profile screwed through the film into the
        /// frame.
        case mechanical

        public var label: String {
            switch self {
            case .daylight: "daylight (not anchored)"
            case .wetGlazed: "wet glazed (silicone bead)"
            case .mechanical: "mechanically attached"
            }
        }

        /// What the anchorage holds per metre of edge before the filmed sheet pulls out, N/m; nil
        /// for as much as the film carries.
        /// - Wet glazed: the film's tension. In the open tests 20 of 22 wet-glazed panes stayed in
        ///   their frames where their film had yielded (3M's and Solar Gard's GSA reports; the two
        ///   that did not, large panes, pulled out along one edge). Hooper's silicone joints for
        ///   laminated glass, 1.11 MPa at 0.1 m/s (thesis, §6.4, the strength he recommends designing
        ///   to), would hold 14 kN/m over the bead's 13 mm and let 6 and 8 mil film go; his joints
        ///   pulled at 4 m/s were 75% stronger.
        /// - Mechanical: 7.3 kN/m, the lower end of Madico's FrameGard, "tested to hold from 500 to
        ///   800 pounds per linear foot" (a vendor's claim; no test of it is open): less than 6 or
        ///   8 mil film carries at its yield, so such film pulls out once it yields. The open tests
        ///   are mixed: 3M's gasketed profile held small panes (8 of 12 graded 2) and lost large
        ///   ones (3 of 4 graded 5); a screwed batten held (ARA); a flexible profile let go round its
        ///   perimeter (Solar Gard).
        /// - Daylight: nothing at the edges (`releasesOnRebound`).
        public var capacity: Double? {
            switch self {
            case .daylight, .wetGlazed: nil
            case .mechanical: 500 * 4.448222 / 0.3048
            }
        }

        /// Daylight film's sheet stays while the blast pushes it in and goes once it moves back
        /// out: in 21 of the 22 open daylight tests it was not thrown into the room, but tore round
        /// its edges and fell or was drawn outward (3M's arena report E1298, "ejected to exterior";
        /// ARA's, "landed approximately 2 ft in front of structure").
        public var releasesOnRebound: Bool { self == .daylight }
    }

    /// m.
    public var thickness: Double
    public var anchorage: Anchorage
    /// Yield stress, Pa: 103 MPa, 3M Ultra S800's (product bulletin, 2021, ASTM D882), its
    /// polyester's.
    public var yieldStress: Double
    /// Strain at break: 135% (3M Ultra S800 technical data sheet, Rev G, 2025, ASTM D882; 140%
    /// along the roll in the bulletin).
    public var breakStrain: Double
    /// Young's modulus, Pa: 3.59 GPa (520 ksi, the data sheet); Mattei, Cozzarini and Bedon
    /// measured 3.31 GPa on another commercial film (*Symmetry* 14, 2022, 162).
    public var modulus: Double
    /// What the anchorage holds per metre of edge, N/m, where a product's tested value is known;
    /// nil for the anchorage's own (`Anchorage.capacity`).
    public var anchorageCapacity: Double?

    /// kg/m³: polyester's.
    public static let density = 1390.0

    public init(
        thickness: Double, anchorage: Anchorage, yieldStress: Double = 103e6, breakStrain: Double = 1.35,
        modulus: Double = 3.59e9, anchorageCapacity: Double? = nil
    ) {
        precondition(thickness > 0 && yieldStress > 0 && breakStrain > 0 && modulus > 0)
        self.thickness = thickness
        self.anchorage = anchorage
        self.yieldStress = yieldStress
        self.breakStrain = breakStrain
        self.modulus = modulus
        self.anchorageCapacity = anchorageCapacity
    }

    /// A film `mils` thousandths of an inch thick (as films are sold: 4, 7, 8, 14 mil).
    public static func mils(_ mils: Double, anchorage: Anchorage) -> SecurityFilm {
        SecurityFilm(thickness: mils * 25.4e-6, anchorage: anchorage)
    }

    /// The membrane's tension once the glass has cracked, N/m: the film at its yield. The
    /// polyester hardens beyond it, to 207–227 MPa at break (the bulletin); the membrane, as the
    /// laminate's, is held at one tension.
    public var tension: Double { yieldStress * thickness }

    /// Reject what the membrane cannot use, including values loaded from a document.
    public func validate() throws {
        guard
            [thickness, yieldStress, breakStrain, modulus, anchorageCapacity ?? 1].allSatisfy({
                $0.isFinite && $0 > 0
            })
        else {
            throw ImportedMesh.ImportError.invalid(
                "A security film's thickness and properties must be positive.")
        }
    }
}

extension EnvelopePanel {
    /// A monolithic pane a × b (m) of `thickness` (m), annealed or toughened, with security film
    /// on it: the bare pane on Moore's large-deflection plate and E1300's flaw model
    /// (`largeDeflectionGlass`), the film adding its mass, and once the glass cracks the film's
    /// membrane (`SDOFSystem.Membrane`):
    /// - at the film's yield tension (`SecurityFilm.tension`), reached as its average strain,
    ///   (8/3)(x/a)², reaches its yield strain;
    /// - torn when that average strain reaches its strain at break;
    /// - pulled out when the tension at its edges passes what its anchorage holds
    ///   (`SecurityFilm.Anchorage.capacity`), or for daylight film once it moves back out.
    ///
    /// Toughened glass breaks at four times the annealed pane's strength, E1300's glass type
    /// factor for fully tempered glass against annealed under a short load (ASTM E1300, Table 1).
    /// The film adds no stiffness before the glass cracks.
    public static func filmedGlass(
        _ film: SecurityFilm, thickness: Double, toughened: Bool, a: Double, b: Double,
        sixtySecondStrength: Double? = nil
    ) -> SDOFSystem {
        let short = min(a, b)
        let aspect = max(a, b) / short
        let strength =
            (sixtySecondStrength ?? GlassStrength.sixtySecond(area: a * b)) * (toughened ? 4 : 1)
        var system = largeDeflectionGlass(
            thickness: thickness, material: toughened ? .toughenedGlass : .annealedGlass, a: a, b: b,
            sixtySecondStrength: strength)
        system.massPerArea += SecurityFilm.density * film.thickness
        // Average strain (8/3)(x/a)² at the film's yield and at its break.
        let yieldRatio = (3 * film.yieldStress / film.modulus / 8).squareRoot()
        system.membrane = SDOFSystem.Membrane(
            tension: film.tension, shape: LaminatedGlass.membraneShape(aspect: aspect), span: short,
            tearRatio: (3 * film.breakStrain / 8).squareRoot(), plateauDeflection: yieldRatio * short,
            edgeCapacity: film.anchorageCapacity ?? film.anchorage.capacity,
            releasesOnRebound: film.anchorage.releasesOnRebound ? true : nil)
        return system
    }
}
