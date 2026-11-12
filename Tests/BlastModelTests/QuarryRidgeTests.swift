import Testing
import simd

@testable import BlastModel

/// The ridge cut's CPU parts: its layout on a terrain, its blocks, its stylised firings and launch,
/// and placing it (emmettl/bombcad-work#131). Illustrative scene; these are consistency checks.
@Suite("Ridge cut", .serialized)
struct QuarryRidgeTests {
    static let ridge = QuarrySite.builtInRidge()

    static func small(_ site: QuarrySite = ridge, seed: UInt64 = 2026) throws -> QuarryFace {
        var options = QuarryFace.Options()
        options.blocks = 3000
        options.seed = seed
        options.meshDetail = 1
        var face = try QuarryFace(site: site, options: options)
        face.generate()
        return face
    }

    @Test(
        "The cut's floor is its depth below the crest, its walls rise from it, and the rock between fills it")
    func blocksFillTheCut() throws {
        let face = try Self.small()
        let ridge = try #require(face.ridge)
        #expect(abs(ridge.floor - (ridge.crest - QuarryRidge.defaultDepth)) < 1e-3)
        // The crest is on the line, near the built-in ridge's own crest (its axis at y = 0).
        #expect(abs(face.world(SIMD2(ridge.crestX, 0)).x - BuiltInRidge.axis(0)) < 6)
        // The ground after the cut: the floor in the middle, the old ground well outside the walls.
        let middle = ridge.crestX
        #expect(abs(face.height(face.terrain.heights, middle, 0) - ridge.floor) < 1e-3)
        let outside = ridge.halfWidth + 2 + (ridge.crest - ridge.floor) / ridge.wallSlope
        #expect(
            face.height(face.terrain.heights, middle, outside + 1)
                == face.height(face.original, middle, outside + 1))
        // The cut runs out on both flanks within the line.
        #expect(ridge.cutStart > 2 && ridge.cutEnd < face.length - 2 && ridge.cutEnd - ridge.cutStart > 50)
        #expect(face.blocks.count > 1500)
        #expect(face.blocks.allSatisfy { !$0.skin })
        for block in face.blocks {
            let c = block.centre
            let near = [-2 * block.size, 0, 2 * block.size]
            let old = near.flatMap { d in near.map { face.height(face.original, c.x + d, c.y + $0) } }.max()!
            let new = near.flatMap { d in near.map { face.height(face.terrain.heights, c.x + d, c.y + $0) } }
                .min()!
            #expect(c.z > new - block.size && c.z < old + block.size, "\(c) between \(new) and \(old)")
            #expect(abs(c.y) < outside + block.size)
        }
        let again = try Self.small()
        #expect(again.blocks.map(\.centre) == face.blocks.map(\.centre))
    }

    @Test(
        "A cut laid on a turned and moved copy of the ridge finds the same cut; flat ground, a slope and a line along the crest are refused"
    )
    func layoutOnTerrain() throws {
        // The middle of the built-in ridge turned a quarter round and moved.
        let built = Self.ridge.terrain
        let size = 501
        let first = SIMD2<Float>(-250, -250)
        var heights = [Float](repeating: 0, count: size * size)
        for j in 0..<size {
            for i in 0..<size {
                // (i, j) here is (x, y) = first + (j, size - 1 - i) of the built-in ridge.
                heights[i + size * j] = built.height(at: first + SIMD2(Float(j), Float(size - 1 - i)))
            }
        }
        let origin = SIMD2<Float>(3000, -7000)
        let turned = Terrain(origin: origin, spacing: 1, columns: size, rows: size, heights: heights)
        func place(_ p: SIMD2<Float>) -> SIMD2<Float> {
            origin + SIMD2(Float(size - 1) - (p.y - first.y), p.x - first.x)
        }
        let base = Self.ridge
        let site = QuarrySite(
            terrain: turned, start: place(base.start), end: place(base.end), depth: base.depth,
            scene: .ridgeCut,
            width: base.width)
        let original = try QuarryFace(site: base)
        let moved = try QuarryFace(site: site)
        let (a, b) = (try #require(original.ridge), try #require(moved.ridge))
        #expect(abs(a.crest - b.crest) < 0.05 && abs(a.crestX - b.crestX) < 0.6)
        #expect(abs(a.cutStart - b.cutStart) < 1.5 && abs(a.cutEnd - b.cutEnd) < 1.5)
        let volume = { (f: QuarryFace) in
            zip(f.original, f.terrain.heights).reduce(Float(0)) { $0 + $1.0 - $1.1 }
        }
        #expect(abs(volume(original) / volume(moved) - 1) < 0.02)

        let flat = Terrain(
            origin: .zero, spacing: 2, columns: 300, rows: 300, heights: Array(repeating: 5, count: 90_000))
        #expect(throws: QuarryFace.Failure.noFace) {
            try QuarryFace(
                site: QuarrySite(
                    terrain: flat, start: SIMD2(100, 300), end: SIMD2(300, 300), scene: .ridgeCut))
        }
        let slope = Terrain(
            origin: .zero, spacing: 2, columns: 300, rows: 300,
            heights: (0..<90_000).map { Float($0 % 300) * 0.3 })
        #expect(throws: QuarryFace.Failure.noFace) {
            try QuarryFace(
                site: QuarrySite(
                    terrain: slope, start: SIMD2(100, 300), end: SIMD2(300, 300), scene: .ridgeCut))
        }
        // Along the crest rather than across it.
        let along = QuarrySite(
            terrain: built, start: SIMD2(BuiltInRidge.axis(-60), -60), end: SIMD2(BuiltInRidge.axis(60), 60),
            scene: .ridgeCut)
        #expect(throws: QuarryFace.Failure.noFace) { try QuarryFace(site: along) }
    }

    @Test(
        "Each firing order fires every point once at the stagger, in rows inside the cut; centre out starts at the crest"
    )
    func firings() throws {
        let face = try Self.small()
        let ridge = try #require(face.ridge)
        for count in [6, 16, 30] {
            for order in QuarryFiringOrder.allCases {
                let firings = QuarryFiringPattern.pattern(
                    face: face, count: count, first: 1.8, stagger: 0.07, order: order)
                #expect(firings.count == count)
                let times = firings.map(\.time).sorted()
                for (k, t) in times.enumerated() { #expect(abs(t - (1.8 + 0.07 * Float(k))) < 1e-4) }
                for f in firings {
                    let p = f.position
                    #expect(p.x >= ridge.cutStart && p.x <= ridge.cutEnd)
                    #expect(abs(p.y) < ridge.halfWidth * 0.5)
                    let floor = face.height(face.terrain.heights, p.x, p.y)
                    let top = face.height(face.original, p.x, p.y)
                    #expect(p.z > floor && p.z < top)
                }
                // Two rows from 10 firings, one below.
                let rows = Set(firings.map { $0.position.y > 0 ? 1 : $0.position.y < 0 ? -1 : 0 })
                #expect(rows.count == (count >= 10 ? 2 : 1))
                if order == .leftToRight {
                    let byTime = firings.sorted { $0.time < $1.time }.map(\.position.x)
                    #expect(byTime == byTime.sorted())
                }
                if order == .centreOut {
                    let firstFired = try #require(firings.min { $0.time < $1.time })
                    let nearest = firings.map { abs($0.position.x - ridge.crestX) }.min()!
                    #expect(abs(abs(firstFired.position.x - ridge.crestX) - nearest) < 1e-3)
                }
            }
        }
        // A face's pattern is its row, as it was.
        let quarry = try QuarryFaceTests.small()
        let row = QuarryFiringPattern.row(face: quarry, count: 12, stagger: 0.05, order: .centreOut)
        let pattern = QuarryFiringPattern.pattern(face: quarry, count: 12, stagger: 0.05, order: .centreOut)
        #expect(row.map(\.position) == pattern.map(\.position) && row.map(\.time) == pattern.map(\.time))
    }

    @Test(
        "The launch heaves the crest: blocks near the walls stay, most of the rest go up and out down their own flank"
    )
    func launch() throws {
        var face = try Self.small()
        let ridge = try #require(face.ridge)
        let firings = QuarryFiringPattern.pattern(face: face)
        var blocks = face.blocks
        let state = QuarryLaunch().apply(to: &blocks, firings: firings, face: face)
        let held = (0..<blocks.count).filter { state.fire[$0] == .greatestFiniteMagnitude }
        let released = (0..<blocks.count).filter { state.fire[$0] < .greatestFiniteMagnitude }
        #expect(!held.isEmpty && released.count > held.count)
        // The held ones are those near the walls: none in the middle of the floor.
        for n in held {
            let c = face.blocks[n].centre
            #expect(abs(c.y) > ridge.halfWidth(at: c.x) - 11, "held at \(c)")
        }
        var up = 0
        var outward = 0
        var sided = 0
        let law = QuarryLaunch()
        for n in released {
            let v = state.velocity[n]
            #expect(simd_length(v) <= law.speed0 * 1.2 * 1.01)
            #expect(state.fire[n] >= firings.map(\.time).min()!)
            if v.z > 0 { up += 1 }
            let c = face.blocks[n].centre
            let way = face.outward(at: c).x
            if abs(way) > 0.5 {
                sided += 1
                if v.x * way > 0 { outward += 1 }
            }
        }
        // (Those below a firing go down onto the floor.)
        #expect(Float(up) > 0.75 * Float(released.count), "\(up) of \(released.count) up")
        // The heave: every released block swells up, and most let go still rising at least as
        // fast as they swelled, so the crest goes on rising as a mass as it breaks.
        #expect(released.allSatisfy { state.swell[$0].z > 0 && state.swell[$0].w >= law.ridgeRise })
        let rising = released.filter { state.velocity[$0].z >= 0.9 * state.swell[$0].z }.count
        #expect(Float(rising) > 0.75 * Float(released.count), "\(rising) of \(released.count) rising")
        #expect(Float(outward) > 0.6 * Float(sided))
        // Down the flank: out of the start's side toward the start, out of the end's toward the end.
        #expect(face.outward(at: SIMD3(ridge.cutStart + 3, 0, 0)).x < 0)
        #expect(face.outward(at: SIMD3(ridge.cutEnd - 3, 0, 0)).x > 0)
        face = try QuarryFaceTests.small()
        #expect(face.outward(at: SIMD3(50, 0, 0)) == SIMD3(0, -1, 0))
    }

    @Test("A first cut is laid across the highest ridge, at right angles to it; none on a slope")
    func suggestion() throws {
        let built = Self.ridge.terrain
        let cut = try #require(QuarryStripGuide.suggestRidgeCut(terrain: built))
        let middle = (cut.start + cut.end) / 2
        let along = simd_normalize(cut.end - cut.start)
        #expect(abs(along.x) > 0.9, "\(along)")
        let length = simd_distance(cut.start, cut.end)
        #expect(length > 60 && length < 420)
        // Across the crest: the line's highest point is near the ridge's axis there.
        var best = (h: -Float.infinity, p: middle)
        for k in 0...200 {
            let p = cut.start + (cut.end - cut.start) * Float(k) / 200
            let h = built.height(at: p)
            if h > best.h { best = (h, p) }
        }
        #expect(abs(best.p.x - BuiltInRidge.axis(best.p.y)) < 8)
        _ = try QuarryFace(
            site: QuarrySite(
                terrain: built, start: cut.start, end: cut.end, depth: QuarryRidge.defaultDepth,
                scene: .ridgeCut))
        let slope = Terrain(
            origin: .zero, spacing: 2, columns: 300, rows: 300,
            heights: (0..<90_000).map { Float($0 % 300) * 0.3 })
        #expect(QuarryStripGuide.suggestRidgeCut(terrain: slope) == nil)
    }

    @Test("The cut drawn on the ground: its line, and its floor's outline closed round it")
    func lines() throws {
        let built = Self.ridge.terrain
        let l = QuarryStripGuide.ridgeLines(
            terrain: built, start: SIMD2(-80, 0), end: SIMD2(80, 0), width: 28, step: 4)
        #expect(l.face.count == 41)
        #expect(l.back.count == 2 * 41 + 1)
        #expect(l.back.first == l.back.last)
        #expect(abs(l.back[0].y - 14) < 1e-4 && abs(l.back[41].y + 14) < 1e-4)
        for p in l.face + l.back { #expect(abs(p.z - built.height(at: SIMD2(p.x, p.y))) < 1e-4) }
    }
}
