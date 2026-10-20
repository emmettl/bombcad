import Foundation
import Testing
import simd

@testable import BlastModel

@Suite("The terrain hides the fireball from what is behind it")
struct ThermalTerrainTests {
    private let domain = SIMD3<Float>(100, 100, 50)

    /// A ridge 10 m high across the domain, its crest at x = 50, its flanks 10 m long either side.
    private var ridge: Terrain { .ridge(domain: domain, spacing: 1, crest: 50, height: 10, halfWidth: 10) }

    /// A rough terrain of random heights, twisted in every cell, offset from the domain's corner so
    /// that rays run off its nodes, where the edge is carried outward.
    private var rough: Terrain {
        var random = SeededRandom(seed: 11)
        let (columns, rows) = (14, 11)
        return Terrain(
            origin: SIMD2(10, 20), spacing: 5, columns: columns, rows: rows,
            heights: (0..<columns * rows).map { _ in random.next(in: 0...9) }, source: "random")
    }

    /// Segments from just above the surface to anywhere in the domain above the floor.
    private func segments(over terrain: Terrain, count: Int) -> [ThermalRay] {
        var random = SeededRandom(seed: 3)
        return (0..<count).map { _ in
            let x = SIMD2<Float>(random.next(in: 0...100), random.next(in: 0...100))
            let start = SIMD3(x.x, x.y, terrain.height(at: x) + random.next(in: 0.001...4))
            let end = SIMD3<Float>(
                random.next(in: 0...100), random.next(in: 0...100), random.next(in: 0...30))
            return ThermalRay(
                origin: start, direction: simd_normalize(end - start), length: simd_distance(end, start))
        }
    }

    @Test("The sight-line test agrees with the surface sampled finely along each segment")
    func againstSampling() throws {
        let terrain = rough
        let sight = try #require(TerrainSight(terrain))
        let rays = segments(over: terrain, count: 2000)
        var (checked, blocked) = (0, 0)
        for ray in rays {
            // The lowest the segment comes below or above the surface, at 4,000 points.
            var lowest = Float.infinity
            for n in 0...4000 {
                let p = ray.origin + Float(n) / 4000 * ray.length * ray.direction
                lowest = min(lowest, p.z - terrain.height(at: p))
            }
            // Too close to call by sampling: a grazing segment, or a step between samples.
            if abs(lowest) < 0.05 { continue }
            checked += 1
            if lowest < 0 { blocked += 1 }
            #expect(
                sight.blocks(from: ray.origin, to: ray.end) == (lowest < 0), "\(ray), clearance \(lowest)")
        }
        print("\(checked) segments checked by sampling, \(blocked) blocked")
        #expect(checked > 1800 && blocked > 250 && checked - blocked > 250)
    }

    @Test("Receivers on a block's faces below the terrain are buried")
    func buriedFaces() {
        var spec = ThermalSpec()
        spec.groundSpacing = 20
        spec.surfaceSpacing = 1
        var scenario = Scenario(
            name: "Cut", domainSize: domain, boxes: [Box(min: SIMD3(52, 45, 0), max: SIMD3(54, 55, 20))],
            charge: Charge(mass: 1, position: SIMD3(30, 50, 1)))
        scenario.gauges = []
        scenario.terrain = ridge
        let receivers = ThermalExposure.receivers(scene: FragmentScene(scenario), spec: spec)
        let block = receivers.filter { $0.surface == "block 0" }
        #expect(!block.isEmpty)
        #expect(block.allSatisfy { !ridge.contains($0.position) })
    }
}

/// A small seeded generator.
private struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func next(in range: ClosedRange<Float>) -> Float {
        range.lowerBound + Float(next() >> 40) / Float(1 << 24) * (range.upperBound - range.lowerBound)
    }
}
