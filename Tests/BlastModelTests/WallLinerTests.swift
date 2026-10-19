import Foundation
import Testing

@testable import BlastModel

/// A polyurea liner on unreinforced blockwork against Ciornei's shock-tube walls (University of
/// Ottawa, MASc, 2012, ruor.uottawa.ca/handle/10393/23180, §3.3): 2 × 2 m walls of 90 mm hollow
/// concrete block (140 kg/m²) spanning up between steel supports, URM-1 bare and URM-2 with 3 mm
/// of Line-X sprayed on its inside face and lapped onto the frame, each shot in turn with the
/// shock tube's reflected peak and impulse, and the largest deflection measured.
@Suite("Wall liners")
struct WallLinerTests {
    /// Peak (kPa), impulse (kPa·ms), largest deflection (mm, nil where the wall collapsed).
    static let lined: [(peak: Double, impulse: Double, deflection: Double?)] = [
        (8.7, 68.2, 2.2), (14.6, 128.7, 6.4), (23, 188.5, 10.3), (32, 294.5, 23), (37.5, 338.5, 36.9),
        (42.1, 406.3, 50), (46.1, 433.8, 69.2), (53.9, 483.3, 88.4), (84.4, 597.2, 158.9), (78.1, 723.4, nil),
    ]
    static let bare: [(peak: Double, impulse: Double, deflection: Double?)] = [
        (6.1, 53.1, 9.1), (13.7, 150.9, 23.8), (23.4, 179.3, 56.5), (30.7, 265.1, nil),
    ]

    static func wall(lined: Bool) -> SDOFSystem {
        var masonry = StructureMaterial.masonry
        masonry.steel = nil
        var system = EnvelopePanel.unreinforcedMasonryOneWay(
            thickness: 0.09, material: masonry, span: 2, edges: .simplySupported)
        system.massPerArea = 140
        return lined ? system.lined(.polyurea(mm: 3), span: 2) : system
    }

    static func run(_ system: SDOFSystem, _ shot: (peak: Double, impulse: Double, deflection: Double?))
        -> SDOFResponse
    {
        let step = 2e-5
        return system.response(
            pressures: LaminatedGlassMeasurements.triangle(
                peak: shot.peak * 1e3, impulse: shot.impulse, step: step, until: 0.1),
            step: step)
    }

    @Test("The liner's membrane: Ciornei's strain over a tenth of the span, and where it tears")
    func membrane() {
        let liner = WallLiner.polyurea(mm: 3)
        // 250 mm on 2 m: an arc 80.5 mm longer, 40% over 0.2 m.
        #expect(abs(liner.strain(deflection: 0.25, span: 2) - 0.4023) < 0.001)
        let tear = liner.tearDeflection(span: 2)
        #expect(abs(liner.strain(deflection: tear, span: 2) - 0.82) < 1e-6)
        // At the tear the liner pulls at its 14 MPa: 42 kN/m at sin θ.
        let theta = atan(4 * tear / 2)
        #expect(abs(liner.resistance(deflection: tear, span: 2) - 2 * 14e6 * 0.003 * sin(theta) / 2) < 1)
    }

    /// Each shot from the wall as built (the tests' walls had taken the earlier shots). The tests'
    /// walls arched against their supports (the gap at the top filled); the model's masonry does
    /// not arch, so under the small shots it goes several times as far as measured and the bare
    /// wall is lost on the second shot, where the test's held to its fourth. Once the lined wall is
    /// past its thickness, the liner's membrane carries it: 1.3–1.9 times the measured deflection.
    /// It holds the last shot, 246 mm, where the test's tore through at 254 mm after nine earlier
    /// shots: its tear, at 82% over a tenth of the span, needs about 350 mm.
    @Test("Ciornei's lined and bare blockwork walls, shot by shot")
    func ciornei() {
        var ratios: [Double] = []
        for (name, shots, lined) in [("URM-2, lined", Self.lined, true), ("URM-1, bare", Self.bare, false)] {
            let system = Self.wall(lined: lined)
            for (n, shot) in shots.enumerated() {
                let response = Self.run(system, shot)
                let lost = response.lostResistanceAt != nil
                print(
                    String(
                        format: "%@ %.1f kPa %.0f kPa·ms: %@ (measured %@)", name, shot.peak, shot.impulse,
                        lost ? "lost" : String(format: "%.0f mm", response.peakDeflection * 1e3),
                        shot.deflection.map { String(format: "%.0f mm", $0) } ?? "collapsed"))
                if lined {
                    // Held through every shot; the test's was until the last, which tore it through.
                    #expect(!lost)
                    if let measured = shot.deflection, measured > 80 {
                        ratios.append(response.peakDeflection * 1e3 / measured)
                    }
                } else if n >= 1 {
                    #expect(lost)
                }
            }
        }
        print(ratios.map { String(format: "%.2f", $0) }.joined(separator: " "))
        #expect(ratios.count == 2 && ratios.allSatisfy { $0 > 1.1 && $0 < 2 })
        #expect(abs(WallLiner.polyurea(mm: 3).tearDeflection(span: 2) - 0.35) < 0.03)
    }

    @Test("A lined brick wall holds in the damage path where the bare one falls")
    func envelopeWall() throws {
        let owner = UUID()
        var brick = EnvelopeConstruction(
            objectID: owner, walls: .unreinforcedMasonry, source: .user, detail: "")
        // A 6 m long, 3 m tall wall of 215 mm brick facing y, under 100 kPa and 1,000 kPa·ms.
        let load = EnvelopeComponentLoad(
            id: "\(owner.uuidString)/wall/0.0", owner: owner, kind: .wall,
            region: Box(min: SIMD3(0, 0, 0), max: SIMD3(6, 0.215, 3)), axis: 1, binS: 1e-4,
            outerPa: LaminatedGlassMeasurements.triangle(peak: 100e3, impulse: 1000, step: 1e-4, until: 0.3),
            innerPa: [], supportEdges: [true, true, true, true])
        let bare = try #require(EnvelopeDamageAssessment.assess(load, construction: brick))
        brick.wallLiner = .polyurea(mm: 3)
        let lined = try #require(EnvelopeDamageAssessment.assess(load, construction: brick))
        print(bare.levels, bare.rotationDeg, lined.levels, lined.rotationDeg)
        #expect(bare.levels == .failed ... .failed && bare.failedAtS != nil)
        #expect(lined.levels == .heavy ... .heavy && lined.failedAtS == nil && lined.launch == nil)
        let decoded = try JSONDecoder().decode(EnvelopeConstruction.self, from: JSONEncoder().encode(brick))
        #expect(decoded.wallLiner == brick.wallLiner)
    }
}
