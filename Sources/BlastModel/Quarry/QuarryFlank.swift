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
                // From the bed's top surface above the ledge, bare rock with a little soil, to its front.
                for b in stride(from: -ledge.run * 0.5 - 2, through: ledge.run * 0.5 + 0.6, by: 0.5) {
                    let q = mid + side * a + ledge.downhill * b
                    if let n = texel(q.x, q.y) { rock[n] = max(rock[n], 0.85) }
                }
                let front = mid + side * a + ledge.downhill * (ledge.run * 0.5 + 1)
                if let n = texel(front.x, front.y) { source[n] = 1 }
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
                // Below the dense rock round the cut, and a little from any steep ground.
                let uphill = SIMD2(position(i, j).0, position(i, j).1) + gradient[n] / max(slope, 1e-3) * 1.5
                if slope > 0.05, paves(uphill.x, uphill.y) { source[n] = max(source[n], 0.9) }
                source[n] = max(source[n], 0.3 * max(0, min(1, (slope - 0.7) / 0.35)))
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
                    let slope = simd_length(gradient[n])
                    let reach = 2 + 6 * max(0, min(1, (slope - 0.3) / 0.4))
                    var amount = frozen[n]
                    for k in 1...14 {
                        let gi = Int(((p.x - low.x) / spacing).rounded())
                        let gj = Int(((p.y - low.y) / spacing).rounded())
                        guard gi >= 0, gj >= 0, gi < columns, gj < rows else { break }
                        let g = gradient[gi + gj * columns]
                        let l = simd_length(g)
                        guard l > 0.05 else { break }
                        p += g / l * spacing
                        let qi = Int(((p.x - low.x) / spacing).rounded())
                        let qj = Int(((p.y - low.y) / spacing).rounded())
                        guard qi >= 0, qj >= 0, qi < columns, qj < rows else { break }
                        amount = max(amount, frozen[qi + qj * columns] * exp(-Float(k) / reach))
                    }
                    let (x, y) = (low.x + Float(i) * spacing, low.y + Float(j) * spacing)
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
            let gentle = 1 - max(0, min(1, (slope - 0.35) / 0.5))
            let patches = max(
                0, min(1, (QuarryNoise.fbm(SIMD3(x / 16, y / 16, 9.1), octaves: 3) + 0.25) / 0.4))
            let open = (1 - max(0, min(1, (scree[n] - 0.15) / 0.45))) * (1 - rock[n])
            grass[n] = gentle * open * (0.35 + 0.65 * patches)
        }
    }

    /// The render-only stones of the scree and the clumps of scrub on the grass, `scale` times
    /// as many as the film draws.
    public func stones(scale: Float = 1) -> [Stone] {
        var out: [Stone] = []
        var r = QuarryRandom(seed: 2_026_111_2)
        func rotation(normal: SIMD3<Float>, yaw: Float, tilt: SIMD2<Float>) -> SIMD4<Float> {
            // About the vertical by `yaw`, leaning a little, then from up to the ground's normal.
            func multiply(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> SIMD4<Float> {
                let (av, bv) = (SIMD3(a.x, a.y, a.z), SIMD3(b.x, b.y, b.z))
                let v = a.w * bv + b.w * av + simd_cross(av, bv)
                return SIMD4(v, a.w * b.w - simd_dot(av, bv))
            }
            let turn = SIMD4<Float>(0, 0, sin(yaw / 2), cos(yaw / 2))
            let lean = SIMD4<Float>(sin(tilt.x / 2), 0, 0, cos(tilt.x / 2))
            let up = SIMD3<Float>(0, 0, 1)
            let axis = simd_cross(up, normal)
            let s = simd_length(axis)
            let toNormal =
                s < 1e-5
                ? SIMD4<Float>(0, 0, 0, 1)
                : SIMD4(axis / s * sin(asin(min(1, s)) / 2), cos(asin(min(1, s)) / 2))
            let q = multiply(toNormal, multiply(lean, turn))
            return q / simd_length(q)
        }
        for j in 1..<(rows - 1) {
            for i in 1..<(columns - 1) {
                let n = i + j * columns
                guard !paving[n], cut[n] < 0.5, rock[n] < 0.5 else { continue }
                let (x, y) = position(i, j)
                let g = gradient[n]
                let normal = simd_normalize(SIMD3(-g.x, -g.y, 1))
                // Stones: about 2.2 a square metre where the scree is full, larger toward its
                // thin toe, where the big ones roll to.
                let wanted = scree[n] * 3.5 * scale
                var k = Int(wanted)
                if r.float() < wanted - Float(k) { k += 1 }
                for _ in 0..<k {
                    let (px, py) = (x + r.float(-0.5, 0.5), y + r.float(-0.5, 0.5))
                    let toe: Float = scree[n] < 0.4 ? 1.6 : 1
                    let size = min(1.1, 0.09 * pow(max(r.float(), 0.003), -0.42) * toe)
                    let z = groundHeight(px, py) + size * 0.22
                    out.append(
                        Stone(
                            posSize: SIMD4(px, py, z, size),
                            rotation: rotation(
                                normal: normal, yaw: r.float(0, 6.283),
                                tilt: SIMD2(r.float(-0.25, 0.25), 0)),
                            look: SIMD4(0, r.float(), r.float(), 0)))
                }
                // Scrub: low shrubs in clumps on the grass, two or three rounded masses each.
                let clumps = max(0, QuarryNoise.fbm(SIMD3(x / 9, y / 9, 4.4), octaves: 2) + 0.1)
                if r.float() < grass[n] * 0.05 * scale * clumps * 4 {
                    let width = r.float(0.5, 1.4)
                    let parts = 2 + Int(r.float() * 1.99)
                    let seed = r.float()
                    for _ in 0..<parts {
                        let (px, py) = (x + r.float(-0.35, 0.35) * width, y + r.float(-0.35, 0.35) * width)
                        let size = width * r.float(0.45, 0.7)
                        guard !paves(px, py) else { continue }
                        out.append(
                            Stone(
                                posSize: SIMD4(px, py, groundHeight(px, py) + size * 0.3, size),
                                rotation: rotation(
                                    normal: SIMD3(0, 0, 1), yaw: r.float(0, 6.283), tilt: SIMD2(0, 0)),
                                look: SIMD4(1, seed, r.float(), 0)))
                    }
                }
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

extension QuarryFace {
    /// The ledges of a ridge cut's flanks as render-only rock: each a slab of its bed standing out
    /// of the slope on its downhill side, its top the bed's top, its sides joints between it and
    /// its neighbours along the bed, its front a little rounded at the top, all weathered.
    mutating func appendLedges(_ flank: QuarryFlank, level: Int) -> Int {
        let ledges = flank.ledges
        let normal = Self.beddingNormal
        // Neighbours along the same bed, for the joints between them.
        var byBed: [Int: [Int]] = [:]
        for (k, ledge) in ledges.enumerated() { byBed[ledge.bed, default: []].append(k) }
        var meshes = [(vertices: [Vertex], indices: [UInt32])](repeating: ([], []), count: ledges.count)
        let frozenByBed = byBed
        meshes.withUnsafeMutableBufferPointer { out in
            nonisolated(unsafe) let output = out
            DispatchQueue.concurrentPerform(iterations: ledges.count) { k in
                let ledge = ledges[k]
                var r = QuarryRandom(seed: UInt64(k) &+ 90_211)
                let down = SIMD3(ledge.downhill.x, ledge.downhill.y, 0)
                let side = SIMD3(-down.y, down.x, 0)
                let middle = ledge.contour + down * (ledge.run * 0.5)
                var poly = QuarryPolyhedron.box(low: middle - 3.2, high: middle + 3.2)
                // Its top and bottom: the bed's, the top a little uneven.
                let tilt = simd_normalize(normal + side * r.float(-0.1, 0.1) + down * r.float(-0.05, 0.12))
                let drop = r.float() < 0.15 ? r.float(0.2, 0.45) : r.float(0.02, 0.12)
                poly.clip(normal: tilt, offset: ledge.top - drop + simd_dot(tilt - normal, middle), kind: 1)
                // Down into the ground below the bed, so it never stands on its underside.
                poly.clip(normal: -normal, offset: -(ledge.bottom - 1.2), kind: 3)
                // Its front, leaning back a little or overhanging, and its back inside the hill.
                let lean = simd_normalize(down + SIMD3(0, 0, r.float(-0.15, 0.4)) + side * r.float(-0.1, 0.1))
                poly.clip(normal: lean, offset: simd_dot(lean, ledge.contour + down * ledge.run), kind: 1)
                poly.clip(normal: -down, offset: simd_dot(-down, ledge.contour - down * 2.2), kind: 3)
                // Joints with its neighbours along the bed, turned a little each.
                var joined = 0
                for other in frozenByBed[ledge.bed] ?? [] where other != k {
                    let q = ledges[other].contour
                    var d = q - ledge.contour
                    d.z = 0
                    let distance = simd_length(d)
                    // Only those along the bed: one across a hollow or a spur cut it to a wedge.
                    guard distance < 5.5, distance > 0.1, abs(simd_dot(d / distance, down)) < 0.55 else {
                        continue
                    }
                    let turn = side * r.float(-0.07, 0.07)
                    let jn = simd_normalize(d / distance + turn)
                    // Tight joints, a few open a few decimetres, so a run reads as one ledge.
                    let gap = r.float() < 0.25 ? r.float(0.12, 0.3) : r.float(0.01, 0.06)
                    poly.clip(
                        normal: jn, offset: simd_dot(jn, (ledge.contour + q) * 0.5) - gap,
                        kind: 3)
                    joined += 1
                }
                // Alone, it ends in joints of its own along the bed.
                if joined < 2 {
                    let half = r.float(0.9, 1.6)
                    poly.clip(normal: side, offset: simd_dot(side, ledge.contour + side * half), kind: 3)
                    poly.clip(normal: -side, offset: simd_dot(-side, ledge.contour - side * half), kind: 3)
                }
                // The front's top edge worn round.
                let edge = simd_normalize(down + normal)
                let corner =
                    ledge.contour + down * ledge.run + normal * (ledge.top - simd_dot(ledge.contour, normal))
                poly.clip(normal: edge, offset: simd_dot(edge, corner) - r.float(0.15, 0.5), kind: 1)
                let (volume, centroid) = poly.volumeAndCentroid
                guard poly.faces.count >= 4, poly.faces.count < 40, volume > 0.6 else { return }
                var vertices: [Vertex] = []
                var indices: [UInt32] = []
                var faceRandom = QuarryRandom(seed: UInt64(k) &+ 7717)
                let tags = poly.faces.map { _ in QuarryRock.faceTag(weathering: 1, random: faceRandom.float())
                }
                Self.tessellate(
                    poly, centre: centroid, origin: .zero, body: 0, level: level, warp: 0, seed: 0,
                    relief: 0.75, rounding: 0.35, tags: tags, vertices: &vertices, indices: &indices)
                output[k] = (vertices, indices)
            }
        }
        var made = 0
        for mesh in meshes where !mesh.vertices.isEmpty {
            let base = UInt32(dressingVertices.count)
            dressingVertices.append(contentsOf: mesh.vertices)
            dressingIndices.append(contentsOf: mesh.indices.map { $0 + base })
            made += 1
        }
        return made
    }
}
