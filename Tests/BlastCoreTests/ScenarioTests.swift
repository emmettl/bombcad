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

    @Test("Each piece of a structure is reinforced as it asks")
    func reinforcementSettings() {
        let wall = Box(x: 0...0.25, y: 0...4, height: 3)
        let column = Box(x: 2...2.5, y: 0...0.5, height: 3)
        var model = StructureModel(solids: [wall, column], elementSize: 0.0625)
        model.autoReinforce()
        // Automatic: a mat in each face of the wall, and the column as a column.
        #expect(model.reinforcement.count == 3)
        let automatic = model.reinforcement

        model.setReinforcement(.none, of: 0)
        model.setReinforcement(.column(longitudinal: 0.03, ties: 0.01), of: 1)
        model.autoReinforce()
        #expect(model.reinforcement == [ReinforcementLayer(region: column, ratio: SIMD3(0.01, 0.01, 0.03))])

        model.setReinforcement(.mats(areaPerMetre: 1000e-6, depth: 0.05, bothFaces: false), of: 0)
        model.autoReinforce()
        let mat = model.reinforcement[0]
        // One mat, 50 mm in from the low face across the wall's thickness, smeared over one
        // element: 1000 mm²/m in a 62.5 mm band is a ratio of 1.6% each way along the wall.
        #expect(model.reinforcement.count == 2)
        #expect(abs((mat.region.min.x + mat.region.max.x) / 2 - 0.05) < 1e-6)
        #expect(abs(mat.ratio.y - 0.016) < 1e-6 && abs(mat.ratio.z - 0.016) < 1e-6 && mat.ratio.x == 0)

        // Removing a piece removes its setting with it, so the rest keep theirs.
        model.removeSolid(at: 0)
        #expect(model.solids == [column])
        #expect(model.reinforcement(of: 0) == .column(longitudinal: 0.03, ties: 0.01))
        model.setReinforcement(.automatic, of: 0)
        model.autoReinforce()
        #expect(model.reinforcement == [automatic[2]])
    }

    @Test("A layout saved before newer settings existed still opens, with their defaults")
    func olderLayouts() throws {
        var scenario = ScenarioPreset.blastWall.scenario
        scenario.structure?.setReinforcement(.none, of: 0)
        scenario.structure?.autoReinforce()
        let data = try JSONEncoder().encode(scenario)
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var structure = try #require(json["structure"] as? [String: Any])
        var material = try #require(structure["material"] as? [String: Any])
        // Settings added to the material and the structure after the first saved layouts.
        for key in ["crackResidual", "crushBand", "crushLength"] {
            #expect(material.removeValue(forKey: key) != nil, "\(key) should be saved")
        }
        #expect(structure.removeValue(forKey: "solidReinforcement") != nil)
        structure["material"] = material
        json["structure"] = structure
        let old = try JSONSerialization.data(withJSONObject: json)

        let opened = try JSONDecoder().decode(Scenario.self, from: old)
        var expected = scenario
        expected.structure?.solidReinforcement = []
        #expect(opened == expected)
        #expect(opened.structure?.material.crackResidual == 0.1)
        #expect(opened.structure?.material.crushBand == 0)
        #expect(opened.structure?.material.crushLength == 0)
        // The saved bars are kept as they were; the setting reads as automatic.
        #expect(opened.structure?.reinforcement == scenario.structure?.reinforcement)
        #expect(opened.structure?.reinforcement(of: 0) == .automatic)
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

    @Test("The Kingery-Bulmash polynomials reproduce Swisdak's tables and the IATG examples")
    func kingeryBulmashCurves() throws {
        // Rows of Swisdak's Table 3: Z, arrival (ms), incident and reflected pressure (kPa),
        // duration (ms), incident and reflected impulse (kPa ms), all per kg^(1/3).
        let rows: [[Double]] = [
            [1.0, 0.467, 1354, 8152, 1.720, 236.3, 884.7],
            [2.0, 1.693, 283.7, 1058, 2.053, 134.6, 363.8],
            [5.0, 8.242, 43.23, 100.9, 3.793, 59.31, 125.6],
            [10.0, 21.66, 14.89, 31.54, 4.779, 31.04, 59.33],
            [20.0, 49.93, 6.102, 12.44, 5.940, 15.89, 28.67],
        ]
        for row in rows {
            let point = try #require(KingeryBulmash.point(at: row[0]))
            let duration = try #require(KingeryBulmash.scaledDuration(at: row[0]))
            let pairs = [
                (point.scaledArrival * 1000, row[1]), (point.incidentPressure / 1000, row[2]),
                (point.reflectedPressure / 1000, row[3]), (duration * 1000, row[4]),
                (point.scaledIncidentImpulse, row[5]), (point.scaledReflectedImpulse, row[6]),
            ]
            for (value, table) in pairs {
                #expect(abs(value - table) / table < 0.01, "Z = \(row[0]): \(value) against \(table)")
            }
        }
        #expect(abs((KingeryBulmash.shockVelocity(at: 5) ?? 0) - 398) < 4)
        // The independent IATG worked examples agree with the curves within a few per cent.
        for example in KingeryBulmash.hemisphericalSurfaceBurst {
            let point = try #require(KingeryBulmash.point(at: example.scaledDistance))
            #expect(abs(point.incidentPressure / example.incidentPressure - 1) < 0.06)
            #expect(abs(point.scaledReflectedImpulse / example.scaledReflectedImpulse - 1) < 0.06)
            #expect(abs(point.scaledArrival / example.scaledArrival - 1) < 0.06)
        }
        #expect(KingeryBulmash.point(at: 0.1) == nil)
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
