import Foundation
import Metal
import Testing
import simd

@testable import BlastCore
@testable import BlastModel

/// Shells at a pitch (`Inclination`): planes laid through their solids' boxes, meshed in their own
/// planes, their elements taking their axes from their corners.
@Suite("Shells at a pitch", .gpuThreads)
struct InclinedShellTests {
    let material = StructureMaterial.elastic(density: 2400, youngsModulus: 30e9, poissonRatio: 0.2)

    /// The tip's deflection, square to the plate, of a 2 m plate cantilevered from its low edge under
    /// its weight: laid at `pitch`, or flat under the weight's share across it (cos pitch).
    private func cantilever(pitch degrees: Float, flat: Bool) throws -> Float {
        let device = try #require(MTLCreateSystemDefaultDevice(), "This test needs a Metal device")
        let pitch = degrees * .pi / 180
        var model: StructureModel
        if flat {
            model = StructureModel(
                solids: [Box(min: SIMD3(0, 0, 4.95), max: SIMD3(1, 2, 5.05))], material: material,
                elementSize: 0.125, fixedBase: false)
        } else {
            model = StructureModel(
                solids: [Box(min: SIMD3(0, 0, 5), max: SIMD3(1, 2 * cos(pitch), 5 + 2 * sin(pitch)))],
                material: material,
                elementSize: 0.125, fixedBase: false)
            model.setInclination(Inclination(rise: 1, upwards: true, thickness: 0.1), of: 0)
        }
        model.elementKind = .shell
        // Clamped along its low edge, 5 m up, clear of the floor.
        model.supports = [Box(min: SIMD3(-0.01, -0.01, 4.94), max: SIMD3(1.01, 0.01, 5.06))]
        let solver = try ShellSolver(device: device, model: model)
        if flat { solver.gravity = 9.81 * cos(pitch) }
        solver.damping = 400
        solver.advance(steps: Int((0.3 / Double(solver.criticalTimeStep)).rounded()))
        let normal = flat ? SIMD3<Float>(0, 0, 1) : SIMD3(0, -sin(pitch), cos(pitch))
        let tip = flat ? SIMD3<Float>(0.5, 2, 5) : SIMD3(0.5, 2 * cos(pitch), 5 + 2 * sin(pitch))
        var deflection: Float = 0
        let positions = solver.referencePositions
        solver.mutateNodes { nodes in
            let n = positions.indices.min {
                simd_distance(positions[$0], tip) < simd_distance(positions[$1], tip)
            }!
            deflection = -simd_dot(nodes[n].displacement, normal)
        }
        return deflection
    }

    @Test(
        "Cantilevered at 30°, a plate bends square to itself as the flat one under its weight's share across it"
    )
    func cantilevered() throws {
        let pitched = try cantilever(pitch: 30, flat: false)
        let flat = try cantilever(pitch: 30, flat: true)
        // Kirchhoff's strip, q L⁴ / 8D, for scale: about 1.6 mm.
        #expect(flat > 1e-3 && flat < 3e-3, "\(flat)")
        #expect(abs(pitched / flat - 1) < 0.02, "\(pitched) against \(flat)")
    }
}
