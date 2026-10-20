import Foundation
import Testing
import simd

@testable import BlastModel

/// Failed concrete that becomes particles keeping its mass (`StructureModel.rubbleParticles`).
@Suite("Rubble particles")
struct RubbleParticleTests {
    @Test("Rubble is saved with the model, and a model saved without it reads without it")
    func persistence() throws {
        var model = StructureModel(solids: [Box(min: .zero, max: SIMD3(1, 1, 1))], elementSize: 0.25)
        let plain = try JSONEncoder().encode(model)
        let object = try #require(try JSONSerialization.jsonObject(with: plain) as? [String: Any])
        #expect(object["rubbleParticles"] == nil)
        #expect(!(try JSONDecoder().decode(StructureModel.self, from: plain)).rubbleParticles)
        model.rubbleParticles = true
        let read = try JSONDecoder().decode(StructureModel.self, from: JSONEncoder().encode(model))
        #expect(read.rubbleParticles && read == model)
    }
}
