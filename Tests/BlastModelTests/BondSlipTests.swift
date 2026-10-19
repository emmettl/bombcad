import Foundation
import Testing
import simd

@testable import BlastModel

/// Bars that slip in their concrete (`BondSlip`), against the fib Model Code 2010's crack
/// spacing and tension stiffening for a reinforced tie.
@Suite("Bond slip")
struct BondSlipTests {
    @Test("Without bars that slip, nothing changes; a model's bond is saved")
    func persistence() throws {
        var model = StructureModel(solids: [Box(min: .zero, max: SIMD3(1, 1, 1))], elementSize: 0.25)
        #expect(model.bondSlip == nil)
        model.bondSlip = BondSlip(condition: .splitting, barDiameter: 0.02)
        let data = try JSONEncoder().encode(model)
        #expect(try JSONDecoder().decode(StructureModel.self, from: data) == model)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["bondSlip"] = nil
        let old = try JSONDecoder().decode(
            StructureModel.self, from: try JSONSerialization.data(withJSONObject: object))
        #expect(old.bondSlip == nil)
    }

    @Test("The bond laws follow the Model Code's table")
    func laws() {
        let fc: Float = 30e6
        let pullOut = BondSlip(condition: .pullOut).law(compressiveStrength: fc)
        let pullOutPeak: Float = 2.5 * Float(30).squareRoot() * 1e6
        #expect(abs(pullOut.peak - pullOutPeak) < 1e3)
        #expect(pullOut.s1 == 1e-3 && pullOut.s2 == 2e-3 && abs(pullOut.residual - 0.4 * pullOut.peak) < 1)
        let splitting = BondSlip(condition: .splitting).law(compressiveStrength: fc)
        let splittingPeak: Float = 7 * pow(Float(1.2), 0.25) * 1e6
        #expect(abs(splitting.peak - splittingPeak) < 1e3)
        #expect(splitting.residual == 0 && abs(splitting.s3 - 1.2 * splitting.s1) < 1e-9)
        // At its peak slip, the pull-out curve's rising branch reaches the splitting strength.
        let reached: Float = pullOut.peak * pow(splitting.s1 / 1e-3, 0.4)
        #expect(abs(reached - splitting.peak) < 1e3)
    }
}
