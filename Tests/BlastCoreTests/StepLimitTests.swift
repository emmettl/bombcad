import Foundation
import Metal
import Testing
import simd

@testable import BlastCore
@testable import BlastModel

/// An element distorted past the step's reach is removed rather than left to ring
/// (emmettl/bombcad-work#36): a one-point hexahedron's highest frequency is at most
/// c sqrt(8 sum |grad N_a|^2) (Flanagan and Belytschko), and a whole element at today's step
/// (0.5 of the transit time) sits at 0.866 of the stable limit, 2 over it. Raising the step past
/// that, rather than distorting elements, puts every element past it alike.
@Suite("Elements past the step's reach")
struct StepLimitTests {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    /// A concrete block resting on the ground, 0.4 × 0.2 × 0.2 m in elements of 50 mm, no charge.
    private func block() -> Scenario {
        var material = StructureMaterial.concrete(name: "Elastic", compressiveStrength: 30e6)
        material.tensileStrength = 1e12
        let model = StructureModel(
            solids: [Box(min: SIMD3(0.3, 0.3, 0), max: SIMD3(0.7, 0.5, 0.2))], material: material,
            elementSize: 0.05, fixedBase: true)
        return Scenario(
            name: "Block", domainSize: SIMD3(1, 0.8, 0.6), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(0.1, 0.1, 0.1)), structure: model)
    }

    /// The elements removed after `steps` steps at `safety` times the transit time.
    private func removed(safety: Float, steps: Int = 4) throws -> (removed: Int, total: Int) {
        let solver = try BlastSolver(device: device, scenario: block(), cellSize: 0.1)
        let structure = try #require(solver.structure)
        structure.timeStepSafety = safety
        structure.advance(steps: steps)
        let summary = structure.summary()
        return (summary.erodedElements, summary.activeElements + summary.erodedElements)
    }

    @Test("At today's step, and just below the limit, no whole element is removed")
    func wholeElementsStay() throws {
        for safety: Float in [0.5, 0.55] {
            let (gone, total) = try removed(safety: safety, steps: 40)
            #expect(total == 128 && gone == 0, "\(gone) of \(total) removed at \(safety)")
        }
    }

    @Test("Past the limit (0.866 at 0.5, so 1.04 at 0.6) every element is removed at once")
    func pastTheLimitGoes() throws {
        let (gone, total) = try removed(safety: 0.6)
        #expect(total == 128 && gone == total, "\(gone) of \(total) removed")
    }
}
