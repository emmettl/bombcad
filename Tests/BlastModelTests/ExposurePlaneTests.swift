import Foundation
import Testing

@testable import BlastModel

@Suite("Spatial exposure and diagnostic profiling", .serialized)
struct ExposurePlaneTests {
    @Test("Street fixtures retain common owners and reject overlapping bodies")
    func fixtures() throws {
        let isolated = try StreetInteractionStudy.make(.isolated)
        let pair = try StreetInteractionStudy.make(.pair)
        let street = try StreetInteractionStudy.make(.street)
        #expect(
            isolated.structuralObjects.count == 1 && pair.structuralObjects.count == 2
                && street.structuralObjects.count == 4)
        #expect(isolated.structuralObjects[0].id == pair.structuralObjects[0].id)
        #expect(pair.structuralObjects.map(\.id) == Array(street.structuralObjects.prefix(2)).map(\.id))
        for scene in [isolated, pair, street] {
            try scene.validateObjectOwnership()
            try scene.validateStructuralSeparation()
            #expect(!scene.chargeIsBlocked)
        }
    }
}
