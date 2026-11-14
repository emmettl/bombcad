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

    @Test("Outcrops are drawn in short pieces en échelon, and talus lies at a crag's ends")
    func rockMasses() throws {
        let flank = try #require(QuarryFlank(face: Self.face))
        // A tag keeps its shift along the bedding's normal to its step, and the rest of its bits.
        for shift: Float in [-0.45, -0.1, 0, 0.25, 0.45] {
            let tag = QuarryFace.outcropTag(
                above: 1.2, random: 0.5, part: .face, layer: 2, joint: 0.4, crag: true, shift: shift)
            #expect(abs(QuarryFace.outcropShift(tag) - shift) <= QuarryFace.outcropShiftStep / 2 + 1e-5)
            #expect(
                QuarryFace.isCrag(tag) && (tag >> 19) & 7 == 2
                    && (tag >> 16) & 7 == QuarryFace.OutcropPart.face.rawValue)
        }
        // Each long run's outcrop is drawn shifted, within half a metre of its bed, and not all the
        // same way along it (emmettl/bombcad-work#149).
        var shifted = 0
        var long = 0
        for (k, run) in flank.ledgeRuns().enumerated() where run.count >= 4 {
            long += 1
            let mesh = QuarryFace.outcrop(run.map { flank.ledges[$0] }, flank: flank, seed: UInt64(k))
            let shifts = mesh.vertices.map { QuarryFace.outcropShift($0.body) }
            #expect(shifts.allSatisfy { abs($0) <= 0.5 })
            if (shifts.max() ?? 0) - (shifts.min() ?? 0) > 0.2 { shifted += 1 }
        }
        #expect(long > 0 && shifted * 10 >= long * 9)
        // Stones at both ends of each crag, where its beds go under the slope.
        let stones = flank.stones()
        for crag in flank.crags {
            let side = SIMD2(-crag.downhill.y, crag.downhill.x)
            for end: Float in [-1, 1] {
                let at = SIMD2(crag.centre.x, crag.centre.y) + side * (end * crag.width / 2)
                let near = stones.filter {
                    $0.look.x < 0.5 && simd_distance(SIMD2($0.posSize.x, $0.posSize.y), at) < 9
                }
                #expect(near.count >= 5)
            }
        }
    }

    @Test("Every outcrop piece and crag faces out: where its tops show, they face up")
    func outcropsFaceOut() throws {
        // Judged from the drawn top, a fifth of the outcrops' pieces were drawn inside out, dark
        // hollow shells on the flanks: a short piece whose top layer was gone over all of it took
        // its way out from a row folded back under the ground (emmettl/bombcad-work#150).
        let flank = try #require(QuarryFlank(face: Self.face))
        var meshes = flank.ledgeRuns().enumerated().map { k, run in
            QuarryFace.outcrop(run.map { flank.ledges[$0] }, flank: flank, seed: UInt64(k))
        }
        meshes += flank.crags.enumerated().map { k, crag in
            QuarryFace.crag(crag, flank: flank, seed: UInt64(k))
        }
        var pieces = 0
        for mesh in meshes {
            let piece = Self.pieces(mesh)
            var votes: [Int: (up: Int, down: Int)] = [:]
            for (i, v) in mesh.vertices.enumerated()
            where (v.body >> 16) & 7 == QuarryFace.OutcropPart.top.rawValue
                && v.z - flank.groundHeight(v.x, v.y) > 0.2
            {
                let up = Float((v.normal >> 20) & 1023) / 511.5 - 1 > 0
                var vote = votes[piece[i]] ?? (0, 0)
                if up { vote.up += 1 } else { vote.down += 1 }
                votes[piece[i]] = vote
            }
            for vote in votes.values {
                pieces += 1
                #expect(vote.up > vote.down)
            }
        }
        #expect(pieces > 100)
    }

    /// Which connected sheet (piece) of `mesh` each vertex is in.
    static func pieces(_ mesh: (vertices: [QuarryFace.Vertex], indices: [UInt32])) -> [Int] {
        var parent = Array(mesh.vertices.indices)
        func find(_ a: Int) -> Int {
            var a = a
            while parent[a] != a {
                parent[a] = parent[parent[a]]
                a = parent[a]
            }
            return a
        }
        for t in stride(from: 0, to: mesh.indices.count, by: 3) {
            let a = find(Int(mesh.indices[t]))
            parent[find(Int(mesh.indices[t + 1]))] = a
            parent[find(Int(mesh.indices[t + 2]))] = a
        }
        return mesh.vertices.indices.map(find)
    }

    @Test("No outcrop piece lies on the slope as a thin slab: each stands a quarter as high as it is wide")
    func outcropsNotSlabs() throws {
        // Thin slabs and lips a few decimetres high and metres across, where a bed lay nearly along
        // the slope, sunk part way, or was left where the layers over it were gone; and long thin
        // points at the pieces' ends (emmettl/bombcad-work#150).
        let flank = try #require(QuarryFlank(face: Self.face))
        var pieces = 0
        for (k, run) in flank.ledgeRuns().enumerated() {
            let mesh = QuarryFace.outcrop(run.map { flank.ledges[$0] }, flank: flank, seed: UInt64(k))
            let piece = Self.pieces(mesh)
            var shown: [Int: [SIMD3<Float>]] = [:]
            for (i, v) in mesh.vertices.enumerated() {
                let above = v.z - flank.groundHeight(v.x, v.y)
                if above > 0.05 { shown[piece[i], default: []].append(SIMD3(v.x, v.y, above)) }
            }
            for points in shown.values where points.count > 4 {
                pieces += 1
                // Its width: its plan's narrower spread (as a uniform strip's width), and how high
                // it stands.
                let centre = points.reduce(SIMD3<Float>.zero, +) / Float(points.count)
                var (xx, xy, yy): (Float, Float, Float) = (0, 0, 0)
                for p in points {
                    let d = p - centre
                    (xx, xy, yy) = (xx + d.x * d.x, xy + d.x * d.y, yy + d.y * d.y)
                }
                let n = Float(points.count)
                (xx, xy, yy) = (xx / n, xy / n, yy / n)
                let half = (xx + yy) / 2
                let narrow = half - ((xx - yy) * (xx - yy) / 4 + xy * xy).squareRoot()
                let width = (max(narrow, 0) * 12).squareRoot()
                let high = points.map(\.z).max()!
                #expect(
                    high >= 0.25 * width,
                    "a piece \(width) m wide stands \(high) m at \(centre.x), \(centre.y)")
            }
        }
        #expect(pieces > 100)
    }

    /// A piece's plan, from the points of it that stand out of the ground: its length along its long
    /// axis, its median width over its middle half, its width 0.3 to 0.8 m in from each end, and how
    /// far the middle of that end stretch stands off the line of the piece's middle part (a
    /// tail or hook), the last two as shares of the median width.
    struct Plan {
        var centre: SIMD2<Float>
        var length: Float
        var width: Float
        var ends: [Float]
        var offsets: [Float]
    }

    /// Points over each piece's surface, its triangles sampled every 0.2 m or so, where it stands
    /// out of the ground, in plan.
    static func shownPlan(
        _ mesh: (vertices: [QuarryFace.Vertex], indices: [UInt32]), piece: [Int], flank: QuarryFlank
    ) -> [Int: [SIMD2<Float>]] {
        var shown: [Int: [SIMD2<Float>]] = [:]
        for t in stride(from: 0, to: mesh.indices.count, by: 3) {
            let v = (0..<3).map { mesh.vertices[Int(mesh.indices[t + $0])] }
            let p = v.map { SIMD3($0.x, $0.y, $0.z) }
            let longest = max(simd_distance(p[0], p[1]), simd_distance(p[1], p[2]), simd_distance(p[2], p[0]))
            let n = max(1, min(40, Int((longest / 0.2).rounded(.up))))
            for i in 0...n {
                for j in 0...(n - i) {
                    let (a, b) = (Float(i) / Float(n), Float(j) / Float(n))
                    let q = p[0] + (p[1] - p[0]) * a + (p[2] - p[0]) * b
                    if q.z - flank.groundHeight(q.x, q.y) > 0.05 {
                        shown[piece[Int(mesh.indices[t])], default: []].append(SIMD2(q.x, q.y))
                    }
                }
            }
        }
        return shown
    }

    /// `points` split into the patches they make in plan (touching in 0.3 m cells).
    static func patches(_ points: [SIMD2<Float>]) -> [[SIMD2<Float>]] {
        func cell(_ p: SIMD2<Float>) -> SIMD2<Int32> {
            SIMD2(Int32((p.x / 0.3).rounded(.down)), Int32((p.y / 0.3).rounded(.down)))
        }
        var cells: [SIMD2<Int32>: [SIMD2<Float>]] = [:]
        for p in points { cells[cell(p), default: []].append(p) }
        var seen = Set<SIMD2<Int32>>()
        var out: [[SIMD2<Float>]] = []
        for start in cells.keys where !seen.contains(start) {
            var patch: [SIMD2<Float>] = []
            var stack = [start]
            seen.insert(start)
            while let c = stack.popLast() {
                patch += cells[c]!
                for dx: Int32 in -1...1 {
                    for dy: Int32 in -1...1 {
                        let n = c &+ SIMD2(dx, dy)
                        if cells[n] != nil, !seen.contains(n) {
                            seen.insert(n)
                            stack.append(n)
                        }
                    }
                }
            }
            out.append(patch)
        }
        return out
    }

    static func plan(_ points: [SIMD2<Float>]) -> Plan? {
        guard points.count > 8 else { return nil }
        let centre = points.reduce(SIMD2<Float>.zero, +) / Float(points.count)
        var (xx, xy, yy): (Float, Float, Float) = (0, 0, 0)
        for p in points {
            let d = p - centre
            (xx, xy, yy) = (xx + d.x * d.x, xy + d.x * d.y, yy + d.y * d.y)
        }
        let angle = 0.5 * atan2(2 * xy, xx - yy)
        let long = SIMD2(cos(angle), sin(angle))
        let across = SIMD2(-long.y, long.x)
        let ab = points.map { SIMD2(simd_dot($0 - centre, long), simd_dot($0 - centre, across)) }
        let (low, high) = (ab.map(\.x).min()!, ab.map(\.x).max()!)
        let length = high - low
        func window(_ from: Float, _ to: Float) -> (width: Float, middle: Float)? {
            let inside = ab.filter { $0.x >= from && $0.x <= to }.map(\.y)
            guard inside.count >= 3 else { return nil }
            return (inside.max()! - inside.min()!, (inside.max()! + inside.min()!) / 2)
        }
        var middles: [(a: Float, width: Float, middle: Float)] = []
        var a = low + 0.25 * length
        while a + 0.5 <= high - 0.25 * length {
            if let w = window(a, a + 0.5) { middles.append((a + 0.25, w.width, w.middle)) }
            a += 0.25
        }
        guard length > 2, middles.count >= 2 else { return nil }
        let width = middles.map(\.width).sorted()[middles.count / 2]
        // The middle part's line: a least-squares fit of its windows' middles.
        let n = Float(middles.count)
        let ma = middles.map(\.a).reduce(0, +) / n
        let mm = middles.map(\.middle).reduce(0, +) / n
        var (sab, saa): (Float, Float) = (0, 0)
        for w in middles {
            sab += (w.a - ma) * (w.middle - mm)
            saa += (w.a - ma) * (w.a - ma)
        }
        let slope = saa > 1e-6 ? sab / saa : 0
        var ends: [Float] = []
        var offsets: [Float] = []
        for (from, to) in [(low + 0.3, low + 0.8), (high - 0.8, high - 0.3)] {
            guard let w = window(from, to) else { continue }
            ends.append(w.width / width)
            let fit = mm + slope * ((from + to) / 2 - ma)
            offsets.append(abs(w.middle - fit) / width)
        }
        return Plan(centre: centre, length: length, width: width, ends: ends, offsets: offsets)
    }

    @Test("Outcrop pieces end broad in plan: no point or hooked tail at either end")
    func outcropEnds() throws {
        // Pieces narrowed to a point in plan, or ran out in a tail, where a row's top went under the
        // slope and only its front stood out, a thin wall or lip (emmettl/bombcad-work#151). Judged
        // on the surface as drawn, sampled every 0.2 m, in the patches it shows in plan.
        let flank = try #require(QuarryFlank(face: Self.face))
        var plans: [Plan] = []
        for (k, run) in flank.ledgeRuns().enumerated() {
            let mesh = QuarryFace.outcrop(run.map { flank.ledges[$0] }, flank: flank, seed: UInt64(k))
            let piece = Self.pieces(mesh)
            let shown = Self.shownPlan(mesh, piece: piece, flank: flank)
            plans += shown.values.flatMap(Self.patches).compactMap(Self.plan)
        }
        // Main's code before emmettl/bombcad-work#151: ends down to 0.09 of a piece's width, a patch's
        // end standing off its line by 2.5 widths; 0.22 and 1.24 after.
        #expect(plans.count > 150)
        for plan in plans {
            #expect(
                plan.ends.allSatisfy { $0 >= 0.2 } && plan.offsets.allSatisfy { $0 <= 1.5 },
                "a piece at \(plan.centre) ends \(plan.ends) of its width, its ends off its line by \(plan.offsets)"
            )
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
