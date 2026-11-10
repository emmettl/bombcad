import Metal
import Testing
import simd

@testable import BlastCore
@testable import BlastModel

/// The quarry face's contact solver, fired and left to settle. Illustrative scene: these guard the
/// stability found in stage 3 of docs/hillside-blast.md (no block thrown by contact, the pile at
/// rest at the end), nothing more.
@Suite("Quarry face solver", .serialized, .gpuThreads)
struct QuarrySimulationTests {
    @Test("A small face fires and settles: nothing thrown by contact, the pile at rest at the end")
    func firesAndSettles() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var options = QuarryFace.Options()
        options.blocks = 20000
        options.meshDetail = 1
        var face = try QuarryFace(site: .builtIn(), options: options)
        face.generate()
        let firings = QuarryFiringPattern.row(face: face, count: 10, first: 0.5, stagger: 0.08)
        let simulation = try QuarrySimulation(
            device: device, face: face, launch: QuarryLaunch(), firings: firings, dt: 1 / 240)
        let bodies = simulation.bodyCount
        func positions() -> [SIMD3<Float>] {
            let p = simulation.pose.contents().bindMemory(to: SIMD4<Float>.self, capacity: 2 * bodies)
            return (0..<bodies).map { SIMD3(p[2 * $0].x, p[2 * $0].y, p[2 * $0].z) }
        }
        let launch = QuarryLaunch()
        var fastest: Float = 0
        var before: [SIMD3<Float>] = []
        let frames = 30 * 12
        for frame in 0..<frames {
            simulation.advance(substeps: 8)
            fastest = max(fastest, simulation.census().maxSpeed)
            if frame == frames - 31 { before = positions() }
        }
        let after = positions()
        #expect(after.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
        // The stated launch law gives at most 1.2 speed0 (and falling adds a little); contact must
        // not throw anything faster.
        #expect(fastest < launch.speed0 * 1.2 + 10)
        // In the last second the pile is at rest: a late block may still topple off the new face,
        // but nothing rings or creeps (before the fixes of stage 3, 77 of 92,000 moved over 10 cm
        // and the 99th percentile was 2.8 cm).
        let moved = zip(before, after).map { simd_distance($0, $1) }.sorted()
        #expect(moved[moved.count * 99 / 100] < 0.01)
        #expect(moved.filter { $0 > 0.1 }.count < max(10, bodies / 1000))
        // It did fire: much of the rock has moved from where it stood.
        let start = face.blocks.map(\.centre)
        #expect(zip(start, after).filter { simd_distance($0, $1) > 1 }.count > bodies / 4)
    }
}
