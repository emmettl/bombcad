import Foundation
import Testing
import simd

@testable import BlastModel

/// The base's connection to the ground (`Anchorage`) against statics: bearing, pull-off,
/// sliding at the friction limit and overturning about the toe.
@Suite("Anchorage")
struct AnchorageTests {
    @Test("Friction that falls with pressure takes an exponent below 1, so that its force still grows")
    func frictionExponentBound() throws {
        var law = Anchorage.neoprenePad
        try law.validate()
        for exponent in [1, 1.5] as [Float] {
            law.frictionExponent = exponent
            #expect(throws: (any Error).self) { try law.validate() }
        }
    }

    @Test("Connections are recognised by name")
    func connections() {
        #expect(BaseConnection(.soil(bearingCapacity: 300e3)) == .soil)
        for connection in BaseConnection.allCases {
            #expect(BaseConnection(connection.anchorage) == connection)
        }
        #expect(BaseConnection(.dowelled(ratio: 0.01)) == .dowelled)
        #expect(BaseConnection(.resting(friction: 0.3)) == .resting)
    }

    @Test("A model's anchorage is saved, and models saved without one still open")
    func persistence() throws {
        var model = StructureModel(solids: [Box(min: .zero, max: SIMD3(1, 1, 1))], elementSize: 0.25)
        model.baseAnchorage = .dowelled(ratio: 0.005)
        let data = try JSONEncoder().encode(model)
        #expect(try JSONDecoder().decode(StructureModel.self, from: data) == model)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["baseAnchorage"] = nil
        let old = try JSONDecoder().decode(
            StructureModel.self, from: try JSONSerialization.data(withJSONObject: object))
        #expect(old.baseAnchorage == nil)
        #expect(old.fixedBase)
    }
}
