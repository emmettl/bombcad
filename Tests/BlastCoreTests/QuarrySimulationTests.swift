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
        // The stated launch law gives at most 1.2 speed0, and falling adds a little; a small piece
        // struck from above by a heavy block can be driven down faster than either (the rock of
        // 12 November 2026 has more small slabs: 28.2 m/s here, 30.2 m/s at 116,000 blocks). The
        // contact fault of stage 2 threw blocks to the 45 m/s cap, well past this bound.
        #expect(fastest < launch.speed0 * 1.2 + 14)
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

    @Test(
        "A ridge cut's crest heaves as a mass before it breaks: the rock over the cut rises while it swells")
    func ridgeHeaves() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var options = QuarryFace.Options()
        options.blocks = 20000
        options.meshDetail = 1
        var face = try QuarryFace(site: .builtIn(.ridgeCut), options: options)
        face.generate()
        let firings = QuarryFiringPattern.pattern(face: face)
        let launch = QuarryLaunch()
        var blocks = face.blocks
        let state = launch.apply(to: &blocks, firings: firings, face: face)
        let simulation = try QuarrySimulation(
            device: device, face: face, launch: launch, firings: firings, dt: 1 / 240)
        // The rock nearest the old ground over the cut, fired.
        let top = (0..<blocks.count).filter {
            let c = face.blocks[$0].centre
            return state.fire[$0] < .greatestFiniteMagnitude && face.height(face.original, c.x, c.y) - c.z < 2
        }
        #expect(top.count > 200)
        // Watched when the first of it lets go, among those that have swelled for 0.7 of their rise
        // and not yet let go.
        let first = top.map { state.fire[$0] }.min()!
        let frames = Int((first * 30).rounded(.down))
        for _ in 0..<frames { simulation.advance(substeps: 8) }
        let now = Float(frames) / 30
        let swelling = top.filter {
            state.fire[$0] > now && state.fire[$0] - state.swell[$0].w < now - 0.7 * state.swell[$0].w
        }
        #expect(swelling.count > 20, "\(swelling.count) swelling at \(now) s")
        let p = simulation.pose.contents().bindMemory(to: SIMD4<Float>.self, capacity: 2 * blocks.count)
        let rise = swelling.map { p[2 * $0].z - face.blocks[$0].centre.z }.sorted()
        // At 0.7 of its rise the swell has moved a block 0.45 of its amplitude (up to 4.5 m;
        // less by the walls): uncarried, the crest's top only sank before it broke.
        #expect(rise[rise.count / 2] > 0.8, "median rise \(rise[rise.count / 2]) m")
        // As a mass: most of it rises together.
        #expect(rise[rise.count / 10] > 0.3, "10th percentile \(rise[rise.count / 10]) m")
    }
}
