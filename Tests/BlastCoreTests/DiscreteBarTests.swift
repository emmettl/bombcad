import Foundation
import Metal
import Testing

@testable import BlastCore
@testable import BlastModel

/// Bars as their own trusses embedded in the elements (`DiscreteBar`), against the smeared bars'
/// checks: elastic sharing, and a tie's cracks and tension stiffening by the Model Code.
@Suite("Discrete bars", .gpuThreads)
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
}
