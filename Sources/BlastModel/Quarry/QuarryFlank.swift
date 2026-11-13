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

    /// One render-only stone of the scree, or one clump of a low shrub: centre and size (m), its
    /// turn as a quaternion (x, y, z, w), and what it is (x: 0 a stone, 1 a shrub; y: a random
    /// value; z: its tint). Layout matches `FlankStone` in `QuarryRender.metal`.
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

    /// The margin of dense rock round the cut (m), before its ragged edge (up to `marginWander`
    /// more).
    public static let margin: Float = 2.5
    public static let marginWander: Float = 5
    /// Ledges crop out on slopes steeper than about this (rise over run), and stand apart along
    /// their bed by about `ledgeSpacing` (m).
    public static let ledgeSlope: Float = 0.3
    public static let ledgeSpacing: Float = 3.2

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
        // metres to a couple of tens along the bed.
        let clusters = QuarryNoise.fbm(SIMD3(x / 34, y / 34, 3.3), octaves: 3) + 0.25 * high
        let runs = QuarryNoise.fbm(SIMD3(x / 7, y / 7, 8.8), octaves: 2)
        let steep = max(0, min(1, (slope - Self.ledgeSlope) / 0.25))
        return max(0, min(1, (clusters - 0.06) / 0.12)) * max(0, min(1, (runs + 0.08) / 0.16)) * steep
    }

    /// The ledges: where a hard bed's top meets the ground going uphill, in the outcrops, one
    /// every `ledgeSpacing` or so along the bed, clear of the dense rock round the cut.
    mutating func findLedges(ridge: QuarryRidge) {
        let normal = QuarryFace.beddingNormal
        var best: [Int64: (Float, Ledge)] = [:]
        for j in 1..<(rows - 1) {
            for i in 1..<(columns - 1) {
                let n = i + j * columns
                guard !paving[n], cutDistance[n] > Self.margin + 1.5 else { continue }
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
                guard !paves(contour.x, contour.y) else { continue }
                let top = Self.bedLevel(Float(bed + 1), near: simd_dot(contour, normal))
                let bottom = Self.bedLevel(Float(bed), near: top)
                let thickness = top - bottom
                guard thickness > 0.7 else { continue }
                let run = max(0.6, min(r.float(1.2, 3.2), 1.2 * thickness / slope))
                let ledge = Ledge(
                    contour: contour, downhill: down, top: top, bottom: bottom, run: run, bed: bed,
                    seed: r.float())
                let key =
                    Int64(floor(contour.x / Self.ledgeSpacing))
                    &+ Int64(floor(contour.y / Self.ledgeSpacing)) &* 100_003 &+ Int64(bed) &* 10_000_019
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
            return !paving[n] && cut[n] < 0.5
        }
        /// A stone of `size` (m) at (x, y), sunk by `sink` of its size.
        func stone(_ x: Float, _ y: Float, _ size: Float, sink: Float) {
            guard clear(x, y) else { return }
            stones.append(
                Stone(
                    posSize: SIMD4(x, y, groundHeight(x, y) + size * (0.3 - sink), size),
                    rotation: turn(normal: normal(x, y), yaw: r.float(0, 6.283), lean: r.float(-0.3, 0.3)),
                    look: SIMD4(0, r.float(), r.float(), 0)))
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
                let width = min(2.6, 0.95 * pow(max(r.float(), 0.02), -0.3))
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
                stone(p.x, p.y, lr.float(0.4, 1.2), sink: 0.2)
            }
        }
        return stones + bushes
    }

    /// How many of `stones()` are stones; the rest are bushes' lobes.
    public static func stoneCount(_ stones: [Stone]) -> Int {
        stones.firstIndex { $0.look.x > 0.5 } ?? stones.count
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
    /// The body bits of an outcrop's vertex, read by `ledgeVertex` in QuarryRender.metal: its height
    /// above the ground (cm, to 10.23 m), its run's random value (6 bits), the point of the
    /// profile it is (0 buried behind, 2-4 the top, 5-6 the nose, 7-12 the front's tiers, 13-14 the
    /// foot) and how open a joint across it is there (4 bits).
    public static func outcropTag(above: Float, random: Float, part: Int, joint: Float = 0) -> UInt32 {
        let height = UInt32(max(0, min(1023, (above * 100).rounded())))
        let value = UInt32(max(0, min(63, (random * 63).rounded())))
        let crack = UInt32(max(0, min(15, (joint * 15).rounded())))
        return height | (value << 10) | (UInt32(part) << 16) | (crack << 20)
    }

    /// The points of an outcrop's profile, from buried behind it over its top and down its front
    /// to buried at its foot.
    static let outcropProfile = 15

    /// One run of ledges as an outcrop of its bed (render-only, illustrative): a weathered stratum
    /// swept along the bed, its top the bed's top following the dip, worn uneven and stepped where
    /// a lamina has come away; its front rounded at the nose, in two or three tiers that stand out
    /// or are undercut, with a notch at each parting; broken across by joints; dipping under the
    /// ground at its ends and in gaps along it, and buried at its back and foot.
    static func outcrop(
        _ run: [QuarryFlank.Ledge], flank: QuarryFlank, seed: UInt64
    ) -> (vertices: [Vertex], indices: [UInt32]) {
        var r = QuarryRandom(seed: seed &* 0x9E37_79B9 &+ 90_211)
        let bedNormal = beddingNormal
        let top = run[0].top
        let thickness = run[0].top - run[0].bottom
        let random = r.float()
        // The bed's top at (x, y), and the ground.
        func bedTop(_ q: SIMD2<Float>) -> Float {
            (top - bedNormal.x * q.x - bedNormal.y * q.y) / bedNormal.z
        }
        func ground(_ q: SIMD2<Float>) -> Float { flank.groundHeight(q.x, q.y) }
        // The line along the bed through the ledges' contours, and on past each end.
        var points = run.map { SIMD2($0.contour.x, $0.contour.y) }
        var downs = run.map(\.downhill)
        var reaches = run.map(\.run)
        let strike = SIMD2(-downs[0].y, downs[0].x)
        let firstWay = points.count > 1 ? simd_normalize(points[0] - points[1]) : -strike
        let lastWay =
            points.count > 1 ? simd_normalize(points[points.count - 1] - points[points.count - 2]) : strike
        points.insert(points[0] + firstWay * r.float(0.9, 1.9), at: 0)
        points.append(points[points.count - 1] + lastWay * r.float(0.9, 1.9))
        downs.insert(downs[0], at: 0)
        downs.append(downs[downs.count - 1])
        reaches.insert(reaches[0] * 0.8, at: 0)
        reaches.append(reaches[reaches.count - 1] * 0.8)
        var lengths: [Float] = [0]
        for k in 1..<points.count { lengths.append(lengths[k - 1] + simd_distance(points[k], points[k - 1])) }
        let total = lengths[lengths.count - 1]
        guard total > 1 else { return ([], []) }
        // Joints across it every 1.8 to 4.2 m, each opened its own amount.
        var joints: [(at: Float, depth: Float)] = []
        var next = r.float(1.2, 3.2)
        while next < total - 1 {
            joints.append((next, r.float(0.4, 1)))
            next += r.float(1.1, 3.2)
        }
        // Each block between joints its own: standing out or set back, and some with their top
        // lamina gone, so the run reads as jointed blocks of its bed, stepped at each joint.
        let blocks: [(out: Float, drop: Float)] = (0...joints.count).map { _ in
            (r.float(-0.45, 0.35), r.float() < 0.45 ? r.float(0.08, 0.32) : 0)
        }
        var samples = Array(stride(from: Float(0), through: total, by: 0.55))
        if samples[samples.count - 1] < total - 0.15 { samples.append(total) }
        for joint in joints {
            samples += [joint.at - 0.13, joint.at - 0.03, joint.at + 0.03, joint.at + 0.13]
        }
        samples.sort()
        var along: [Float] = []
        for u in samples where along.isEmpty || u - along[along.count - 1] > 0.05 { along.append(u) }
        // The run's own shape: its nose, its tiers and partings, its lean.
        let nose = r.float(0.08, 0.25)
        let partings = (r.float(0.28, 0.45), r.float(0.6, 0.82))
        let standOut = (r.float(-0.55, 0.25), r.float(-0.65, 0.35))
        let notch = (r.float(0.05, 0.32), r.float(0.05, 0.32))
        let lean = r.float(-0.08, 0.12)
        let phase = r.float(0, 100)
        let columns = Self.outcropProfile
        var grid: [SIMD3<Float>] = []
        grid.reserveCapacity(along.count * columns)
        var cracks: [Float] = []
        var segment = 0
        for u in along {
            while segment < points.count - 2 && lengths[segment + 1] < u { segment += 1 }
            let t = max(
                0, min(1, (u - lengths[segment]) / max(lengths[segment + 1] - lengths[segment], 1e-4)))
            let p = points[segment] + (points[segment + 1] - points[segment]) * t
            var d = downs[segment] + (downs[segment + 1] - downs[segment]) * t
            d = simd_length(d) > 1e-3 ? simd_normalize(d) : downs[segment]
            let reach = reaches[segment] + (reaches[segment + 1] - reaches[segment]) * t
            // Where the bed's top meets the ground along the slope here.
            func excess(_ s: Float) -> Float { ground(p + d * s) - bedTop(p + d * s) }
            var s0: Float = 0
            if excess(-2.5) > 0, excess(2.5) < 0 {
                var (a, b): (Float, Float) = (-2.5, 2.5)
                for _ in 0..<20 {
                    let m = (a + b) / 2
                    if excess(m) > 0 { a = m } else { b = m }
                }
                s0 = (a + b) / 2
            }
            let c = p + d * s0
            let w = SIMD3(c.x, c.y, phase)
            func at(_ s: Float) -> SIMD2<Float> { c + d * s }
            func height(_ s: Float) -> Float { bedTop(at(s)) - ground(at(s)) }
            // How much of it stands out here: none at its ends, little in its gaps.
            let ends = min(smoothstep(0, 1.5, u), smoothstep(total, total - 1.5, u))
            let gaps = smoothstep(-0.34, -0.12, QuarryNoise.fbm(w / 5, octaves: 2))
            let stand = ends * gaps
            var joint: Float = 0
            for j in joints { joint = max(joint, j.depth * (1 - smoothstep(0.03, 0.12, abs(u - j.at)))) }
            cracks.append(joint)
            // This block's own step, eased over a few centimetres either side of its joints.
            var step = blocks[0]
            for (k, j) in joints.enumerated() {
                let t = smoothstep(j.at - 0.04, j.at + 0.04, u)
                step.out += (blocks[k + 1].out - blocks[k].out) * t
                step.drop += (blocks[k + 1].drop - blocks[k].drop) * t
            }
            // Its front, wandering, no taller than a little over the bed is thick.
            var front = max(0.6, reach * (1.25 + 0.8 * QuarryNoise.fbm(w / 2.3 + 3, octaves: 2)))
            while front > 0.6 && height(front) > 1.35 * thickness { front -= 0.1 }
            front = max(0.5, front + step.out) * (0.55 + 0.45 * stand) - joint * 0.12
            let rise = max(0.15, height(front))
            let sink = (1 - stand) * (rise + 0.45)
            // A lamina come away from the top's front part.
            let lamina = 0.2 * smoothstep(0.05, 0.3, QuarryNoise.fbm(w / 3.1 + 5, octaves: 2)) + step.drop
            let wobble = (
                0.5 * QuarryNoise.fbm(w / 1.9 + 11, octaves: 2),
                0.55 * QuarryNoise.fbm(w / 1.9 + 19, octaves: 2)
            )
            let noseBottom = bedTop(at(front)) - lamina - nose
            let face = max(0.05, noseBottom - ground(at(front)))
            let fit = min(1, face / 0.7)
            let wander = 0.12 * QuarryNoise.fbm(w / 2.6 + 23, octaves: 2)
            let parting1 = noseBottom - (partings.0 + wander) * face
            let parting2 = noseBottom - (partings.1 + wander) * face
            let front1 = front + (standOut.0 + wobble.0) * fit
            let front2 = front + (standOut.1 + wobble.1) * fit
            let foot = front2 + 0.1
            let profile: [(Float, Float)] = [
                (-1.2, min(bedTop(at(-1.2)), ground(at(-1.2))) - 0.4),
                (-0.35, min(bedTop(at(-0.35)) - 0.06, ground(at(-0.35)) - 0.12)),
                (0.3 * (front - nose), bedTop(at(0.3 * (front - nose))) - 0.03),
                (0.65 * (front - nose), bedTop(at(0.65 * (front - nose))) - lamina * 0.5),
                (front - nose, bedTop(at(front - nose)) - lamina),
                (front - nose * 0.3, bedTop(at(front)) - lamina - nose * 0.3),
                (front, noseBottom),
                (front - lean * partings.0 * face, parting1 + 0.06 * fit),
                (min(front, front1) - notch.0 * fit, parting1 - 0.04 * fit),
                (front1, parting1 - 0.14 * fit),
                (front1 - lean * (partings.1 - partings.0) * face, parting2 + 0.06 * fit),
                (min(front1, front2) - notch.1 * fit, parting2 - 0.04 * fit),
                (front2, parting2 - 0.14 * fit),
                (foot, min(ground(at(foot)) + 0.05, parting2 - 0.2 * fit)),
                (foot + 0.55, ground(at(foot + 0.55)) - 0.45),
            ]
            for (s, z) in profile {
                let q = at(s)
                grid.append(SIMD3(q.x, q.y, z - sink))
            }
        }
        let rows = along.count
        guard rows >= 2 else { return ([], []) }
        func normals(_ g: [SIMD3<Float>]) -> [SIMD3<Float>] {
            var out = [SIMD3<Float>](repeating: .zero, count: g.count)
            for i in 0..<rows {
                for j in 0..<columns {
                    let du = g[min(rows - 1, i + 1) * columns + j] - g[max(0, i - 1) * columns + j]
                    let dv = g[i * columns + min(columns - 1, j + 1)] - g[i * columns + max(0, j - 1)]
                    out[i * columns + j] = simd_cross(du, dv)
                }
            }
            // Outward: the top faces up.
            let middle = out[(rows / 2) * columns + 3]
            let sign: Float = middle.z < 0 ? -1 : 1
            return out.map { simd_length($0) > 1e-8 ? simd_normalize($0) * sign : SIMD3(0, 0, 1) }
        }
        // Weathered: worn unevenly along its own normal, a decimetre or so, finer between.
        var shaped = grid
        let first = normals(grid)
        for k in 0..<grid.count {
            let p = grid[k] + SIMD3(0, 0, phase)
            let wear =
                0.1 * QuarryNoise.fbm(p * 0.6, octaves: 3) + 0.05 * QuarryNoise.fbm(p * 2.6 + 7, octaves: 2)
            shaped[k] = grid[k] + first[k] * wear
        }
        let final = normals(shaped)
        var vertices: [Vertex] = []
        vertices.reserveCapacity(shaped.count)
        for (k, p) in shaped.enumerated() {
            let above = p.z - flank.groundHeight(p.x, p.y)
            vertices.append(
                Vertex(
                    x: p.x, y: p.y, z: p.z, normal: pack(normal: final[k], kind: 1),
                    body: outcropTag(
                        above: above, random: random, part: k % columns, joint: cracks[k / columns])))
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
    /// them along a bed, in `ledgeVertices` and `ledgeIndices`. Returns how many were made.
    mutating func appendLedges(_ flank: QuarryFlank) -> Int {
        let runs = flank.ledgeRuns()
        let ledges = flank.ledges
        var meshes = [(vertices: [Vertex], indices: [UInt32])](repeating: ([], []), count: runs.count)
        meshes.withUnsafeMutableBufferPointer { out in
            nonisolated(unsafe) let output = out
            DispatchQueue.concurrentPerform(iterations: runs.count) { k in
                output[k] = Self.outcrop(runs[k].map { ledges[$0] }, flank: flank, seed: UInt64(k))
            }
        }
        var made = 0
        for mesh in meshes where !mesh.vertices.isEmpty {
            let base = UInt32(ledgeVertices.count)
            ledgeVertices.append(contentsOf: mesh.vertices)
            ledgeIndices.append(contentsOf: mesh.indices.map { $0 + base })
            made += 1
        }
        return made
    }
}

private func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
    let t = max(0, min(1, (x - a) / (b - a)))
    return t * t * (3 - 2 * t)
}
