import Foundation
import Testing
import simd

@testable import BlastModel

/// The candidate close-in branch taken only in sight of the charge (`CloseIn.inSightOnly`,
/// emmettl/bombcad-work#56): off as fitted; on, a shielded façade close in keeps the fitted terms.
@Suite("Close-in branch in sight only")
struct CloseInSightTests {
    func features(distance: Double, crossed: Int) -> FacadeLoadSurrogate.Features {
        FacadeLoadSurrogate.Features(
            distanceM: distance, cosIncidence: 0.5, buildingsCrossed: crossed, blockedM: Double(crossed) * 8,
            ridgeM: 0, groundRiseM: 0, heightM: 2, shadowM: crossed > 0 ? 10 : 0, frontM: 20)
    }

    @Test("Off as fitted; on, the branch for components in sight and the fitted terms behind buildings")
    func inSight() throws {
        let mass = 100_000.0
        let fitted = FacadeLoadSurrogate.Coefficients.fitted
        #expect(fitted.closeIn?.inSightOnly == nil)
        var candidate = fitted
        candidate.closeIn?.inSightOnly = true
        var none = fitted
        none.closeIn = nil
        // Z 3.5, inside the branch.
        let near = 3.5 * cbrt(mass)
        for crossed in [0, 2] {
            let f = features(distance: near, crossed: crossed)
            let now = FacadeLoadSurrogate.predict(f, mass: mass, cellSize: 4, coefficients: fitted)
            let mine = FacadeLoadSurrogate.predict(f, mass: mass, cellSize: 4, coefficients: candidate)
            let without = FacadeLoadSurrogate.predict(f, mass: mass, cellSize: 4, coefficients: none)
            #expect(now != without)
            #expect(mine == (crossed == 0 ? now : without))
        }
        // Beyond the branch, nothing changes.
        let far = features(distance: 12 * cbrt(mass), crossed: 2)
        #expect(
            FacadeLoadSurrogate.predict(far, mass: mass, cellSize: 4, coefficients: candidate)
                == FacadeLoadSurrogate.predict(far, mass: mass, cellSize: 4, coefficients: fitted))
        // Old coefficient files, without the field, read as before.
        let data = try JSONEncoder().encode(fitted)
        let decoded = try JSONDecoder().decode(FacadeLoadSurrogate.Coefficients.self, from: data)
        #expect(decoded == fitted)
    }
}
