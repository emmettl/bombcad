import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

/// The terrain's ground surface as cut cells.
@Suite("Terrain cut cells")
struct TerrainCutCellTests {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    private func cut() -> SolverConfiguration {
        var configuration = SolverConfiguration()
        configuration.terrainCutCells = true
        return configuration
    }

    @Test("Level ground part way up a cell: its share, apertures, wall and the cell its rest goes to")
    func level() {
        let grid = Grid(nx: 4, ny: 3, nz: 6, cellSize: 0.5)
        let domain = SIMD3<Float>(2, 1.5, 3)
        // 0.65 m: the second cell is 0.7 full.
        let high = TerrainCutGeometry(
            terrain: .sampled(domain: domain, spacing: 0.5) { _ in 0.65 }, grid: grid)
        let cell = high.record(1, 1, 1)
        #expect(
            abs(cell.x - 0.7) < 1e-5 && abs(cell.y - 0.7) < 1e-5 && abs(cell.z - 0.7) < 1e-5 && cell.w == 0)
        #expect(high.record(1, 1, 0) == .zero && high.record(1, 1, 2) == .one)
        #expect(high.column(1, 1).w == 1)
        #expect(high.cutColumns.count == grid.nx * grid.ny)
        let wall = high.walls[Int(high.column(1, 1).x)]
        #expect(
            simd_distance(SIMD3(wall.x, wall.y, wall.z), SIMD3(0, 0, -1)) < 1e-6 && abs(wall.w - 1) < 1e-6)
        // 0.9 m: the second cell is 0.2 full, and passes the rest of its difference to the one above.
        let low = TerrainCutGeometry(terrain: .sampled(domain: domain, spacing: 0.5) { _ in 0.9 }, grid: grid)
        #expect(abs(low.alpha(1, 1, 1) - 0.2) < 1e-5)
        #expect(low.column(1, 1).w == 2)
    }

    @Test("Under a slope the cut cells hold the volume above it")
    func slopeVolume() {
        let grid = Grid(nx: 24, ny: 4, nz: 16, cellSize: 0.25)
        let domain = SIMD3<Float>(6, 1, 4)
        let terrain = Terrain.slope(domain: domain, spacing: 0.25, foot: 1, angle: 25)
        let geometry = TerrainCutGeometry(terrain: terrain, grid: grid, samples: 16)
        var air = 0.0
        for k in 0..<grid.nz { for i in 0..<grid.nx { air += Double(geometry.alpha(i, 0, k)) } }
        air *= 0.25 * 0.25 * 0.25 * Double(grid.ny)
        // The ground under the slope: 5 m of rise at tan 25°, and the rest of the box's floor flat.
        let ground = 0.5 * 5 * (5 * tan(25 * Double.pi / 180)) * 1
        let expected = 6.0 * 4.0 * 1.0 - ground
        #expect(abs(air - expected) / expected < 2e-3, "\(air) against \(expected)")
    }

    private func closedHill(_ configuration: SolverConfiguration, mass: Float = 2) throws -> BlastSolver {
        var scenario = Scenario(
            name: "Closed hill", domainSize: SIMD3(16, 8, 8), boxes: [],
            charge: Charge(mass: mass, position: SIMD3(4, 4, 1.5)))
        scenario.reflectiveFaces = .all
        scenario.terrain = .hill(
            domain: scenario.domainSize, spacing: 0.3, centre: SIMD2(10, 4), height: 4, radius: 2.5)
        return try BlastSolver(
            device: device, scenario: scenario, cellSize: 0.25, configuration: configuration)
    }

    @Test("Air at rest over a hill stays exactly at rest, with gravity or without", arguments: [false, true])
    func rest(gravity: Bool) throws {
        var configuration = cut()
        if gravity { configuration.gravity = AirGravity() }
        let solver = try closedHill(configuration, mass: 0)
        let before = solver.withState { Array($0) }
        _ = solver.advance(steps: 40)
        let after = solver.withState { Array($0) }
        let changed = zip(before, after).filter { $0 != $1 }.count
        #expect(changed == 0, "\(changed) cells changed")
    }

    @Test("A closed box over a hill conserves its gas to round-off", arguments: [false, true])
    func conservation(afterburning: Bool) throws {
        var configuration = cut()
        configuration.afterburning = afterburning
        let solver = try closedHill(configuration)
        let before = solver.totals()
        let fuel = solver.speciesTotals()
        _ = solver.advance(steps: 200)
        let after = solver.totals()
        #expect(abs(after.mass / before.mass - 1) < 1e-5, "mass \(after.mass / before.mass - 1)")
        // With afterburning, energy less the heat the fuel left will release.
        let heat = Double(configuration.afterburnEnergy)
        let held = before.energy + (afterburning ? fuel.fuel * heat : 0)
        let now = after.energy + (afterburning ? solver.speciesTotals().fuel * heat : 0)
        #expect(abs(now / held - 1) < 1e-5, "energy \(now / held - 1)")
        if afterburning {
            // Oxygen, less what the burnt fuel took, is conserved.
            let now = solver.speciesTotals()
            let burnt = fuel.fuel - now.fuel
            let oxygen = now.oxygen + burnt * Double(BlastSolver.oxygenPerFuel)
            #expect(abs(oxygen / fuel.oxygen - 1) < 1e-5, "oxygen \(oxygen / fuel.oxygen - 1)")
        }
    }

    @Test("Off, the terrain is the staircase it was, to the bit")
    func off() throws {
        var scenario = ScenarioPreset.openGround.scenario
        scenario.terrain = .hill(
            domain: scenario.domainSize, spacing: 1, centre: SIMD2(44, 32), height: 6, radius: 6)
        let a = try BlastSolver(device: device, scenario: scenario, cellSize: 0.5)
        var configuration = SolverConfiguration()
        configuration.terrainCutCells = false
        let b = try BlastSolver(
            device: device, scenario: scenario, cellSize: 0.5, configuration: configuration)
        _ = a.advance(steps: 30)
        _ = b.advance(steps: 30)
        #expect(a.withState { x in b.withState { y in Array(x) == Array(y) } })
        #expect(a.terrainCut == nil)
    }

    @Test("Under gravity, a burst over a hill conserves its mass to round-off")
    func gravityMass() throws {
        var configuration = cut()
        configuration.gravity = AirGravity()
        let solver = try closedHill(configuration)
        let before = solver.totals()
        _ = solver.advance(steps: 200)
        #expect(abs(solver.totals().mass / before.mass - 1) < 1e-5)
    }
}
