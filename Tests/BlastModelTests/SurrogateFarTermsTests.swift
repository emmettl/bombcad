import Foundation
import Testing

@testable import BlastModel

/// The façade surrogate's far terms (`FacadeLoadSurrogate.Coefficients.Far`, emmettl/bombcad-work#104;
/// docs/surrogate-first-look.md): the default since the user adopted them on 25 October 2026
/// (emmettl/bombcad-work#105), leaving every load the far terms do not reach as clear-top's, and the
/// earlier sets untouched.
@Suite("Façade far terms")
struct SurrogateFarTermsTests {
    typealias S = FacadeLoadSurrogate

    static func side(_ distance: Double, cos: Double, crossed: Int) -> S.Features {
        var f = FacadeLoadSurrogateTests.facing(distance)
        f.cosIncidence = cos
        f.buildingsCrossed = crossed
        f.blockedM = 12 * Double(crossed)
        return f
    }

    @Test("The default has the far terms; the earlier sets have none, and save as they did")
    func defaultsUntouched() throws {
        #expect(S.TermSet.adopted == .deepCity && S.Coefficients.adopted.far == .deepCity)
        #expect(S.Coefficients.adopted.glassFront == nil)
        #expect(S.Coefficients.clearTop.far == nil && S.Coefficients.fitted.far == nil)
        #expect(S.Coefficients.clearTopFront.far == nil && S.Coefficients.roofs.far == nil)
        let data = try JSONEncoder().encode(S.Coefficients.clearTop)
        #expect(!String(decoding: data, as: UTF8.self).contains("\"far\""))
        let back = try JSONDecoder().decode(S.Coefficients.self, from: data)
        #expect(back == .clearTop)
    }

    @Test("The deep-city sets are clear-top with far terms, a front only on the fronted one")
    func namedCandidates() throws {
        #expect(try SurrogateBench.termSet(["--terms", "deep-city"]) == .deepCity)
        #expect(try SurrogateBench.termSet(["--terms", "deep-city-front"]) == .deepCityFront)
        #expect(S.TermSet.deepCity.loadScatter == S.TermSet.clearTop.loadScatter)
        var bare = S.Coefficients.deepCity
        bare.far = nil
        bare.fittedTo = S.Coefficients.clearTop.fittedTo
        #expect(bare == .clearTop)
        #expect(S.Coefficients.deepCity.glassFront == nil)
        var unfronted = S.Coefficients.deepCityFront
        unfronted.glassFront = nil
        #expect(unfronted == .deepCity)
        let back = try JSONDecoder().decode(
            S.Coefficients.self, from: try JSONEncoder().encode(S.Coefficients.deepCityFront))
        #expect(back == .deepCityFront)
    }

    @Test(
        "Where the far terms are nothing, every load is clear-top's to the bit",
        arguments: [20_000.0, 500_000.0])
    func nothingNear(mass: Double) {
        let near: [S.Features] = [
            Self.side(40, cos: 1, crossed: 0), Self.side(400, cos: -0.6, crossed: 12),
            Self.side(1_700, cos: -1, crossed: 30), Self.side(2_600, cos: 0.8, crossed: 30),
            Self.side(3_000, cos: 0, crossed: 5),
        ]
        for f in near {
            #expect(
                S.predict(f, mass: mass, cellSize: 4, coefficients: .deepCity)
                    == S.predict(f, mass: mass, cellSize: 4, coefficients: .clearTop))
        }
    }

    @Test("Deep in a city the peak rises by the two terms; the impulse and the rise do not move")
    func deepRaised() {
        let f = Self.side(2_500, cos: -0.5, crossed: 60)
        let clear = S.predict(f, mass: 500_000, cellSize: 4, coefficients: .clearTop)
        let deep = S.predict(f, mass: 500_000, cellSize: 4, coefficients: .deepCity)
        let far = S.Coefficients.Far.deepCity
        let expected = exp(far.peakDepth * (log(61) - log(31)) + far.peakAway * 0.5 * log(2_500 / 1_750))
        #expect(abs(deep.peakPa / clear.peakPa - expected) < 1e-9)
        #expect(deep.peakPa > clear.peakPa * 1.1)
        #expect(deep.impulsePaS == clear.impulsePaS && deep.riseShare == clear.riseShare)
        #expect(deep.arrivalS == clear.arrivalS)
        // The walls take the far terms with the loads, on their own rise.
        #expect(S.Coefficients.deepCity.forStructures.far == .deepCity)
        #expect(S.Coefficients.deepCity.forStructures.rise == S.Coefficients.clearTop.forStructures.rise)
    }
}
