import Foundation
import Testing

@testable import BlastModel

/// The one-point element's hourglass cap on the whole-event mesh (emmettl/bombcad-work#36 step 3),
/// on the cracked-hex reference with the shader's reading of the cap (`uncrackedCapAtStrength`
/// false: an element whose centre has not cracked caps at the tension its centre has reached).
/// - A hinge two elements deep (the large-panel block's 175 mm wall, its light mesh at
///   mid-depth, bent statically past cracking) holds about three quarters of the section's moment.
/// - An uncracked element, never stretched at its centre, warped in a mode below its cracking
///   strain is held at 2% of the tensile strength: its modes yield far below the concrete's
///   strength.
@Suite("The hourglass cap two elements deep")
struct HingeSectionTests {
    static let concrete = CrackedHex.Concrete(
        youngsModulus: 4700e6 * 31.0.squareRoot(), compressiveStrength: 31e6,
        tensileStrength: 0.3e6 * pow(31.0, 2.0 / 3.0), fractureEnergy: 73 * pow(31.0, 0.18), bandWidth: 0.0875
    )
    static let wall = CrackedHex.ReinforcedSection(
        depth: 0.175, barHeight: 0.0875, barAreaPerWidth: 142e-6, concrete: concrete,
        steel: CrackedHex.Steel(yieldStress: 250e6))
    /// Past cracking, to where the cracked wall's moment has settled.
    static let curvatures: [Double] = [
        0.0005, 0.001, 0.0015, 0.002, 0.003, 0.005, 0.01, 0.02, 0.04, 0.06, 0.08, 0.1,
    ]

    @Test("Two through, a cracked wall's hinge holds 0.6–0.9 of the section's moment")
    func twoThrough() {
        let section = CrackedHex.sectionAnalysis(Self.wall, bandWidth: 0.0875, curvatures: Self.curvatures)
        let model = CrackedHex.momentCurvature(
            Self.wall, elementsThroughDepth: 2, formulation: .today, curvatures: Self.curvatures,
            smearedBars: true,
            uncrackedCapAtStrength: false)
        #expect(model.moments.count == Self.curvatures.count, "the static solve stopped")
        let ratio = (model.moments.last ?? 0) / (section.last ?? 1)
        #expect(ratio > 0.6 && ratio < 0.9, "today's \(model.moments.last ?? 0) against \(section.last ?? 0)")
    }

    @Test("An uncracked element warped in a mode below cracking is held at 2% of the tensile strength")
    func warpedElement() {
        let h = 0.0875
        let mesh = CrackedHex.BoxMesh(nx: 1, ny: 1, nz: 1, h: h)
        let c = Self.concrete
        // The fourth mode along x, its amplitude a stretching the faces to half the cracking
        // strain (2 a / h).
        let a = 0.25 * h * c.crackingStrain
        var u = Array(repeating: 0.0, count: 24)
        for corner in 0..<8 {
            let s = CrackedHex.corner(corner)
            u[3 * corner] = a * s.x * s.y * s.z
        }
        var element = CrackedHex.Element(
            geometry: mesh.geometry(0, 0, 0), law: .concrete(c), formulation: .today)
        element.uncrackedCapAtStrength = false
        let force = element.evaluate(u, from: element.initialState).state.hourglassForce[3]
        let held = (force * force).sum().squareRoot()
        let floor = 0.125 * 0.02 * c.tensileStrength * h * h
        let elastic = 8 * c.youngsModulus * h / 48 * a
        #expect(abs(held - floor) < 1e-6 * floor, "held at \(held) N against the floor's \(floor)")
        #expect(elastic > 10 * floor, "elastically it would be \(elastic) N")
    }
}
