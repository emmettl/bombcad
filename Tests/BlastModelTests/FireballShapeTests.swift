import Foundation
import Testing
import simd

@testable import BlastModel

@Suite("The fireball's shape and its radiation")
struct FireballShapeTests {
    @Test("A description names its fireball model, the volume unless it says otherwise")
    func model() throws {
        #expect(try JSONDecoder().decode(ThermalSpec.self, from: Data("{}".utf8)).fireball == .volume)
        let sphere = try JSONDecoder().decode(ThermalSpec.self, from: Data(#"{"fireball": "sphere"}"#.utf8))
        #expect(sphere.fireball == .sphere)
    }
}
