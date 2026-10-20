import Foundation
import Testing
import simd

@testable import BlastModel

/// The strain rate the rate laws see averaged over a fixed time (`strainRateWindow`) rather than
/// over the last 50 steps.
@Suite("Strain-rate window")
struct StrainRateWindowTests {
    @Test("The window defaults to 100 µs, left out of saves; other windows and the 50-step average are kept")
    func codable() throws {
        var model = StructureModel(solids: [Box(min: .zero, max: SIMD3(1, 1, 1))], elementSize: 0.1)
        #expect(model.strainRateWindow == StructureModel.defaultStrainRateWindow)
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(model)) as? [String: Any]
        #expect(plain?["strainRateWindow"] == nil)
        let reread = try JSONDecoder().decode(StructureModel.self, from: JSONEncoder().encode(model))
        #expect(reread.strainRateWindow == StructureModel.defaultStrainRateWindow)
        model.strainRateWindow = 1.2e-4
        let decoded = try JSONDecoder().decode(StructureModel.self, from: JSONEncoder().encode(model))
        #expect(decoded.strainRateWindow == 1.2e-4)
        // The 50-step average, saved as 0, comes back as nil rather than as the default.
        model.strainRateWindow = nil
        let steps = try JSONDecoder().decode(StructureModel.self, from: JSONEncoder().encode(model))
        #expect(steps.strainRateWindow == nil)
    }
}
