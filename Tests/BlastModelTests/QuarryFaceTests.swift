import Testing
import simd

@testable import BlastModel

/// The quarry face's CPU parts: its layout on a terrain, its blocks, its stylised firing
/// patterns and its packed poses. Illustrative scene; these are consistency checks.
@Suite("Quarry face", .serialized)
struct QuarryFaceTests {
    static func small(_ site: QuarrySite = .builtIn(), seed: UInt64 = 2026) throws -> QuarryFace {
        var options = QuarryFace.Options()
        options.blocks = 3000
        options.seed = seed
        options.meshDetail = 1
        var face = try QuarryFace(site: site, options: options)
        face.generate()
        return face
    }

    @Test("Blocks fill the cut between the old and new surfaces, and the generator repeats itself")
    func blocksFillTheCut() throws {
        let face = try Self.small()
        #expect(face.blocks.count > 1500)
        let broken = face.blocks.filter { !$0.skin }
        #expect(!broken.isEmpty && broken.count < face.blocks.count)
        for block in broken {
            let c = block.centre
            // Within a block's size of the cut, sideways too: the faces are steep.
            let near = [-block.size, 0, block.size]
            let old = near.map { face.height(face.original, c.x, c.y + $0) }.max()!
            let new = near.map { face.height(face.terrain.heights, c.x, c.y + $0) }.min()!
            #expect(c.z > new - block.size && c.z < old + block.size, "\(c) between \(new) and \(old)")
            #expect(block.volume > 0 && block.sphereCount >= 1)
        }
        let again = try Self.small()
        #expect(again.blocks.count == face.blocks.count)
        #expect(again.blocks.map(\.centre) == face.blocks.map(\.centre))
        let other = try Self.small(seed: 7)
        #expect(other.blocks.map(\.centre) != face.blocks.map(\.centre))
    }

    @Test("A strip laid on any terrain finds its face; one on flat ground is refused")
    func layoutOnTerrain() throws {
        // The built-in hill turned a quarter round and moved: the same face, found again.
        let built = QuarrySite.builtIn().terrain
        let columns = built.rows
        let rows = built.columns
        var heights = [Float](repeating: 0, count: columns * rows)
        for j in 0..<rows {
            for i in 0..<columns { heights[i + columns * j] = built.height(column: j, row: columns - 1 - i) }
        }
        let origin = SIMD2<Float>(1000, 2000)
        let turned = Terrain(origin: origin, spacing: 1, columns: columns, rows: rows, heights: heights)
        // (x, y) of the built-in hill lies at origin + (row from the top, x + 420) here.
        func place(_ p: SIMD2<Float>) -> SIMD2<Float> {
            origin + SIMD2(Float(columns - 1) - (p.y + 420), p.x + 420)
        }
        let site = QuarrySite(terrain: turned, start: place(SIMD2(0, 0)), end: place(SIMD2(180, 0)))
        let face = try Self.small(site)
        #expect(face.blocks.filter { !$0.skin }.count > 1000)
        #expect(abs(face.faceLine(90)) < 12)
        #expect(simd_distance(face.world(SIMD2(180, 0)), place(SIMD2(180, 0))) < 1e-3)
        let flat = Terrain(
            origin: .zero, spacing: 2, columns: 300, rows: 300, heights: Array(repeating: 5, count: 90_000))
        #expect(throws: QuarryFace.Failure.noFace) {
            try QuarryFace(site: QuarrySite(terrain: flat, start: SIMD2(100, 300), end: SIMD2(400, 300)))
        }
        #expect(throws: QuarryFace.Failure.stripTooShort) {
            try QuarryFace(site: QuarrySite(terrain: flat, start: SIMD2(100, 300), end: SIMD2(110, 300)))
        }
    }

    @Test("Each firing order fires every point once, at the stagger, starting at the first time")
    func firingOrders() throws {
        let face = try Self.small()
        for order in QuarryFiringOrder.allCases {
            let row = QuarryFiringPattern.row(
                face: face, count: 12, first: 1.8, stagger: 0.07, order: order)
            #expect(row.count == 12)
            let times = row.map(\.time).sorted()
            for (k, t) in times.enumerated() { #expect(abs(t - (1.8 + 0.07 * Float(k))) < 1e-5) }
            #expect(zip(row, row.dropFirst()).allSatisfy { $0.position.x < $1.position.x })
        }
        let right = QuarryFiringPattern.row(face: face, count: 5, order: .rightToLeft)
        #expect(right.first!.time > right.last!.time)
        let centre = QuarryFiringPattern.row(face: face, count: 5, order: .centreOut)
        #expect(centre[2].time == centre.map(\.time).min())
    }

    @Test("The launch law is the stated one: bounded, and nothing held moves")
    func launchLaw() throws {
        let face = try Self.small()
        var blocks = face.blocks
        let launch = QuarryLaunch()
        let row = QuarryFiringPattern.row(face: face)
        let state = launch.apply(to: &blocks, firings: row, face: face)
        for (n, block) in face.blocks.enumerated() {
            let speed = simd_length(state.velocity[n])
            #expect(speed <= launch.speed0 * 1.2 + 1e-3)
            if block.skin { #expect(speed == 0 && state.fire[n] == .greatestFiniteMagnitude) }
        }
    }

    @Test("Packed poses come back within millimetres and a tenth of a degree, interpolated between")
    func poseCacheRoundTrip() {
        let bodies = 200
        var random = QuarryRandom(seed: 3)
        let low = SIMD3<Float>(-90, -190, -6)
        let high = SIMD3<Float>(290, 110, 110)
        func pose() -> [SIMD4<Float>] {
            (0..<bodies).flatMap { _ -> [SIMD4<Float>] in
                let p = SIMD3(random.float(-80, 280), random.float(-180, 100), random.float(0, 100))
                let q = simd_normalize(SIMD4(random.unit(), random.float(-1, 1)))
                return [SIMD4(p, 1), q]
            }
        }
        let frames = [pose(), pose(), pose()]
        var still = [Bool](repeating: false, count: bodies)
        still[7] = true
        let cache = QuarryPoseCache(rest: frames[0], still: still, frames: 3, low: low, high: high, stride: 2)
        for (f, frame) in frames.enumerated() {
            frame.withUnsafeBufferPointer { cache.store(frame: f, pose: $0.baseAddress!) }
        }
        var out = [SIMD4<Float>](repeating: .zero, count: 2 * bodies)
        for f in [0, 2] {
            out.withUnsafeMutableBufferPointer { cache.decode(frame: f, into: $0.baseAddress!) }
            for n in 0..<bodies where n != 7 {
                let a = frames[f][2 * n]
                #expect(
                    simd_distance(SIMD3(a.x, a.y, a.z), SIMD3(out[2 * n].x, out[2 * n].y, out[2 * n].z))
                        < 0.006)
                let q = frames[f][2 * n + 1]
                #expect(abs(simd_dot(q, out[2 * n + 1])) > 0.9999)
            }
        }
        // The middle frame is between the two stored ones.
        out.withUnsafeMutableBufferPointer { cache.decode(frame: 1, into: $0.baseAddress!) }
        let a = frames[0][0]
        let b = frames[2][0]
        let mid = (SIMD3(a.x, a.y, a.z) + SIMD3(b.x, b.y, b.z)) / 2
        #expect(simd_distance(mid, SIMD3(out[0].x, out[0].y, out[0].z)) < 0.01)
        // The still block stays at rest; it is not stored.
        #expect(out[14] == SIMD4(frames[0][14].x, frames[0][14].y, frames[0][14].z, 1))
        #expect(cache.bytes < 3 * bodies * 32)
    }
}
