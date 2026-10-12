import Foundation
import Testing

@testable import BlastCore

/// Concrete options that a saved model must keep, and the bench's `--bond`.
@Suite("Model options saved and read")
struct ModelOptionPersistenceTests {
    private func roundTrip(_ model: StructureModel) throws -> StructureModel {
        try JSONDecoder().decode(StructureModel.self, from: JSONEncoder().encode(model))
    }

    @Test("Pressed interlock and the hourglass options are saved")
    func crackOptions() throws {
        var model = StructureModel(solids: [Box(min: .zero, max: SIMD3(1, 1, 1))], elementSize: 0.25)
        model.pressedInterlock = true
        model.hourglassFollowsCracking = true
        model.hourglassCapsSteel = false
        let read = try roundTrip(model)
        #expect(read.pressedInterlock)
        #expect(read.hourglassFollowsCracking && !read.hourglassCapsSteel)
        #expect(read == model)
    }

    @Test("A model saved before those options were reads with today's meaning, and saves as before")
    func olderFiles() throws {
        let model = StructureModel(solids: [Box(min: .zero, max: SIMD3(1, 1, 1))], elementSize: 0.25)
        let data = try JSONEncoder().encode(model)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        // At their standard values they are not written, so the file is as an older version wrote it.
        #expect(object["pressedInterlock"] == nil)
        #expect(object["hourglassFollowsCracking"] == nil && object["hourglassCapsSteel"] == nil)
        let read = try JSONDecoder().decode(StructureModel.self, from: data)
        #expect(!read.pressedInterlock)
        #expect(read.retiredOptions.isEmpty)
        #expect(!read.hourglassFollowsCracking && read.hourglassCapsSteel)
    }

    @Test("A model saved with options since retired opens with what now applies, and a note of each")
    func retiredOptions() throws {
        let model = StructureModel(
            solids: [Box(min: .zero, max: SIMD3(1, 1, 1))],
            material: .concrete(name: "C30", compressiveStrength: 30e6), elementSize: 0.25)
        var json = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(model)) as? [String: Any])
        json["crackAxes"] = "lattice"
        json["slipWidensCracks"] = false
        json["crackShearStiffness"] = true
        json["barRateAlongBars"] = false
        var material = try #require(json["material"] as? [String: Any])
        material["crushLength"] = 0.048
        material["crushBand"] = 0.05
        material["tensionRateLaw"] = "malvarRoss"
        material["steelRateLaw"] = "malvarCrawford"
        json["material"] = material
        let read = try JSONDecoder().decode(
            StructureModel.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(read.retiredOptions.count == 8, "\(read.retiredOptions)")
        #expect(read.retiredOptions.contains { $0.contains("Crack axes 'lattice'") })
        // Everything else reads as it was saved.
        var expected = model
        expected.retiredOptions = read.retiredOptions
        #expect(read == expected)
        // Saved at what now applies, they leave no note: an older file with the defaults.
        json["crackAxes"] = "turningUntilOpen"
        json["slipWidensCracks"] = true
        json["crackShearStiffness"] = false
        json["barRateAlongBars"] = true
        json["material"] = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(model.material)) as? [String: Any])
        let plain = try JSONDecoder().decode(
            StructureModel.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(plain.retiredOptions.isEmpty)
    }

    @Test("--bond names bars that slip or the mortar joint, never both")
    func bondArgument() {
        #expect(BondArgument(present: false, value: nil) == .absent)
        #expect(BondArgument(present: true, value: "pullout") == .bars(.pullOut))
        #expect(BondArgument(present: true, value: "splitting") == .bars(.splitting))
        #expect(BondArgument(present: true, value: "confined") == .bars(.confinedSplitting))
        #expect(BondArgument(present: true, value: "none") == .perfect)
        // Alone, or followed by another option, it is the joint where masonry meets concrete.
        #expect(BondArgument(present: true, value: nil) == .mortar)
        #expect(BondArgument(present: true, value: "--preset") == .mortar)
        #expect(BondArgument(present: true, value: "mortar") == .mortar)
        #expect(BondArgument(present: true, value: "pullout").bondSlip(diameter: 0.012)?.barDiameter == 0.012)
        #expect(BondArgument(present: true, value: nil).bondSlip(diameter: 0.012) == nil)
        #expect(BondArgument(present: true, value: "none").bondSlip(diameter: 0.012) == nil)
    }
}
