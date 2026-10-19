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

    @Test(
        "A closed box over a hill conserves its gas to round-off, with sub-grid mixing too",
        arguments: [(false, false), (true, false), (true, true)])
    func conservation(afterburning: Bool, mixing: Bool) throws {
        var configuration = cut()
        configuration.afterburning = afterburning
        if mixing { configuration.mixing = .sigma }
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

    @Test(
        "Refined, a closed box over a hill conserves its gas to round-off across the levels",
        arguments: [
            (false, false, 1), (true, false, 1), (false, true, 1), (false, false, 2), (true, false, 2),
            (false, true, 2),
        ])
    func refinedConservation(afterburning: Bool, gravity: Bool, levels: Int) throws {
        var configuration = cut()
        configuration.refinement = 2
        configuration.refinementLevels = levels
        configuration.refinementThreshold = 0.02
        configuration.afterburning = afterburning
        if gravity { configuration.gravity = AirGravity() }
        let solver = try closedHill(configuration)
        #expect(solver.terrainCut != nil && solver.refinement?.cutTerrain == true)
        #expect(levels == 1 || solver.finerRefinement?.cutTerrain == true)
        let before = solver.totals()
        let fuel = solver.speciesTotals()
        var refinedCut = false
        for _ in 0..<12 {
            _ = solver.advance(steps: 10)
            // Patches over the hill's cut cells, at some point.
            refinedCut =
                refinedCut
                || (solver.refinement?.holdsAny(from: SIMD3(28, 4, 0), through: SIMD3(52, 28, 16)) ?? false)
        }
        #expect(refinedCut)
        let after = solver.totals()
        #expect(abs(after.mass / before.mass - 1) < 1e-5, "mass \(after.mass / before.mass - 1)")
        let heat = Double(configuration.afterburnEnergy)
        let held = before.energy + (afterburning ? fuel.fuel * heat : 0)
        let now = after.energy + (afterburning ? solver.speciesTotals().fuel * heat : 0)
        #expect(abs(now / held - 1) < 1e-5, "energy \(now / held - 1)")
        if afterburning {
            let species = solver.speciesTotals()
            let oxygen = species.oxygen + (fuel.fuel - species.fuel) * Double(BlastSolver.oxygenPerFuel)
            #expect(abs(oxygen / fuel.oxygen - 1) < 1e-5, "oxygen \(oxygen / fuel.oxygen - 1)")
        }
    }

    @Test("Cut by default, refined once or twice too; the staircase when off, and on flat ground")
    func defaults() throws {
        var scenario = ScenarioPreset.openGround.scenario
        scenario.terrain = .hill(
            domain: scenario.domainSize, spacing: 1, centre: SIMD2(44, 32), height: 6, radius: 6)
        #expect(try BlastSolver(device: device, scenario: scenario, cellSize: 0.5).terrainCut != nil)
        var off = SolverConfiguration()
        off.terrainCutCells = false
        var twice = SolverConfiguration()
        twice.refinement = 2
        twice.refinementLevels = 2
        var refined = SolverConfiguration()
        refined.refinement = 2
        for configuration in [refined, twice] {
            #expect(
                try BlastSolver(
                    device: device, scenario: scenario, cellSize: 0.5, configuration: configuration
                )
                .terrainCut != nil)
        }
        let staircase = try BlastSolver(device: device, scenario: scenario, cellSize: 0.5, configuration: off)
        #expect(staircase.terrainCut == nil)
        #expect(staircase.terrainSurface == scenario.terrain!.surfaceCells(grid: staircase.grid))
        scenario.terrain = .flat(domain: scenario.domainSize, spacing: 1)
        #expect(try BlastSolver(device: device, scenario: scenario, cellSize: 0.5).terrainCut == nil)
    }

    @Test("Over a plateau lying on cells' faces, beside a hill, the gas is conserved to round-off")
    func plateau() throws {
        var scenario = Scenario(
            name: "Plateau", domainSize: SIMD3(16, 8, 8), boxes: [],
            charge: Charge(mass: 2, position: SIMD3(4, 4, 2.5)))
        scenario.reflectiveFaces = .all
        // Level at exactly 1 m (four cells), where the cells above it are whole and the cells below
        // solid, rising to a hill: whole cells meet the solid ground across their faces.
        scenario.terrain = .sampled(domain: scenario.domainSize, spacing: 0.25) { p in
            max(1, 4 * exp(-simd_length_squared(p - SIMD2(10, 4)) / 6.25))
        }
        var configuration = cut()
        configuration.afterburning = true
        let solver = try BlastSolver(
            device: device, scenario: scenario, cellSize: 0.25, configuration: configuration)
        let before = solver.totals()
        _ = solver.advance(steps: 200)
        let after = solver.totals()
        #expect(abs(after.mass / before.mass - 1) < 1e-5, "mass \(after.mass / before.mass - 1)")
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

    /// A closed box over a hill a metre high, its lowest 0.8 m (the hill's flanks, not its top) full
    /// of stoichiometric methane–air, lit a quarter of a metre above a flank: the cloud's edge crosses
    /// the cut cells.
    private func burningHill(_ configuration: SolverConfiguration, panels: [VentPanel] = []) throws
        -> BlastSolver
    {
        var scenario = Scenario(
            name: "Burning hill", domainSize: SIMD3(4, 2, 2), boxes: [],
            charge: Charge(mass: 0, position: .zero))
        scenario.reflectiveFaces = .all
        scenario.terrain = .hill(
            domain: scenario.domainSize, spacing: 0.05, centre: SIMD2(2.5, 1), height: 1, radius: 0.6)
        scenario.deflagration = Deflagration(
            gas: .methane, region: Box(min: .zero, max: SIMD3(4, 2, 0.8)), ignition: SIMD3(1.75, 1, 0.45))
        scenario.ventPanels = panels
        return try BlastSolver(
            device: device, scenario: scenario, cellSize: 0.1, configuration: configuration)
    }

    @Test("A deflagration over a hill burns on cut cells, conserving its gas and the cloud's to round-off")
    func deflagration() throws {
        let solver = try burningHill(cut())
        #expect(solver.terrainCut != nil)
        let heat = Double(
            Deflagration(gas: .methane, region: Box(min: .zero, max: .one), ignition: .zero)
                .heatPerKilogram(
                    atmosphere: Atmosphere(), airModel: solver.configuration.airModel,
                    gamma: solver.configuration.gamma))
        let before = solver.totals()
        let cloud = solver.speciesTotals().oxygen
        let unburnt = try #require(solver.deflagrationState()).unburnt
        _ = solver.advance(until: 0.2)
        let after = solver.totals()
        let state = try #require(solver.deflagrationState())
        // It burns, the flame reaching the hill's cut cells.
        #expect(state.unburnt < unburnt * 0.998, "\(state.unburnt / unburnt)")
        #expect(abs(after.mass / before.mass - 1) < 1e-5, "mass \(after.mass / before.mass - 1)")
        // The cloud's gas, burnt or not, is carried, never made or lost.
        #expect(abs(solver.speciesTotals().oxygen / cloud - 1) < 1e-5)
        // Energy less the heat the unburnt mixture has yet to release.
        let held = before.energy + unburnt * heat
        let now = after.energy + state.unburnt * heat
        #expect(abs(now / held - 1) < 1e-5, "energy \(now / held - 1)")
    }

    @Test("Vent panels keep the terrain's cut cells")
    func ventPanelsKeepCutCells() throws {
        let panel = VentPanel(
            box: Box(min: SIMD3(0.5, 0.5, 0.2), max: SIMD3(0.6, 1.5, 1)), releasePressure: 5e3)
        let solver = try burningHill(cut(), panels: [panel])
        #expect(solver.terrainCut != nil && solver.terrain != nil)
        #expect(solver.ventPanelOpenTimes.count == 1)
    }

    @Test("A cell mostly ground under a block standing on it is solid, and a blast beside it stays finite")
    func cappedSliver() throws {
        // Ground a tenth of the way up its cells' second layer; a block whose base lies below it,
        // so that the slivers of air under it would be shut in; 100 kg 5 m from its side.
        var scenario = Scenario(
            name: "Capped slivers", domainSize: SIMD3(48, 48, 16),
            boxes: [Box(min: SIMD3(20, 18, 1.7), max: SIMD3(30, 30, 6))],
            charge: Charge(mass: 100, position: SIMD3(15, 24, 2.5)))
        scenario.reflectiveFaces = .all
        scenario.terrain = Terrain.sampled(domain: scenario.domainSize, spacing: 0.5, source: "slivers") {
            p in
            1.9 + 0.0005 * p.x
        }
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 1, configuration: cut())
        let geometry = try #require(solver.terrainCut?.geometry)
        // Under the block, the sliver is solid; beside it, air.
        #expect(geometry.alpha(25, 24, 1) < 0.2 && solver.isSolid(25, 24, 1))
        #expect(geometry.alpha(10, 24, 1) < 0.2 && !solver.isSolid(10, 24, 1))
        let before = solver.totals()
        _ = solver.advance(until: 0.03)
        let after = solver.totals()
        #expect(after.mass.isFinite && after.energy.isFinite)
        #expect(abs(after.mass / before.mass - 1) < 1e-5, "mass \(after.mass / before.mass - 1)")
        #expect(abs(after.energy / before.energy - 1) < 1e-5, "energy \(after.energy / before.energy - 1)")
    }

    @Test("Refined, a sliver under a block only the fine cells hold is solid there")
    func cappedFineSliver() throws {
        // Ground a fifth of the way up the fine cells' third layer, in coarse cells over half air;
        // a block from 1.6 to 2.4 m, which the fine cells hold whole and the coarse cells as their
        // third layer, so the coarse cells under it stay air while the fine sliver beneath it is
        // shut in.
        var scenario = Scenario(
            name: "Capped fine slivers", domainSize: SIMD3(48, 48, 16),
            boxes: [Box(min: SIMD3(20, 18, 1.6), max: SIMD3(30, 30, 2.4))],
            charge: Charge(mass: 100, position: SIMD3(15, 24, 2.5)))
        scenario.reflectiveFaces = .all
        scenario.terrain = Terrain.sampled(domain: scenario.domainSize, spacing: 0.5, source: "fine slivers")
        {
            p in
            1.4 + 0.0005 * p.x
        }
        var configuration = cut()
        configuration.refinement = 2
        configuration.refinementThreshold = 0.02
        let solver = try BlastSolver(
            device: device, scenario: scenario, cellSize: 1, configuration: configuration)
        let geometry = try #require(solver.terrainCut?.geometry)
        #expect(geometry.alpha(25, 24, 1) > 0.5 && !solver.isSolid(25, 24, 1) && solver.isSolid(25, 24, 2))
        let before = solver.totals()
        var covered = false
        for _ in 0..<10 {
            _ = solver.advance(steps: 10)
            let level = try #require(solver.refinement)
            if level.holdsAny(from: SIMD3(25, 24, 1), through: SIMD3(25, 24, 1)) {
                covered = true
                // The fine sliver under the block (a sixth air) is solid; the one beside it is air.
                let fine = level.fineReader()
                #expect(fine(SIMD3(50, 48, 2)) == nil)
                #expect(
                    !level.holdsAny(from: SIMD3(18, 24, 1), through: SIMD3(18, 24, 1))
                        || fine(SIMD3(36, 48, 2)) != nil)
            }
        }
        #expect(covered)
        let after = solver.totals()
        #expect(after.mass.isFinite && after.energy.isFinite)
        // The block's fine outline differs from its coarse one, which gives up 3e-4 of the gas; the
        // capped sliver made 2e-3 more.
        #expect(abs(after.mass / before.mass - 1) < 1e-3, "mass \(after.mass / before.mass - 1)")
        #expect(abs(after.energy / before.energy - 1) < 1e-3, "energy \(after.energy / before.energy - 1)")
    }

    @Test(
        "Under a block's fine outline, a coarse cut cell restricted from its fine cells holds their air's mean"
    )
    func blockedRestriction() throws {
        // Ground at 1.41 m, so the coarse cells from 1 to 2 m are cut (0.59 air); a block from
        // x = 20.6 m, so the coarse cell from 20 to 21 m stays air while the fine cells from 20.5
        // m are the block's. Restricted over the coarse share, which knows nothing of the block,
        // that cell held half its fine air's density.
        var scenario = Scenario(
            name: "Block on cut ground", domainSize: SIMD3(48, 48, 16),
            boxes: [Box(min: SIMD3(20.6, 18, 0), max: SIMD3(30, 30, 3))],
            charge: Charge(mass: 100, position: SIMD3(15, 24, 2.5)))
        scenario.reflectiveFaces = .all
        scenario.terrain = Terrain.sampled(
            domain: scenario.domainSize, spacing: 0.5, source: "block on cut ground"
        ) {
            p in
            1.4 + 0.0005 * p.x
        }
        var configuration = cut()
        configuration.refinement = 2
        configuration.refinementThreshold = 0.02
        let solver = try BlastSolver(
            device: device, scenario: scenario, cellSize: 1, configuration: configuration)
        let geometry = try #require(solver.terrainCut?.geometry)
        #expect(
            geometry.alpha(20, 24, 1) > 0.5 && geometry.alpha(20, 24, 1) < 1 && !solver.isSolid(20, 24, 1))
        var checked = 0
        for _ in 0..<12 {
            _ = solver.advance(steps: 8)
            let level = try #require(solver.refinement)
            guard level.holdsAny(from: SIMD3(20, 24, 1), through: SIMD3(20, 24, 1)) else { continue }
            let fine = level.fineReader()
            // The block's fine cells are solid; the air's are those at x = 40.
            #expect(fine(SIMD3(41, 48, 3)) == nil)
            let pressures = [SIMD3(40, 48, 3), SIMD3(40, 49, 3), SIMD3(40, 48, 2), SIMD3(40, 49, 2)]
                .compactMap {
                    fine($0).map { solver.primitive(of: $0.state).pressure }
                }
            guard let low = pressures.min(), let high = pressures.max() else { continue }
            let coarse = solver.primitive(20, 24, 1).pressure
            #expect(
                coarse > 0.99 * low && coarse < 1.01 * high, "coarse \(coarse) Pa, fine \(low)-\(high) Pa")
            checked += 1
        }
        #expect(checked > 0)
    }

    @Test("Beside a charge on a slope no cut cell is drained to the pressure floor, and a closed box keeps its energy")
    func noCellDrained() throws {
        // The open ground's 100 kg on the recommended air over a 20° slope, closed and without
        // afterburning: from step 34 the sweep's strong expansion left cells whose redistributed
        // difference took them below nothing, and the floor added 1.2 kJ by step 45.
        var configuration = SolverConfiguration.recommended
        configuration.afterburning = false
        configuration.reflectiveFaces = .all
        var scenario = ScenarioPreset.openGround.scenario
        let domain = scenario.domainSize
        scenario.replaceTerrain(with: .slope(domain: domain, spacing: 1, foot: 0.3 * domain.x, angle: 20))
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.5, configuration: configuration)
        let start = solver.totals()
        let mask = solver.maskBuffer.contents().bindMemory(to: UInt8.self, capacity: solver.grid.cellCount)
        var lowest = Float.infinity
        for _ in 0..<45 {
            #expect(solver.advance(steps: 1).isStable)
            solver.withState { cells in
                for n in cells.indices where mask[n] == 0 {
                    let c = cells[n]
                    let kinetic =
                        0.5 * (c.momentumX * c.momentumX + c.momentumY * c.momentumY + c.momentumZ * c.momentumZ)
                        / c.density
                    lowest = min(lowest, (c.energy - kinetic) / c.density)
                }
            }
        }
        let end = solver.totals()
        #expect(lowest > 1_000, "the lowest specific internal energy, \(lowest) J/kg")
        #expect(abs(end.energy - start.energy) < 200, "energy \(start.energy) J -> \(end.energy) J")
    }
}
