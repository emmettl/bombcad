import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

@Suite("Congestion below the grid", .serialized, .gpuThreads)
struct CongestionTests {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    /// A rig's lattice: 43 mm pipes at 0.2 m along all three axes (MERGE's array A).
    static let lattice = CongestionArray(
        name: "Lattice", region: Box(min: SIMD3(1, 1, 1), max: SIMD3(3, 3, 3)), diameter: 0.043, pitch: 0.2,
        axes: [0, 1, 2])

    private func solver(_ scenario: Scenario, cellSize: Float, periodic: Bool = false) throws -> BlastSolver {
        var configuration = SolverConfiguration()
        configuration.skipStillAir = false
        configuration.periodicSides = periodic
        return try BlastSolver(
            device: device, scenario: scenario, cellSize: cellSize, configuration: configuration)
    }

    private func closedBox(_ arrays: [CongestionArray]) -> Scenario {
        var scenario = Scenario(
            name: "Box", domainSize: SIMD3(4, 4, 4), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(0.5, 0.5, 0.5)))
        scenario.reflectiveFaces = .all
        scenario.congestion = arrays
        return scenario
    }

    @Test("The array's fields: its volume blockage, and its drag with the row's blockage factor")
    func fields() {
        let array = Self.lattice
        // Three sets of 43 mm pipes at 0.2 m: 3 × π 0.043² / 4 / 0.2² = 10.9%, MERGE's 10%
        // nominal less the joints counted twice.
        #expect(abs(array.volumeBlockage - 0.1089) < 0.001)
        let field = CongestionField(arrays: [array], grid: Grid(nx: 16, ny: 16, nz: 16, cellSize: 0.25))
        let inside = field.porosityDrag[8 + 16 * (8 + 16 * 8)]
        #expect(abs(inside.x - (1 - array.volumeBlockage)) < 1e-5)
        // Across x, the pipes along y and z: 2 × 0.043 / 0.2² m⁻¹, times C_D 1.2, the row factor
        // (1 − 0.1075)/(0.785)² = 1.449, and ½.
        let expected = 0.5 * 1.2 * 1.449 * 2 * 0.043 / 0.04
        #expect(abs(inside.y / Float(expected) - 1) < 0.002, "\(inside.y)")
        #expect(inside.y == inside.z && inside.z == inside.w)
        // Outside the region, nothing; at its edge, the share of the cell inside.
        #expect(field.porosityDrag[0] == SIMD4(1, 0, 0, 0))
    }

    @Test("Still air in and around porous cells stays still")
    func stillAirStaysStill() throws {
        let solver = try solver(closedBox([Self.lattice]), cellSize: 0.25)
        solver.fill(uniform: Primitive(density: 1.225, pressure: 101_325))
        solver.restart()
        solver.advance(steps: 60)
        var fastest: Float = 0
        var furthest: Float = 0
        for k in 0..<16 {
            for j in 0..<16 {
                for i in 0..<16 {
                    let air = solver.primitive(i, j, k)
                    fastest = max(fastest, simd_length(air.velocity))
                    furthest = max(furthest, abs(air.pressure - 101_325))
                }
            }
        }
        #expect(fastest < 1e-4, "\(fastest) m/s")
        #expect(furthest < 0.05, "\(furthest) Pa")
    }

    @Test("The porous cells conserve the air's mass, β_v ρ summed, as a pulse crosses them")
    func massConserved() throws {
        let scenario = closedBox([Self.lattice])
        let solver = try solver(scenario, cellSize: 0.25)
        let field = CongestionField(arrays: scenario.congestion!, grid: solver.grid)
        solver.mutateState { cells in
            for k in 0..<16 {
                for j in 0..<16 {
                    for i in 0..<16 {
                        let high = i < 4
                        cells[solver.grid.index(i, j, k)] = CellState(
                            Primitive(density: high ? 2.0 : 1.225, pressure: high ? 300_000 : 101_325),
                            gamma: 1.4)
                    }
                }
            }
        }
        solver.restart()
        func mass() -> Double {
            var total = 0.0
            for k in 0..<16 {
                for j in 0..<16 {
                    for i in 0..<16 {
                        let index = solver.grid.index(i, j, k)
                        total +=
                            Double(field.porosityDrag[index].x) * Double(solver.primitive(i, j, k).density)
                    }
                }
            }
            return total
        }
        let before = mass()
        let result = solver.advance(steps: 80)
        #expect(result.isStable)
        #expect(abs(mass() / before - 1) < 2e-6, "\(mass() / before - 1)")
    }

    @Test("A uniform stream through the obstacles slows as their drag has it, u = u₀ / (1 + ½ CR u₀ t)")
    func dragSlowsStream() throws {
        var scenario = Scenario(
            name: "Stream", domainSize: SIMD3(2, 2, 1), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(0.1, 0.1, 0.1)))
        scenario.reflectiveFaces = .all
        scenario.congestion = [
            CongestionArray(
                region: Box(min: .zero, max: SIMD3(2, 2, 1)), diameter: 0.02, pitch: 0.2, axes: [2])
        ]
        let solver = try solver(scenario, cellSize: 0.25, periodic: true)
        let speed: Float = 20
        solver.fill(uniform: Primitive(density: 1.225, velocity: SIMD3(speed, 0, 0), pressure: 101_325))
        solver.restart()
        let field = CongestionField(arrays: scenario.congestion!, grid: solver.grid)
        let drag = field.porosityDrag[solver.grid.index(4, 4, 2)].y
        solver.advance(until: 0.05)
        let expected = speed / (1 + drag * speed * Float(solver.time))
        let measured = solver.primitive(4, 4, 2).velocity.x
        #expect(abs(measured / expected - 1) < 0.01, "\(measured) against \(expected) m/s")
        #expect(measured < 0.99 * speed)
    }
}
