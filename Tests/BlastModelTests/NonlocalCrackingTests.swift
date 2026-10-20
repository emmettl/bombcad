import Foundation
import Testing
import simd

@testable import BlastModel

/// Cracks that soften by their strain averaged across their band (`crackAveraging`).
@Suite("Nonlocal cracking")
struct NonlocalCrackingTests {
    @Test("Nonlocal cracking is saved, and a body without it is unchanged")
    func saved() throws {
        var model = StructureModel(solids: [Box(min: .zero, max: SIMD3(1, 1, 1))], elementSize: 0.25)
        let data = try JSONEncoder().encode(model)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["crackAveraging"] == nil)
        model.crackAveraging = 0.05
        #expect(try JSONDecoder().decode(StructureModel.self, from: JSONEncoder().encode(model)) == model)
    }
}
