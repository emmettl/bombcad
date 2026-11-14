import Foundation
import simd

// A ridge cut's flanks as ground (emmettl/bombcad-work#135): where the dense render-only rock
// stands round the cut, where bedded ledges crop out of the slopes, where scree lies below them and
// where dry grass and low scrub grow on the gentler ground. Illustrative, for the eye: the ground
// cover is procedural and chosen by eye; it is no survey of any real hillside and has no part in
// the solver. Render-only, like the dressing it extends.

/// The cover of a ridge cut's flanks, on a 1 m grid in the cut's frame over the dressing's area.
public struct QuarryFlank: Sendable {
    /// One bedded ledge cropping out of a slope: the slab of bed `bed` that stands proud of the
    /// ground on its downhill side, from where the bed's top meets the ground (`contour`) out to
    /// `run` metres downhill, between the bed's top and bottom (along the bedding's normal).
    public struct Ledge: Sendable, Equatable {
        public var contour: SIMD3<Float>
        /// Downhill in plan, unit.
        public var downhill: SIMD2<Float>
        public var top: Float
        public var bottom: Float
        public var run: Float
        public var bed: Int
        /// A random value of its own, 0...1.
        public var seed: Float
    }

    /// A crag (emmettl/bombcad-work#141): several beds stacked into a small cliff standing out of a
    /// steep flank, from `beds.lowerBound` at its foot to `beds.upperBound` on top, `width` metres
    /// along the strike. `centre` is where its top bed's top meets the ground at its middle; its
    /// foot is about `reach` metres downhill of it.
    public struct Crag: Sendable, Equatable {
        public var centre: SIMD3<Float>
        /// Downhill in plan, unit.
        public var downhill: SIMD2<Float>
        public var width: Float
        public var beds: ClosedRange<Int>
        public var reach: Float
        /// A random value of its own, 0...1.
        public var seed: Float
    }

    /// One render-only stone of the scree, or one clump of a low shrub: centre and size (m), its
    /// turn as a quaternion (x, y, z, w), and what it is (x: 0 a stone, 1 a shrub; y: a random
    /// value; z: its tint; w: for a stone, 1 an angular block fallen from an outcrop or a crag, 0 a
    /// weathered stone). Layout matches `FlankStone` in `QuarryRender.metal`.
    public struct Stone: Sendable {
        public var posSize: SIMD4<Float>
        public var rotation: SIMD4<Float>
        public var look: SIMD4<Float>
    }

    public let low: SIMD2<Float>
    public let spacing: Float = 1
    public let columns: Int
    public let rows: Int
    /// The ground after the cut, the slope's gradient, and how far each texel is from the cut in
    /// plan (m).
    public private(set) var ground: [Float]
    public private(set) var gradient: [SIMD2<Float>]
    public private(set) var cutDistance: [Float]
    /// Per texel, 0...1: loose stones, grass and scrub, the ground under and round the render-only
    /// rock, and the cut itself (the ground the broken rock is taken from).
    public private(set) var scree: [Float]
    public private(set) var grass: [Float]
    public private(set) var rock: [Float]
    public private(set) var cut: [Float]
    /// Where the dense render-only rock of `QuarryFace.buildDressing` stands: the cut and a ragged
    /// margin round it, so that the cut's broken rock is of a piece with rock round it.
    public private(set) var paving: [Bool]
    /// How far inside the dense rock each texel is from its edge (m; 0 outside it).
    public private(set) var pavingDepth: [Float] = []
    public private(set) var ledges: [Ledge] = []
    /// The crags, and the ground they stand on and just round them (no ledges, stones or bushes
    /// there).
    public private(set) var crags: [Crag] = []
    public private(set) var cragMask: [Bool] = []

    /// The margin of dense rock round the cut (m), before its ragged edge (up to `marginWander`
    /// more).
    public static let margin: Float = 2.5
    public static let marginWander: Float = 5
    /// Ledges crop out on slopes steeper than about this (rise over run), and stand apart along
    /// their bed by about `ledgeSpacing` (m).
    public static let ledgeSlope: Float = 0.3
    public static let ledgeSpacing: Float = 3.2
    /// At most this many crags, at least `cragSpacing` apart (m), on slopes steeper than
    /// `cragSlope`, at least `cragClear` from the cut and from the opening view's sight lines.
    public static let cragCount = 6
    public static let cragSpacing: Float = 60
    public static let cragSlope: Float = 0.6
    public static let cragClear: Float = 30
    /// Stones at least this big (m) are drawn with the finer, rounder shape (`lobeShape`).
    public static let largeStone: Float = 0.45

    /// The flanks of `face`'s ridge cut, nil for a face.
    public init?(face: QuarryFace) {
        guard let ridge = face.ridge else { return nil }
        let (lowXY, highXY) = ridge.dressingArea(low: face.low, high: face.high)
        low = lowXY
        columns = Int((highXY.x - lowXY.x) / spacing) + 1
        rows = Int((highXY.y - lowXY.y) / spacing) + 1
        let count = columns * rows
        let t = face.terrain
        let gridHigh = t.origin + SIMD2(Float(t.columns - 2), Float(t.rows - 2)) * t.spacing
        @Sendable func inGrid(_ x: Float, _ y: Float) -> Bool {
            x > t.origin.x + 1 && x < gridHigh.x && y > t.origin.y + 1 && y < gridHigh.y
        }
        var ground = [Float](repeating: 0, count: count)
        var cut = [Float](repeating: 0, count: count)
        let (columns, rows, low, spacing) = (columns, rows, low, spacing)
        ground.withUnsafeMutableBufferPointer { g in
            cut.withUnsafeMutableBufferPointer { c in
                nonisolated(unsafe) let (gOut, cOut) = (g, c)
                DispatchQueue.concurrentPerform(iterations: rows) { j in
                    for i in 0..<columns {
                        let (x, y) = (low.x + Float(i) * spacing, low.y + Float(j) * spacing)
                        let n = i + j * columns
                        if inGrid(x, y) {
                            let now = face.height(t.heights, x, y)
                            gOut[n] = now
                            cOut[n] = face.height(face.original, x, y) - now > 0.3 ? 1 : 0
                        } else {
                            gOut[n] = face.oldHeight(x, y)
                        }
                    }
                }
            }
        }
        self.ground = ground
        self.cut = cut
        gradient = [SIMD2<Float>](repeating: .zero, count: count)
        for j in 0..<rows {
            for i in 0..<columns {
                let (a, b) = (max(0, i - 1), min(columns - 1, i + 1))
                let (c, d) = (max(0, j - 1), min(rows - 1, j + 1))
                gradient[i + j * columns] = SIMD2(
                    (ground[b + j * columns] - ground[a + j * columns]) / (Float(b - a) * spacing),
                    (ground[i + d * columns] - ground[i + c * columns]) / (Float(d - c) * spacing))
            }
        }
        cutDistance = Self.distance(
            from: cut.map { $0 > 0.5 }, columns: columns, rows: rows, spacing: spacing)
        paving = [Bool](repeating: false, count: count)
        rock = [Float](repeating: 0, count: count)
        scree = [Float](repeating: 0, count: count)
        grass = [Float](repeating: 0, count: count)
        for j in 0..<rows {
            for i in 0..<columns {
                let n = i + j * columns
                let (x, y) = position(i, j)
                let wander = 0.5 + QuarryNoise.fbm(SIMD3(x / 14, y / 14, 2.9), octaves: 3)
                paving[n] =
                    cut[n] > 0.5
                    || (cutDistance[n] < Self.margin + Self.marginWander * max(0, wander)
                        && ground[n] > ridge.floor - 3)
            }
        }
        pavingDepth = Self.distance(from: paving.map { !$0 }, columns: columns, rows: rows, spacing: spacing)
        findCrags(face: face, ridge: ridge)
        findLedges(ridge: ridge)
        cover(ridge: ridge)
    }

    /// Texel (i, j)'s position in the cut's frame.
    public func position(_ i: Int, _ j: Int) -> (Float, Float) {
        (low.x + Float(i) * spacing, low.y + Float(j) * spacing)
    }

    /// The texel nearest (x, y), nil off the grid.
    public func texel(_ x: Float, _ y: Float) -> Int? {
        let i = Int(((x - low.x) / spacing).rounded())
        let j = Int(((y - low.y) / spacing).rounded())
        guard i >= 0, j >= 0, i < columns, j < rows else { return nil }
        return i + j * columns
    }

    /// The ground at (x, y), bilinear on the grid (clamped to it).
    public func groundHeight(_ x: Float, _ y: Float) -> Float {
        let gx = max(0, min(Float(columns - 2), (x - low.x) / spacing))
        let gy = max(0, min(Float(rows - 2), (y - low.y) / spacing))
        let (i, j) = (Int(gx), Int(gy))
        let (fx, fy) = (gx - Float(i), gy - Float(j))
        let n = i + j * columns
        let a = ground[n] + (ground[n + 1] - ground[n]) * fx
        let b = ground[n + columns] + (ground[n + columns + 1] - ground[n + columns]) * fx
        return a + (b - a) * fy
    }

    /// Whether the dense render-only rock stands at (x, y).
    public func paves(_ x: Float, _ y: Float) -> Bool { texel(x, y).map { paving[$0] } ?? false }

    /// How far inside the dense rock (x, y) is from its edge (m; 0 outside it).
    public func edgeDepth(_ x: Float, _ y: Float) -> Float { texel(x, y).map { pavingDepth[$0] } ?? 0 }

    /// How far the dense rock's outer surface sinks toward its edge, so that it goes under the
    /// ground there (m): 0.9 at the edge, none 3 m in, bilinear between texels so the surface it
    /// shapes is smooth.
    public func sink(_ x: Float, _ y: Float) -> Float {
        let gx = max(0, min(Float(columns - 2), (x - low.x) / spacing))
        let gy = max(0, min(Float(rows - 2), (y - low.y) / spacing))
        let (i, j) = (Int(gx), Int(gy))
        let (fx, fy) = (gx - Float(i), gy - Float(j))
        func at(_ n: Int) -> Float { 0.9 * max(0, 1 - min(pavingDepth[n], 3) / 3) }
        let n = i + j * columns
        let a = at(n) + (at(n + 1) - at(n)) * fx
        let b = at(n + columns) + (at(n + columns + 1) - at(n + columns)) * fx
        return a + (b - a) * fy
    }

    /// How much of the steep ground's set-back from the render-only rock to take at (x, y): all
    /// of it well inside the dense rock, none outside it, tapering over its last 3 m.
    public func setBack(_ x: Float, _ y: Float) -> Float { min(1, edgeDepth(x, y) / 3) }

    /// Two-pass chamfer distance (m) from the texels marked.
    static func distance(from marked: [Bool], columns: Int, rows: Int, spacing: Float) -> [Float] {
        var d = marked.map { $0 ? Float(0) : Float.infinity }
        let (a, b) = (spacing, spacing * Float(2).squareRoot())
        for j in 0..<rows {
            for i in 0..<columns {
                let n = i + j * columns
                var v = d[n]
                if i > 0 { v = min(v, d[n - 1] + a) }
                if j > 0 {
                    v = min(v, d[n - columns] + a)
                    if i > 0 { v = min(v, d[n - columns - 1] + b) }
                    if i < columns - 1 { v = min(v, d[n - columns + 1] + b) }
                }
                d[n] = v
            }
        }
        for j in stride(from: rows - 1, through: 0, by: -1) {
            for i in stride(from: columns - 1, through: 0, by: -1) {
                let n = i + j * columns
                var v = d[n]
                if i < columns - 1 { v = min(v, d[n + 1] + a) }
                if j < rows - 1 {
                    v = min(v, d[n + columns] + a)
                    if i < columns - 1 { v = min(v, d[n + columns + 1] + b) }
                    if i > 0 { v = min(v, d[n + columns - 1] + b) }
                }
                d[n] = v
            }
        }
        return d
    }

    /// The bedding's coordinate `s` along its normal at which `bedCoordinate` reaches `c` (it
    /// rises monotonically).
    static func bedLevel(_ c: Float, near s0: Float) -> Float {
        var (a, b) = (s0 - 6, s0 + 6)
        for _ in 0..<30 {
            let m = (a + b) / 2
            if QuarryFracture.bedCoordinate(m) < c { a = m } else { b = m }
        }
        return (a + b) / 2
    }

    /// How much the slopes crop out at (x, y): in broken clusters, more high on the flanks.
    func outcrop(_ n: Int, ridge: QuarryRidge) -> Float {
        let (x, y) = position(n % columns, n / columns)
        let slope = simd_length(gradient[n])
        let high = max(0, min(1, (ground[n] - ridge.floor + 10) / max(ridge.crest - ridge.floor + 10, 1)))
        // Crags in clusters a few tens of metres across, their ledges broken into runs of a few
        // metres to a couple of tens along the bed; denser in the clusters' cores, thinning to
        // the odd run at their edges, with bare slope between (they were spread evenly over each
        // cluster until emmettl/bombcad-work#147).
        let clusters = QuarryNoise.fbm(SIMD3(x / 34, y / 34, 3.3), octaves: 3) + 0.25 * high
        let cores = QuarryNoise.fbm(SIMD3(x / 13, y / 13, 6.6), octaves: 2)
        let runs = QuarryNoise.fbm(SIMD3(x / 7, y / 7, 8.8), octaves: 2)
        let steep = max(0, min(1, (slope - Self.ledgeSlope) / 0.25))
        let inCluster = max(0, min(1, (clusters - 0.08) / 0.14))
        return inCluster * max(0, min(1, (runs + 0.02 + 0.2 * cores + 0.1 * inCluster) / 0.14)) * steep
    }

    /// The crags: a few places on the steep flanks, clear of the cut and of the opening view's
    /// sight lines to the crest, where several beds stand out together as a small cliff, the top
    /// one a hard bed. Chosen by slope and broad noise, the steepest first, `cragSpacing` apart.
    mutating func findCrags(face: QuarryFace, ridge: QuarryRidge) {
        cragMask = [Bool](repeating: false, count: columns * rows)
        let normal = QuarryFace.beddingNormal
        // The opening view's lines from the eye to what it looks at and to the crest either side
        // of the cut, in plan; the pull-back moves along the first.
        var sights: [(SIMD2<Float>, SIMD2<Float>)] = []
        if let view = QuarryRidgeView.opening(face) {
            let eye = SIMD2(view.orbit.eye.x, view.orbit.eye.y)
            let wall = ridge.halfWidth + (ridge.crest - ridge.floor) / ridge.wallSlope + 3
            for target in [
                SIMD2(view.orbit.focus.x, view.orbit.focus.y), SIMD2(ridge.crestX, wall),
                SIMD2(ridge.crestX, -wall),
            ] {
                sights.append((eye, target))
            }
        }
        func off(_ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
            let ab = b - a
            let t = max(0, min(1, simd_dot(p - a, ab) / max(simd_length_squared(ab), 1e-6)))
            return simd_distance(p, a + ab * t)
        }
        // The slope's mean over 9 m round a texel, and how steady its direction is there (1 a
        // plane, less on a spur or in a hollow).
        func meanSlope(_ i: Int, _ j: Int) -> (SIMD2<Float>, Float) {
            var sum = SIMD2<Float>.zero
            var lengths: Float = 0
            for dj in stride(from: -4, through: 4, by: 2) {
                for di in stride(from: -4, through: 4, by: 2) {
                    let g = gradient[(i + di) + (j + dj) * columns]
                    sum += g
                    lengths += simd_length(g)
                }
            }
            return (sum / 25, simd_length(sum) / max(lengths, 1e-6))
        }
        var candidates: [(score: Float, i: Int, j: Int)] = []
        let border = 24
        guard columns > 2 * border, rows > 2 * border else { return }
        for j in stride(from: border, to: rows - border, by: 3) {
            for i in stride(from: border, to: columns - border, by: 3) {
                let n = i + j * columns
                guard !paving[n], cut[n] < 0.5, cutDistance[n] > Self.cragClear else { continue }
                let (g, steady) = meanSlope(i, j)
                let slope = simd_length(g)
                guard slope > Self.cragSlope, slope < 1.5, steady > 0.85 else { continue }
                let (x, y) = position(i, j)
                let p = SIMD2(x, y)
                guard sights.allSatisfy({ off(p, $0.0, $0.1) > Self.cragClear }) else { continue }
                let score = slope * (0.7 + QuarryNoise.fbm(SIMD3(x / 45, y / 45, 5.5), octaves: 2))
                candidates.append((score, i, j))
            }
        }
        candidates.sort { ($0.score, $1.i, $1.j) > ($1.score, $0.i, $0.j) }
        var r = QuarryRandom(seed: 2_026_111_41)
        for candidate in candidates where crags.count < Self.cragCount {
            let (x, y) = position(candidate.i, candidate.j)
            guard
                crags.allSatisfy({
                    simd_distance(SIMD2($0.centre.x, $0.centre.y), SIMD2(x, y)) > Self.cragSpacing
                })
            else { continue }
            let (g, _) = meanSlope(candidate.i, candidate.j)
            let down = -g / simd_length(g)
            let side = SIMD2(-down.y, down.x)
            let p = SIMD3(x, y, groundHeight(x, y))
            // Its top a hard bed; its foot as many beds down as make it 5 to 9 m high.
            var top = Int(floor(QuarryFracture.bedCoordinate(simd_dot(p, normal))))
            while QuarryRock.kind(bed: top) == .shale { top -= 1 }
            let topLevel = Self.bedLevel(Float(top + 1), near: simd_dot(p, normal))
            let height = r.float(5, 9)
            var bottom = top
            var bottomLevel = Self.bedLevel(Float(top), near: topLevel)
            while topLevel - bottomLevel < height, bottom > top - 9 {
                bottom -= 1
                bottomLevel = Self.bedLevel(Float(bottom), near: bottomLevel)
            }
            // Where its top meets the ground, and where its foot does, down the slope.
            func level(_ s: Float, _ q: SIMD2<Float>) -> Float {
                (s - normal.x * q.x - normal.y * q.y) / normal.z
            }
            var s0: Float = 0
            while s0 > -8,
                groundHeight(x + down.x * s0, y + down.y * s0) < level(topLevel, SIMD2(x, y) + down * s0)
            {
                s0 -= 0.25
            }
            let centre = SIMD2(x, y) + down * s0
            var reach: Float = 0
            while reach < 15 {
                let q = centre + down * reach
                if groundHeight(q.x, q.y) < level(bottomLevel, q) { break }
                reach += 0.25
            }
            let width = r.float(22, 40)
            guard reach > 3, reach < 14 else { continue }
            // All of it on the map, clear of the dense rock, on steep ground.
            var fits = true
            for a in stride(from: -width / 2 - 4, through: width / 2 + 4, by: 2) {
                for s in stride(from: -6, through: reach + 5, by: 2) {
                    let q = centre + side * a + down * s
                    guard let n = texel(q.x, q.y), !paving[n], cutDistance[n] > Self.cragClear * 0.6 else {
                        fits = false
                        break
                    }
                }
                if !fits { break }
            }
            guard fits else { continue }
            crags.append(
                Crag(
                    centre: SIMD3(centre.x, centre.y, groundHeight(centre.x, centre.y)), downhill: down,
                    width: width,
                    beds: bottom...top, reach: reach, seed: r.float()))
            for a in stride(from: -width / 2 - 4, through: width / 2 + 4, by: 0.5) {
                for s in stride(from: -6, through: reach + 4, by: 0.5) {
                    let q = centre + side * a + down * s
                    if let n = texel(q.x, q.y) { cragMask[n] = true }
                }
            }
        }
    }

    /// The ledges: where a hard bed's top meets the ground going uphill, in the outcrops, one
    /// every `ledgeSpacing` or so along the bed, clear of the dense rock round the cut.
    mutating func findLedges(ridge: QuarryRidge) {
        let normal = QuarryFace.beddingNormal
        var best: [Int64: (Float, Ledge)] = [:]
        for j in 1..<(rows - 1) {
            for i in 1..<(columns - 1) {
                let n = i + j * columns
                guard !paving[n], !cragMask[n], cutDistance[n] > Self.margin + 1.5 else { continue }
                let g = gradient[n]
                let slope = simd_length(g)
                guard slope > Self.ledgeSlope else { continue }
                let (x, y) = position(i, j)
                var r = QuarryRandom(seed: UInt64(n) &* 0x9E37_79B9 &+ 77)
                guard r.float() < outcrop(n, ridge: ridge) else { continue }
                let down = -g / slope
                let p = SIMD3(x, y, ground[n])
                let uphill = SIMD2(x, y) - down * spacing
                let u = SIMD3(uphill.x, uphill.y, groundHeight(uphill.x, uphill.y))
                let cp = QuarryFracture.bedCoordinate(simd_dot(p, normal))
                let cu = QuarryFracture.bedCoordinate(simd_dot(u, normal))
                let bed = Int(floor(cp))
                // Massive limestone crops out; sandstone and ironstone in some beds; shale never
                // (it weathers back under the scree).
                let kind = QuarryRock.kind(bed: bed)
                let crops =
                    kind == .limestone || (kind != .shale && QuarryRock.bedHash(bed &* 31 &+ 5) & 1 == 0)
                guard Int(floor(cu)) > bed, crops else { continue }
                // Where the bed's top crosses the ground between the two.
                let f = max(0, min(1, (Float(bed + 1) - cp) / max(cu - cp, 1e-4)))
                let contour = p + (u - p) * f
                guard !paves(contour.x, contour.y),
                    !(texel(contour.x, contour.y).map { cragMask[$0] } ?? true)
                else { continue }
                let top = Self.bedLevel(Float(bed + 1), near: simd_dot(contour, normal))
                let bottom = Self.bedLevel(Float(bed), near: top)
                let thickness = top - bottom
                guard thickness > 0.7 else { continue }
                let run = max(0.6, min(r.float(1.2, 3.2), 1.2 * thickness / slope))
                let ledge = Ledge(
                    contour: contour, downhill: down, top: top, bottom: bottom, run: run, bed: bed,
                    seed: r.float())
                // One a cell along the bed, the cells closer here and wider there, so the ledges
                // are not evenly spaced.
                let wide = QuarryNoise.fbm(SIMD3(contour.x / 19, contour.y / 19, 9.1), octaves: 2)
                let size = wide < -0.12 ? 0 : wide < 0.12 ? 1 : 2
                let cell = Self.ledgeSpacing * [0.7, 1, 1.6][size]
                let key =
                    Int64(floor(contour.x / cell))
                    &+ Int64(floor(contour.y / cell)) &* 100_003 &+ Int64(bed) &* 10_000_019
                    &+ Int64(size) &* 1_000_000_007
                let priority = r.float()
                if (best[key]?.0 ?? -1) < priority { best[key] = (priority, ledge) }
            }
        }
        ledges = best.values.map(\.1).sorted {
            ($0.bed, $0.contour.x, $0.contour.y) < ($1.bed, $1.contour.x, $1.contour.y)
        }
    }

    /// Rock round the render-only rock, scree below it, grass on the rest of the gentler ground.
    mutating func cover(ridge: QuarryRidge) {
        let count = columns * rows
        // Under the ledges' slabs, and where the stones fall from: their fronts.
        var source = [Float](repeating: 0, count: count)
        for ledge in ledges {
            let mid = SIMD2(ledge.contour.x, ledge.contour.y) + ledge.downhill * (ledge.run * 0.5)
            let side = SIMD2(-ledge.downhill.y, ledge.downhill.x)
            for a in stride(from: Float(-1.4), through: 1.4, by: 0.7) {
                // Under the outcrop, bare rock; behind it the slope's own turf and soil.
                for b in stride(from: -ledge.run * 0.5 - 0.4, through: ledge.run * 0.5 - 0.2, by: 0.5) {
                    let q = mid + side * a + ledge.downhill * b
                    if let n = texel(q.x, q.y) { rock[n] = max(rock[n], 0.7) }
                }
                // Scree below some of them: others stand in the grass.
                let front = mid + side * a + ledge.downhill * (ledge.run * 0.5 + 1)
                let falls = smoothstep(
                    -0.05, 0.12, QuarryNoise.fbm(SIMD3(front.x / 13, front.y / 13, 2.2), octaves: 2))
                if let n = texel(front.x, front.y) { source[n] = max(source[n], 0.9 * falls) }
            }
        }
        // Below the crags, scree in fans from most of their feet, and bare rock under them.
        for crag in crags {
            let side = SIMD2(-crag.downhill.y, crag.downhill.x)
            let centre = SIMD2(crag.centre.x, crag.centre.y)
            for a in stride(from: -crag.width / 2, through: crag.width / 2, by: 0.7) {
                for b in stride(from: Float(-1), through: crag.reach, by: 0.7) {
                    let q = centre + side * a + crag.downhill * b
                    if let n = texel(q.x, q.y) { rock[n] = max(rock[n], 0.8) }
                }
                let front = centre + side * a + crag.downhill * (crag.reach + 1.2)
                let falls = smoothstep(
                    -0.2, 0.05, QuarryNoise.fbm(SIMD3(front.x / 9, front.y / 9, 2.7), octaves: 2))
                if let n = texel(front.x, front.y) { source[n] = max(source[n], falls) }
            }
            // Talus at its ends, where its beds go under the slope (emmettl/bombcad-work#149).
            for end in [Float(-1), 1] {
                for along in stride(from: Float(0), through: 12, by: 0.7) {
                    let t = 1 - along / (crag.width / 2)
                    for b in stride(from: -0.15 * crag.width * t * t, through: crag.reach + 1, by: 0.7) {
                        let q = centre + side * (end * t * crag.width / 2) + crag.downhill * b
                        if let n = texel(q.x, q.y) { source[n] = max(source[n], 0.75) }
                    }
                }
            }
        }
        for j in 1..<(rows - 1) {
            for i in 1..<(columns - 1) {
                let n = i + j * columns
                if paving[n] {
                    rock[n] = 1
                    continue
                }
                let slope = simd_length(gradient[n])
                // Below the dense rock round the cut in fans, a lobe here and there along its edge
                // rather than a band all the way round (it greyed the whole near flank in the
                // default view until 13 November 2026), and a little from the steepest ground.
                let (x, y) = position(i, j)
                let fans = smoothstep(0.02, 0.16, QuarryNoise.fbm(SIMD3(x / 11, y / 11, 6.6), octaves: 2))
                let uphill = SIMD2(x, y) + gradient[n] / max(slope, 1e-3) * 1.5
                if slope > 0.05, paves(uphill.x, uphill.y) { source[n] = max(source[n], 0.9 * fans) }
                source[n] = max(source[n], 0.25 * fans * max(0, min(1, (slope - 0.9) / 0.35)))
            }
        }
        // Spread a little along the slope too, so the aprons are fans, not strips.
        for _ in 0..<2 {
            var spread = source
            for j in 1..<(rows - 1) {
                for i in 1..<(columns - 1) {
                    let n = i + j * columns
                    let around = source[n - 1] + source[n + 1] + source[n - columns] + source[n + columns]
                    spread[n] = max(source[n], 0.85 * (source[n] + around) / 5)
                }
            }
            source = spread
        }
        // Scree: what falls from the sources runs down the slope, further on steep ground.
        let (columns, rows, low, spacing) = (columns, rows, low, spacing)
        let gradient = gradient
        let paving = paving
        let frozen = source
        var scree = [Float](repeating: 0, count: count)
        scree.withUnsafeMutableBufferPointer { s in
            nonisolated(unsafe) let out = s
            DispatchQueue.concurrentPerform(iterations: rows) { j in
                for i in 0..<columns {
                    let n = i + j * columns
                    guard !paving[n] else { continue }
                    var p = SIMD2(low.x + Float(i) * spacing, low.y + Float(j) * spacing)
                    let (x, y) = (p.x, p.y)
                    let slope = simd_length(gradient[n])
                    // Fans: wider the further they run, their toes in lobes that reach on or stop
                    // short (they followed the slope's lines as strips with straight sides until 13
                    // November 2026).
                    let lobe = QuarryNoise.fbm(SIMD3(x / 4.5, y / 4.5, 1.9), octaves: 2)
                    let reach = (2 + 6 * max(0, min(1, (slope - 0.3) / 0.4))) * max(0.35, 0.8 + 1.4 * lobe)
                    var amount = frozen[n]
                    func source(_ q: SIMD2<Float>) -> Float {
                        let qi = Int(((q.x - low.x) / spacing).rounded())
                        let qj = Int(((q.y - low.y) / spacing).rounded())
                        guard qi >= 0, qj >= 0, qi < columns, qj < rows else { return 0 }
                        return frozen[qi + qj * columns]
                    }
                    for k in 1...14 {
                        let gi = Int(((p.x - low.x) / spacing).rounded())
                        let gj = Int(((p.y - low.y) / spacing).rounded())
                        guard gi >= 0, gj >= 0, gi < columns, gj < rows else { break }
                        let g = gradient[gi + gj * columns]
                        let l = simd_length(g)
                        guard l > 0.05 else { break }
                        p += g / l * spacing
                        let side = SIMD2(-g.y, g.x) / l * (Float(k) * 0.28 * spacing)
                        let fade = exp(-Float(k) / reach)
                        amount = max(
                            amount, source(p) * fade, 0.8 * fade * max(source(p + side), source(p - side)))
                    }
                    let streaks = 0.65 + 0.9 * QuarryNoise.fbm(SIMD3(x / 6, y / 6, 5.7), octaves: 3)
                    out[n] = max(0, min(1, amount * streaks))
                }
            }
        }
        self.scree = scree
        for n in 0..<count {
            if paving[n] || cut[n] > 0.5 {
                grass[n] = 0
                continue
            }
            let (x, y) = position(n % columns, n / columns)
            let slope = simd_length(gradient[n])
            // Grass holds on steep ground too, short of crags (it gave out from a slope of 0.35 to
            // 0.85 until 13 November 2026, leaving the near flank bare).
            let gentle = 1 - max(0, min(1, (slope - 0.7) / 0.6))
            let patches = max(
                0, min(1, (QuarryNoise.fbm(SIMD3(x / 16, y / 16, 9.1), octaves: 3) + 0.25) / 0.4))
            let open = (1 - max(0, min(1, (scree[n] - 0.15) / 0.45))) * (1 - rock[n])
            grass[n] = gentle * open * (0.35 + 0.65 * patches)
        }
    }

    /// The render-only stones of the scree and the ground and the scrub on the grass, `scale` times
    /// as many as the film draws: the stones first (`look.x` 0), then the bushes' lobes (`look.x` 1).
    /// Stones lie in clusters, from fist-sized to boulders, the biggest at a fan's toe and fallen
    /// below the ledges; a few lie half-buried in the grass. Each bush is several rounded lobes about
    /// a low dome, its own colour, each lobe a little lighter or darker.
    public func stones(scale: Float = 1) -> [Stone] {
        var stones: [Stone] = []
        var bushes: [Stone] = []
        var r = QuarryRandom(seed: 2_026_111_3)
        func turn(normal: SIMD3<Float>, yaw: Float, lean: Float) -> SIMD4<Float> {
            // About the vertical by `yaw`, leaning a little, then from up to the ground's normal.
            func multiply(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> SIMD4<Float> {
                let (av, bv) = (SIMD3(a.x, a.y, a.z), SIMD3(b.x, b.y, b.z))
                let v = a.w * bv + b.w * av + simd_cross(av, bv)
                return SIMD4(v, a.w * b.w - simd_dot(av, bv))
            }
            let spin = SIMD4<Float>(0, 0, sin(yaw / 2), cos(yaw / 2))
            let tilt = SIMD4<Float>(sin(lean / 2), 0, 0, cos(lean / 2))
            let axis = simd_cross(SIMD3<Float>(0, 0, 1), normal)
            let s = simd_length(axis)
            let toNormal =
                s < 1e-5
                ? SIMD4<Float>(0, 0, 0, 1)
                : SIMD4(axis / s * sin(asin(min(1, s)) / 2), cos(asin(min(1, s)) / 2))
            let q = multiply(toNormal, multiply(tilt, spin))
            return q / simd_length(q)
        }
        func normal(_ x: Float, _ y: Float) -> SIMD3<Float> {
            guard let n = texel(x, y) else { return SIMD3(0, 0, 1) }
            return simd_normalize(SIMD3(-gradient[n].x, -gradient[n].y, 1))
        }
        func clear(_ x: Float, _ y: Float) -> Bool {
            guard let n = texel(x, y) else { return false }
            return !paving[n] && cut[n] < 0.5 && !cragMask[n]
        }
        /// A stone of `size` (m) at (x, y), sunk by `sink` of its size; `angular` a block fallen
        /// from an outcrop or a crag.
        func stone(
            _ x: Float, _ y: Float, _ size: Float, sink: Float, angular: Bool = false, anywhere: Bool = false
        ) {
            guard anywhere ? texel(x, y).map({ !paving[$0] && cut[$0] < 0.5 }) ?? false : clear(x, y) else {
                return
            }
            stones.append(
                Stone(
                    posSize: SIMD4(x, y, groundHeight(x, y) + size * (0.3 - sink), size),
                    rotation: turn(normal: normal(x, y), yaw: r.float(0, 6.283), lean: r.float(-0.3, 0.3)),
                    look: SIMD4(0, r.float(), r.float(), angular ? 1 : 0)))
        }
        // Sizes from a fist to a boulder, on a power law.
        func size(_ low: Float, _ high: Float, _ power: Float) -> Float {
            min(high, low * pow(max(r.float(), 1e-3), -power))
        }
        for j in 1..<(rows - 1) {
            for i in 1..<(columns - 1) {
                let n = i + j * columns
                guard !paving[n], cut[n] < 0.5, rock[n] < 0.5 else { continue }
                let (x, y) = position(i, j)
                // Clusters a few metres across, and none between them on thin scree.
                let cluster = max(
                    0, min(1, (QuarryNoise.fbm(SIMD3(x / 3.5, y / 3.5, 6.1), octaves: 2) + 0.12) / 0.3))
                let wanted = scree[n] * (0.4 + 2.2 * cluster) * 0.85 * scale
                var groups = Int(wanted)
                if r.float() < wanted - Float(groups) { groups += 1 }
                for _ in 0..<groups {
                    // A group: a larger stone or two and smaller ones round them.
                    let (gx, gy) = (x + r.float(-0.5, 0.5), y + r.float(-0.5, 0.5))
                    let toe: Float = scree[n] < 0.4 ? 1.5 : 1
                    let lead = size(0.16, 1.2, 0.5) * toe
                    stone(gx, gy, min(1.5, lead), sink: 0.2)
                    for _ in 0..<Int(r.float(1, 4.99)) {
                        let a = r.float(0, 6.283)
                        let d = lead * 0.5 + r.float(0.05, 0.45)
                        stone(gx + cos(a) * d, gy + sin(a) * d, size(0.1, 0.45, 0.45), sink: 0.18)
                    }
                }
                // Boulders at the fans' thin toes, where the big ones roll to.
                if scree[n] > 0.08, scree[n] < 0.45, r.float() < 0.035 * scale {
                    stone(x + r.float(-0.5, 0.5), y + r.float(-0.5, 0.5), r.float(0.7, 1.7), sink: 0.25)
                }
                // A few stones half-buried in the grass.
                if grass[n] > 0.3, r.float() < 0.04 * grass[n] * scale {
                    stone(x + r.float(-0.5, 0.5), y + r.float(-0.5, 0.5), size(0.22, 0.8, 0.5), sink: 0.3)
                }
                // Bushes in clumps on the grass: several lobes about a low dome.
                let clumps = max(
                    0, min(1, (QuarryNoise.fbm(SIMD3(x / 13, y / 13, 4.4), octaves: 3) + 0.02) / 0.25))
                guard r.float() < grass[n] * 0.05 * scale * clumps * clumps else { continue }
                // A few big ones, so the scrub still shows from far off.
                let width = min(2.6, 0.95 * pow(max(r.float(), 0.02), -0.3)) * (r.float() < 0.15 ? 1.6 : 1)
                let (bx, by) = (x + r.float(-0.5, 0.5), y + r.float(-0.5, 0.5))
                guard clear(bx, by) else { continue }
                let tint = r.float()
                let seed = r.float()
                let lobes = 4 + Int(r.float() * 3.99)
                for k in 0..<lobes {
                    // The first lobe the crown, the rest round it, lower toward the edge.
                    let a = Float(k) / Float(lobes) * 6.283 + r.float(-0.5, 0.5)
                    let out = k == 0 ? r.float(0, 0.1) : r.float(0.15, 0.4)
                    let (px, py) = (bx + cos(a) * out * width, by + sin(a) * out * width)
                    let lobe = width * (k == 0 ? r.float(0.55, 0.7) : r.float(0.38, 0.55))
                    guard clear(px, py) else { continue }
                    let rise = min(0.8 * lobe, width * 0.32 * (1 - out * 1.2) + lobe * 0.25)
                    let ground = groundHeight(px, py)
                    bushes.append(
                        Stone(
                            posSize: SIMD4(px, py, ground + rise, lobe),
                            rotation: turn(normal: SIMD3(0, 0, 1), yaw: r.float(0, 6.283), lean: 0),
                            look: SIMD4(1, seed + Float(k) * 0.137, tint, r.float())))
                }
            }
        }
        // Blocks fallen from the ledges, below their fronts.
        for ledge in ledges {
            var lr = QuarryRandom(
                seed: UInt64(bitPattern: Int64(ledge.bed)) &* 31 &+ UInt64(ledge.seed * 1e6))
            guard lr.float() < 0.55 * scale else { continue }
            let side = SIMD2(-ledge.downhill.y, ledge.downhill.x)
            for _ in 0..<(1 + Int(lr.float() * 2.5)) {
                let p =
                    SIMD2(ledge.contour.x, ledge.contour.y) + ledge.downhill
                    * (ledge.run + lr.float(0.4, 4.5))
                    + side * lr.float(-1.6, 1.6)
                stone(p.x, p.y, lr.float(0.4, 1.2), sink: 0.2, angular: lr.float() < 0.7)
            }
        }
        // Blocks fallen from the crags, below their feet, the biggest furthest out.
        for crag in crags {
            var cr = QuarryRandom(seed: UInt64(crag.seed * 1e6) &+ 977)
            let side = SIMD2(-crag.downhill.y, crag.downhill.x)
            let centre = SIMD2(crag.centre.x, crag.centre.y)
            for _ in 0..<Int(crag.width * 1.1 * scale) {
                let size = min(2.4, 0.45 * pow(max(cr.float(), 0.02), -0.45))
                let p =
                    centre + side * cr.float(-0.55, 0.55) * crag.width
                    + crag.downhill * (crag.reach + cr.float(0.2, 2.5) + size * cr.float(0.5, 3))
                stone(p.x, p.y, size, sink: 0.22, angular: cr.float() < 0.75, anywhere: true)
            }
            // Talus at its ends, where its beds go under the slope: blocks and stones half buried
            // there and below (emmettl/bombcad-work#149), over its last 12 m, as the slope climbs
            // over its beds well inside the sweep's ends. The end's line is bowed back about 0.15
            // of the crag's width (`crag(_:flank:seed:)`).
            for end in [Float(-1), 1] {
                for _ in 0..<Int(26 * scale) {
                    let size = min(1.5, 0.28 * pow(max(cr.float(), 0.02), -0.45))
                    let t = 1 - cr.float(0, 12) / (crag.width / 2)
                    let p =
                        centre + side * (end * t * crag.width / 2)
                        + crag.downhill * (-0.15 * crag.width * t * t + cr.float(0.3, crag.reach + 1.5))
                    stone(p.x, p.y, size, sink: 0.3, angular: cr.float() < 0.7, anywhere: true)
                }
            }
            // Scree along its whole foot (emmettl/bombcad-work#151): stones and small blocks banked
            // against it, half buried, so the slope meets it in a ragged line of fallen rock. Those
            // that land under its overhang or inside it are hidden.
            var fr = QuarryRandom(seed: UInt64(crag.seed * 1e6) &+ 151)
            for _ in 0..<Int(crag.width * 2.4 * scale) {
                let size = min(0.9, 0.16 * pow(max(fr.float(), 0.02), -0.5))
                let t = fr.float(-1, 1)
                let p =
                    centre + side * (t * crag.width / 2)
                    + crag.downhill
                    * (-0.15 * crag.width * t * t + crag.reach * fr.float(0.75, 1.1) + fr.float(-0.3, 0.9))
                stone(p.x, p.y, size, sink: 0.35, angular: fr.float() < 0.6, anywhere: true)
            }
        }
        // The small stones first, then the large (drawn rounder), then the bushes' lobes.
        let small = stones.filter { $0.posSize.w < Self.largeStone }
        let large = stones.filter { $0.posSize.w >= Self.largeStone }
        return small + large + bushes
    }

    /// How many of `stones()` are stones; the rest are bushes' lobes.
    public static func stoneCount(_ stones: [Stone]) -> Int {
        stones.firstIndex { $0.look.x > 0.5 } ?? stones.count
    }

    /// How many of `stones()` are small stones, drawn with `stoneShape`; the large ones after them
    /// take `lobeShape`.
    public static func smallStoneCount(_ stones: [Stone]) -> Int {
        stones.firstIndex { $0.look.x > 0.5 || $0.posSize.w >= largeStone } ?? stones.count
    }

    /// A stone: an icosahedron's 20 triangles, unindexed, as float4 points (w unused), which
    /// `flankStoneVertex` makes irregular and stretches to the stone's own proportions.
    public static func stoneShape() -> [SIMD4<Float>] {
        let (corners, faces) = icosahedron()
        return faces.flatMap { [SIMD4(corners[$0.0], 0), SIMD4(corners[$0.1], 0), SIMD4(corners[$0.2], 0)] }
    }

    static func icosahedron() -> ([SIMD3<Float>], [(Int, Int, Int)]) {
        let t = (1 + Float(5).squareRoot()) / 2
        let corners: [SIMD3<Float>] = [
            SIMD3(-1, t, 0), SIMD3(1, t, 0), SIMD3(-1, -t, 0), SIMD3(1, -t, 0),
            SIMD3(0, -1, t), SIMD3(0, 1, t), SIMD3(0, -1, -t), SIMD3(0, 1, -t),
            SIMD3(t, 0, -1), SIMD3(t, 0, 1), SIMD3(-t, 0, -1), SIMD3(-t, 0, 1),
        ]
        let faces: [(Int, Int, Int)] = [
            (0, 11, 5), (0, 5, 1), (0, 1, 7), (0, 7, 10), (0, 10, 11), (1, 5, 9), (5, 11, 4), (11, 10, 2),
            (10, 7, 6), (7, 1, 8), (3, 9, 4), (3, 4, 2), (3, 2, 6), (3, 6, 8), (3, 8, 9), (4, 9, 5),
            (2, 4, 11), (6, 2, 10), (8, 6, 7), (9, 8, 1),
        ]
        return (corners.map { simd_normalize($0) }, faces)
    }

    /// A bush's lobe: a sphere of 80 triangles, unindexed, as float4 points (w unused), the shape
    /// `flankBushVertex` makes lumpy.
    public static func lobeShape() -> [SIMD4<Float>] {
        let (corners, faces) = icosahedron()
        var out: [SIMD4<Float>] = []
        for (a, b, c) in faces {
            let (pa, pb, pc) = (corners[a], corners[b], corners[c])
            let (ab, bc, ca) = (simd_normalize(pa + pb), simd_normalize(pb + pc), simd_normalize(pc + pa))
            for tri in [(pa, ab, ca), (ab, pb, bc), (ca, bc, pc), (ab, bc, ca)] {
                out += [SIMD4(tri.0, 0), SIMD4(tri.1, 0), SIMD4(tri.2, 0)]
            }
        }
        return out
    }

    /// The cover packed for a texture: scree, grass, rock and cut as bytes, row by row from the
    /// grid's first row (low y).
    public func packed() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 4 * columns * rows)
        func byte(_ v: Float) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        for n in 0..<(columns * rows) {
            out[4 * n] = byte(scree[n])
            out[4 * n + 1] = byte(grass[n])
            out[4 * n + 2] = byte(rock[n])
            out[4 * n + 3] = byte(cut[n])
        }
        return out
    }
}

extension QuarryFlank {
    /// The ledges in runs: those of one bed near enough along it to be one outcrop, each run in
    /// order along the bed, walked from one end.
    public func ledgeRuns() -> [[Int]] {
        var byBed: [Int: [Int]] = [:]
        for (k, ledge) in ledges.enumerated() { byBed[ledge.bed, default: []].append(k) }
        func along(_ a: Int, _ b: Int) -> Float? {
            var d = ledges[b].contour - ledges[a].contour
            d.z = 0
            let distance = simd_length(d)
            // Along the bed, not across a hollow or a spur to the same bed further round.
            guard distance < 7.5, distance > 0.05,
                abs(simd_dot(SIMD2(d.x, d.y) / distance, ledges[a].downhill)) < 0.6
            else { return nil }
            return distance
        }
        var runs: [[Int]] = []
        for bed in byBed.keys.sorted() {
            let members = byBed[bed]!
            var neighbours: [Int: [(Int, Float)]] = [:]
            for a in members {
                for b in members where b != a {
                    if let d = along(a, b) { neighbours[a, default: []].append((b, d)) }
                }
            }
            var left = Set(members)
            func open(_ k: Int) -> [(Int, Float)] { (neighbours[k] ?? []).filter { left.contains($0.0) } }
            while !left.isEmpty {
                // From an end: the one with fewest neighbours still free.
                let start = left.min { (open($0).count, $0) < (open($1).count, $1) }!
                var run = [start]
                left.remove(start)
                var current = start
                var heading = SIMD2<Float>.zero
                func onward(_ k: Int) -> Bool {
                    let step = ledges[k].contour - ledges[current].contour
                    return simd_dot(SIMD2(step.x, step.y), heading) >= 0
                }
                while let next = open(current).filter({ onward($0.0) }).min(by: {
                    ($0.1, $0.0) < ($1.1, $1.0)
                }) {
                    let step = ledges[next.0].contour - ledges[current].contour
                    heading = SIMD2(step.x, step.y)
                    run.append(next.0)
                    left.remove(next.0)
                    current = next.0
                }
                runs.append(run)
            }
        }
        return runs
    }
}

extension QuarryFace {
    /// What part of an outcrop's profile a vertex is, for its shading.
    public enum OutcropPart: UInt32, Sendable {
        /// Under the ground behind it or at its foot.
        case buried = 0
        /// The top of a layer, where it shows.
        case top
        /// A layer's front.
        case face
        /// The parting between two layers, drawn back into the rock.
        case parting
        /// Its foot, running into the ground.
        case foot
    }

    /// The body bits of an outcrop's vertex, read by `ledgeVertex` in QuarryRender.metal: its height
    /// above the ground (cm, to 10.23 m), its outcrop's random value (6 bits), what part of the
    /// profile it is (3 bits), which layer from the top (3 bits), how open a joint across it is there
    /// (4 bits), whether it is a crag's (1 bit), and how far its beds are drawn shifted along the
    /// bedding's normal there (`OutcropForm`, 5 bits: 5 cm steps, 15 none), so the shader colours
    /// its layers as the beds they are.
    public static func outcropTag(
        above: Float, random: Float, part: OutcropPart, layer: Int = 0, joint: Float = 0, crag: Bool = false,
        shift: Float = 0
    ) -> UInt32 {
        let height = UInt32(max(0, min(1023, (above * 100).rounded())))
        let value = UInt32(max(0, min(63, (random * 63).rounded())))
        let crack = UInt32(max(0, min(15, (joint * 15).rounded())))
        let moved = UInt32(max(0, min(31, (shift / Self.outcropShiftStep).rounded() + 15)))
        return height | (value << 10) | (part.rawValue << 16) | (UInt32(max(0, min(layer, 7))) << 19)
            | (crack << 22)
            | ((crag ? 1 : 0) << 26) | (moved << 27)
    }

    /// How thick, on average, what an outcrop's row shows above the slope is at least (m), and the
    /// most it is tipped back to make it so (radians; `outcropMesh`, emmettl/bombcad-work#150):
    /// thinner, it lay on the slope as a thin slab or lip.
    static let slabThickness: Float = 0.42
    static let slabTilt: Float = 0.3
    /// How far a ledge's outcrop sinks under the ground at its ends (m; `outcropMesh`).
    static let outcropEnd: Float = 0.3
    /// The most an outcrop piece's line turns, a metre along it (radians; `outcrop`,
    /// emmettl/bombcad-work#151).
    static let outcropTurn: Float = 0.08

    /// The sharpest turn of a line through `points`, a metre along it (radians).
    static func sharpestTurn(_ points: [SIMD2<Float>]) -> Float {
        var sharpest: Float = 0
        for k in 1..<max(1, points.count - 1) {
            let (a, b) = (points[k] - points[k - 1], points[k + 1] - points[k])
            let (la, lb) = (simd_length(a), simd_length(b))
            guard la > 1e-3, lb > 1e-3 else { continue }
            let turn = acos(max(-1, min(1, simd_dot(a, b) / (la * lb))))
            sharpest = max(sharpest, turn / (0.5 * (la + lb)))
        }
        return sharpest
    }

    /// The step of an outcrop's shift along the bedding's normal in its vertices' tags (m).
    public static let outcropShiftStep: Float = 0.05

    /// How far an outcrop's vertex's beds are drawn shifted along the bedding's normal (m;
    /// `outcropTag`).
    public static func outcropShift(_ body: UInt32) -> Float {
        (Float(body >> 27 & 31) - 15) * outcropShiftStep
    }

    /// Whether an outcrop's vertex is a crag's (`outcropTag`).
    public static func isCrag(_ body: UInt32) -> Bool { body >> 26 & 1 == 1 }

    /// One layer of an outcrop, between two levels along the bedding's normal: a set of laminae of
    /// one bed in a ledge's outcrop, or a whole bed in a crag. `soft` is 0 for a hard bed, 1 for
    /// shale, which weathers back under the beds above it.
    struct OutcropLayer {
        var top: Float
        var bottom: Float
        var soft: Float
    }

    /// How an outcrop sits, besides its layers (emmettl/bombcad-work#147): how far it has tipped
    /// forward, down the slope, about the line where its top meets the ground (radians), and how
    /// far apart its joints are against the usual.
    ///
    /// Since emmettl/bombcad-work#149 an outcrop is drawn in short pieces en échelon: each piece's
    /// beds shifted along the bedding's normal by `shift` at its middle and by `skew` a metre along
    /// it either way (as if by small faults and a slight twist), so each runs a little obliquely
    /// across the slope and steps off the next, rather than all following the bed's line. `runOn` is
    /// how far a piece runs on past its end ledges.
    struct OutcropForm {
        var tilt: Float = 0
        var joints: Float = 1
        var shift: Float = 0
        var skew: Float = 0
        var runOn: ClosedRange<Float> = 0.4...1
    }

    /// One run of ledges as an outcrop of its bed (render-only, illustrative; `outcropMesh`): the bed
    /// in one to three layers where its laminae have parted, along a line through the ledges eased
    /// so that a short or sharply turning run is not bent into a crescent. Not all alike
    /// (emmettl/bombcad-work#147): about a quarter stand on the bed below too, a mass two beds
    /// high (a soft bed weathered back under the hard one), and some have tipped forward a
    /// little, crept down the slope; some are broken into short blocks, some into long ones.
    static func outcrop(
        _ run: [QuarryFlank.Ledge], flank: QuarryFlank, seed: UInt64
    ) -> (vertices: [Vertex], indices: [UInt32]) {
        var r = QuarryRandom(seed: seed &* 0x9E37_79B9 &+ 90_211)
        var shape = QuarryRandom(seed: seed &* 0x2545_F491 &+ 147)
        let (top, bottom) = (run[0].top, run[0].bottom)
        let thickness = top - bottom
        let count =
            thickness > 1.6 ? (r.float() < 0.35 ? 3 : 2) : thickness > 0.95 ? (r.float() < 0.6 ? 2 : 1) : 1
        var levels = [bottom]
        if count == 2 { levels.append(bottom + thickness * r.float(0.35, 0.6)) }
        if count == 3 {
            levels += [bottom + thickness * r.float(0.22, 0.4), bottom + thickness * r.float(0.55, 0.75)]
        }
        levels.append(top)
        var layers: [OutcropLayer] = []
        let kind = shape.float()
        var form = OutcropForm()
        // The bed below as well, if it is not too thick: a hard one standing with it, a soft one
        // weathered back under it.
        let below = run[0].bed - 1
        let belowBottom = QuarryFlank.bedLevel(Float(below), near: bottom)
        if kind < 0.27, bottom - belowBottom < 2.4, bottom - belowBottom > 0.3, run.count > 1 {
            let soft: Float =
                switch QuarryRock.kind(bed: below) {
                case .shale: 0.6
                case .sandstone: 0.3
                default: 0
                }
            layers.append(OutcropLayer(top: bottom, bottom: belowBottom, soft: soft))
        }
        if shape.float() < 0.4 { form.tilt = shape.float(0.04, 0.17) }
        // Some in short blocks, some long and little broken.
        form.joints = shape.float() < 0.5 ? shape.float(0.65, 1) : shape.float(1, 1.8)
        for k in 0..<count {
            // The lowest set of laminae is often the weaker, undercut under the rest.
            layers.append(
                OutcropLayer(
                    top: levels[k + 1], bottom: levels[k], soft: k == 0 && count > 1 ? r.float(0, 0.7) : 0))
        }
        var points = run.map { SIMD2($0.contour.x, $0.contour.y) }
        var mean = run.map(\.downhill).reduce(SIMD2<Float>.zero, +)
        mean = simd_length(mean) > 1e-3 ? simd_normalize(mean) : run[0].downhill
        let downs = run.map { simd_normalize($0.downhill + mean * 1.5) }
        if points.count > 2 {
            for _ in 0..<4 {
                var eased = points
                for k in 1..<(points.count - 1) {
                    eased[k] = 0.25 * points[k - 1] + 0.5 * points[k] + 0.25 * points[k + 1]
                }
                points = eased
            }
        }
        // In short pieces en échelon (emmettl/bombcad-work#149): one to four ledges each, each piece's
        // beds shifted a little along the bedding's normal and twisted along it, the same way along
        // the run, so each piece runs a little obliquely across the slope and steps off the next; a
        // lone ledge made a tor, a short block two beds high in places. Swept whole along the bed's
        // line, every outcrop read from above as a row.
        var split = QuarryRandom(seed: seed &* 0x5851_F42D &+ 149)
        var pieces: [Range<Int>] = []
        if points.count < 3 {
            pieces = [0..<points.count]
        } else {
            var start = 0
            while start < points.count {
                let want = split.float() < 0.25 ? 1 : 2 + Int(split.float() * 2.99)
                pieces.append(start..<min(points.count, start + want))
                start += want
            }
        }
        let sense: Float = split.float() < 0.5 ? -1 : 1
        var vertices: [Vertex] = []
        var indices: [UInt32] = []
        for piece in pieces {
            var (p, d) = (Array(points[piece]), Array(downs[piece]))
            var pieceForm = form
            var pieceLayers = layers
            // A short piece lies straight, square to the slope.
            var chord: Float = 0
            if p.count > 1 {
                let (a, b) = (p[0], p[p.count - 1])
                chord = simd_distance(a, b)
                if chord < 9, chord > 0.5 {
                    let way = (b - a) / chord
                    p = p.map { a + way * simd_dot($0 - a, way) }
                    d = d.map { _ in mean }
                } else if p.count > 2 {
                    // A longer piece's curve eased until it turns no more than `outcropTurn` a metre
                    // (emmettl/bombcad-work#151): a tighter turn, its profiles fanning out from it,
                    // gave its outline in plan a hook or a tail.
                    for _ in 0..<24 where Self.sharpestTurn(p) > Self.outcropTurn {
                        var eased = p
                        for k in 1..<(p.count - 1) {
                            eased[k] = 0.25 * p[k - 1] + 0.5 * p[k] + 0.25 * p[k + 1]
                        }
                        p = eased
                    }
                }
            }
            if p.count == 1, pieces.count > 1 {
                // A tor: a short block, broken small, and two beds high where the bed below stands
                // with it.
                pieceForm.runOn = 0.9...1.7
                pieceForm.joints = split.float(0.5, 0.8)
                if pieceLayers[0].bottom == bottom, bottom - belowBottom < 2.4, bottom - belowBottom > 0.3,
                    split.float() < 0.6
                {
                    let soft: Float = QuarryRock.kind(bed: below) == .shale ? 0.4 : 0
                    pieceLayers.insert(OutcropLayer(top: bottom, bottom: belowBottom, soft: soft), at: 0)
                }
            }
            // Its shift at its middle and its twist, its ends within 0.45 m of the bed.
            let half = chord / 2 + pieceForm.runOn.upperBound
            pieceForm.shift = split.float(-0.12, 0.12)
            pieceForm.skew =
                sense * min(split.float(0.04, 0.1), (0.45 - abs(pieceForm.shift)) / max(half, 0.5))
            let mesh = outcropMesh(
                points: p, downs: d, layers: pieceLayers, crag: false, flank: flank, form: pieceForm, r: &r)
            let base = UInt32(vertices.count)
            vertices += mesh.vertices
            indices += mesh.indices.map { $0 + base }
        }
        return (vertices, indices)
    }

    /// A crag (render-only, illustrative; `outcropMesh`): each of its beds a layer, shale weathered
    /// back under the harder beds. Since emmettl/bombcad-work#147 it is a mass, not a wall: its
    /// line bows out down the slope and wanders a little, so its ends turn back into the hill and
    /// show their sides, and its beds run out at its ends nearly together, so the ends sink into
    /// the slope as a whole (a straight line whose beds ran out a bed at a time, seen from along
    /// the flank, read as plates on edge).
    static func crag(_ crag: QuarryFlank.Crag, flank: QuarryFlank, seed: UInt64) -> (
        vertices: [Vertex], indices: [UInt32]
    ) {
        var r = QuarryRandom(seed: seed &* 0x2545_F491 &+ 41_141)
        // Each bed's levels found from the one above, down from the top.
        var levels: [Int: Float] = [:]
        var near = simd_dot(crag.centre, beddingNormal)
        for bed in crag.beds.reversed() {
            if levels[bed + 1] == nil { levels[bed + 1] = QuarryFlank.bedLevel(Float(bed + 1), near: near) }
            levels[bed] = QuarryFlank.bedLevel(Float(bed), near: levels[bed + 1]!)
            near = levels[bed]!
        }
        var layers: [OutcropLayer] = []
        for bed in crag.beds {
            let (top, bottom) = (levels[bed + 1]!, levels[bed]!)
            let kind = QuarryRock.kind(bed: bed)
            let soft: Float = kind == .shale ? 1 : kind == .sandstone ? 0.35 : 0
            // A thick hard bed parts in two.
            if top - bottom > 2.2, soft < 0.5 {
                let middle = bottom + (top - bottom) * r.float(0.4, 0.6)
                layers += [
                    OutcropLayer(top: middle, bottom: bottom, soft: soft),
                    OutcropLayer(top: top, bottom: middle, soft: soft),
                ]
            } else {
                layers.append(OutcropLayer(top: top, bottom: bottom, soft: soft))
            }
        }
        layers = Array(layers.suffix(7))
        let down = crag.downhill
        let side = SIMD2(-down.y, down.x)
        let centre = SIMD2(crag.centre.x, crag.centre.y)
        let phase = r.float(0, 100)
        // Its line bowed out down the slope by `bow` at its middle, wandering a little.
        let width = crag.width
        let bow = width * r.float(0.1, 0.2)
        var points: [SIMD2<Float>] = []
        var downs: [SIMD2<Float>] = []
        for k in 0...8 {
            let t = Float(k) / 8 * 2 - 1
            let wander = 0.9 * QuarryNoise.fbm(SIMD3(t * 2.2, phase, 7.7), octaves: 2)
            points.append(centre + side * (t * width / 2) + down * (wander - bow * t * t))
            // Square to the bow, but turned no more than about 20 degrees from down the slope:
            // turned further its ends' profiles ran across the slope, found no foot, and stood out
            // as long slabs.
            downs.append(simd_normalize(down + side * max(-0.36, min(0.36, 4 * bow * t / width))))
        }
        return outcropMesh(points: points, downs: downs, layers: layers, crag: true, flank: flank, r: &r)
    }

    /// An outcrop of `layers` (bottom to top) swept along `points` (render-only, illustrative): the
    /// top layer's top is its bed's following the dip, from where it meets the ground to the top
    /// layer's front; down from there each layer's front in turn, with a parting drawn back between
    /// each and the next, to its foot, buried in the ground. Each layer is broken by joints into
    /// blocks of its own (most joints cut every layer, some one only): each block's front stands
    /// out or back, square or skew to the run, its corners broken back and its top dropped where a
    /// lamina has gone; now and then a block has fallen away and left a bay. A layer weathers back
    /// along stretches of its own, so tiers come and go and the layers above overhang it, soft ones
    /// most; its front leans back or is undercut. The whole sinks under the ground at its ends (a
    /// crag draws back into the slope there) and, for a ledge's outcrop, in gaps along it.
    static func outcropMesh(
        points inPoints: [SIMD2<Float>], downs inDowns: [SIMD2<Float>], layers: [OutcropLayer], crag: Bool,
        flank: QuarryFlank, form: OutcropForm = OutcropForm(), r: inout QuarryRandom
    ) -> (vertices: [Vertex], indices: [UInt32]) {
        let normal = beddingNormal
        let random = r.float()
        let m = layers.count
        guard m > 0, !inPoints.isEmpty else { return ([], []) }
        // How far the beds are drawn shifted along the bedding's normal where the sweep is
        // (`OutcropForm`), set for each sample along it.
        var shift: Float = 0
        func level(_ s: Float, _ q: SIMD2<Float>) -> Float {
            (s + shift - normal.x * q.x - normal.y * q.y) / normal.z
        }
        func ground(_ q: SIMD2<Float>) -> Float { flank.groundHeight(q.x, q.y) }
        var (points, downs) = (inPoints, inDowns)
        if !crag {
            let strike = SIMD2(-downs[0].y, downs[0].x)
            let n = points.count
            let firstWay =
                n > 1 && simd_distance(points[0], points[1]) > 1e-3
                ? simd_normalize(points[0] - points[1]) : -strike
            let lastWay =
                n > 1 && simd_distance(points[n - 1], points[n - 2]) > 1e-3
                ? simd_normalize(points[n - 1] - points[n - 2]) : strike
            // Run on a little past the end ledges and sunk there over a short way, so an end is a
            // broken block, not a long wedge thinning into the ground (thin slivers until
            // emmettl/bombcad-work#147).
            let (on, off) = (form.runOn.lowerBound, form.runOn.upperBound)
            points.insert(points[0] + firstWay * r.float(on, off), at: 0)
            points.append(points[points.count - 1] + lastWay * r.float(on, off))
            downs.insert(downs[0], at: 0)
            downs.append(downs[downs.count - 1])
        }
        var lengths: [Float] = [0]
        for k in 1..<points.count { lengths.append(lengths[k - 1] + simd_distance(points[k], points[k - 1])) }
        let total = lengths[lengths.count - 1]
        guard total > 1 else { return ([], []) }
        func shiftAt(_ u: Float) -> Float { form.shift + form.skew * (u - total / 2) }
        // Joints: most cut every layer, some one only.
        struct Joint {
            var at: Float
            var open: Float
        }
        struct Block {
            /// Its front's stand-out at its two ends and at a kink between (`kinkAt` of the way).
            var outA: Float
            var outB: Float
            var outKink: Float
            var kinkAt: Float
            var drop: Float
            var chamfer: Float
            /// How far its front bulges out (+) or is hollowed (-) half way down, as a share of
            /// the layer's thickness.
            var bulge: Float
            /// The parting over it closed: it and the layer above stand as one.
            var merged: Bool
            /// How many layers from the top are gone over it (the top layer's blocks only).
            var strip: Int
        }
        var shared: [Float] = []
        var next = r.float(1, crag ? 3.5 : 2.8)
        while next < total - 0.8 {
            shared.append(next)
            next += (crag ? r.float(1.6, 4.5) : r.float(1.4, 3.6)) * form.joints
        }
        var joints: [[Joint]] = []
        var blocks: [[Block]] = []
        for _ in 0..<m {
            var own: [Joint] = []
            for at in shared where r.float() < 0.9 { own.append(Joint(at: at, open: r.float(0.3, 1))) }
            var extra = r.float(0.8, 3)
            while extra < total - 0.6 {
                if r.float() < 0.15 { own.append(Joint(at: extra, open: r.float(0.2, 0.8))) }
                extra += r.float(0.8, 3)
            }
            own.sort { $0.at < $1.at }
            var kept: [Joint] = []
            for j in own where kept.isEmpty || j.at - kept[kept.count - 1].at > 0.5 { kept.append(j) }
            joints.append(kept)
            let spread: Float = crag ? 0.4 : 0.45
            var row: [Block] = []
            for _ in 0...kept.count {
                let out = r.float(-spread, spread * 0.8)
                var block = Block(
                    outA: out + r.float(-0.3, 0.3) * (crag ? 1.5 : 1),
                    outB: out + r.float(-0.3, 0.3) * (crag ? 1.5 : 1),
                    outKink: out + r.float(-0.35, 0.3),
                    kinkAt: r.float(0.25, 0.75), drop: r.float() < 0.55 ? r.float(0.05, 0.5) : 0,
                    chamfer: crag ? r.float(0.3, 0.9) : r.float(0.1, 0.6), bulge: r.float(-0.3, 0.25),
                    merged: r.float() < (crag ? 0.7 : 0.45),
                    strip: m > 1 && r.float() < 0.35 ? (m > 2 && r.float() < 0.35 ? 2 : 1) : 0)
                if r.float() < (crag ? 0.1 : 0.1) {
                    // Fallen away, leaving a bay.
                    block.outA -= r.float(0.5, 1.2)
                    block.outB = block.outA + r.float(-0.3, 0.3)
                    block.outKink = block.outA - r.float(0, 0.3)
                    block.drop += r.float(0.1, 0.35)
                }
                row.append(block)
            }
            blocks.append(row)
        }
        // A layer gone from over a block only where what is left under it is thick enough to stand
        // as a block: a thin lower layer left bare ran out over the slope as a thin plate or lip
        // (emmettl/bombcad-work#148).
        for b in blocks[m - 1].indices where blocks[m - 1][b].strip > 0 {
            while blocks[m - 1][b].strip > 0,
                layers[m - 1 - blocks[m - 1][b].strip].top - layers[0].bottom < 0.5
            {
                blocks[m - 1][b].strip -= 1
            }
        }
        // No block of the top layers left standing alone at an end, nor a short one within, where
        // those over its neighbours are gone: alone it stood as a slab on the layer below
        // (emmettl/bombcad-work#148).
        do {
            let top = joints[m - 1]
            let row = blocks[m - 1]
            for b in row.indices where row[b].strip == 0 {
                let start = b == 0 ? 0 : top[b - 1].at
                let end = b == top.count ? total : top[b].at
                let before = b > 0 ? row[b - 1].strip : 0
                let after = b < row.count - 1 ? row[b + 1].strip : 0
                // At either end, any block standing alone so; within, a short one.
                let atEnd = b == 0 || b == row.count - 1
                if end - start < 2.5 || atEnd, before > 0 || b == 0, after > 0 || b == row.count - 1,
                    max(before, after) > 0
                {
                    blocks[m - 1][b].strip = min(before > 0 ? before : after, after > 0 ? after : before)
                }
            }
        }
        // Where the top layers are gone over a block, those beside it curve back into the hill over
        // `stripRound` past the joint rather than ending at it in a square-cut slab.
        let stripRound: Float = 1.2
        func standingDistance(_ u: Float, _ layer: Int) -> Float {
            let top = joints[m - 1]
            let row = blocks[m - 1]
            let b = top.firstIndex { $0.at > u } ?? top.count
            var best = Float.infinity
            for k in max(0, b - 2)...min(row.count - 1, b + 2) where layer < m - row[k].strip {
                let start = k == 0 ? 0 : top[k - 1].at
                let end = k == top.count ? total : top[k].at
                best = min(best, max(0, start - u, u - end))
            }
            return best
        }
        // Each layer's own weathering.
        struct Look {
            var batter: Float
            var recess: Float
            var goneDepth: Float
            var goneAt: Float
            var nose: Float
            var lean: Float
            var notch: Float
            var overhang: Float
            var phase: Float
        }
        var looks: [Look] = []
        for layer in layers {
            let soft = layer.soft
            looks.append(
                Look(
                    batter: crag ? r.float(0, 0.35) : r.float(0, 0.12),
                    recess: soft * (crag ? r.float(0.6, 1.4) : r.float(0.2, 0.5)),
                    goneDepth: (crag ? r.float(0.2, 0.7) : r.float(0.2, 0.6)) * (0.6 + soft),
                    goneAt: r.float(0, 0.25) - 0.15 * soft,
                    nose: crag ? r.float(0.15, 0.45) : r.float(0.02, 0.1),
                    lean: soft > 0.3 ? r.float(0.1, 0.45) : r.float(-0.12, 0.22),
                    notch: crag && soft < 0.5 ? r.float(0.02, 0.12) : r.float(0.05, 0.3),
                    overhang: soft > 0.3 ? 0.1 : crag ? r.float(0.12, 0.45) : r.float(0.15, 0.45),
                    phase: r.float(0, 100)))
        }
        let phase = r.float(0, 100)
        // How far in from each end each layer of a crag starts: further the higher it is, in steps
        // of half a metre to a metre and a quarter (emmettl/bombcad-work#149: a twentieth of its
        // width at most until then, so its beds ran out nearly together and its end was a square
        // block seen from along the flank).
        var extents: [(Float, Float)] = []
        var steps: (Float, Float) = (total * 0.01, total * 0.01)
        for layer in 0..<m {
            if crag, layer > 0 {
                steps.0 += r.float(0.5, 1.25)
                steps.1 += r.float(0.5, 1.25)
            }
            extents.append(crag ? steps : (0, 0))
        }
        var samples = Array(stride(from: Float(0), through: total, by: crag ? 0.6 : 0.5))
        if samples[samples.count - 1] < total - 0.15 { samples.append(total) }
        for layerJoints in joints {
            for j in layerJoints {
                samples += [j.at - 0.12, j.at - 0.03, j.at + 0.03, j.at + 0.12]
                // A crag's blocks' rounded corners (emmettl/bombcad-work#151).
                if crag { samples += [j.at - 0.6, j.at - 0.35, j.at + 0.35, j.at + 0.6] }
            }
        }
        for (b, j) in joints[m - 1].enumerated()
        where blocks[m - 1][b].strip != blocks[m - 1][b + 1].strip {
            for t: Float in [0.15, 0.35, 0.6, 0.85, 1.1, 1.3] { samples += [j.at - t, j.at + t] }
        }
        // A crag's layer runs out over `runOut`, its front curving back into the hill (1.6 m until
        // emmettl/bombcad-work#149).
        let runOut: Float = 2.2
        for (a, b) in extents where crag {
            for t: Float in [0, 0.12, 0.3, 0.55, 0.8, 1] {
                samples += [a + runOut * t, total - b - runOut * t]
            }
        }
        if !crag {
            for t: Float in [0.04, 0.12, 0.2, 0.28] where Self.outcropEnd + 0.05 < total / 2 {
                samples += [Self.outcropEnd * t / 0.28, total - Self.outcropEnd * t / 0.28]
            }
        }
        samples.sort()
        var along: [Float] = []
        for u in samples where u >= 0 && u <= total && (along.isEmpty || u - along[along.count - 1] > 0.04) {
            along.append(u)
        }
        let rows = along.count
        guard rows >= 2 else { return ([], []) }
        let topLevel = layers[m - 1].top
        let bottomLevel = layers[0].bottom
        // Where the top meets the ground along the slope at each sample, and how far below that the
        // foot's level does, eased along the run.
        var frames: [(p: SIMD2<Float>, d: SIMD2<Float>)] = []
        var meets: [Float] = []
        var found: [Bool] = []
        var segment = 0
        let span: Float = crag ? 6 : 2.5
        let longest: Float = crag ? 16 : max(4.5, 2.4 * (topLevel - bottomLevel) / normal.z)
        func excess(_ k: Int, _ s: Float, _ at: Float) -> Float {
            let q = frames[k].p + frames[k].d * s
            return ground(q) - level(at, q)
        }
        for (k, u) in along.enumerated() {
            shift = shiftAt(u)
            while segment < points.count - 2 && lengths[segment + 1] < u { segment += 1 }
            let t = max(
                0, min(1, (u - lengths[segment]) / max(lengths[segment + 1] - lengths[segment], 1e-4)))
            let p = points[segment] + (points[segment + 1] - points[segment]) * t
            var d = downs[segment] + (downs[segment + 1] - downs[segment]) * t
            d = simd_length(d) > 1e-3 ? simd_normalize(d) : downs[segment]
            frames.append((p, d))
            var s0: Float = 0
            let bracketed = excess(k, -span, topLevel) > 0 && excess(k, span, topLevel) < 0
            if bracketed {
                var (a, b) = (-span, span)
                for _ in 0..<20 {
                    let mid = (a + b) / 2
                    if excess(k, mid, topLevel) > 0 { a = mid } else { b = mid }
                }
                s0 = (a + b) / 2
            }
            meets.append(s0)
            found.append(bracketed)
        }
        // Where the top's line is not found within reach of a row, it is taken along the run from the
        // rows on either side where it is (emmettl/bombcad-work#151): taken as the sweep's own line,
        // a row there jumped up to `span` down or up the slope from its neighbours, and the piece's
        // outline in plan had a tail or a hook.
        if found.contains(true) {
            for k in along.indices where !found[k] {
                let before = (0..<k).last { found[$0] }
                let after = ((k + 1)..<along.count).first { found[$0] }
                switch (before, after) {
                case (let a?, let b?):
                    meets[k] =
                        meets[a] + (meets[b] - meets[a]) * (along[k] - along[a]) / (along[b] - along[a])
                case (let a?, nil): meets[k] = meets[a]
                case (nil, let b?): meets[k] = meets[b]
                default: break
                }
            }
        }
        var feet: [Float] = []
        for (k, u) in along.enumerated() {
            shift = shiftAt(u)
            let s0 = meets[k]
            var foot: Float = 0.5
            if excess(k, s0, bottomLevel) > 0 {
                foot = longest
                var s: Float = 0.25
                while s < longest {
                    if excess(k, s0 + s, bottomLevel) < 0 {
                        foot = s
                        break
                    }
                    s += 0.25
                }
            }
            feet.append(foot)
        }
        func eased(_ v: [Float], _ width: Float) -> [Float] {
            along.indices.map { k in
                var (sum, weight): (Float, Float) = (0, 0)
                for q in along.indices where abs(along[q] - along[k]) <= width {
                    let w = 1 - abs(along[q] - along[k]) / (width * 1.01)
                    sum += v[q] * w
                    weight += w
                }
                return sum / weight
            }
        }
        meets = eased(meets, crag ? 2.5 : 1.2)
        feet = eased(feet, crag ? 2.5 : 1.2)
        // Where a crag shows (emmettl/bombcad-work#149): as its line bows back into the hill the
        // slope climbs over its beds, so its visible ends lie well inside the sweep's. Its ends are
        // tapered, stepped and settled from where its top stands at least half a metre out of the
        // slope; measured from the sweep's own ends they were under the ground, and what showed
        // was the beds cut off by the slope in straight sweeps, the blocks square-ended.
        var (shownFrom, shownTo) = (Float(0), total)
        if crag {
            let shown = along.indices.filter { k in
                let (p, d) = frames[k]
                return stride(from: meets[k], through: meets[k] + feet[k] + 0.5, by: 0.5).contains { s in
                    level(topLevel, p + d * s) - ground(p + d * s) > 0.5
                }
            }
            if let a = shown.first, let b = shown.last, along[b] - along[a] > 8 {
                (shownFrom, shownTo) = (along[a], along[b])
            }
        }
        // The profile's layout: buried behind, the top layer's top, each layer's front (with the
        // parting above it for all but the top one), the foot.
        var parts: [OutcropPart] = [.buried, .buried, .top, .top, .top]
        var layerOf = [0, 0, 0, 0, 0]
        for k in 0..<m {
            if k > 0 {
                parts += [.parting, .top]
                layerOf += [k, k]
            }
            parts += crag ? [.face, .face, .face, .face] : [.face, .face, .face]
            layerOf += crag ? [k, k, k, k] : [k, k, k]
        }
        parts += [.foot, .foot]
        layerOf += [m - 1, m - 1]
        let columns = parts.count
        var grid: [SIMD3<Float>] = []
        grid.reserveCapacity(rows * columns)
        var opened: [Float] = []
        opened.reserveCapacity(rows * columns)
        // A ledge's outcrop ends over a short way, so its end is a broken block's steep end
        // (emmettl/bombcad-work#150): sunk over 0.8 m, its top ran down to a point, and from above
        // or along the slope its end read as a thin slab or blade.
        let endLength: Float = crag ? 6 : Self.outcropEnd
        var built:
            [(profile: [SIMD2<Float>], stand: Float, opens: [Float], c: SIMD2<Float>, d: SIMD2<Float>)] = []
        built.reserveCapacity(rows)
        for (k, u) in along.enumerated() {
            shift = shiftAt(u)
            let (p, d) = frames[k]
            let c = p + d * meets[k]
            let w = SIMD3(c.x, c.y, phase)
            func at(_ s: Float) -> SIMD2<Float> { c + d * s }
            let ends = min(
                smoothstep(shownFrom, shownFrom + endLength, u), smoothstep(shownTo, shownTo - endLength, u))
            // Gaps open and close over a short way (emmettl/bombcad-work#151: over -0.34 to -0.12 of the
            // noise, a metre or more, so each side of a gap sank slowly and narrowed to a point in plan).
            let gaps = crag ? 1 : smoothstep(-0.25, -0.21, QuarryNoise.fbm(w / 5, octaves: 2))
            let stand = ends * gaps
            var base = max(
                0.5, feet[k] * (0.88 + 0.45 * QuarryNoise.fbm(w / 4 + 3, octaves: 2)) + (crag ? 0.25 : 0.1))
            base *= crag ? 0.2 + 0.8 * ends : 0.55 + 0.45 * stand
            var fronts = [Float](repeating: 0, count: m)
            var drops = [Float](repeating: 0, count: m)
            var opens = [Float](repeating: 0, count: m)
            var bulges = [Float](repeating: 0, count: m)
            var closed = [Bool](repeating: false, count: m)
            var batter: Float = 0
            for layer in 0..<m {
                let look = looks[layer]
                let js = joints[layer]
                let b = js.firstIndex { $0.at > u } ?? js.count
                let start = b == 0 ? 0 : js[b - 1].at
                let end = b == js.count ? total : js[b].at
                let block = blocks[layer][b]
                let t = (u - start) / max(end - start, 1e-3)
                var out =
                    t < block.kinkAt
                    ? block.outA + (block.outKink - block.outA) * t / block.kinkAt
                    : block.outKink + (block.outB - block.outKink) * (t - block.kinkAt) / (1 - block.kinkAt)
                // Its corners broken back; on a crag, weathered round (emmettl/bombcad-work#151: cut back
                // straight, a crag's blocks read as squarish masonry).
                let corner = max(0, 1 - min(u - start, end - u) / block.chamfer)
                let rounded = crag ? block.chamfer * (1 - (max(0, 1 - corner * corner)).squareRoot()) : 0
                out -= crag ? rounded : corner * block.chamfer * 0.9
                let lw = SIMD3(u / (crag ? 6 : 4.5), Float(layer) * 3.7, look.phase)
                let gone =
                    smoothstep(look.goneAt - 0.06, look.goneAt + 0.06, QuarryNoise.fbm(lw, octaves: 2))
                    * look.goneDepth
                let wobble =
                    0.1 * QuarryNoise.fbm(SIMD3(u / 1.6, Float(layer) * 5.1, look.phase + 3), octaves: 2)
                var open: Float = 0
                for j in js { open = max(open, j.open * (1 - smoothstep(0.03, 0.12, abs(u - j.at)))) }
                // Where the outcrop sinks at its ends and gaps, a layer neither overhangs the one
                // below nor is weathered or battered back under the one above, so the layers stand
                // flush and sink as one block: with the lower layers drawn back into the slope, the
                // top layer was left standing out of it alone, a thin plate or lip (until
                // emmettl/bombcad-work#148).
                var f = base - batter - (look.recess + gone) * stand + out + wobble
                if layer > 0 { f = min(f, fronts[layer - 1] + look.overhang * stand * stand) }
                f -= open * 0.3
                fronts[layer] = f
                drops[layer] =
                    block.drop + (crag ? rounded * 0.7 : corner * block.chamfer * 0.35) + open * 0.12
                // A crag's block tops uneven (emmettl/bombcad-work#151): each tipped a little its own way
                // along the run, and hummocky, rather than all flat at the bed's level.
                if crag {
                    let thick = layers[layer].top - layers[layer].bottom
                    let lean = QuarryNoise.hash(Int32(b), Int32(layer), Int32(look.phase * 100))
                    let hummock = max(
                        0, QuarryNoise.fbm(SIMD3(u / 1.7, Float(layer) * 4.1, look.phase + 23), octaves: 2))
                    drops[layer] += thick * (0.1 * (1 + lean * (2 * t - 1)) + 0.35 * hummock)
                }
                opens[layer] = open
                bulges[layer] = block.bulge
                closed[layer] = block.merged && layer < m - 1
                batter += look.batter * stand
            }
            // Over some blocks of the top layer, it and maybe the one below are gone, so the
            // outcrop's top steps down a layer there; elsewhere the top layer stands.
            let topJoints = joints[m - 1]
            let strip = blocks[m - 1][topJoints.firstIndex { $0.at > u } ?? topJoints.count].strip
            fronts[m - 1] = max(fronts[m - 1], 0.2)
            // Where a parting has closed, the layer under it stands with the one above as one.
            for layer in stride(from: m - 2, through: 0, by: -1) where closed[layer] {
                fronts[layer] = fronts[layer + 1]
                drops[layer] = 0
            }
            var roundingDown = false
            for layer in max(0, m - strip)..<m where strip > 0 {
                let t = 1 - standingDistance(u, layer) / stripRound
                let round = t <= 0 ? 0 : sqrt(1 - (1 - t) * (1 - t))
                fronts[layer] = -1.5 + (fronts[layer] + 1.5) * round
                // On a crag its top rounds down most of the way too (emmettl/bombcad-work#149).
                drops[layer] +=
                    (1 - round) * (crag ? max(0.3, 0.85 * (layers[layer].top - layers[layer].bottom)) : 0.3)
                if crag, round < 1 { roundingDown = true }
            }
            // A crag's upper beds run out before its lower ones, so its ends step down; each bed's
            // front curves back into the hill over a metre and a half as it runs out, its top
            // rounding down, rather than ending in a square-cut slab (until
            // emmettl/bombcad-work#148).
            for layer in 0..<m where crag {
                let inside = min(u - shownFrom - extents[layer].0, shownTo - extents[layer].1 - u) / runOut
                guard inside < 1 else { continue }
                let t = max(0, inside)
                let round = t <= 0 ? 0 : sqrt(1 - (1 - t) * (1 - t))
                fronts[layer] = -1.5 + (fronts[layer] + 1.5) * round
                // Its top rounds down most of the way to its foot as it runs out
                // (emmettl/bombcad-work#149: 0.35 m until then, so each bed's end stood as a
                // square-cut face its whole thickness high).
                drops[layer] += (1 - round) * max(0.35, 0.85 * (layers[layer].top - layers[layer].bottom))
            }
            // How far a layer's top may be lowered at its front: most of its thickness where a crag's
            // bed runs out, rounding down into the slope (emmettl/bombcad-work#149).
            var endDrop: Float = 0.45
            if roundingDown
                || crag
                    && min(u - shownFrom, shownTo - u) < (extents.map { max($0.0, $0.1) }.max() ?? 0) + runOut
            {
                endDrop = 0.85
            }
            // A lamina come away from the top's front part.
            let lamina = 0.2 * smoothstep(0.05, 0.3, QuarryNoise.fbm(w / 3.1 + 5, octaves: 2))
            var profile: [SIMD2<Float>] = []
            profile.reserveCapacity(columns)
            let topFront = fronts[m - 1] - looks[m - 1].nose
            profile.append(SIMD2(-1.2, min(level(topLevel, at(-1.2)), ground(at(-1.2))) - 0.4))
            profile.append(SIMD2(-0.35, min(level(topLevel, at(-0.35)) - 0.06, ground(at(-0.35)) - 0.12)))
            for (share, worn) in [(Float(0.35), Float(0.2)), (0.7, 0.6), (1, 1)] {
                let s = share * topFront
                let thick = level(topLevel, at(s)) - level(layers[m - 1].bottom, at(s))
                profile.append(
                    SIMD2(
                        s,
                        level(topLevel, at(s)) - min(endDrop * thick, (lamina + drops[m - 1]) * worn) - 0.03)
                )
            }
            // The partings between layers are not quite planes: each wanders a little up and down
            // along the run, so the layers thicken and thin.
            var wander = [Float](repeating: 0, count: m + 1)
            for layer in 1..<max(m, 1) {
                let thin = min(
                    layers[layer].top - layers[layer].bottom, layers[layer - 1].top - layers[layer - 1].bottom
                )
                wander[layer] =
                    0.3 * thin * QuarryNoise.fbm(SIMD3(u / 2.2, Float(layer) * 7.3, phase + 11), octaves: 2)
                // A crag's beds pinch and swell more, over longer stretches too (emmettl/bombcad-work#151).
                if crag {
                    wander[layer] +=
                        0.4 * thin * QuarryNoise.fbm(SIMD3(u / 7, Float(layer) * 2.9, phase + 31), octaves: 2)
                }
            }
            func topOf(_ layer: Int, _ q: SIMD2<Float>) -> Float {
                level(layers[layer].top, q) + wander[layer + 1]
            }
            func bottomOf(_ layer: Int, _ q: SIMD2<Float>) -> Float {
                level(layers[layer].bottom, q) + wander[layer]
            }
            for layer in stride(from: m - 1, through: 0, by: -1) {
                let (f, look) = (fronts[layer], looks[layer])
                let thick = max(0.1, topOf(layer, at(f)) - bottomOf(layer, at(f)))
                let lowered = min(endDrop * thick, layer == m - 1 ? lamina + drops[layer] : drops[layer])
                let nose = closed[layer] ? 0 : min(look.nose, (crag ? 0.45 : 0.3) * thick)
                if layer < m - 1 {
                    let back = min(fronts[layer + 1], f) - (closed[layer] ? 0 : look.notch)
                    profile.append(SIMD2(back, topOf(layer, at(back)) - 0.02))
                    profile.append(SIMD2(f - nose, topOf(layer, at(f - nose)) - lowered))
                }
                let upper = topOf(layer, at(f)) - lowered - nose
                // A crag's arris weathered round, a quarter circle of its nose (emmettl/bombcad-work#151).
                if crag { profile.append(SIMD2(f - 0.29 * nose, upper + 0.71 * nose)) }
                profile.append(SIMD2(f, upper))
                // Over a closed parting below, the face runs on down without leaning.
                let lean = layer > 0 && closed[layer - 1] ? 0 : look.lean
                let low = f - lean * thick
                let lower = bottomOf(layer, at(low)) + 0.04
                profile.append(
                    SIMD2(f - lean * thick * 0.5 + bulges[layer] * thick * 0.6, (upper + lower) / 2))
                profile.append(SIMD2(low, lower))
            }
            let foot = fronts[0]
            profile.append(
                SIMD2(foot + 0.12, min(ground(at(foot + 0.12)) + 0.05, level(bottomLevel, at(foot)) - 0.15)))
            profile.append(SIMD2(foot + 0.65, ground(at(foot + 0.65)) - 0.45))
            // Tipped forward about where its top meets the ground: its front and foot lower, its
            // buried back a little higher.
            if form.tilt > 0 {
                let pivot = level(topLevel, at(0))
                let (cosine, sine) = (cos(form.tilt), sin(form.tilt))
                profile = profile.map { q in
                    let up = q.y - pivot
                    return SIMD2(q.x * cosine + up * sine, pivot - q.x * sine + up * cosine)
                }
            }
            // Nothing of it stands above the ground uphill of where its top meets it: a layer gone
            // from over a block, or drawn back past that line, lies under the soil there.
            for (column, q) in profile.enumerated() where q.x < 0 && parts[column] != .buried {
                profile[column].y = min(q.y, ground(at(q.x)) - 0.08)
            }
            built.append((profile, stand, opens, c, d))
        }
        // Each row sunk where the outcrop sinks at its ends and gaps (`stand` under 1): lowered whole,
        // or sunk out of sight rather than left as a sliver a few centimetres proud of the slope,
        // which read as a thin lip at a run's end (emmettl/bombcad-work#148).
        var sinks = [Float](repeating: 0, count: rows)
        for (k, row) in built.enumerated() {
            func at(_ s: Float) -> SIMD2<Float> { row.c + row.d * s }
            var rise: Float = 0.15
            for q in row.profile { rise = max(rise, q.y - ground(at(q.x))) }
            sinks[k] = (1 - row.stand) * (rise + 0.45)
            if row.stand < 0.999, rise - sinks[k] < 0.3 { sinks[k] = rise + 0.45 }
        }
        // A minimum thickness (emmettl/bombcad-work#150): where what a row shows above the slope, as
        // sunk, is on average less thick than `slabThickness` (or a quarter of how far down the slope
        // it shows, if that is less), it is tipped back about where its top met the ground, its
        // front raised, by about as much as that takes and at most `slabTilt`, eased along the run;
        // its foot keeps to the ground and its back stays buried. A bed lying nearly along the slope,
        // or a lower layer left where those over it are gone, stood out of the slope as a thin slab
        // or lip a few decimetres high, tapering to an edge.
        var tilts = [Float](repeating: 0, count: rows)
        for (k, row) in built.enumerated() where !crag {
            func at(_ s: Float) -> SIMD2<Float> { row.c + row.d * s }
            let above = row.profile.map { $0.y - sinks[k] - ground(at($0.x)) }
            var (low, high, area) = (Float.infinity, -Float.infinity, Float(0))
            for i in 1..<above.count where above[i - 1] > 0 || above[i] > 0 {
                let (x0, x1) = (row.profile[i - 1].x, row.profile[i].x)
                let (a0, a1) = (above[i - 1], above[i])
                let cross = x0 + (x1 - x0) * a0 / (a0 - a1)
                let (from, to) = (a0 > 0 ? x0 : cross, a1 > 0 ? x1 : cross)
                (low, high) = (min(low, from, to), max(high, from, to))
                // Its area above the ground, walked along the profile (a shoelace).
                area += from * max(a1, 0) - to * max(a0, 0)
            }
            let width = high - low
            guard width > 0.3 else { continue }
            let mean = abs(area) / 2 / width
            let wanted = min(Self.slabThickness, 0.25 * width)
            tilts[k] = max(0, min(Self.slabTilt, 2 * (wanted - mean) / max(high, 0.5)))
        }
        tilts = eased(tilts, 1.2)
        var tilted: [[SIMD2<Float>]] = []
        for (k, row) in built.enumerated() {
            func at(_ s: Float) -> SIMD2<Float> { row.c + row.d * s }
            let sink = sinks[k]
            var profile = row.profile
            if tilts[k] > 1e-3 {
                let pivot = ground(at(0)) - sink
                let (cosine, sine) = (cos(tilts[k]), sin(tilts[k]))
                for (column, q) in row.profile.enumerated() where parts[column] != .foot {
                    let up = q.y - sink - pivot
                    let x = q.x * cosine - up * sine
                    var y = pivot + q.x * sine + up * cosine + sink
                    if x < 0 { y = min(y, ground(at(x)) + sink - (parts[column] == .buried ? 0.4 : 0.08)) }
                    profile[column] = SIMD2(x, y)
                }
            }
            tilted.append(profile)
        }
        // No fins (emmettl/bombcad-work#151): a ledge's outcrop row of which, as sunk, only its front
        // stands out of the slope, narrower down the slope than about its own height or half a
        // metre, or lower than 0.15 m, is sunk out of sight, and so is one left standing alone
        // between sunk rows. Where a row's top went under the slope and its front stayed proud (as
        // a piece sinks at its ends, or where the slope falls away in front), it stood as a thin
        // wall, and in plan the piece ran out in a point or a tail.
        if !crag {
            var hidden = [Bool](repeating: false, count: rows)
            var spans = [Float](repeating: 0, count: rows)
            var talls = [Float](repeating: 0, count: rows)
            for (k, row) in built.enumerated() {
                func at(_ s: Float) -> SIMD2<Float> { row.c + row.d * s }
                let above = tilted[k].map { $0.y - sinks[k] - ground(at($0.x)) }
                var (low, high, tallest) = (Float.infinity, -Float.infinity, Float(0))
                for i in 1..<above.count where above[i - 1] > 0 || above[i] > 0 {
                    let (x0, x1) = (tilted[k][i - 1].x, tilted[k][i].x)
                    let (a0, a1) = (above[i - 1], above[i])
                    let cross = x0 + (x1 - x0) * a0 / (a0 - a1)
                    let (from, to) = (a0 > 0 ? x0 : cross, a1 > 0 ? x1 : cross)
                    (low, high) = (min(low, from, to), max(high, from, to))
                    tallest = max(tallest, a0, a1)
                }
                spans[k] = high - low
                talls[k] = tallest
                hidden[k] = tallest < 0.15 || high - low < max(0.5, 0.8 * tallest)
            }
            // Each stretch of rows that shows ends where it is still broad: rows at its ends that show
            // less than 0.45 of its usual breadth down the slope, within the outer third of it, are
            // sunk too, so it ends in a block's steep end, not a narrow lip or tail.
            var k = 0
            while k < rows {
                guard !hidden[k] else {
                    k += 1
                    continue
                }
                var end = k
                while end + 1 < rows, !hidden[end + 1] { end += 1 }
                let stretch = Array(k...end)
                // A stretch shorter along the run than about half its height, or 0.9 m, stood as a
                // thin upright plate: sunk whole.
                let tallest = stretch.map { talls[$0] }.max() ?? 0
                if along[end] - along[k] < max(0.9, 0.5 * tallest) {
                    for q in stretch { hidden[q] = true }
                    k = end + 1
                    continue
                }
                let usual = stretch.map { spans[$0] }.sorted()[stretch.count / 2]
                let third = (along[end] - along[k]) / 3
                for q in stretch where along[q] - along[k] <= third {
                    guard spans[q] < 0.45 * usual else { break }
                    hidden[q] = true
                }
                for q in stretch.reversed() where along[end] - along[q] <= third {
                    guard spans[q] < 0.45 * usual else { break }
                    hidden[q] = true
                }
                k = end + 1
            }
            for k in 0..<rows
            where !hidden[k] && (k == 0 || hidden[k - 1]) && (k == rows - 1 || hidden[k + 1]) {
                hidden[k] = true
            }
            for (k, row) in built.enumerated() where hidden[k] {
                func at(_ s: Float) -> SIMD2<Float> { row.c + row.d * s }
                var rise: Float = 0.15
                for q in tilted[k] { rise = max(rise, q.y - ground(at(q.x))) }
                sinks[k] = rise + 0.45
            }
        }
        for (k, row) in built.enumerated() {
            let (opens, c, d) = (row.opens, row.c, row.d)
            let (u, stand, sink) = (along[k], row.stand, sinks[k])
            func at(_ s: Float) -> SIMD2<Float> { c + d * s }
            let profile = tilted[k]
            // A crag's ends settle into the slope rather than sinking straight down
            // (emmettl/bombcad-work#149): what stands above the ground is lowered toward it, so its
            // beds bend with the slope's own curve as they go under, each block of its foot by its
            // own amount, so the end steps down in broken, partly buried blocks. Sunk straight
            // down, its layers met the slope in straight sweeps.
            var keep: Float = 1
            if crag {
                let foot = joints[0]
                let block = blocks[0][foot.firstIndex { $0.at > u } ?? foot.count]
                keep = pow(stand, 0.6 + 4 * (min(block.chamfer, 0.6) - 0.1))
            }
            for (column, q) in profile.enumerated() {
                let xy = at(q.x)
                var z = q.y - sink
                if crag {
                    let below = ground(xy)
                    let above = q.y - below
                    z = above > 0 ? below + above * keep - (1 - keep) * 0.45 : q.y - (1 - keep) * 0.45
                    // Partly buried where the slope meets it (emmettl/bombcad-work#151): within a metre of
                    // the ground it is sunk by up to about 0.75 m in patches a metre or two across, so
                    // the slope's scree laps up over its foot and its beds' ends raggedly, rather than
                    // meeting its layers in straight lines.
                    let low = z - below
                    if low < 1.2 {
                        let patch = QuarryNoise.fbm(SIMD3(xy.x / 1.3, xy.y / 1.3, phase + 51), octaves: 3)
                        z -= max(0, patch + 0.2) * 0.8 * (1 - smoothstep(0.15, 1.2, low))
                    }
                }
                grid.append(SIMD3(xy.x, xy.y, z))
                opened.append(opens[m - 1 - layerOf[column]])
            }
        }
        // Which way is out, from the sweep's own handedness: each row's profile runs from its buried
        // back over the top and down the fronts to its foot, so the rock lies on the same side of
        // it all along, and the top faces up where the run's way along and its way down the slope
        // turn anticlockwise seen from above. Judged from the drawn top (emmettl/bombcad-work#147:
        // by a vote of the rows where the top layer's top shows, else at the middle row), a short
        // piece whose top layer was gone over all of it had no row to vote, and its middle row,
        // folded back under the ground, turned it inside out: dark, hollow shells on the flanks,
        // a fifth of the pieces (emmettl/bombcad-work#150).
        var turn: Float = 0
        for k in 1..<rows {
            let (a, b) = (frames[k - 1], frames[k])
            let way = b.p - a.p
            let down = a.d + b.d
            turn += way.x * down.y - way.y * down.x
        }
        let outward: Float = turn < 0 ? -1 : 1
        func normals(_ g: [SIMD3<Float>]) -> [SIMD3<Float>] {
            var out = [SIMD3<Float>](repeating: .zero, count: g.count)
            for i in 0..<rows {
                for j in 0..<columns {
                    let du = g[min(rows - 1, i + 1) * columns + j] - g[max(0, i - 1) * columns + j]
                    let dv = g[i * columns + min(columns - 1, j + 1)] - g[i * columns + max(0, j - 1)]
                    out[i * columns + j] = simd_cross(du, dv)
                }
            }
            return out.map { simd_length($0) > 1e-8 ? simd_normalize($0) * outward : SIMD3(0, 0, 1) }
        }
        // Broken up: every point moved a little in all three directions by noise, so the edges
        // wander and the faces are uneven planes rather than a sweep's straight courses, and worn
        // a few centimetres along its own normal (a decimetre of smooth wear along the normal made
        // pillows of it until emmettl/bombcad-work#141).
        var shaped = grid
        let first = normals(grid)
        let reach: Float = crag ? 0.38 : 0.2
        for k in 0..<grid.count {
            let p = grid[k] + SIMD3(0, 0, phase)
            let q = p / 1.4
            let move = SIMD3(
                QuarryNoise.fbm(q, octaves: 2), QuarryNoise.fbm(q + 19.1, octaves: 2),
                0.6 * QuarryNoise.fbm(q + 37.7, octaves: 2))
            let wear =
                0.04 * QuarryNoise.fbm(p * 0.9, octaves: 2) + 0.03 * QuarryNoise.fbm(p * 2.8 + 7, octaves: 2)
            // A crag's faces lumpier at a metre too (emmettl/bombcad-work#151): its blocks read as flat
            // slabs of masonry.
            let lumps = crag ? 0.14 * QuarryNoise.fbm(p / 0.9 + 51, octaves: 2) : 0
            shaped[k] = grid[k] + move * reach + first[k] * (wear + lumps)
        }
        let final = normals(shaped)
        var vertices: [Vertex] = []
        vertices.reserveCapacity(shaped.count)
        for (k, p) in shaped.enumerated() {
            let column = k % columns
            vertices.append(
                Vertex(
                    x: p.x, y: p.y, z: p.z, normal: pack(normal: final[k], kind: 1),
                    body: outcropTag(
                        above: p.z - flank.groundHeight(p.x, p.y), random: random, part: parts[column],
                        layer: layerOf[column], joint: opened[k], crag: crag,
                        shift: shiftAt(along[k / columns]))))
        }
        var indices: [UInt32] = []
        indices.reserveCapacity((rows - 1) * (columns - 1) * 6)
        for i in 0..<(rows - 1) {
            for j in 0..<(columns - 1) {
                let a = UInt32(i * columns + j)
                let b = a + UInt32(columns)
                indices += [a, b, a + 1, a + 1, b, b + 1]
            }
        }
        return (vertices, indices)
    }

    /// The ledges of a ridge cut's flanks as render-only outcrops (`outcrop`), one for each run of
    /// them along a bed, and its crags (`crag`), in `ledgeVertices` and `ledgeIndices`. Returns how
    /// many runs were made into outcrops.
    mutating func appendLedges(_ flank: QuarryFlank) -> Int {
        let runs = flank.ledgeRuns()
        let ledges = flank.ledges
        let crags = flank.crags
        var meshes = [(vertices: [Vertex], indices: [UInt32])](
            repeating: ([], []), count: runs.count + crags.count)
        meshes.withUnsafeMutableBufferPointer { out in
            nonisolated(unsafe) let output = out
            DispatchQueue.concurrentPerform(iterations: runs.count + crags.count) { k in
                output[k] =
                    k < runs.count
                    ? Self.outcrop(runs[k].map { ledges[$0] }, flank: flank, seed: UInt64(k))
                    : Self.crag(crags[k - runs.count], flank: flank, seed: UInt64(k - runs.count))
            }
        }
        var made = 0
        for (k, mesh) in meshes.enumerated() where !mesh.vertices.isEmpty {
            let base = UInt32(ledgeVertices.count)
            ledgeVertices.append(contentsOf: mesh.vertices)
            ledgeIndices.append(contentsOf: mesh.indices.map { $0 + base })
            if k < runs.count { made += 1 }
        }
        return made
    }
}

private func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
    let t = max(0, min(1, (x - a) / (b - a)))
    return t * t * (3 - 2 * t)
}
