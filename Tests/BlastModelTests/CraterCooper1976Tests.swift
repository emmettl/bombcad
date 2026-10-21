import Foundation
import Testing

@testable import BlastModel

@Suite("Craters against H. F. Cooper's 1976 high-explosive data")
struct CraterCooper1976Tests {
    typealias C = CooperCraters1976

    func fixture() throws -> C.Fixture {
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Fixtures/Cooper1976/craters.json")
        return try C.fixture(from: url)
    }

    @Test("The fixture: table 1, the height-of-burst law and 135 points from figures 9–12")
    func fixtureHolds() throws {
        let fixture = try fixture()
        #expect(fixture.row(.drySoil)?.v0 == 1000 && fixture.row(.wetSoil)?.v0 == 4000)
        #expect(fixture.heightOfBurst.exponent == 5.2 && fixture.shape.radius.best == 1.2)
        #expect(C.Medium.allCases.map { fixture.points($0).count } == [57, 39, 20, 19])
        // Cooper's own curve runs through his points: within 5% on the geometric mean of radius.
        for medium in C.Medium.allCases {
            let ratios = fixture.points(medium).filter { abs($0.h) < 0.4 }.compactMap { point in
                C.cooperEstimate(fixture, medium: medium, h: point.h).map { cbrt(point.efficiency / $0) }
            }
            let mean = try #require(C.Summary(ratios)).geometricMean
            #expect(abs(mean - 1) < 0.06)
        }
    }

    @Test("Surface bursts read as measured; raised ones 0.90 to the centre (today's), 0.57 to the underside")
    func againstPoints() throws {
        let fixture = try fixture()
        func summary(_ datum: C.Datum, _ band: C.Band) throws -> C.Summary {
            try #require(
                C.Summary(
                    C.pairs(fixture, datum: datum).filter { C.Band(h: $0.h) == band }.map(\.radiusRatio)))
        }
        // Recorded 21 October 2026 (docs/cratering.md#against-cooper-1976).
        let surface = try summary(.underside, .surface)
        #expect(surface.count == 21 && abs(surface.geometricMean - 1.01) < 0.02 && surface.withinBand > 0.9)
        let above = try summary(.underside, .above)
        #expect(above.count == 40 && abs(above.geometricMean - 0.57) < 0.02)
        let centred = try summary(.centre, .above)
        #expect(abs(centred.geometricMean - 0.90) < 0.02 && centred.withinBand > 0.7)
        // Below the surface, which BombCAD counts as on it, the craters are wider than it digs.
        let below = try summary(.underside, .below)
        #expect(below.count == 74 && abs(below.geometricMean - 1.72) < 0.03)
    }

    @Test("A ton's radius at a centre height of one charge radius, to the underside and to the centre")
    func datum() {
        let under = C.bombcadRadius(ground: .alluvium, centreHeight: 1, datum: .underside)
        let centre = C.bombcadRadius(ground: .alluvium, centreHeight: 1, datum: .centre)
        // 0.97 (2 × 0.5 × 2,000)^(1/3) ft on the surface; e^(−1.457 / 3) less a radius up.
        #expect(abs(under - 0.97 * cbrt(2000.0)) < 1e-3)
        #expect(abs(centre / under - exp(-1.457 / 3)) < 1e-4)
        // The centre is BombCAD's own datum since 22 October 2026: a ton resting on alluvium.
        let mass = Float(C.tonKilograms)
        let resting = Charge(mass: mass, position: SIMD3(0, 0, CraterEstimate.chargeRadius(mass: mass)))
        let crater = CraterEstimate(charge: resting, groundHeight: 0, ground: .alluvium)
        #expect(abs(Double(crater?.apparentRadius ?? 0) / 0.3048 - centre) < 1e-3)
    }
}
