import Foundation
import Testing

@testable import BlastModel

@Suite("ADBLAST substructure reference")
struct AdblastSubstructureTests {
    private var fixture: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Fixtures/ADBLAST2015/tests.json")
    }

    @Test("The twelve-shot reference preserves unknowns and support assignments")
    func shots() throws {
        let shots = try AdblastCladdingTest.substructureTests(from: fixture)
        #expect(shots.map(\.test) == Array(1...12))
        #expect(shots.filter { $0.transferLoadF2kN == nil }.map(\.test) == [1, 2])
        #expect(shots.filter { $0.firstDynamicDeflectionMM == nil }.map(\.test) == [8])
        #expect(shots.filter { $0.midPurlinSupport == .free }.map(\.test) == [1, 2, 7, 8, 9, 10])
        // Table 17 is the declared reference even though Table 16 instead says 215 and 165.
        #expect(shots[2].reflectedImpulseKPaMS == 212)
        #expect(shots[3].reflectedImpulseKPaMS == 161)
        #expect(
            shots.suffix(4).allSatisfy { $0.purlinPlasticVerticalMM == 0 && $0.purlinPlasticLateralMM == 0 })
        let profile = shots[0].sheetProfile(yield: 323.62e6)
        // Independent developed-length calculation from Figure A5, for a 1 mm sheet:
        // (119 + 40 + 2 sqrt(24² + 33²)) / 207 = 1.162361 m of steel per m of cover.
        #expect(abs(Double(profile.perWidth.area) / 0.00116236146 - 1) < 1e-5)
        #expect(profile.yieldStress == 323.62e6)
    }

    @Test("The preregistered charge rule uses impulse only, breaks ties down, and refuses incomplete sweeps")
    func charges() {
        let select = AdblastCladdingTest.substructureCharge
        #expect(select(169, [100, 165, 300, 400]) == 0.5)
        #expect(select(200, [100, 300, 500, 700]) == 0.25)
        #expect(select(361, [100, 165, 300, 400]) == 1.5)
        #expect(select(169, [100, 165, 300]) == nil)
        #expect(select(169, [100, .nan, 300, 400]) == nil)
        #expect(select(169, [100, .infinity, 300, 400]) == nil)
        #expect(select(169, [100, 0, 300, 400]) == nil)
        #expect(select(.nan, [100, 165, 300, 400]) == nil)
        #expect(select(-1, [100, 165, 300, 400]) == nil)
    }
}
