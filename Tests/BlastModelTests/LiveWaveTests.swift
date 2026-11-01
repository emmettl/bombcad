import Foundation
import Testing
import simd

@testable import BlastModel

/// The live blast wave's paths, strengths and times (docs/live-wave.md).
struct LiveWaveTests {
    /// An open plan `n` cells square on `cell` m cells, with `blocks` (i0, j0, i1, j1, height) on it.
    static func plan(_ n: Int, cell: Float = 4, blocks: [(Int, Int, Int, Int, Float)] = []) -> LiveWave.Plan {
        var height = [Float](repeating: 0, count: n * n)
        for (i0, j0, i1, j1, h) in blocks {
            for j in j0...j1 { for i in i0...i1 { height[i + n * j] = h } }
        }
        return LiveWave.Plan(
            columns: n, rows: n, cell: cell, height: height, ground: [Float](repeating: 0, count: n * n))
    }

    @Test("In the open the path is the straight line to within 1.3%, and never shorter")
    func openPaths() {
        let plan = Self.plan(201)
        let charge = SIMD3<Float>(402, 402, 0)
        let (path, straight) = LiveWave.paths(plan: plan, charge: charge)
        // Beyond a few cells, within the steps' 1.3% and the lattice's cell or so.
        var worst: Float = 0
        var far: Float = 0
        for n in path.indices where straight[n] > 40 {
            let ratio = path[n] / straight[n]
            #expect(ratio >= 0.9999)
            worst = max(worst, ratio)
            if straight[n] > 300 { far = max(far, ratio) }
        }
        #expect(worst < 1.025)
        #expect(far < 1.014)
        #expect(far > 1.005)
    }

    @Test("In the open the wave is Kingery–Bulmash's along the straight line, uncorrected")
    func openStrength() throws {
        let plan = Self.plan(201)
        let charge = SIMD3<Float>(402, 402, 0)
        let mass = 100_000.0
        let field = LiveWave.field(plan: plan, charge: charge, mass: mass, coefficients: .none)
        // A cell 300 m east, on an axis, where the path is exact.
        let n = (100 + 75) + 201 * 100
        let r = Double(field.straight[n])
        let z = r / cbrt(mass)
        let kb = try #require(KingeryBulmash.point(at: z))
        #expect(abs(Double(field.path[n]) - r) < 1e-3)
        #expect(abs(Double(field.peak[n]) / kb.incidentPressure - 1) < 0.01)
        #expect(abs(Double(field.arrival[n]) / kb.arrival(mass: mass) - 1) < 0.01)
        let duration = try #require(KingeryBulmash.scaledDuration(at: z)) * cbrt(mass)
        #expect(abs(Double(field.duration[n]) / duration - 1) < 0.01)
        // The Friedlander pulse carries Kingery–Bulmash's impulse.
        let steps = 4000
        var impulse = 0.0
        for k in 0..<steps {
            let t = field.arrival[n] + Float((Double(k) + 0.5) / Double(steps)) * field.duration[n]
            impulse += Double(field.overpressure(n, at: t)) * Double(field.duration[n]) / Double(steps)
        }
        #expect(abs(impulse / kb.incidentImpulse(mass: mass) - 1) < 0.02)
        #expect(field.overpressure(n, at: field.arrival[n] - 1e-4) == 0)
        #expect(field.lastArrival > field.arrival[n])
    }

    @Test(
        "Behind a long wall the front comes later and weaker, and over a low one sooner than round a tall one"
    )
    func shadow() {
        let charge = SIMD3<Float>(100 * 4 + 2, 60 * 4 + 2, 0)
        // A wall 20 cells east of the charge, 3 cells thick, 121 long, 10 m and then 40 m high.
        let low = Self.plan(201, blocks: [(120, 0, 122, 120, 10)])
        let tall = Self.plan(201, blocks: [(120, 0, 122, 120, 40)])
        let open = Self.plan(201)
        let behind = 130 + 201 * 60
        let a = LiveWave.field(plan: open, charge: charge, mass: 1000, coefficients: .none)
        let b = LiveWave.field(plan: low, charge: charge, mass: 1000, coefficients: .none)
        let c = LiveWave.field(plan: tall, charge: charge, mass: 1000, coefficients: .none)
        #expect(b.arrival[behind] > a.arrival[behind])
        #expect(c.arrival[behind] > b.arrival[behind])
        #expect(b.peak[behind] < a.peak[behind])
        #expect(c.peak[behind] < b.peak[behind])
        // The path goes over the 10 m wall, hugging it: longer than a string stretched over it
        // through the air (2 m more), shorter than straight up and down it (20 m).
        let over = b.path[behind] - a.path[behind]
        #expect(over > 2 && over < 20)
        #expect(b.excess(behind) > 0.02)
        #expect(a.excess(behind) < 0.001)
        // A cell in front of the wall is as in the open.
        let front = 110 + 201 * 60
        #expect(abs(b.arrival[front] - a.arrival[front]) < 1e-6)
    }

    @Test("A step never cuts the corner of a building between two cells")
    func corners() {
        // Two blocks meeting at a corner, diagonally, leave no gap to pass through.
        let plan = Self.plan(
            41, blocks: [(0, 0, 20, 20, 30), (21, 21, 40, 40, 30)])
        let charge = SIMD3<Float>(30 * 4 + 2, 10 * 4 + 2, 0)
        let (path, straight) = LiveWave.paths(plan: plan, charge: charge)
        // Across the corner, at the other open quarter: over the roofs, 30 m up and down, not
        // through the corner.
        let n = 10 + 41 * 30
        #expect(path[n] > straight[n] + 25)
    }

    @Test("A step knows the cells it crosses and the corners it passes between")
    func stepCells() {
        let diagonal = LiveWave.crossed(1, 1)
        #expect(diagonal.over.isEmpty)
        #expect(diagonal.between.count == 1)
        // (3, −1) passes through the corner at (1.5, −0.5), between (2, 0) and (1, −1).
        let long = LiveWave.crossed(3, -1)
        #expect(
            long.over.count == 2 && long.over.contains { $0 == (1, 0) }
                && long.over.contains { $0 == (2, -1) })
        #expect(long.between.count == 1)
        let pair = long.between[0]
        #expect([pair.0, pair.1].contains { $0 == (2, 0) } && [pair.0, pair.1].contains { $0 == (1, -1) })
        // (2, 1) runs along the edge at x = 1, through two cells' insides and no corner.
        let knight = LiveWave.crossed(2, 1)
        #expect(knight.over.count == 2 && knight.between.isEmpty)
        #expect(LiveWave.steps.count == 32)
    }

    @Test("A plan from a scene matches the learned field's, cell for cell")
    func planFromScene() {
        var scene = ScenarioPreset.streetCanyon.scenario
        scene.charge.position = SIMD3(scene.domainSize.x / 2, scene.domainSize.y / 2, 0.5)
        let plan = LiveWave.Plan(scene: scene, cell: LearnedField.cellSize)
        let learned = LearnedField.Plan(scene: scene)
        #expect(plan.columns == learned.columns && plan.rows == learned.rows)
        #expect(plan.height == learned.height)
        #expect(plan.ground == learned.ground)
    }

    @Test("The cell size coarsens until the plan has few enough cells")
    func cellSize() {
        var scene = ScenarioPreset.streetCanyon.scenario
        #expect(LiveWave.Plan.cellSize(for: scene) == 4)
        scene.domainSize = SIMD3(8000, 8000, 300)
        let cell = LiveWave.Plan.cellSize(for: scene)
        #expect(cell == 8)
        #expect(Double(8000 / cell) * Double(8000 / cell) <= 1_700_000)
    }

    @Test("Friedlander's exponent gives back the impulse share it was asked for")
    func decay() {
        for ratio in [0.45, 0.3, 0.2, 0.1] {
            let b = LiveWave.Table.decay(ratio)
            let share = 1 / b - (1 - exp(-b)) / (b * b)
            #expect(abs(share - ratio) < 1e-6)
        }
        #expect(LiveWave.Table.decay(0.6) == 0)
    }
}
