import Foundation
import Metal
import Testing
import simd

@testable import BlastCore
@testable import BlastModel

/// The strain rate the rate laws see averaged over a fixed time (`strainRateWindow`) rather than
/// over the last 50 steps.
@Suite("Strain-rate window", .gpuThreads)
struct StrainRateWindowTests {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    /// A concrete prism stretched along x at a steady rate from rest, on the step its elements
    /// allow divided by `divisor`: the averaged strain rate of a middle element, over the steady
    /// rate, once `window` has passed, or without one, once fifty of the undivided steps have.
    private func averagedRate(window: Float?, divisor: Float) throws -> Float {
        let h: Float = 0.01
        let prism = Box(min: SIMD3(0, 0, 1), max: SIMD3(0.1, 0.03, 1.03))
        var material = StructureMaterial.concrete(name: "C30", compressiveStrength: 30e6)
        material.poissonRatio = 0
        var model = StructureModel(solids: [prism], material: material, elementSize: h, fixedBase: false)
        model.strainRateWindow = window
        let solver = try StructureSolver(device: device, model: model)
        solver.gravity = 0
        solver.groundContact = false
        solver.stepOverride = solver.stableTimeStep / divisor
        // 0.01 m/s over 0.1 m: 0.1 per second, far below cracking within the run.
        let speed: Float = 0.01
        solver.mutateNodes { nodes in
            for k in 0...solver.ez {
                for j in 0...solver.ey {
                    for i in 0...solver.ex {
                        let n = solver.nodeIndex(i, j, k)
                        nodes[n].isPrescribed = true
                        nodes[n].velocity = SIMD3(speed * Float(i) / Float(solver.ex), 0, 0)
                    }
                }
            }
        }
        let time = Double(window ?? 50 * solver.stableTimeStep)
        solver.advance(steps: Int((time / Double(solver.criticalTimeStep)).rounded()))
        // The equivalent (von Mises) rate of a uniaxial stretch at rate r is r √(2/3).
        let steady = speed / 0.1 * (2.0 / 3.0).squareRoot()
        return solver.strainRate(solver.ex / 2, 1, 1) / steady
    }

    @Test("A window in time averages the same whatever the step; fifty steps do not")
    func stepIndependence() throws {
        let window: Float = 1e-4
        let coarse = try averagedRate(window: window, divisor: 1)
        let fine = try averagedRate(window: window, divisor: 2)
        // After one window, a first-order average of a steady rate has reached 1 − 1/e.
        #expect(abs(coarse - (1 - exp(-1))) < 0.03, "\(coarse)")
        #expect(abs(fine - coarse) < 0.02, "\(coarse) against \(fine)")
        // Fifty steps: after fifty of the undivided steps the average has reached 1 − 1/e on them,
        // but 1 − 1/e² on half-steps, whose fifty last half as long.
        let byStepsCoarse = try averagedRate(window: nil, divisor: 1)
        let byStepsFine = try averagedRate(window: nil, divisor: 2)
        #expect(abs(byStepsCoarse - (1 - exp(-1))) < 0.03, "\(byStepsCoarse)")
        #expect(abs(byStepsFine - (1 - exp(-2))) < 0.03, "\(byStepsFine)")
    }
}
