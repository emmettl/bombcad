import Foundation

/// How steel beams are joined to what they end on (`StructureModel.steelConnection`): a hinge at each
/// end of a steel beam that stops at another member, the beam's end its own node, held to the joint by
/// springs (`ShellMesh.Hinge`). The hinge is half as stiff as a length of the beam one element long
/// (stiffer, the beam's end node, which has only its share of that element's mass, would need a
/// shorter step), so it is rigid by EN 1993-1-8's measure (§5.2.2.5, S_j ≥ 25 EI / L) for a beam
/// over 12.5 elements long. It turns plastically past `momentRatio` of the beam's plastic moment, so the beam's
/// plastic hinge forms in it, and lets the beam go, moment, shear and pull alike, once it has turned
/// `fractureRotation` (its elastic and plastic turn about the beam's bending axes together), as the
/// tested connections did when their flanges fractured. Columns, and members that run on through the
/// joint, keep the joint's node. Without one, members that meet share their node: rigid and
/// unbreakable but by their own fibres' failure.
public struct SteelConnection: Codable, Hashable, Sendable {
    public var name: String
    /// The connection's moment at which it turns plastically, over the beam's plastic moment.
    public var momentRatio: Float
    /// The turn at which it fractures, rad.
    public var fractureRotation: Float
    /// Its strength along the beam, pulled or pushed, over the beam's squash load (its section's
    /// area at yield, the equivalent rectangle's for a `SteelSection`); nil for as strong as the
    /// beam, as a welded flange is.
    public var tensionRatio: Float?

    public init(name: String, momentRatio: Float, fractureRotation: Float, tensionRatio: Float? = nil) {
        self.name = name
        self.momentRatio = momentRatio
        self.fractureRotation = fractureRotation
        self.tensionRatio = tensionRatio
    }

    /// Reject values a hinge cannot use, including ones loaded from a document: a turn at fracture
    /// that is not positive breaks every hinge at once, a NaN never breaks one, and a ratio that is
    /// not positive gives a yield that is not.
    public func validate() throws {
        guard fractureRotation.isFinite, fractureRotation > 0 else {
            throw ImportedMesh.ImportError.invalid("A steel connection's fracture rotation must be positive.")
        }
        guard momentRatio.isFinite, momentRatio > 0, tensionRatio.map({ $0.isFinite && $0 > 0 }) ?? true
        else {
            throw ImportedMesh.ImportError.invalid("A steel connection's strength ratios must be positive.")
        }
    }

    /// A welded unreinforced flange with a bolted web (WUF-B), full-strength: it fractured at a beam
    /// chord rotation of 0.081 rad under a column's removal (Sadek et al., NIST TN 1669, 2010; 0.047
    /// from seismic tests). Its plastic turn begins at 0.95 of the beam's plastic moment, so that the
    /// hinge, not the beam beside it, takes it.
    public static let weldedFlange = Self(
        name: "Welded flange, bolted web (WUF-B)", momentRatio: 0.95, fractureRotation: 0.081)
    /// A reduced beam section (RBS), the beam's flanges cut back beside the column so that it hinges
    /// there: 0.14 rad under a column's removal (NIST TN 1669; 0.073 seismic). Its plastic moment
    /// about 0.8 of the beam's, the reduced section's (AISC 358 sizes the cut so).
    public static let reducedBeamSection = Self(
        name: "Reduced beam section (RBS)", momentRatio: 0.8, fractureRotation: 0.14)
    /// A single-plate shear connection (a fin plate, or shear tab), the simple connection of a gravity
    /// frame's beams to its columns: three 19 mm bolts through a 9.5 mm plate on a W18x35 beam
    /// (Weigand and Berman, 2016, thirteen tests under a column's removal). The turn at which it
    /// fractures, 0.089 rad, is the tests' median (0.067–0.110), their chord rotation as their bolts
    /// sheared or plates tore. Its moment, 0.05 of the beam's plastic moment, is that of the three
    /// bolts' shear strength (130 kN each, A325-X) about the middle one at their 76 mm pitch. Its
    /// strength along the beam, 0.13 of the equivalent rectangle's squash load, is the three-bolt
    /// tests' median pull, 435 kN, over W18x35's (4 M_p / d = 3,350 kN). Its shear, which held
    /// 32–60 kN in the tests once their pull had grown, is left unlimited: under gravity alone it
    /// carries the beam.
    public static let singlePlateShear = Self(
        name: "Single-plate shear (fin plate)", momentRatio: 0.05, fractureRotation: 0.089, tensionRatio: 0.13
    )

    /// Bolted end plates at blast rates, from Culache's tests loaded to failure in 40 ms (half-scale,
    /// S355 beams, 12 mm plates, M12 grade 8.8 bolts; Southampton PhD, 2017, Table 3.5). Their
    /// carbon-steel bolts stripped their threads and broke with little turn, weaker and sooner than
    /// in the same tests loaded over 300 s (127 and 98 kN m, 1.2 degrees): the slow tests' values
    /// would make them 13–41% too strong and half again too ductile at a blast's rate. The moment is over the
    /// beam's plastic moment at S355's nominal yield (305×102×25, 121 kN m; 305×127×37, 191 kN m).
    /// An extended end plate: 90 kN m, 0.70 degrees.
    public static let extendedEndPlate = Self(
        name: "Extended end plate, bolted (at blast rates)", momentRatio: 0.74, fractureRotation: 0.0122)
    /// A flush end plate: 87 kN m, 0.80 degrees.
    public static let flushEndPlate = Self(
        name: "Flush end plate, bolted (at blast rates)", momentRatio: 0.45, fractureRotation: 0.0140)
}
