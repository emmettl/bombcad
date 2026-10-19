import Foundation
import Testing

@testable import BlastModel

/// Bars as their own trusses embedded in the elements (`DiscreteBar`), against the smeared bars'
/// checks: elastic sharing, and a tie's cracks and tension stiffening by the Model Code.
@Suite("Discrete bars")
struct DiscreteBarTests {
    @Test("Discrete bars are saved with the model, and a body without them is unchanged")
    func saved() throws {
        var model = StructureModel(solids: [Box(min: .zero, max: SIMD3(1, 0.1, 0.1))], elementSize: 0.05)
        let data = try JSONEncoder().encode(model)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["discreteBars"] == nil && object["barsAsTrusses"] == nil)
        model.discreteBars = [
            DiscreteBar(start: SIMD3(0.01, 0.05, 0.05), end: SIMD3(0.99, 0.05, 0.05), diameter: 0.012)
        ]
        model.barsAsTrusses = true
        model.trussDiameter = 0.016
        #expect(try JSONDecoder().decode(StructureModel.self, from: JSONEncoder().encode(model)) == model)
    }

    @Test("A layer's smeared bars laid as discrete bars keep its steel, at its depth")
    func fromLayers() {
        var model = StructureModel(solids: [], elementSize: 0.0254 / 8)
        let slab = Box(min: SIMD3(0, 0, 1), max: SIMD3(1.6256, 0.857, 1.1016))
        // The contest slab's mat: nine No. 3 bars along x, No. 3 at 12 in across them.
        model.addMat(
            to: slab, thicknessAxis: 2, areaPerMetre: 9 * 71e-6 / 0.857,
            transverseAreaPerMetre: 71e-6 / 0.3048,
            longitudinalAxis: 0, depth: 0.0254, faces: (low: true, high: false))
        let bars = model.barsFromLayers(diameter: 0.0095)
        let along = bars.filter { abs($0.end.x - $0.start.x) > 1 }
        let across = bars.filter { abs($0.end.y - $0.start.y) > 0.5 }
        #expect(along.count == 9 && across.count == 5, "\(along.count) and \(across.count)")
        let area = along.map(\.area).reduce(0, +)
        #expect(abs(area - 9 * 71e-6) / (9 * 71e-6) < 1e-4)
        #expect(along.allSatisfy { abs($0.start.z - 1.0254) < 1e-5 })
    }

    @Test("A mat of discrete bars lies across the slab at its spacing and depth")
    func mat() {
        var model = StructureModel(solids: [], elementSize: 0.025)
        let slab = Box(min: SIMD3(0, 0, 0), max: SIMD3(2, 1, 0.1))
        model.addBarMat(to: slab, thicknessAxis: 2, along: 0, spacing: 0.2, diameter: 0.01, depth: 0.025)
        #expect(model.discreteBars.count == 10)
        #expect(model.discreteBars.filter { abs($0.start.z - 0.025) < 1e-6 }.count == 5)
        #expect(model.discreteBars.filter { abs($0.start.z - 0.075) < 1e-6 }.count == 5)
        #expect(abs(model.discreteBars[0].start.y - 0.1) < 1e-6)
    }
}
