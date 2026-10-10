import Foundation
import Testing

@testable import BlastCore

/// Concrete options that a saved model must keep, and the bench's `--bond`.
@Suite("Model options saved and read")
struct ModelOptionPersistenceTests {
    private func roundTrip(_ model: StructureModel) throws -> StructureModel {
        try JSONDecoder().decode(StructureModel.self, from: JSONEncoder().encode(model))
    }

    @Test("Pressed interlock, slide-apart and the hourglass options are saved")
    func crackOptions() throws {
        var model = StructureModel(solids: [Box(min: .zero, max: SIMD3(1, 1, 1))], elementSize: 0.25)
        model.pressedInterlock = true
        model.slipWidensCracks = false
        model.hourglassFollowsCracking = true
        model.hourglassCapsSteel = false
        let read = try roundTrip(model)
        #expect(read.pressedInterlock)
        #expect(!read.slipWidensCracks)
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
        #expect(object["slipWidensCracks"] == nil)
        #expect(object["hourglassFollowsCracking"] == nil && object["hourglassCapsSteel"] == nil)
        let read = try JSONDecoder().decode(StructureModel.self, from: data)
        #expect(!read.pressedInterlock)
        #expect(read.slipWidensCracks)
        #expect(!read.hourglassFollowsCracking && read.hourglassCapsSteel)
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
