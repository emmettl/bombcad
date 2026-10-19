import Foundation
import Testing
import simd

@testable import BlastModel

/// The ground's shape as a heightfield the air sees as solid.
@Suite("Terrain")
struct TerrainTests {
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
