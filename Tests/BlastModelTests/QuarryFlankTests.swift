import Testing
import simd

@testable import BlastModel

/// A ridge cut's flanks as ground: the dense rock round the cut, the ledges, scree and grass, and
/// the render-only stones and scrub (emmettl/bombcad-work#135). Illustrative scene; these are
/// consistency checks, not a measure of how it looks.
@Suite("Ridge cut flanks", .serialized)
struct QuarryFlankTests {
    static let face: QuarryFace = {
        var options = QuarryFace.Options()
        options.blocks = 3000
        options.meshDetail = 1
        return try! QuarryFace(site: QuarrySite.builtInRidge(), options: options)
    }()

    @Test("A face has no flanks; a ridge cut's dense rock is the cut and a ragged margin round it")
    func paving() throws {
        var options = QuarryFace.Options()
        options.blocks = 3000
        #expect(QuarryFlank(face: try QuarryFace(site: QuarrySite.builtIn(), options: options)) == nil)
        let flank = try #require(QuarryFlank(face: Self.face))
        let ridge = try #require(Self.face.ridge)
        let reach = QuarryFlank.margin + QuarryFlank.marginWander + 1.5
        var cutTexels = 0
        for n in 0..<(flank.columns * flank.rows) {
            if flank.cut[n] > 0.5 {
                cutTexels += 1
                #expect(flank.paving[n])
            }
            if flank.paving[n] {
                #expect(flank.cutDistance[n] <= reach)
                #expect(flank.grass[n] == 0)
            }
        }
        // The cut is about its volume over its depth in plan, at least.
        #expect(Float(cutTexels) > ridge.cutVolume / (ridge.crest - ridge.floor))
        // The steep ground is set back only inside the dense rock, and fully only well inside it.
        let (x, y) = flank.position(flank.columns / 2, 2)
        #expect(flank.setBack(x, y) == 0)
    }

    @Test("Ledges crop out of the slopes clear of the cut, in beds that are not shale, on the ground")
    func ledges() throws {
        let flank = try #require(QuarryFlank(face: Self.face))
        #expect(flank.ledges.count > 100)
        for ledge in flank.ledges {
            let n = try #require(flank.texel(ledge.contour.x, ledge.contour.y))
            #expect(!flank.paving[n])
            #expect(simd_length(flank.gradient[n]) > QuarryFlank.ledgeSlope * 0.5)
            #expect(QuarryRock.kind(bed: ledge.bed) != .shale)
            #expect(ledge.top > ledge.bottom + 0.6)
            #expect(abs(ledge.contour.z - flank.groundHeight(ledge.contour.x, ledge.contour.y)) < 0.6)
            #expect(ledge.run >= 0.6 && ledge.run <= 3.2)
            // Downhill is down the slope.
            let ahead = SIMD2(ledge.contour.x, ledge.contour.y) + ledge.downhill * 2
            #expect(flank.groundHeight(ahead.x, ahead.y) < ledge.contour.z)
        }
        // In runs along their beds, each ledge in one run, and the runs made into outcrops of their
        // own, not dressing.
        let runs = flank.ledgeRuns()
        #expect(runs.flatMap { $0 }.sorted() == Array(flank.ledges.indices))
        #expect(runs.count < flank.ledges.count)
        for run in runs { #expect(Set(run.map { flank.ledges[$0].bed }).count == 1) }
        var face = Self.face
        let dressing = face.dressingIndices.count
        let made = face.appendLedges(flank)
        #expect(Float(made) > 0.9 * Float(runs.count))
        #expect(face.dressingIndices.count == dressing)
        #expect(face.ledgeIndices.count > 3 * 8 * made)
        #expect(face.ledgeIndices.allSatisfy { Int($0) < face.ledgeVertices.count })
        // Near the ground: buried at their backs and feet, standing no more than a few metres
        // proud of it.
        var buried = 0
        var outcrop = 0
        for v in face.ledgeVertices where !QuarryFace.isCrag(v.body) {
            let above = v.z - flank.groundHeight(v.x, v.y)
            #expect(above < 5)
            if above < 0 { buried += 1 }
            outcrop += 1
        }
        #expect(buried > outcrop / 5)
    }

    @Test("A few crags of several beds stand on the steep flanks, clear of the cut, the view and the ledges")
    func crags() throws {
        let flank = try #require(QuarryFlank(face: Self.face))
        let view = try #require(QuarryRidgeView.opening(Self.face))
        #expect(!flank.crags.isEmpty && flank.crags.count <= QuarryFlank.cragCount)
        let eye = SIMD2(view.orbit.eye.x, view.orbit.eye.y)
        let focus = SIMD2(view.orbit.focus.x, view.orbit.focus.y)
        for (k, crag) in flank.crags.enumerated() {
            let n = try #require(flank.texel(crag.centre.x, crag.centre.y))
            #expect(flank.cutDistance[n] > QuarryFlank.cragClear)
            #expect(crag.beds.count >= 2)
            #expect(crag.reach > 3)
            // Off the line from the eye to what it looks at.
            let p = SIMD2(crag.centre.x, crag.centre.y)
            let t = max(0, min(1, simd_dot(p - eye, focus - eye) / simd_length_squared(focus - eye)))
            #expect(simd_distance(p, eye + (focus - eye) * t) > QuarryFlank.cragClear)
            for other in flank.crags[(k + 1)...] {
                #expect(simd_distance(p, SIMD2(other.centre.x, other.centre.y)) > QuarryFlank.cragSpacing)
            }
        }
        for ledge in flank.ledges {
            let n = try #require(flank.texel(ledge.contour.x, ledge.contour.y))
            #expect(!flank.cragMask[n])
        }
        // Made into outcrops after the ledges', standing several metres proud of the ground.
        var face = Self.face
        _ = face.appendLedges(flank)
        let crag = face.ledgeVertices.filter { QuarryFace.isCrag($0.body) }
        #expect(!crag.isEmpty)
        let tallest = crag.map { $0.z - flank.groundHeight($0.x, $0.y) }.max() ?? 0
        #expect(tallest > 3 && tallest < 14)
        // Fallen blocks below them.
        let stones = flank.stones()
        let below = stones.filter { stone in
            flank.crags.contains {
                simd_distance(SIMD2($0.centre.x, $0.centre.y), SIMD2(stone.posSize.x, stone.posSize.y)) < $0
                    .reach + $0.width
            }
                && stone.look.w > 0.5
        }
        #expect(below.count > flank.crags.count * 3)
        let small = QuarryFlank.smallStoneCount(stones)
        #expect(stones[..<small].allSatisfy { $0.posSize.w < QuarryFlank.largeStone })
    }

    @Test("Scree lies below the ledges more than on open gentle ground, and grass on the gentle ground")
    func cover() throws {
        let flank = try #require(QuarryFlank(face: Self.face))
        var below: [Float] = []
        for ledge in flank.ledges {
            let p = SIMD2(ledge.contour.x, ledge.contour.y) + ledge.downhill * (ledge.run + 2.5)
            if let n = flank.texel(p.x, p.y) { below.append(flank.scree[n]) }
        }
        var gentleScree: [Float] = []
        var gentleGrass: [Float] = []
        var steepGrass: [Float] = []
        for n in 0..<(flank.columns * flank.rows) where !flank.paving[n] {
            let slope = simd_length(flank.gradient[n])
            if slope < 0.15 {
                gentleScree.append(flank.scree[n])
                gentleGrass.append(flank.grass[n])
            } else if slope > 1.6 {
                steepGrass.append(flank.grass[n])
            }
        }
        func mean(_ v: [Float]) -> Float { v.reduce(0, +) / Float(max(v.count, 1)) }
        // Below some of the ledges, not all: others stand in the grass.
        #expect(mean(below) > 0.15)
        #expect(mean(below) > 3 * mean(gentleScree))
        #expect(mean(gentleScree) < 0.1)
        #expect(mean(gentleGrass) > 0.35)
        #expect(steepGrass.isEmpty || mean(steepGrass) < 0.1)
    }

    @Test("Stones lie on the scree and scrub on the grass, on the ground, the same each time")
    func stones() throws {
        let flank = try #require(QuarryFlank(face: Self.face))
        let stones = flank.stones()
        #expect(stones.count > 2000)
        var shrubs = 0
        for stone in stones {
            let p = stone.posSize
            let n = try #require(flank.texel(p.x, p.y))
            #expect(!flank.paving[n] && flank.cut[n] < 0.5)
            #expect(abs(p.z - flank.groundHeight(p.x, p.y)) < p.w)
            #expect(abs(simd_length(stone.rotation) - 1) < 1e-3)
            if stone.look.x > 0.5 { shrubs += 1 }
        }
        // Stones first, then the bushes' lobes, which stand on grass.
        let first = QuarryFlank.stoneCount(stones)
        #expect(stones[..<first].allSatisfy { $0.look.x < 0.5 })
        #expect(stones[first...].allSatisfy { $0.look.x > 0.5 })
        #expect(shrubs > 100 && shrubs < stones.count / 2)
        let around: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(1, 0), SIMD2(-1, 0), SIMD2(0, 1), SIMD2(0, -1)]
        let onGrass = stones[first...].filter { stone in
            around.contains { d in
                flank.texel(stone.posSize.x + d.x, stone.posSize.y + d.y).map { flank.grass[$0] > 0 } ?? false
            }
        }
        #expect(onGrass.count > shrubs * 9 / 10)
        #expect(QuarryFlank.lobeShape().count == 240)
        let again = try #require(QuarryFlank(face: Self.face)).stones()
        #expect(again.map(\.posSize) == stones.map(\.posSize))
        #expect(flank.stones(scale: 0.5).count < stones.count * 3 / 4)
    }

    @Test("Outcrops are not alike: some stand twice as high as most, and a crag's top faces up")
    func rockForms() throws {
        let flank = try #require(QuarryFlank(face: Self.face))
        let runs = flank.ledgeRuns()
        // How high each run's outcrop stands above the ground (emmettl/bombcad-work#147).
        var heights: [Float] = []
        for (k, run) in runs.enumerated() {
            let mesh = QuarryFace.outcrop(run.map { flank.ledges[$0] }, flank: flank, seed: UInt64(k))
            let high = mesh.vertices.map { $0.z - flank.groundHeight($0.x, $0.y) }.max() ?? 0
            if high > 0.2 { heights.append(high) }
        }
        heights.sort()
        let median = heights[heights.count / 2]
        #expect(heights[heights.count * 9 / 10] > 1.5 * median)
        // A crag's top, where it shows, faces up: judged at one row, a bowed crag was drawn
        // inside out.
        for (k, crag) in flank.crags.enumerated() {
            let mesh = QuarryFace.crag(crag, flank: flank, seed: UInt64(k))
            var up = 0
            var shown = 0
            for v in mesh.vertices where (v.body >> 16) & 7 == QuarryFace.OutcropPart.top.rawValue {
                guard v.z - flank.groundHeight(v.x, v.y) > 0.5 else { continue }
                shown += 1
                if Float((v.normal >> 20) & 1023) / 511.5 - 1 > 0 { up += 1 }
            }
            #expect(shown > 0 && up * 10 > shown * 7)
        }
    }

    @Test("A ridge's weathering as drawn breaks along the strike, within reach of the solver's cells")
    func strikeRecess() {
        let n = QuarryFace.beddingNormal
        // Along the middle of a shale bed: its recess comes and goes, rather than one value the
        // length of the crest.
        let shale = (0..<40).first { QuarryRock.kind(bed: $0) == .shale }!
        let s = QuarryFlank.bedLevel(Float(shale) + 0.5, near: 0)
        var along: [Float] = []
        var x: Float = -120
        while x <= 120 {
            let y = 0.3 * x
            let p = SIMD3(x, y, (s - n.x * x - n.y * y) / n.z)
            let r = QuarryRock.strikeRecess(at: p)
            let blended = QuarryRock.blendedRecess(at: p)
            #expect(r >= blended - QuarryRock.strikeOut - 1e-4 && r <= blended + QuarryRock.strikeIn + 1e-4)
            along.append(r)
            x += 1.5
        }
        #expect(along.min()! < 0.6 && along.max()! > 0.85)
        // Anywhere, within reach of the cells' own recess.
        var random = QuarryRandom(seed: 147)
        for _ in 0..<2000 {
            let p = SIMD3(random.float(-150, 150), random.float(-150, 150), random.float(-10, 60))
            let r = QuarryRock.strikeRecess(at: p)
            let blended = QuarryRock.blendedRecess(at: p)
            #expect(r >= blended - QuarryRock.strikeOut - 1e-4 && r <= blended + QuarryRock.strikeIn + 1e-4)
        }
    }
}
