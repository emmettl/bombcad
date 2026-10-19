import Foundation
import Metal
import Testing
import simd

@testable import BlastCore
@testable import BlastModel

@Suite("Scenario setup", .gpuThreads)
struct ScenarioTests {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    @Test("Blocks are voxelised by cell centre")
    func voxelisation() throws {
        let scenario = Scenario(
            name: "Block", domainSize: SIMD3(16, 16, 8),
            boxes: [Box(x: 4...8, y: 6...9, height: 3)],
            charge: Charge(mass: 0, position: SIMD3(1, 1, 1)))
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.5)

        #expect(solver.grid == Grid(nx: 32, ny: 32, nz: 16, cellSize: 0.5))
        #expect(solver.grid.cellCount - solver.fluidCellCount == 8 * 6 * 6)
        #expect(solver.isSolid(8, 12, 0))
        #expect(solver.isSolid(15, 17, 5))
        #expect(!solver.isSolid(7, 12, 0))
        #expect(!solver.isSolid(16, 17, 5))
        #expect(!solver.isSolid(8, 12, 6))
    }

    @Test(
        "The charge releases exactly its TNT-equivalent energy",
        arguments: [SIMD3<Float>(8, 8, 4), SIMD3<Float>(8, 8, 0), SIMD3<Float>(4.1, 7.3, 0.4)])
    func chargeEnergy(position: SIMD3<Float>) throws {
        let empty = Scenario(
            name: "Empty", domainSize: SIMD3(16, 16, 8), boxes: [],
            charge: Charge(mass: 0, position: position))
        var loaded = empty
        loaded.charge.mass = 10
        let baseline = try BlastSolver(device: device, scenario: empty, cellSize: 0.25).totals()
        let solver = try BlastSolver(device: device, scenario: loaded, cellSize: 0.25)
        let totals = solver.totals()

        let released = totals.energy - baseline.energy
        #expect(abs(released - 10 * 4.184e6) / (10 * 4.184e6) < 1e-3)
        #expect(abs(totals.mass - baseline.mass - 10) < 0.05)
    }

    @Test(
        "A charge inside a block releases nothing, on uniform cells and refined alike; one against it all",
        arguments: [1, 2])
    func blockedCharge(refinement: Int) throws {
        var configuration = SolverConfiguration()
        configuration.refinement = refinement
        configuration.refinementLevels = refinement
        // Refined: 2 m coarse cells, 0.5 m fine ones; cells x 10–12 m solid (the block holds their centres).
        // The energy laid is the coarse cells' (which take each fine deposit's mean, and on refined air
        // the patches' finer outline adds air of its own beside the block).
        func coarseEnergy(_ solver: BlastSolver) -> Double {
            solver.withState { cells in
                (0..<solver.grid.cellCount).reduce(0.0) { sum, n in
                    let grid = solver.grid
                    let solid = solver.isSolid(n % grid.nx, (n / grid.nx) % grid.ny, n / (grid.nx * grid.ny))
                    return solid ? sum : sum + Double(cells[n].energy) * Double(pow(grid.cellSize, 3))
                }
            }
        }
        func released(at position: SIMD3<Float>) throws -> (energy: Double, blocked: [Int]) {
            var scene = Scenario(
                name: "Block", domainSize: SIMD3(24, 24, 8), boxes: [Box(x: 4...11.02, y: 4...20, height: 4)],
                charge: Charge(mass: 0, position: position))
            let baseline = coarseEnergy(
                try BlastSolver(device: device, scenario: scene, cellSize: 2, configuration: configuration))
            scene.charge.mass = 1
            let solver = try BlastSolver(
                device: device, scenario: scene, cellSize: 2, configuration: configuration)
            #expect(scene.chargeIsBlocked == !solver.blockedCharges.isEmpty)
            return ((coarseEnergy(solver) - baseline) / Double(scene.charge.energy), solver.blockedCharges)
        }
        // Inside, as a district's charge on a map building: the 4 m balloon of uniform cells laid it
        // in the air around the block, the 1 m one of the fine cells found none and lost it.
        let inside = try released(at: SIMD3(10, 12, 0))
        #expect(inside.blocked == [0] && abs(inside.energy) < 1e-6, "\(inside)")
        // Just outside its face but in a solid coarse cell, no fine cell's air within 1 m: the coarse
        // cells' balloon takes it, all of it.
        let against = try released(at: SIMD3(11.03, 12, 0))
        #expect(against.blocked.isEmpty && abs(against.energy - 1) < 1e-3, "\(against)")
        // On its face, as a contact charge: air on that side.
        let contact = try released(at: SIMD3(4, 12, 0))
        #expect(contact.blocked.isEmpty && abs(contact.energy - 1) < 1e-3, "\(contact)")
    }

    @Test("Gauges inside a block move to the nearest air cell")
    func gaugePlacement() throws {
        let scenario = ScenarioPreset.singleBuilding.scenario
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.5)
        #expect(solver.gaugeHistories.count == scenario.gauges.count)

        let inside = solver.nearestFluidCell(to: SIMD3(36.2, 32, 1.5))
        #expect(!solver.isSolid(inside.i, inside.j, inside.k))
        #expect(inside.i == 71)

        solver.advance(steps: 10)
        for history in solver.gaugeHistories {
            // Before each step, and the state the steps end in.
            #expect(history.count == 11)
            #expect(history.first?.time == 0)
            #expect(zip(history, history.dropFirst()).allSatisfy { $0.time < $1.time })
        }
    }

    @Test("Stepping stops exactly at a time limit")
    func timeLimit() throws {
        let solver = try BlastSolver(
            device: device, scenario: ScenarioPreset.openGround.scenario, cellSize: 1)
        let result = solver.advance(steps: 200, timeLimit: 0.004)
        #expect(result.steps < 200)
        #expect(abs(solver.time - 0.004) < 1e-8)
        #expect(solver.stepCount == result.steps)
    }

    @Test("Every preset fits its domain and starts from a consistent state")
    func presetsAreWellFormed() throws {
        for preset in ScenarioPreset.allCases {
            let scenario = preset.scenario
            #expect(scenario.gauges.count <= BlastSolver.maxGauges)
            let charges = [scenario.charge] + (scenario.additionalCharges ?? [])
            for box in scenario.boxes {
                #expect(all(box.min .>= 0) && all(box.max .<= scenario.domainSize))
                for charge in charges {
                    #expect(!box.contains(charge.position), "\(preset.title): charge inside a block")
                }
            }
            // The internal explosion's domain is a single small room, crossed in about 30 ms.
            #expect(scenario.acousticCrossingTime > 0.02 && scenario.acousticCrossingTime < 0.5)
        }
    }
}

@Suite("Blast validation", .gpuThreads)
struct BlastValidationTests {
    @Test("A surface burst tracks the empirical free-air curve for twice the mass")
    func surfaceBurstAgainstKinneyGraham() throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
        let scenario = ScenarioPreset.openGround.scenario
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.25)
        solver.advance(until: 0.08)

        for (gauge, history) in zip(scenario.gauges, solver.gaugeHistories) {
            let range = Double(simd_distance(gauge.position, scenario.charge.position))
            let reference = KinneyGraham.peakOverpressure(
                mass: Double(2 * scenario.charge.mass), range: range)
            let peak = Double((history.map(\.pressure).max() ?? 0) - scenario.atmosphere.pressure)
            // A captured shock is smeared over a few cells, so the peak reads low near the charge;
            // the ideal-gas balloon source is also only an approximation of a real detonation.
            #expect(
                peak / reference > 0.55 && peak / reference < 1.35, "\(gauge.name): \(peak) vs \(reference)")
        }
    }

    @Test("The impulse on a rigid wall matches Kingery-Bulmash within 10%", arguments: [1, 2])
    func reflectedImpulseAgainstKingeryBulmash(index: Int) throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
        let point = KingeryBulmash.hemisphericalSurfaceBurst[index]
        // The far x face of the domain is the wall; the charge sits on the ground in front of it.
        var scenario = ScenarioPreset.openGround.scenario
        let mass = Double(scenario.charge.mass)
        scenario.reflectiveFaces = [.zMin, .xMax]
        scenario.charge.position = SIMD3(64 - Float(point.range(mass: mass)), 32, 0)
        scenario.gauges = [Gauge("Wall", at: SIMD3(63.99, 32, 0.05))]
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.5)
        solver.advance(until: 0.1)

        let cell = solver.nearestFluidCell(to: scenario.gauges[0].position)
        let impulse = Double(solver.impulse(cell.i, cell.j, cell.k))
        let reference = point.reflectedImpulse(mass: mass)
        #expect(
            abs(impulse - reference) / reference < 0.1, "impulse \(impulse) Pa s against \(reference) Pa s")
        // The shock arrives when it should.
        let history = try #require(solver.gaugeHistories.first)
        let peak = (history.map(\.pressure).max() ?? 0) - scenario.atmosphere.pressure
        let arrival = history.first { $0.pressure - scenario.atmosphere.pressure >= 0.5 * peak }?.time ?? 0
        #expect(
            abs(arrival - point.arrival(mass: mass)) / point.arrival(mass: mass) < 0.1, "arrival \(arrival) s"
        )
    }

    @Test("Close in, a burst in the air reflects off the ground with Kingery-Bulmash's impulse")
    func closeInReflection() throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
        // 1 kg at 0.5 m/kg^(1/3) above rigid ground: the surface-burst curves at the mass over 1.8.
        let height: Float = 0.5
        var scenario = Scenario(
            name: "Close-in reflection", domainSize: SIMD3(1.5, 1.5, 1.4), boxes: [],
            charge: Charge(mass: 1, position: SIMD3(0.75, 0.75, height)),
            gauges: [Gauge("ground", at: SIMD3(0.75, 0.75, 0.005))])
        scenario.reflectiveFaces = .ground
        var configuration = SolverConfiguration()
        configuration.refinement = 2
        let solver = try BlastSolver(
            device: device, scenario: scenario, cellSize: 0.02, configuration: configuration)
        solver.advance(until: Double(height) / 340 + 0.004)
        let samples = try #require(solver.gaugeHistories.first)
        var impulse = 0.0
        for (a, b) in zip(samples, samples.dropFirst()) {
            impulse +=
                (b.time - a.time)
                * Double(max(0.5 * (a.pressure + b.pressure) - scenario.atmosphere.pressure, 0))
        }
        let mass = 1.0 / 1.8
        let reference = try #require(KingeryBulmash.point(at: Double(height) / cbrt(mass))).reflectedImpulse(
            mass: mass)
        #expect(
            abs(impulse - reference) / reference < 0.1, "impulse \(impulse) Pa s against \(reference) Pa s")
    }
}
