import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

/// The luminous gas losing the heat it radiates.
@Suite("Radiative cooling")
struct RadiativeCoolingTests {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    static let sigma = 5.670374e-8
    static let gasConstant: Float = 287.05

    /// A closed cube of air `side` metres across, `cells` a side, holding a sphere of radius
    /// `radius` at `temperature` and at the surrounding pressure, so that nothing moves.
    private func hotSphere(
        side: Float = 6, cells: Int = 24, radius: Float = 2, temperature: Float = 2500,
        cooling: RadiativeCooling?
    ) throws -> BlastSolver {
        var configuration = SolverConfiguration()
        configuration.reflectiveFaces = .all
        configuration.radiativeCooling = cooling
        let dx = side / Float(cells)
        let solver = try BlastSolver(
            device: device, grid: Grid(nx: cells, ny: cells, nz: cells, cellSize: dx),
            configuration: configuration)
        let centre = SIMD3<Float>(repeating: side / 2)
        let pressure: Float = 101_325
        solver.fill { i, j, k in
            let point = (SIMD3<Float>(Float(i), Float(j), Float(k)) + 0.5) * dx
            let hot = simd_distance(point, centre) < radius
            let t: Float = hot ? temperature : 288
            return Primitive(density: pressure / (Self.gasConstant * t), pressure: pressure)
        }
        return solver
    }

    /// The emission of an isothermal sphere of optical radius `tau`, as a share of a black body's
    /// over its surface (Modest, the emittance of an isothermal sphere).
    static func sphereEmittance(_ tau: Double) -> Double {
        1 - (1 - (1 + 2 * tau) * exp(-2 * tau)) / (2 * tau * tau)
    }

    @Test(
        "A hot sphere radiates as an isothermal sphere of its optical radius, and its centre loses 4κσT⁴ e^(−κR)",
        arguments: [(Float(0.01), 0.002, 0.002), (1, 0.005, 0.02), (20, 0.02, 0.02)])
    func isothermalSphere(absorption: Float, totalTolerance: Double, centreTolerance: Double) throws {
        let temperature: Float = 2500
        let solver = try hotSphere(
            temperature: temperature, cooling: RadiativeCooling(absorption: absorption, sootYield: 0))
        let grid = solver.grid
        let centre = grid.index(12, 12, 12)
        let luminous = solver.withState { cells in
            cells.filter { $0.density < 0.5 }.count
        }
        let before = solver.withState { $0[centre] }
        let result = solver.advance(steps: 1)
        let after = solver.withState { $0[centre] }
        let dt = result.lastTimeStep
        let volume = Double(luminous) * pow(Double(grid.cellSize), 3)
        let radius = cbrt(3 * volume / (4 * .pi))
        let tau = Double(absorption) * radius
        let blackBody = Self.sigma * pow(Double(temperature), 4)
        let expected = 4 * .pi * radius * radius * blackBody * Self.sphereEmittance(tau)
        let power = solver.radiatedEnergy / dt
        #expect(
            abs(power / expected - 1) < totalTolerance,
            "κ \(absorption): \(power) W against \(expected) W (τ \(tau))")
        // The sphere's inside does not move, so its centre changes only by what it radiated.
        let centreLoss = Double(before.energy - after.energy) / dt
        let centreExpected = 4 * Double(absorption) * blackBody * exp(-tau)
        let thin = 4 * Double(absorption) * blackBody
        #expect(
            abs(centreLoss - centreExpected) < centreTolerance * max(centreExpected, 1e-3 * thin),
            "κ \(absorption): centre \(centreLoss) W/m³ against \(centreExpected)")
    }

    @Test(
        "Clear of the ground, the gas loses what the thermal radiation's volume measures it radiates",
        arguments: [Float(0.05), 1, 20])
    func agreesWithTheVolume(absorption: Float) throws {
        var spec = ThermalSpec()
        spec.absorption = absorption
        spec.sootYield = 0
        spec.samples = 256
        let solver = try hotSphere(cooling: RadiativeCooling(spec: spec))
        var scenario = Scenario(
            name: "Sphere", domainSize: SIMD3(repeating: 6), boxes: [],
            charge: Charge(mass: 1, position: SIMD3(repeating: 3)))
        scenario.gauges = []
        let exposure = ThermalExposure(spec: spec, scene: FragmentScene(scenario))
        let measured = exposure.radiatedPower(solver.fireball(for: spec))
        let result = solver.advance(steps: 1)
        let lost = solver.radiatedEnergy / result.lastTimeStep
        #expect(abs(lost / measured - 1) < 0.03, "κ \(absorption): lost \(lost) W, measured \(measured) W")
    }

    @Test("Thin gas cools at 4κσT⁴ a cubic metre over many steps, thick gas far more slowly")
    func thinAndThickCooling() throws {
        // The centre's temperature over 5 steps against dT/dt = -4κσT⁴ e^(-κR) / (ρ c_v) at fixed
        // density (the inside of a sphere at rest, too far from its edge for its edge to move).
        func centre(_ absorption: Float) throws -> (
            start: Double, end: Double, elapsed: Double, density: Double
        ) {
            let solver = try hotSphere(cooling: RadiativeCooling(absorption: absorption, sootYield: 0))
            let index = solver.grid.index(12, 12, 12)
            let start = solver.primitive(of: solver.withState { $0[index] })
            var elapsed = 0.0
            for _ in 0..<5 { elapsed += solver.advance(steps: 1).elapsed }
            let end = solver.primitive(of: solver.withState { $0[index] })
            return (
                Double(start.pressure / (start.density * Self.gasConstant)),
                Double(end.pressure / (end.density * Self.gasConstant)), elapsed, Double(start.density)
            )
        }
        let thin = try centre(0.05)
        let heat = thin.density * Double(Self.gasConstant) / 0.4  // ρ c_v
        // Integrated exactly: T^-3 grows by 12 κ σ e^(-κR) t / (ρ c_v).
        let rate = 12 * 0.05 * Self.sigma * exp(-0.05 * 2) / heat
        let expected = pow(pow(thin.start, -3) + rate * thin.elapsed, -1.0 / 3)
        #expect(
            abs((thin.start - thin.end) / (thin.start - expected) - 1) < 0.005,
            "fell \(thin.start - thin.end) K against \(thin.start - expected) K")
        let thick = try centre(20)
        #expect(
            thick.start - thick.end < 1e-3 * (thin.start - thin.end),
            "the opaque centre fell \(thick.start - thick.end) K")
    }

    @Test("In a closed box the energy the gas loses is the energy it radiated")
    func budgetCloses() throws {
        let solver = try hotSphere(cooling: RadiativeCooling(absorption: 1, sootYield: 0))
        let start = solver.totals()
        for _ in 0..<10 { #expect(solver.advance(steps: 20).isStable) }
        let end = solver.totals()
        let radiated = solver.radiatedEnergy
        #expect(radiated > 0.01 * start.energy, "radiated \(radiated) J of \(start.energy) J")
        #expect(
            abs(start.energy - end.energy - radiated) < 1e-5 * radiated,
            "lost \(start.energy - end.energy) J, radiated \(radiated) J")
        #expect(solver.radiationHistory.count == 10 && solver.radiationHistory.last?.energy == radiated)
    }

    @Test("With the air refined in two levels the budget still closes, across the levels' edges")
    func budgetClosesRefined() throws {
        var configuration = SolverConfiguration()
        configuration.reflectiveFaces = .all
        configuration.refinement = 2
        configuration.refinementLevels = 2
        configuration.refinementThreshold = 0.05
        configuration.refinementMemory = 256 << 20
        configuration.radiativeCooling = RadiativeCooling(absorption: 5, sootYield: 0)
        let dx: Float = 0.25
        let solver = try BlastSolver(
            device: device, grid: Grid(nx: 32, ny: 24, nz: 24, cellSize: dx), configuration: configuration)
        // A small balloon of hot, dense gas whose blast refines the air, beside a hot sphere at the
        // surrounding pressure that the blast crosses.
        solver.fill { i, j, k in
            let point = (SIMD3<Float>(Float(i), Float(j), Float(k)) + 0.5) * dx
            if simd_distance(point, SIMD3(2, 3, 3)) < 0.6 {
                return Primitive(density: 4, pressure: 3e6)
            }
            let t: Float = simd_distance(point, SIMD3(5, 3, 3)) < 1.5 ? 3000 : 288
            return Primitive(density: 101_325 / (Self.gasConstant * t), pressure: 101_325)
        }
        let start = solver.totals()
        var finer = 0
        for _ in 0..<6 {
            let result = solver.advance(steps: 20)
            #expect(result.isStable)
            finer = max(finer, result.finerRefinedTiles)
        }
        let end = solver.totals()
        let radiated = solver.radiatedEnergy
        #expect(finer > 0)
        #expect(radiated > 1e-3 * start.energy, "radiated \(radiated) J of \(start.energy) J")
        #expect(
            abs(start.energy - end.energy - radiated) < 1e-5 * radiated,
            "lost \(start.energy - end.energy) J, radiated \(radiated) J")
    }

    @Test("With afterburning and hot air, what burns is what the gas keeps and radiates, its soot included")
    func budgetClosesBurning() throws {
        var scenario = Scenario(
            name: "Room", domainSize: SIMD3(repeating: 4), boxes: [],
            charge: Charge(mass: 8, position: SIMD3(repeating: 2)))
        scenario.reflectiveFaces = .all
        var configuration = SolverConfiguration()
        configuration.afterburning = true
        configuration.airModel = .thermallyPerfect
        configuration.radiativeCooling = RadiativeCooling()
        let solver = try BlastSolver(
            device: device, scenario: scenario, cellSize: 0.25, configuration: configuration)
        let start = solver.totals()
        let fuel = solver.speciesTotals().fuel
        solver.advance(until: 0.03)
        let end = solver.totals()
        let left = solver.speciesTotals().fuel
        let heat = Double(configuration.afterburnEnergy)
        let radiated = solver.radiatedEnergy
        let before = start.energy + heat * fuel
        let after = end.energy + heat * left + radiated
        #expect(fuel - left > 1, "only \(fuel - left) kg burnt")
        #expect(radiated > 0.01 * heat * (fuel - left), "radiated \(radiated) J")
        #expect(
            abs(after - before) < 1e-3 * radiated,
            "energy and fuel \(before) J -> \(after) J, radiated \(radiated) J")
    }

    @Test("Taking the loss every fourth step radiates as taking it every step does, to half a per cent")
    func everyFourthStep() throws {
        func radiated(interval: Int) throws -> Double {
            var cooling = RadiativeCooling(absorption: 1, sootYield: 0)
            cooling.interval = interval
            let solver = try hotSphere(cooling: cooling)
            for _ in 0..<4 { solver.advance(steps: 50) }
            return solver.radiatedEnergy
        }
        let every = try radiated(interval: 1)
        let fourth = try radiated(interval: 4)
        #expect(abs(fourth / every - 1) < 0.005, "\(fourth) J against \(every) J")
    }

    @Test("A box too large for the directions' slices, taken one direction at a time, cools alike")
    func oneDirectionAtATime() throws {
        func run(capacity: Int?) throws -> (energy: Double, state: [CellState]) {
            let cooling = RadiativeCooling(absorption: 1, sootYield: 0)
            let solver = try hotSphere(cooling: cooling)
            if let capacity {
                solver.radiativeCoolingStage = try RadiativeCoolingStage(
                    settings: cooling, device: device, library: solver.library, grid: solver.grid,
                    airModel: solver.configuration.airModel, gamma: solver.configuration.gamma,
                    capacity: capacity)
            }
            solver.advance(steps: 10)
            return (solver.radiatedEnergy, solver.withState { Array($0) })
        }
        let together = try run(capacity: nil)
        let apart = try run(capacity: 100)
        #expect(
            abs(apart.energy / together.energy - 1) < 1e-5, "\(apart.energy) J against \(together.energy) J")
        let worst = zip(together.state, apart.state).map { abs($0.energy - $1.energy) / $0.energy }.max() ?? 0
        #expect(worst < 1e-5, "energy differs by \(worst) of a cell's")
    }

    @Test("With nothing luminous, the air runs exactly as without the cooling")
    func nothingLuminousChangesNothing() throws {
        func run(_ cooling: RadiativeCooling?) throws -> [CellState] {
            var configuration = SolverConfiguration()
            configuration.refinement = 2
            configuration.radiativeCooling = cooling
            let solver = try BlastSolver(
                device: device, scenario: ScenarioPreset.openGround.scenario, cellSize: 0.5,
                configuration: configuration)
            solver.advance(steps: 40)
            #expect(solver.radiatedEnergy == 0)
            return solver.withState { Array($0) }
        }
        let off = try run(nil)
        let on = try run(RadiativeCooling(luminousTemperature: 1e9))
        #expect(off == on)
    }
}
