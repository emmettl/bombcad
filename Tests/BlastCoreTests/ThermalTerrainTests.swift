import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

@Suite("The terrain hides the fireball from what is behind it")
struct ThermalTerrainTests {
    private static let gpu = MTLCreateSystemDefaultDevice()?.supportsRaytracing == true
    private let domain = SIMD3<Float>(100, 100, 50)

    /// A ridge 10 m high across the domain, its crest at x = 50, its flanks 10 m long either side.
    private var ridge: Terrain { .ridge(domain: domain, spacing: 1, crest: 50, height: 10, halfWidth: 10) }

    private func scene(_ terrain: Terrain?) -> FragmentScene {
        var scenario = Scenario(
            name: "Ridge", domainSize: domain, boxes: [], charge: Charge(mass: 1, position: SIMD3(30, 50, 1)))
        scenario.gauges = []
        scenario.terrain = terrain
        return FragmentScene(scenario)
    }

    private func sphere(_ centre: SIMD3<Float>, radius: Float) -> FireballFrame {
        FireballFrame(
            time: 0, volume: 4 / 3 * Double.pi * pow(Double(radius), 3), centre: centre, temperature: 2000,
            hottest: 2000)
    }

    /// The irradiance from `frame` at each of `points`, facing up, with `visibility`.
    private func irradiance(
        _ visibility: any ThermalVisibility, _ terrain: Terrain?, _ frame: FireballFrame,
        at points: [SIMD3<Float>]
    ) -> [Float] {
        var spec = ThermalSpec()
        spec.samples = 1024
        spec.groundSpacing = 50
        spec.surfaceSpacing = 50
        let exposure = ThermalExposure(spec: spec, scene: scene(terrain), visibility: visibility)
        let power = Float(ThermalExposure.stefanBoltzmann) * pow(2000, 4) * spec.emissivity
        return points.map {
            exposure.irradiance(
                at: ThermalReceiver(position: $0, normal: SIMD3(0, 0, 1), surface: "test"), frame,
                power: power)
        }
    }

    /// The tests to run: the CPU's, and the GPU's where it has ray tracing.
    private func visibilities(_ terrain: Terrain?) throws -> [(String, any ThermalVisibility)] {
        var tests: [(String, any ThermalVisibility)] = [
            ("CPU", CPUThermalVisibility(occluders: [], terrain: terrain))
        ]
        if Self.gpu, TerrainSight(terrain) != nil {
            tests.append(("GPU", try #require(MetalThermalVisibility(occluders: [], terrain: terrain))))
        }
        return tests
    }

    @Test("A receiver behind a ridge sees nothing of a fireball low before it, and all of one risen above it")
    func behindARidge() throws {
        let behind = SIMD3<Float>(75, 50, 0.001)
        let before = SIMD3<Float>(20, 50, 0.001)
        let flat = CPUThermalVisibility(occluders: [])
        let low = sphere(SIMD3(30, 50, 4), radius: 2)
        let high = sphere(SIMD3(30, 50, 40), radius: 5)
        // On the plane through the receiver and the crest: half of it is hidden.
        let half = sphere(SIMD3(30, 50, 18), radius: 4)
        let open = irradiance(flat, nil, low, at: [behind, before])
        let openHigh = irradiance(flat, nil, high, at: [behind])[0]
        let openHalf = irradiance(flat, nil, half, at: [behind])[0]
        #expect(open[0] > 0 && open[1] > 0 && openHigh > 0)
        for (name, visibility) in try visibilities(ridge) {
            let found = irradiance(visibility, ridge, low, at: [behind, before])
            #expect(found[0] == 0, "\(name): \(found[0]) W/m² behind the ridge")
            // Before the ridge nothing is in the way: the same rays, the same answer.
            #expect(found[1] == open[1], "\(name)")
            #expect(irradiance(visibility, ridge, high, at: [behind])[0] == openHigh, "\(name)")
            let share = irradiance(visibility, ridge, half, at: [behind])[0] / openHalf
            #expect(share > 0.35 && share < 0.65, "\(name): \(share) of the half-hidden fireball")
            print("\(name): a fireball centred on the crest's sight line, \(share) of it seen")
        }
    }

    @Test("Flat terrain is the floor: no test is added, and the answers are the same")
    func flatIsTheFloor() {
        let flat = Terrain.flat(domain: domain, spacing: 2)
        #expect(TerrainSight(flat) == nil && TerrainSight(nil) == nil)
        #expect(MetalThermalVisibility(occluders: [], terrain: flat) == nil)
        #expect(ThermalExposure.defaultVisibility(occluders: [], terrain: flat) is CPUThermalVisibility)
    }

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

    @Test(
        "The GPU's test is the CPU's, ray for ray, on a rough terrain with blocks",
        .enabled(if: ThermalTerrainTests.gpu))
    func gpuAgrees() throws {
        let terrain = rough
        let blocks = [
            Box(min: SIMD3(40, 40, 0), max: SIMD3(44, 60, 14)),
            Box(min: SIMD3(70, 10, 5), max: SIMD3(72, 30, 20)),
        ]
        let rays = segments(over: terrain, count: 50_000)
        let cpu = CPUThermalVisibility(occluders: blocks, terrain: terrain).visible(rays)
        let metal = try #require(MetalThermalVisibility(occluders: blocks, terrain: terrain))
        let gpu = metal.visible(rays)
        #expect(metal.usage.gpuFrames == 1)
        let differing = zip(cpu, gpu).filter { $0 != $1 }.count
        #expect(differing == 0, "\(differing) of \(rays.count) rays differ")
        let hidden = cpu.filter { !$0 }.count
        #expect(hidden > 10_000 && hidden < 40_000, "\(hidden) hidden")
        // And with no blocks, the terrain alone.
        let alone = try #require(MetalThermalVisibility(occluders: [], terrain: terrain))
        #expect(alone.visible(rays) == CPUThermalVisibility(occluders: [], terrain: terrain).visible(rays))
    }

    /// A cube of gas at 2,000 K, `side` metres, centred at `centre`, in voxels of 0.25 m.
    private func gas(_ centre: SIMD3<Float>, side: Float) -> FireballFrame {
        let size: Float = 0.25
        let n = Int32((side / size).rounded())
        let first = SIMD3<Int32>(((centre - side / 2) / size).rounded(.down))
        let count = Int(n * n * n)
        let cells = LuminousCells(
            voxelSize: size, first: first, counts: SIMD3(repeating: n),
            fills: [UInt8](repeating: 255, count: count),
            temperatures: [UInt16](repeating: 2000, count: count), products: nil)
        return FireballFrame(
            time: 0, volume: cells.volume, centre: centre, temperature: 2000, hottest: 2000, cells: cells)
    }

    @Test("The volume's march stops at the terrain, on the CPU and the GPU alike")
    func march() throws {
        var spec = ThermalSpec()
        spec.fireball = .volume
        spec.absorption = 0.5
        spec.sootYield = 0
        spec.samples = 256
        spec.groundSpacing = 10
        spec.surfaceSpacing = 10
        let spiral = ThermalExposure.spread(spec.samples)
        func exposure(_ terrain: Terrain?, gpu: Bool) throws -> ThermalExposure {
            let march: any ThermalMarch =
                gpu
                ? try #require(MetalThermalMarch(occluders: [], terrain: terrain, spiral: spiral))
                : CPUThermalMarch(occluders: [], terrain: terrain, spiral: spiral)
            return ThermalExposure(
                spec: spec, scene: scene(terrain),
                visibility: CPUThermalVisibility(occluders: [], terrain: terrain),
                march: march)
        }
        func at(_ exposure: ThermalExposure, _ frame: FireballFrame, _ point: SIMD3<Float>) throws -> Float {
            let medium = try #require(exposure.medium(frame))
            let receiver = ThermalReceiver(position: point, normal: SIMD3(0, 0, 1), surface: "test")
            return exposure.march!.irradiance(
                medium, receivers: ThermalReceiverSet([receiver]), occluded: true)[0]
        }
        let low = gas(SIMD3(30, 50, 3), side: 4)
        let behind = SIMD3<Float>(75, 50, 0.001)
        let before = SIMD3<Float>(20, 50, 0.001)
        var answers: [[Float]] = []
        for gpu in Self.gpu ? [false, true] : [false] {
            let flat = try exposure(nil, gpu: gpu)
            let hilly = try exposure(ridge, gpu: gpu)
            #expect(try at(flat, low, behind) > 0)
            #expect(try at(hilly, low, behind) == 0, "gpu: \(gpu)")
            #expect(try at(hilly, low, before) == at(flat, low, before), "gpu: \(gpu)")
            // Every receiver on the ridge's ground, which sees the gas over the crest or not at all.
            answers.append(hilly.irradiance(low))
        }
        if answers.count == 2 {
            let largest = answers[0].max() ?? 0
            let worst = zip(answers[0], answers[1]).map { abs($0 - $1) }.max() ?? 0
            #expect(largest > 0 && worst < 1e-3 * largest, "\(worst) of \(largest)")
            #expect(answers[0].filter { $0 == 0 }.count == answers[1].filter { $0 == 0 }.count)
        }
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
