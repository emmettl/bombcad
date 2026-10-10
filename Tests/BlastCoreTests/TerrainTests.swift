import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

/// The ground's shape as a heightfield the air sees as solid.
@Suite("Terrain")
struct TerrainTests {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    @Test("The bilinear surface reproduces a plane, and its normal")
    func plane() {
        let terrain = Terrain.sampled(domain: SIMD3(20, 12, 10), spacing: 0.7) { 0.3 * $0.x + 0.1 * $0.y + 1 }
        for p in [SIMD2<Float>(3.1, 4.2), SIMD2(0.05, 11.9), SIMD2(13.3, 0.4)] {
            #expect(abs(terrain.height(at: p) - (0.3 * p.x + 0.1 * p.y + 1)) < 1e-4)
            let normal = terrain.normal(at: p)
            #expect(simd_distance(normal, simd_normalize(SIMD3(-0.3, -0.1, 1))) < 1e-4)
        }
        // Beyond the nodes the edge is carried outward, flat.
        let edge = terrain.extent
        #expect(terrain.height(at: SIMD2(edge.x + 5, 3)) == terrain.height(at: SIMD2(edge.x, 3)))
        #expect(terrain.normal(at: SIMD2(-3, -3)).z == 1)
    }

    @Test("Heights round-trip exactly, and scenes without terrain encode as before")
    func persistence() throws {
        let hill = Terrain.hill(
            domain: SIMD3(30, 20, 12), spacing: 0.5, centre: SIMD2(15, 10), height: 4, radius: 3)
        let decoded = try JSONDecoder().decode(Terrain.self, from: JSONEncoder().encode(hill))
        #expect(decoded == hill)

        var scenario = ScenarioPreset.openGround.scenario
        let plain = try JSONEncoder().encode(scenario)
        #expect(String(decoding: plain, as: UTF8.self).contains("terrain") == false)
        #expect(try JSONDecoder().decode(Scenario.self, from: plain).terrain == nil)
        scenario.terrain = .flat(domain: scenario.domainSize, spacing: 1)
        let shaped = try JSONDecoder().decode(Scenario.self, from: JSONEncoder().encode(scenario))
        #expect(shaped.terrain == scenario.terrain)
    }

    @Test("Invalid terrain is refused")
    func validation() {
        let domain = SIMD3<Float>(10, 10, 5)
        #expect(throws: Terrain.Failure.invalidGrid) {
            try Terrain(spacing: 1, columns: 1, rows: 3, heights: [0, 0, 0]).validate()
        }
        #expect(throws: Terrain.Failure.invalidHeight) {
            try Terrain(spacing: 1, columns: 2, rows: 2, heights: [0, -1, 0, 0]).validate()
        }
        #expect(throws: Terrain.Failure.tooHigh(6)) {
            try Terrain(spacing: 1, columns: 2, rows: 2, heights: [0, 6, 0, 0]).validate(domain: domain)
        }
    }

    private func slopeScenario(cell: Float) -> Scenario {
        var scenario = Scenario(
            name: "Slope", domainSize: SIMD3(24, 8, 12), boxes: [],
            charge: Charge(mass: 2, position: SIMD3(4, 4, 1)))
        scenario.terrain = .slope(domain: scenario.domainSize, spacing: cell, foot: 8, angle: 30)
        return scenario
    }

    @Test("A coarse cell is solid exactly where its centre is below the surface")
    func coarseMask() throws {
        let scenario = slopeScenario(cell: 0.5)
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.5)
        let grid = solver.grid
        let terrain = try #require(scenario.terrain)
        var mismatched = 0
        for k in 0..<grid.nz {
            for j in 0..<grid.ny {
                for i in 0..<grid.nx {
                    let c = grid.cellCentre(i, j, k)
                    if solver.isSolid(i, j, k) != terrain.contains(SIMD3(c.x, c.y, c.z)) { mismatched += 1 }
                }
            }
        }
        #expect(mismatched == 0)
        #expect(
            solver.terrainSurface?[30 + grid.nx * 4] == Int32(terrain.buriedCells(i: 30, j: 4, grid: grid)))
    }

    @Test("Fine cells follow the surface at their own resolution, on both levels")
    func fineOutline() throws {
        var configuration = SolverConfiguration()
        configuration.refinement = 2
        configuration.refinementLevels = 2
        configuration.refinementThreshold = -1
        configuration.refinementFinerThreshold = -1
        configuration.refinementMemory = 512 << 20
        var scenario = slopeScenario(cell: 0.5)
        scenario.domainSize = SIMD3(12, 4, 6)
        scenario.terrain = .hill(
            domain: scenario.domainSize, spacing: 0.3, centre: SIMD2(6, 2), height: 3, radius: 2)
        scenario.charge.position = SIMD3(2, 2, 1)
        let solver = try BlastSolver(
            device: device, scenario: scenario, cellSize: 0.5, configuration: configuration)
        _ = solver.advance(steps: 2)
        let terrain = try #require(scenario.terrain)
        let levels = solver.refinementLevels
        #expect(levels.count == 2)
        for level in levels {
            let fine = solver.grid.cellSize / Float(level.parentScale * level.ratio)
            let outline = level.rigidOutline(solver.grid)
            #expect(!outline.isEmpty)
            let wrong = outline.filter { $0.rigid != terrain.contains((SIMD3<Float>($0.cell) + 0.5) * fine) }
            #expect(wrong.isEmpty, "\(wrong.count) of \(outline.count) fine cells")
            #expect(outline.contains { $0.rigid })
        }
    }

    @Test("Flat terrain is exactly the flat ground, with refinement")
    func flatIsGround() throws {
        var configuration = SolverConfiguration()
        configuration.refinement = 2
        configuration.refinementMemory = 256 << 20
        var scenario = Scenario(
            name: "Open", domainSize: SIMD3(16, 12, 8), boxes: [],
            charge: Charge(mass: 1, position: SIMD3(8, 6, 0.5)))
        let plain = try BlastSolver(
            device: device, scenario: scenario, cellSize: 0.5, configuration: configuration)
        scenario.terrain = .flat(domain: scenario.domainSize, spacing: 0.37)
        let flat = try BlastSolver(
            device: device, scenario: scenario, cellSize: 0.5, configuration: configuration)
        _ = plain.advance(steps: 40)
        _ = flat.advance(steps: 40)
        let same = plain.withState { a in flat.withState { b in Array(a) == Array(b) } }
        #expect(same)
    }

    @Test("A closed box over a hill conserves its gas, refined")
    func conservation() throws {
        var configuration = SolverConfiguration()
        configuration.refinement = 2
        configuration.refinementMemory = 256 << 20
        var scenario = Scenario(
            name: "Closed hill", domainSize: SIMD3(20, 12, 10), boxes: [],
            charge: Charge(mass: 2, position: SIMD3(5, 6, 1)))
        scenario.reflectiveFaces = .all
        scenario.terrain = .hill(
            domain: scenario.domainSize, spacing: 0.4, centre: SIMD2(13, 6), height: 4, radius: 2.5)
        let solver = try BlastSolver(
            device: device, scenario: scenario, cellSize: 0.5, configuration: configuration)
        let before = solver.totals()
        let result = solver.advance(steps: 120)
        let after = solver.totals()
        #expect(result.refinedTiles > 0)
        // Where the coarse and fine outlines differ, a new patch gains still air in fine cells of air
        // under solid coarse cells and gives up the gas over fine cells of terrain under coarse cells
        // of air; the two nearly balance over the surface: 0.08% in 120 steps.
        #expect(abs(after.mass / before.mass - 1) < 2e-3)
        #expect(abs(after.energy / before.energy - 1) < 2e-3)
    }

    @Test("The ground slice reads the first cell of air above the terrain")
    func groundSlice() throws {
        let scenario = slopeScenario(cell: 0.5)
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.5)
        _ = solver.advance(steps: 60)
        let slice = solver.groundSlice(low: SIMD2(0, 0), high: SIMD2(24, 8))
        let grid = solver.grid
        for i in stride(from: 0, to: grid.nx, by: 5) {
            let j = 4
            let k = Int(solver.terrainSurface![i + grid.nx * j])
            let n = 3 * (i + Int(slice.counts.x) * j)
            #expect(!slice.values[n].isNaN)
            #expect(slice.values[n + 1] == solver.peakOverpressure(i, j, k))
        }
    }
}

/// What follows the terrain besides the air: fragments landing, thermal receivers.
@Suite("Terrain downstream")
struct TerrainDownstreamTests {
    /// Still air of `density` over a 100 m cube, for `duration` from `start`.
    private func still(density: Float, from start: Double, duration: Double) -> (AirSlice, AirSlice) {
        let counts = SIMD3<Int32>(repeating: 10)
        let values = [Float16](
            repeating: 0, count: 5 * 1000
        ).enumerated().map { n, _ in n % 5 == 0 ? Float16(density) : n % 5 == 4 ? Float16(0.101325) : 0 }
        let ambient = Primitive(density: density, pressure: 101_325)
        let a = AirSlice(
            time: start, cellSize: 10, grid: counts, first: .zero, counts: counts, stride: 1, values: values,
            ambient: ambient)
        var b = a
        b.time = start + duration
        return (a, b)
    }

    @Test("A fragment lands on the terrain's surface, where its path meets it")
    func fragmentLands() {
        // A 30° slope rising along x from x = 20 m; dropped from 30 m over x = 40 m, where the
        // surface is 20 tan 30° = 11.55 m up.
        let terrain = Terrain.slope(domain: SIMD3(100, 100, 50), spacing: 1, foot: 20, angle: 30)
        var cloud = FragmentCloud(
            particles: [.init(position: SIMD3(40, 50, 30), velocity: .zero, mass: 0.01, area: 1e-4)],
            terrain: terrain)
        var t = 0.0
        while cloud.airborne > 0, t < 5 {
            let (a, b) = still(density: 0, from: t, duration: 0.01)
            cloud.advance(from: a, to: b)
            t += 0.01
        }
        let impact = cloud.impacts[0]
        #expect(impact.surface == "ground")
        #expect(abs(impact.position.z - 20 * tan(Float.pi / 6)) < 1e-3)
        #expect(abs(impact.time - (2 * (30 - 11.547) / 9.81).squareRoot()) < 2e-3)
    }

    @Test("Thermal receivers on the ground lie on the terrain, facing out of it")
    func thermalReceivers() throws {
        var scenario = Scenario(
            name: "Hill", domainSize: SIMD3(40, 30, 20), boxes: [],
            charge: Charge(mass: 10, position: SIMD3(5, 15, 1)))
        let hill = Terrain.hill(
            domain: scenario.domainSize, spacing: 0.5, centre: SIMD2(25, 15), height: 6, radius: 5)
        scenario.terrain = hill
        let grids = ThermalExposure.surfaceGrids(scene: FragmentScene(scenario), spec: ThermalSpec())
        let ground = try #require(grids.first { $0.surface == "ground" })
        #expect(!ground.receivers.isEmpty)
        for receiver in ground.receivers {
            // A millimetre off the surface along the normal there.
            let foot = receiver.position - 0.001 * receiver.normal
            #expect(simd_distance(receiver.normal, hill.normal(at: SIMD2(foot.x, foot.y))) < 1e-5)
            #expect(abs(foot.z - hill.height(at: foot)) < 1e-4)
        }
        #expect(ground.receivers.contains { $0.normal.z < 0.9 })
    }

    @Test("The USD export carries the terrain as a mesh of its nodes")
    func usd() throws {
        let folder = FileManager.default.temporaryDirectory.appending(
            path: "terrain-usd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "scene.usda")
        var scenario = Scenario(
            name: "Ridge", domainSize: SIMD3(12, 8, 6), boxes: [],
            charge: Charge(mass: 1, position: SIMD3(2, 4, 0.5)))
        scenario.terrain = .ridge(domain: scenario.domainSize, spacing: 2, crest: 6, height: 2, halfWidth: 3)
        let writer = try USDSceneWriter(url: url, scenario: scenario, frameInterval: 0.001)
        try writer.append(nil)
        try writer.finish()
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("def Mesh \"Terrain\""))
        #expect(text.contains("bombcad:terrainSource = \"ridge 2.0 m high, 6.0 m wide\""))
        // 7 × 5 nodes, 6 × 4 quads; the crest's nodes are 2 m up.
        let mesh = try #require(text.components(separatedBy: "def Mesh \"Terrain\"").last)
        let points = try #require(
            mesh.components(separatedBy: "point3f[] points = [").last?.prefix { $0 != "]" })
        #expect(points.components(separatedBy: "), (").count == 35)
        #expect(points.contains("(6, 0, 2)"))
        // Flat ground has none.
        scenario.terrain = .flat(domain: scenario.domainSize, spacing: 2)
        let flatURL = folder.appending(path: "flat.usda")
        let flat = try USDSceneWriter(url: flatURL, scenario: scenario, frameInterval: 0.001)
        try flat.append(nil)
        try flat.finish()
        #expect(try !String(contentsOf: flatURL, encoding: .utf8).contains("Terrain"))
    }
}
