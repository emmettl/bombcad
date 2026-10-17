import Foundation
import Testing

@testable import BlastCore

@Suite("A casing's metal and dimensions")
struct FragmentCasingTests {
    @Test("The metal is the description's distribution and density, and sets both")
    func metal() throws {
        var spec = FragmentSpec()
        #expect(spec.metal == .steel)
        spec.metal = .castIron
        #expect(spec.massExponent == 1 && spec.fragmentDensity == 7200 && spec.metal == .castIron)
        // Any other pair is no named metal, and setting none leaves it.
        spec.fragmentDensity = 2700
        #expect(spec.metal == nil)
        spec.metal = nil
        #expect(spec.fragmentDensity == 2700)
        // A cast-iron description saved and read back is cast iron still.
        spec.metal = .castIron
        let read = try JSONDecoder().decode(FragmentSpec.self, from: JSONEncoder().encode(spec))
        #expect(read.metal == .castIron)
    }

    @Test("Dimensions hold the charge and weigh the casing's mass, and give Mott's standing")
    func dimensions() throws {
        var spec = FragmentSpec()
        spec.casingMass = 10
        spec.count = 2000
        let cylinder = try #require(spec.casingDimensions(chargeMass: 100))
        // 100 kg at 1,600 kg/m³ in a cylinder twice as long as wide: π d³ / 2.
        #expect(abs(Float.pi * pow(cylinder.diameter, 3) / 2 - 100.0 / 1600) < 1e-6)
        // Its side wall, π d (2d) t, weighs the casing.
        #expect(abs(7850 * .pi * 2 * cylinder.diameter * cylinder.diameter * cylinder.thickness - 10) < 1e-3)
        spec.casing = .sphere
        let sphere = try #require(spec.casingDimensions(chargeMass: 100))
        #expect(abs(Float.pi * pow(sphere.diameter, 3) / 6 - 100.0 / 1600) < 1e-6)
        #expect(abs(7850 * .pi * sphere.diameter * sphere.diameter * sphere.thickness - 10) < 1e-3)
        #expect(spec.casingDimensions(chargeMass: 0) == nil)
        // With them the fragments follow Mott, and their standing is an approximation.
        spec.wallThickness = sphere.thickness
        spec.innerDiameter = sphere.diameter
        try spec.validate()
        #expect(spec.mottMeanMass != nil)
        let scenario = Scenario(
            name: "Cased", domainSize: SIMD3(repeating: 40), boxes: [],
            charge: Charge(mass: 100, position: SIMD3(20, 20, 1)))
        let standing = SceneStanding(StandingInputs(scenario: scenario, cellSize: 0.5, fragments: spec))
        #expect(standing.results.first { $0.kind == .fragments }?.level == .approximation)
        spec.wallThickness = nil
        spec.innerDiameter = nil
        let plain = SceneStanding(StandingInputs(scenario: scenario, cellSize: 0.5, fragments: spec))
        #expect(plain.results.first { $0.kind == .fragments }?.level == .illustrative)
    }
}
