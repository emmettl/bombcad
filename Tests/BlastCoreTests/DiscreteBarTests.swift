import Foundation
import Metal
import Testing

@testable import BlastCore

/// Bars as their own trusses embedded in the elements (`DiscreteBar`), against the smeared bars'
/// checks: elastic sharing, and a tie's cracks and tension stiffening by the Model Code.
@Suite("Discrete bars")
struct DiscreteBarTests {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    @Test("Uncracked, a tie's discrete bars carry E_s A ε, slipping or not")
    func elastic() throws {
        for bond in [nil, BondSlip(condition: .pullOut, barDiameter: TieBenchmark.diameter)] {
            let result = try TieBenchmark.run(
                device: device, elementSize: 0.05, bond: bond, strain: 1e-4, discrete: true)
            // Two bars of half the 2% each.
            let area = TieBenchmark.ratio * TieBenchmark.side * TieBenchmark.side / 2
            let expected = 200e9 * area * 1e-4
            let mean = result.bar.forces.reduce(0, +) / Float(result.bar.forces.count)
            #expect(abs(mean - expected) / expected < 0.1, "\(mean) N against \(expected) N")
            // Concrete and steel together.
            let concrete = TieBenchmark.material.youngsModulus * TieBenchmark.side * TieBenchmark.side * 1e-4
            #expect(abs(result.load - concrete - 2 * expected) / result.load < 0.1, "\(result.load) N")
        }
    }

    @Test(
        "A tie's discrete bars that slip crack it at the Model Code's spacing and stiffen as it says, on two meshes"
    )
    func tie() throws {
        let bond = BondSlip(condition: .pullOut, barDiameter: TieBenchmark.diameter)
        let transfer = TieBenchmark.transferLength()
        let expected = TieBenchmark.expectedLoad(
            strain: 1.5e-3, beta: 0.4, strength: TieBenchmark.material.tensileStrength)
        for h: Float in [0.02, 0.01] {
            let result = try TieBenchmark.run(device: device, elementSize: h, bond: bond, discrete: true)
            // (8 and 7 cracks, 70.1 and 71.9 kN, when written.)
            let cracks = Float(result.spacings.count + 1)
            #expect(
                cracks >= 1 / (2 * transfer) - 1 && cracks <= 1 / transfer + 1, "\(cracks) cracks on \(h) m")
            #expect(abs(result.load - expected) / expected < 0.12, "\(result.load / 1000) kN on \(h) m")
            // The bars carry most at the cracks and less between them, where the concrete takes
            // tension through the bond.
            let forces = result.bar.forces
            #expect((forces.max() ?? 0) > 1.15 * (forces.min() ?? 0), "\(forces)")
        }
    }

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

    @Test("A bar that leaves the concrete is refused")
    func outside() {
        var model = StructureModel(
            solids: [Box(min: SIMD3(0, 0, 1), max: SIMD3(1, 0.1, 1.1))],
            material: TieBenchmark.material, elementSize: 0.05, fixedBase: false)
        model.discreteBars = [
            DiscreteBar(start: SIMD3(0.5, 0.05, 1.05), end: SIMD3(1.5, 0.05, 1.05), diameter: 0.012)
        ]
        #expect(throws: BlastError.self) { _ = try StructureSolver(device: device, model: model) }
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
