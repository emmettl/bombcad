import Foundation
import Testing

@testable import BlastCore

@Suite("Slabs under contact charges")
struct ContactSlabTests {
    struct Fixture: Decodable {
        struct Group: Decodable {
            var thickness: Float
            var semtex: Float
            var scaledThickness: Float
            var breach: Bool
            var spallDiameter: [Float]
            var debrisMass: [Float]
            var tipVelocity: [Float]

            enum CodingKeys: String, CodingKey {
                case thickness = "thickness_m"
                case semtex = "semtex10_g"
                case scaledThickness, breach
                case spallDiameter = "spallDiameter_cm"
                case debrisMass = "debrisMass_kg"
                case tipVelocity = "vxMax_m_s"
            }
        }
        var groups: [Group]
    }

    static let fixture = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "Fixtures/Hupfauf/slabs.json")

    @Test("The benchmark's slabs carry the fixture's measurements")
    func matchesFixture() throws {
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: Self.fixture))
        #expect(fixture.groups.count == ContactSlabTest.tests.count)
        for test in ContactSlabTest.tests {
            let group = try #require(
                fixture.groups.first {
                    abs($0.thickness - test.thickness) < 1e-6
                        && abs($0.semtex - test.semtex * 1000) < 1e-3
                })
            #expect(group.breach == test.breach)
            #expect(abs(group.scaledThickness - test.scaledThickness) < 0.01)
            #expect(group.spallDiameter.count == test.spallDiameter.count)
            for (measured, used) in zip(group.spallDiameter, test.spallDiameter) {
                #expect(abs(measured / 100 - used) < 1e-5)
            }
            #expect(group.debrisMass == test.debrisMass)
            #expect(group.tipVelocity == test.tipVelocity)
            // The thesis's fit for the debris's fastest velocity passes within 10 m/s of each group.
            let mean = group.tipVelocity.reduce(0, +) / Float(group.tipVelocity.count)
            #expect(abs(test.fittedTipVelocity - mean) < 10)
        }
    }
}
