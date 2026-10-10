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
        arguments: [
            (AirGravity(), AirModel.idealGas), (AirGravity(lapseRate: 0), .idealGas),
            (AirGravity(), .thermallyPerfect),
        ])
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

    @Test("Refined in two levels, and over a hill, air at rest stays at rest to the bit")
    func restingRefinedAndHill() throws {
        // Every block refined, twice: the fine cells are filled with the coarse cells' deviations
        // from the background, none, and their own background.
        var configuration = SolverConfiguration()
        configuration.gravity = AirGravity()
        configuration.refinement = 2
        configuration.refinementLevels = 2
        configuration.refinementThreshold = -1
        configuration.refinementMemory = 256 << 20
        let refined = try BlastSolver(
            device: device, grid: Grid(nx: 8, ny: 8, nz: 32, cellSize: 1), configuration: configuration)
        refined.fill(uniform: Primitive(density: 1.225, pressure: 101_325))
        let result = refined.advance(steps: 100)
        #expect(result.finerRefinedTiles > 0)
        #expect(fastest(refined) == 0, "refined: \(fastest(refined)) m/s")
        // A closed box over a hill, its terrain solid in the mask.
        var scenario = Scenario(
            name: "Hill", domainSize: SIMD3(20, 12, 10), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(5, 6, 1)))
        scenario.reflectiveFaces = .all
        scenario.terrain = .hill(
            domain: scenario.domainSize, spacing: 0.4, centre: SIMD2(10, 6), height: 4, radius: 2.5)
        var hillConfiguration = SolverConfiguration()
        hillConfiguration.gravity = AirGravity()
        let hill = try BlastSolver(
            device: device, scenario: scenario, cellSize: 0.5, configuration: hillConfiguration)
        hill.advance(steps: 100)
        #expect(fastest(hill) == 0, "hill: \(fastest(hill)) m/s")
    }

    @Test("In a closed box the gas's energy and its potential energy are conserved together")
    func energyWithPotential() throws {
        let solver = try column(
            AirGravity(lapseRate: 0), cells: SIMD3(16, 16, 32), cellSize: 0.5, faces: .all)
        // A hot bubble at the surrounding pressure, which rises.
        solver.mutateState { cells in
            for k in 0..<32 {
                for j in 0..<16 {
                    for i in 0..<16 {
                        let x = (SIMD3<Float>(Float(i), Float(j), Float(k)) + 0.5) * 0.5
                        guard simd_distance(x, SIMD3(4, 4, 4)) < 2 else { continue }
                        let n = solver.grid.index(i, j, k)
                        cells[n].density *= 0.5
                    }
                }
            }
        }
        solver.restart()
        func total() -> Double {
            solver.withState { cells in
                var sum = 0.0
                for k in 0..<32 {
                    for j in 0..<16 {
                        for i in 0..<16 {
                            let c = cells[solver.grid.index(i, j, k)]
                            sum += Double(c.energy) + Double(c.density) * 9.80665 * (Double(k) + 0.5) * 0.5
                        }
                    }
                }
                return sum * 0.125
            }
        }
        let before = total()
        let kinetic = { () -> Double in
            solver.withState { cells in
                cells.reduce(0.0) { $0 + 0.5 * Double($1.momentumZ * $1.momentumZ) / Double($1.density) }
                    * 0.125
            }
        }
        solver.advance(until: 0.5)
        let after = total()
        #expect(kinetic() > 1, "the bubble moved only \(kinetic()) J")
        #expect(abs(after - before) < 1e-6 * before, "\(before) J -> \(after) J")
    }

    @Test("A light sphere released at rest first accelerates as potential flow has it, g Δρ / (ρ + ρa / 2)")
    func bubbleAcceleration() throws {
        let solver = try column(
            AirGravity(lapseRate: 0), cells: SIMD3(48, 48, 64), cellSize: 0.25, faces: .ground)
        let centre = SIMD3<Float>(6, 6, 6)
        let radius: Float = 2
        // Half the surrounding density at the same pressure: twice as hot.
        solver.mutateState { cells in
            for k in 0..<64 {
                for j in 0..<48 {
                    for i in 0..<48 {
                        let x = (SIMD3<Float>(Float(i), Float(j), Float(k)) + 0.5) * 0.25
                        guard simd_distance(x, centre) < radius else { continue }
                        cells[solver.grid.index(i, j, k)].density *= 0.5
                    }
                }
            }
        }
        solver.restart()
        // The light gas's mean upward velocity, from the momentum of the cells that started light.
        let light = solver.withState { cells in
            (0..<cells.count).filter { cells[$0].density < 0.9 }
        }
        let time = 0.05
        solver.advance(until: time)
        let speed = solver.withState { cells in
            light.reduce(0.0) { $0 + Double(cells[$1].momentumZ / cells[$1].density) } / Double(light.count)
        }
        let expected = 9.80665 * 0.5 / (0.5 + 0.5) * time
        #expect(abs(speed / expected - 1) < 0.15, "\(speed) m/s against \(expected)")
    }

    @Test("Under gravity, skipping still air gives the same answer to the bit, with afterburning")
    func stillAirSkipped() throws {
        func run(skip: Bool) throws -> (state: [CellState], peak: [Float]) {
            var configuration = SolverConfiguration()
            configuration.gravity = AirGravity()
            configuration.afterburning = true
            configuration.skipStillAir = skip
            let solver = try BlastSolver(
                device: device, scenario: ScenarioPreset.streetCanyon.scenario, cellSize: 0.5,
                configuration: configuration)
            solver.advance(steps: 60)
            let grid = solver.grid
            var peak: [Float] = []
            for k in stride(from: 0, to: grid.nz, by: 3) {
                for j in stride(from: 0, to: grid.ny, by: 3) {
                    for i in stride(from: 0, to: grid.nx, by: 3) {
                        peak.append(solver.peakOverpressure(i, j, k))
                    }
                }
            }
            return (solver.withState { Array($0) }, peak)
        }
        let skipped = try run(skip: true)
        let swept = try run(skip: false)
        #expect(skipped.state == swept.state)
        #expect(skipped.peak == swept.peak)
    }

    @Test("Under gravity, overpressure is against the ambient pressure at its height")
    func localOverpressure() throws {
        var configuration = SolverConfiguration()
        configuration.gravity = AirGravity()
        configuration.reflectiveFaces = .ground
        let solver = try BlastSolver(
            device: device, grid: Grid(nx: 8, ny: 8, nz: 64, cellSize: 1), configuration: configuration)
        solver.fill(uniform: Primitive(density: 1.225, pressure: 101_325))
        solver.setGauges(cells: [(4, 4, 0), (4, 4, 60)])
        solver.advance(steps: 50)
        var largest: Float = 0
        for k in 0..<64 { largest = max(largest, abs(solver.peakOverpressure(4, 4, k))) }
        #expect(largest == 0, "peak overpressure in air at rest \(largest) Pa")
        for history in solver.gaugeHistories {
            let worst = history.map { abs($0.pressure - 101_325) }.max() ?? 0
            #expect(worst < 0.01, "a gauge in air at rest read \(worst) Pa")
        }
    }
}
