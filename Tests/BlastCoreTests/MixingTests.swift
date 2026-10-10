import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

/// Sub-grid turbulent mixing in the air.
@Suite("Sub-grid mixing")
struct MixingTests {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    private func box(_ mixing: SubgridMixing?, cells: SIMD3<Int>, faces: BoundaryFaces = .all) throws
        -> BlastSolver
    {
        var configuration = SolverConfiguration()
        configuration.mixing = mixing
        configuration.reflectiveFaces = faces
        return try BlastSolver(
            device: device, grid: Grid(nx: cells.x, ny: cells.y, nz: cells.z, cellSize: 0.25),
            configuration: configuration)
    }

    @Test("In a closed box a swirling hot bubble's mass and energy are conserved with mixing")
    func conservation() throws {
        let solver = try box(SubgridMixing(), cells: SIMD3(24, 24, 24))
        solver.fill { i, j, k in
            let x = (SIMD3<Float>(Float(i), Float(j), Float(k)) + 0.5) * 0.25 - 3
            let hot = simd_length(x) < 1.5
            let swirl = SIMD3<Float>(-x.y, x.x, 0) * (hot ? 20 : 0)
            return Primitive(density: hot ? 0.6 : 1.2, velocity: swirl, pressure: 101_325)
        }
        let before = solver.totals()
        solver.advance(steps: 100)
        let after = solver.totals()
        #expect(abs(after.mass / before.mass - 1) < 1e-6, "mass \(before.mass) -> \(after.mass)")
        #expect(abs(after.energy / before.energy - 1) < 1e-6, "energy \(before.energy) -> \(after.energy)")
    }

    @Test("A planar shock, compression without rotation, passes as without mixing")
    func shockUnchanged() throws {
        func run(_ mixing: SubgridMixing?) throws -> [Float] {
            let solver = try box(mixing, cells: SIMD3(128, 4, 4), faces: [])
            solver.fill { i, _, _ in
                i < 32 ? Primitive(density: 4, pressure: 1e6) : Primitive(density: 1.2, pressure: 101_325)
            }
            solver.advance(steps: 80)
            return (0..<128).map { solver.primitive($0, 2, 2).pressure }
        }
        let with = try run(SubgridMixing())
        let without = try run(nil)
        let worst = zip(with, without).map { abs($0 - $1) / $1 }.max() ?? 0
        #expect(worst < 1e-4, "pressure differs by \(worst) of itself")
    }

    @Test("A shear layer spreads faster with mixing than with the grid's own diffusion alone")
    func shearSpreads() throws {
        func thickness(_ mixing: SubgridMixing?) throws -> Double {
            let solver = try box(mixing, cells: SIMD3(8, 8, 64), faces: [])
            solver.fill { _, _, k in
                let z = (Float(k) + 0.5 - 32) * 0.25
                return Primitive(density: 1.2, velocity: SIMD3(20 * tanh(z / 0.25), 0, 0), pressure: 101_325)
            }
            solver.advance(until: 0.2)
            return (0..<64).reduce(0.0) { sum, k in
                let u = Double(solver.primitive(4, 4, k).velocity.x) / 40
                return sum + (0.25 - u * u) * 0.25
            }
        }
        let with = try thickness(SubgridMixing())
        let without = try thickness(nil)
        #expect(with > 1.1 * without, "momentum thickness \(with) m with mixing, \(without) m without")
    }
}
