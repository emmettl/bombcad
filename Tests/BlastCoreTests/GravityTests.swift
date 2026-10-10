import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

/// Gravity acting on the air.
@Suite("Gravity")
struct GravityTests {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    private func column(
        _ gravity: AirGravity, cells: SIMD3<Int> = SIMD3(8, 8, 64), cellSize: Float = 1,
        faces: BoundaryFaces = .ground, airModel: AirModel = .idealGas, refinement: Int = 1
    ) throws -> BlastSolver {
        var configuration = SolverConfiguration()
        configuration.gravity = gravity
        configuration.reflectiveFaces = faces
        configuration.airModel = airModel
        configuration.refinement = refinement
        let solver = try BlastSolver(
            device: device, grid: Grid(nx: cells.x, ny: cells.y, nz: cells.z, cellSize: cellSize),
            configuration: configuration)
        solver.fill(uniform: Primitive(density: 1.225, pressure: 101_325))
        return solver
    }

    /// The fastest speed of the air anywhere, m/s.
    private func fastest(_ solver: BlastSolver) -> Float {
        solver.withState { cells in
            cells.map { simd_length(SIMD3($0.momentumX, $0.momentumY, $0.momentumZ)) / $0.density }.max() ?? 0
        }
    }

    @Test(
        "Air at rest in its hydrostatic atmosphere stays at rest, to the bit",
        arguments: [(AirGravity(), AirModel.idealGas), (AirGravity(lapseRate: 0), .idealGas), (AirGravity(), .thermallyPerfect)])
    func restingColumn(gravity: AirGravity, airModel: AirModel) throws {
        let solver = try column(gravity, airModel: airModel)
        let start = solver.withState { Array($0) }
        solver.advance(steps: 200)
        let end = solver.withState { Array($0) }
        let changed = zip(start, end).filter { $0 != $1 }.count
        #expect(changed == 0, "\(changed) cells changed; fastest \(fastest(solver)) m/s")
        // The background's pressure at the top, 63.5 m up, against the barometric formula.
        let top = solver.primitive(4, 4, 63)
        let expected = gravity.atmosphere(at: 63.5, ground: Primitive(density: 1.225, pressure: 101_325))
        #expect(abs(top.pressure / expected.pressure - 1) < 1e-5)
        #expect(abs(101_325 - top.pressure - 1.225 * 9.80665 * 63.5) < 0.01 * 1.225 * 9.80665 * 63.5)
    }
}
