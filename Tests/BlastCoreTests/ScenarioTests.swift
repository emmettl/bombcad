import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

@Suite("Scenario setup")
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
            #expect(history.count == 10)
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
            for box in scenario.boxes {
                #expect(all(box.min .>= 0) && all(box.max .<= scenario.domainSize))
                #expect(!box.contains(scenario.charge.position), "\(preset.title): charge inside a block")
            }
            #expect(scenario.acousticCrossingTime > 0.05 && scenario.acousticCrossingTime < 0.5)
        }
    }

    @Test("The Kinney-Graham reference curve has the expected shape")
    func kinneyGraham() {
        // Roughly 10 atmospheres at a scaled distance of 1 m/kg^(1/3), falling monotonically.
        let atOne = KinneyGraham.peakOverpressureRatio(scaledDistance: 1)
        #expect(atOne > 9 && atOne < 11)
        let distances = stride(from: 0.2, through: 40, by: 0.2)
        let values = distances.map { KinneyGraham.peakOverpressureRatio(scaledDistance: $0) }
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 > $1 })
        #expect(
            abs(KinneyGraham.peakOverpressure(mass: 8, range: 2) - 101_325 * atOne) < 1)
    }
}

@Suite("Blast validation")
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

    @Test("The Kingery-Bulmash reference points scale as tabulated")
    func kingeryBulmashPoints() {
        let points = KingeryBulmash.hemisphericalSurfaceBurst
        #expect(points.count == 3)
        // The middle row of the source table: 10,000 kg at 50 m.
        let middle = points[1]
        #expect(abs(middle.range(mass: 10_000) - 50) < 1e-9)
        #expect(abs(middle.incidentPressure - 202_000) < 1)
        #expect(abs(middle.reflectedImpulse(mass: 10_000) - 6550) < 1e-6)
        #expect(abs(middle.arrival(mass: 10_000) - 0.0481) < 1e-9)
        #expect(zip(points, points.dropFirst()).allSatisfy { $0.scaledDistance < $1.scaledDistance })
    }
}
