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

    @Test(
        "The σ-model sees no turbulence in a pure shear or a point source's flow, and Nicoud's value in 3-D strain"
    )
    func sigmaModel() throws {
        let n = 24
        let dx: Float = 0.25
        // The eddy viscosity the first step works out for the velocity field `velocity` (of the cell's
        // centre, measured from the box's middle), with sub-grid mixing `mixing`.
        func viscosity(_ mixing: SubgridMixing, _ velocity: @escaping (SIMD3<Float>) -> SIMD3<Float>) throws
            -> (BlastSolver, [Float])
        {
            let solver = try box(mixing, cells: SIMD3(n, n, n))
            solver.fill { i, j, k in
                let x = (SIMD3<Float>(Float(i), Float(j), Float(k)) + 0.5 - Float(n) / 2) * dx
                return Primitive(density: 1.2, velocity: velocity(x), pressure: 101_325)
            }
            solver.advance(steps: 1)
            return (solver, try #require(solver.eddyViscosities()))
        }
        // The values two cells or more from the box's sides, `within` the given distance of its middle,
        // with that distance.
        func interior(_ solver: BlastSolver, _ values: [Float], within: ClosedRange<Float>) -> [(
            r: Float, nu: Float
        )] {
            (0..<solver.grid.cellCount).compactMap { index in
                let (i, j, k) = (index % n, (index / n) % n, index / (n * n))
                guard [i, j, k].allSatisfy({ $0 >= 2 && $0 < n - 2 }) else { return nil }
                let r = simd_length((SIMD3<Float>(Float(i), Float(j), Float(k)) + 0.5 - Float(n) / 2) * dx)
                return within.contains(r) ? (r, values[index]) : nil
            }
        }
        // A pure shear: Smagorinsky's (C Δ)² |du/dy|, the σ-model nothing.
        let shear: (SIMD3<Float>) -> SIMD3<Float> = { SIMD3(10 * $0.y, 0, 0) }
        let (s1, smagorinsky) = try viscosity(SubgridMixing(), shear)
        let (s2, sigma) = try viscosity(.sigma, shear)
        let expected: Float = (0.17 * dx) * (0.17 * dx) * 10
        #expect(interior(s1, smagorinsky, within: 0...10).allSatisfy { abs($0.nu / expected - 1) < 1e-3 })
        #expect(interior(s2, sigma, within: 0...10).allSatisfy { $0.nu < 1e-4 * expected })
        // The irrotational flow from a point source (the unburnt gas's ahead of a spherical flame).
        // Exactly sampled, its gradient is axisymmetric and the σ-model's operator zero; the grid's
        // differences are not quite, and leave a share of Smagorinsky's (C Δ)² √12 / r³ that falls as
        // (Δ / r)²: a quarter at five cells, a twelfth at ten.
        let source: (SIMD3<Float>) -> SIMD3<Float> = { x in x / pow(max(simd_length(x), 0.1), 3) }
        let (s3, point) = try viscosity(.sigma, source)
        func share(_ cell: (r: Float, nu: Float)) -> Float {
            let length: Float = 0.17 * dx
            let smagorinsky: Float = length * length * Float(12).squareRoot() / (cell.r * cell.r * cell.r)
            return cell.nu / smagorinsky
        }
        let near = interior(s3, point, within: 1.25...1.5).map(share)
        let far = interior(s3, point, within: 2.25...2.5).map(share)
        #expect(near.allSatisfy { $0 < 0.5 }, "largest share \(near.max() ?? 0) at five cells")
        let mean = far.reduce(0, +) / Float(max(far.count, 1))
        #expect(mean < 0.15, "mean share \(mean) at nine cells")
        // A uniform gradient of singular values 30, 20 and 10 /s: σ₃(σ₁ − σ₂)(σ₂ − σ₃)/σ₁² = 10/9 /s.
        let strain: (SIMD3<Float>) -> SIMD3<Float> = { SIMD3(10 * $0.y, 20 * $0.z, -30 * $0.x) }
        let (s4, values) = try viscosity(.sigma, strain)
        let nicoud: Float = (1.35 * dx) * (1.35 * dx) * 10 / 9
        #expect(interior(s4, values, within: 0...10).allSatisfy { abs($0.nu / nicoud - 1) < 1e-3 })
    }
}
