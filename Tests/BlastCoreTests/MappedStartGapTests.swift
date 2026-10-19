import Foundation
import Metal
import RadialBlast
import Testing

@testable import BlastCore

/// The mapped start's choices that `MappedChargeTests` leaves unchecked: which configurations fall
/// back to the balloon, how far a charge is mapped (its caps, vent panels and shaped ground), the
/// ground's share of the charge, the time limit the app sets, the products' own gas and their
/// burning. The mapped start has been the default since 18 October 2026 (`recommended`), so each
/// of these now decides how most runs begin.
///
/// Drafted on 18 October 2026 by reading the code; built and run on the Studio on 19 October 2026.
@Suite("Mapped start: fallbacks, reach and options", .gpuThreads)
struct MappedStartGapTests {
    /// `mappings(for:)` maps nothing, and the balloon is laid, with dissociating air, the
    /// afterburning limit, gravity, sub-grid mixing or a gas cloud: the one-dimensional solution
    /// has none of them. Radiative cooling still maps (since 468f69b3): the gas starts losing its
    /// heat once mapped, and the fireball's first moments radiate little of it. A slip in that guard would start such a run
    /// from a solution that leaves out what the configuration asked for, silently.
    @Test("Each configuration the one-dimensional solution cannot carry falls back to the balloon")
    func disqualified() throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
        let scenario = ScenarioPreset.openGround.scenario
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.5)
        var base = solver.configuration
        base.mappedCharge = true
        solver.configuration = base
        // The open ground is mapped as it stands, so each change below is what stops it.
        try #require(solver.mappings(for: scenario).count == 1)

        let changes: [(String, (inout SolverConfiguration) -> Void)] = [
            ("dissociating air", { $0.airModel = .dissociating }),
            (
                "the afterburning limit",
                {
                    $0.afterburning = true
                    $0.afterburnLimit = AfterburnLimit()
                }
            ),
            ("gravity", { $0.gravity = AirGravity() }),
            ("sub-grid mixing", { $0.mixing = SubgridMixing() }),
            ("mapping off", { $0.mappedCharge = false }),
        ]
        for (name, change) in changes {
            var configuration = base
            change(&configuration)
            solver.configuration = configuration
            #expect(solver.mappings(for: scenario).isEmpty, "\(name)")
        }
        // Radiative cooling is carried from the mapped state on, so it keeps the mapping.
        var cooling = base
        cooling.radiativeCooling = RadiativeCooling()
        solver.configuration = cooling
        #expect(solver.mappings(for: scenario).count == 1)
        // A gas cloud starts as its own deflagration, never as a mapped charge.
        solver.configuration = base
        var cloud = scenario
        cloud.deflagration = Deflagration(
            region: Box(min: SIMD3(28, 28, 0), max: SIMD3(36, 36, 4)), ignition: SIMD3(32, 32, 1))
        #expect(solver.mappings(for: cloud).isEmpty)
    }

    /// The reach is the least of 0.8 of the way to the nearest open face, `mappedChargeCells`
    /// cells and `mappedChargeScaledReach` m/kg^(1/3). No test sets either cap, and the scaled
    /// reach is set nowhere in the sources either. On the open ground (64 x 64 x 32 m, 100 kg at
    /// the middle of the floor, 0.5 m cells) the nearest open faces are 32 m off, so the faces give
    /// 25.6 m, 64 cells give 32 m and 6 m/kg^(1/3) gives 27.8 m.
    @Test("The mapped reach is the least of the faces' 0.8, the cells' cap and the scaled reach's cap")
    func reachCaps() throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
        let scenario = ScenarioPreset.openGround.scenario
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.5)
        solver.configuration.mappedCharge = true
        func radius() throws -> Float { try #require(solver.mappings(for: scenario).first).radius }

        #expect(abs(try radius() - 0.8 * 32) < 1e-4)
        solver.configuration.mappedChargeCells = 10
        #expect(abs(try radius() - 10 * 0.5) < 1e-4)
        solver.configuration.mappedChargeCells = 64
        solver.configuration.mappedChargeScaledReach = 1
        #expect(abs(try radius() - cbrt(Float(100))) < 1e-4)
        // Below three cells the charge is not mapped at all.
        solver.configuration.mappedChargeScaledReach = 1.4 / cbrt(Float(100))
        #expect(solver.mappings(for: scenario).isEmpty)
    }

    /// A vent panel that releases (a positive release pressure) stops the mapping short of it, as a
    /// block does; one that never releases is left to the panes and blocks the scene has. Neither
    /// case is in any test.
    @Test("A releasing vent panel limits the reach to 0.8 of the way to it")
    func ventPanels() throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
        var scenario = ScenarioPreset.openGround.scenario
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.5)
        solver.configuration.mappedCharge = true
        let c = scenario.charge.position
        let panel = Box(min: c + SIMD3(5, -1, 0), max: c + SIMD3(5.1, 1, 2))
        scenario.ventPanels = [VentPanel(box: panel, releasePressure: 0)]
        #expect(abs((solver.mappings(for: scenario).first?.radius ?? 0) - 25.6) < 1e-4)
        scenario.ventPanels = [VentPanel(box: panel, releasePressure: 2000)]
        #expect(abs((solver.mappings(for: scenario).first?.radius ?? 0) - 0.8 * 5) < 1e-4)
    }

    /// On shaped terrain the ground is no mirror: a charge on the surface is not mapped (its
    /// nearest ground is at the charge), and one held 4 m above a flat stretch of it is mapped to
    /// 0.8 of that height with no mirrors. The terrain branch of `mapping(of:among:scenario:)`,
    /// which samples the surface a quarter cell apart, is reached by no test.
    @Test("Over shaped terrain the ground mirrors nothing, and limits the reach as an obstacle does")
    func shapedTerrain() throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
        var scenario = ScenarioPreset.openGround.scenario
        // Flat to x = 40 m, then rising at 20°: the charge's own ground is flat but the terrain
        // as a whole is not.
        scenario.terrain = Terrain.slope(domain: scenario.domainSize, spacing: 0.25, foot: 40, angle: 20)
        scenario.charge.position = SIMD3(16, 32, 0)
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.5)
        solver.configuration.mappedCharge = true
        #expect(solver.mappings(for: scenario).isEmpty)

        scenario.charge.position = SIMD3(16, 32, 4)
        let mapping = try #require(solver.mappings(for: scenario).first)
        #expect(mapping.mirrors == 0)
        // The surface is sampled an eighth of a metre apart, so the nearest sample may lie up to
        // 0.09 m off the point straight below; measured on the Studio, 19 October 2026, the reach is 3.2 m exactly.
        #expect(abs(mapping.radius - 0.8 * 4) < 0.01, "\(mapping.radius) m")
    }

    /// On earth or rock the air sees a smaller charge (`Scenario.coupled(to:)`), and the mapped
    /// solution must start from that charge, not the whole one. `MappedChargeTests` maps only on
    /// rigid ground, and no test combines `ground` with `mappedCharge`.
    @Test("On soft ground the mapped charge brings the coupled charge's energy, as the balloon does")
    func coupledGround() throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
        let scenario = ScenarioPreset.openGround.scenario
        var configuration = SolverConfiguration()
        configuration.ground = .playa
        let solver = try BlastSolver(
            device: device, scenario: scenario, cellSize: 0.5, configuration: configuration)
        let balloon = solver.totals()
        solver.configuration.mappedCharge = true
        try solver.load(scenario)
        let mapped = solver.totals()
        let coupled = Double(scenario.coupled(to: .playa).charge.energy)
        // The playa takes a share of the surface burst: the test means nothing if it takes none.
        try #require(coupled < 0.99 * Double(scenario.charge.energy))
        #expect(!solver.mappedRadii.isEmpty)
        // Measured on the Studio, 19 October 2026: they differ by 3e-5 of the coupled charge's energy.
        #expect(
            abs(mapped.energy - balloon.energy) < 0.005 * coupled,
            "\(mapped.energy) J against \(balloon.energy) J")
    }

    /// `mappedStartLatest`, which the app sets to half the run's duration, stops the
    /// one-dimensional solution early so that a short run still steps the grid. Only the app sets
    /// it; no core test does. Stopped short, the start still holds the charge's energy and the
    /// clock is at the limit, not at the time the shock would have taken to reach its radius.
    @Test("A time limit on the mapped start stops it at the limit, still holding the charge's energy")
    func latestStart() throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
        let scenario = ScenarioPreset.openGround.scenario
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.5)
        let balloon = solver.totals()
        solver.configuration.mappedCharge = true
        try solver.load(scenario)
        let unlimited = solver.time
        let limit = unlimited / 10
        solver.mappedStartLatest = limit
        try solver.load(scenario)
        // The solution finishes the step that crosses the limit (as `MappedChargeTests` finds of
        // `solved(toShockRadius:until:)`), so the clock lands at or just past it.
        #expect(
            solver.time >= limit * (1 - 1e-6) && solver.time < unlimited,
            "\(solver.time) s against \(limit) s")
        let short = solver.totals()
        // Measured on the Studio, 19 October 2026: the clock lands on the limit and the energy is the balloon's to 7e-4 of the
        // charge's.
        #expect(
            abs(short.energy - balloon.energy) < 0.005 * Double(scenario.charge.energy),
            "\(short.energy) J against \(balloon.energy) J")
        // Loading again without the mapping clears what the mapped start left.
        solver.mappedStartLatest = nil
        solver.configuration.mappedCharge = false
        try solver.load(scenario)
        #expect(solver.mappedRadii.isEmpty && solver.time == 0)
    }

    /// With `mappedChargeProducts` the one-dimensional solution gives the products TNT's JWL
    /// law; only `blastbench products` and `closeair --products` set it. Laid on the grid, the
    /// charge's energy is the same as the balloon's whichever law the products had.
    @Test("With the products' own law the mapped start still lays down the charge's energy")
    func productsOnGrid() throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
        let scenario = ScenarioPreset.openGround.scenario
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.5)
        let balloon = solver.totals()
        solver.configuration.mappedCharge = true
        solver.configuration.mappedChargeProducts = true
        try solver.load(scenario)
        #expect(solver.mappedStart.first?.blast.gas.products != nil)
        let mapped = solver.totals()
        // Measured on the Studio, 19 October 2026: the two differ by 4e-5 of the charge's energy (the ideal-gas start is held to 3%).
        #expect(
            abs(mapped.energy - balloon.energy) < 0.005 * Double(scenario.charge.energy),
            "\(mapped.energy) J against \(balloon.energy) J")
    }

    /// The afterburning the one-dimensional solution is given: none without afterburning; with it,
    /// `afterburnEnergy` at a rate of one over `afterburnTime` times the cube root of the mass,
    /// or at no rate at all when `mappedChargeBurns` is off, the products then carried unburnt to
    /// burn on the grid. No test sets `afterburnEnergy`, `afterburnTime` or `mappedChargeBurns`.
    @Test("The one-dimensional solution burns as the configuration says, or carries the products unburnt")
    func afterburnSetup() {
        let charge = Charge(mass: 8, position: .zero)
        var configuration = SolverConfiguration()
        configuration.mappedCharge = true
        func solution() -> SphericalBlast {
            BlastSolver.mappedSolution(
                charge, radius: 5, mirrors: 1, configuration: configuration, ambientDensity: 1.225)
        }
        #expect(solution().afterburn == nil)

        configuration.afterburning = true
        configuration.afterburnEnergy = 9e6
        configuration.afterburnTime = 20e-3
        let burning = solution().afterburn
        #expect(burning?.energy == 9e6)
        // 1 / (20 ms x 2), the cube root of 8 kg being 2.
        #expect(abs((burning?.rate ?? 0) - 25) < 1e-6)
        #expect(abs((burning?.diffusivity ?? 0) - Double(configuration.mappedChargeMixing) * 2) < 1e-9)

        configuration.mappedChargeBurns = false
        #expect(solution().afterburn?.rate == 0)
    }
}
